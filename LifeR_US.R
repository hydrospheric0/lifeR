# Using eBird Status & Trends products to map cumulative potential lifers. Note that running this for a big region (like the whole US) or for many species requires *lots* of working memory.

# Ensure user library is on the path (packages installed via install_packages.R)
.libPaths(c(path.expand("~/R/library"), .libPaths()))

# Load packages
library(ggplot2)
library(dplyr)
library(tidyr)
library(stringr)
library(lubridate)
library(purrr)
library(tibble)
library(readr)
library(here)
library(ebirdst)
library(rebird)
library(terra)
library(sf)
library(rnaturalearth)
#library(rnaturalearthhires)
library(tidyterra)
library(gifski)
library(png)

here()

n_cores_logical <- max(1L, parallel::detectCores(logical = TRUE))

# Available RAM (Linux /proc/meminfo, fallback for macOS/other)
get_available_ram_gb <- function() {
  if (file.exists("/proc/meminfo")) {
    lines <- readLines("/proc/meminfo", warn = FALSE)
    avail <- grep("MemAvailable", lines, value = TRUE)
    if (length(avail) > 0) {
      return(as.numeric(sub(".*:\\s*(\\d+)\\s*kB.*", "\\1", avail[1])) / 1e6)
    }
  }
  # macOS fallback
  tryCatch({
    val <- system("sysctl -n hw.memsize 2>/dev/null", intern = TRUE)
    as.numeric(val) / 1e9
  }, error = function(e) NA_real_)
}

# Available disk space on the output volume (GB)
get_available_disk_gb <- function(path = here()) {
  tryCatch({
    df_out <- system(sprintf("df -BG '%s' 2>/dev/null | tail -1", path), intern = TRUE)
    as.numeric(gsub("G", "", strsplit(trimws(df_out), "\\s+")[[1]][4]))
  }, error = function(e) NA_real_)
}

# Process RSS in GB (Linux only)
get_process_rss_gb <- function() {
  tryCatch({
    lines <- readLines("/proc/self/status", warn = FALSE)
    val   <- grep("^VmRSS:", lines, value = TRUE)
    if (length(val) == 0L) return(NA_real_)
    as.numeric(gsub("[^0-9]", "", val[1L])) / 1e6
  }, error = function(e) NA_real_)
}

# Guard: abort if RSS exceeds a safe fraction of available memory
check_memory_pressure <- function(label = "", max_fraction = 0.85) {
  rss_gb  <- get_process_rss_gb()
  avail   <- get_available_ram_gb()
  if (is.na(rss_gb) || is.na(avail)) return(invisible(NULL))  # non-Linux: skip
  total_gb <- as.numeric(sub(".*:\\s*(\\d+)\\s*kB.*", "\\1",
    grep("MemTotal", readLines("/proc/meminfo", warn = FALSE), value = TRUE)[1])) / 1e6
  if (rss_gb > total_gb * max_fraction) {
    stop(sprintf(
      "Memory safety limit reached at [%s]: process using %.1f GB / %.1f GB total (%.0f%%).\n  Free up memory or use a coarser resolution.",
      label, rss_gb, total_gb, rss_gb / total_gb * 100))
  }
  invisible(rss_gb)
}

# Guard: abort if disk space is too low for output
check_disk_space <- function(min_gb = 2, path = here()) {
  avail <- get_available_disk_gb(path)
  if (!is.na(avail) && avail < min_gb) {
    stop(sprintf(
      "Insufficient disk space: %.1f GB available, need at least %d GB.\n  Free disk space or change output directory.",
      avail, min_gb))
  }
  invisible(avail)
}

ram_gb  <- get_available_ram_gb()
disk_gb <- get_available_disk_gb()
message(sprintf("[hardware] %d logical cores | %.0f GB RAM available | %.0f GB disk free",
  n_cores_logical,
  ifelse(is.na(ram_gb), -1, ram_gb),
  ifelse(is.na(disk_gb), -1, disk_gb)))

# Store S&T rasters in the project folder (data/ebirdst/) rather than the
# hidden R per-user directory.  Python scripts and R scripts share this path.
# Must be set before any ebirdst function is called.
ebirdst_cache_dir <- here("data", "ebirdst")
dir.create(ebirdst_cache_dir, recursive = TRUE, showWarnings = FALSE)
Sys.setenv(EBIRDST_DATA_DIR = ebirdst_cache_dir)

# Set parameters
region <- "US" # must use eBird country or state-level regional codes. Examples: "US" (United States), "US-NY" (New York State, USA), "MX-TAM" (Tamaulipas, Mexico). Find state codes in the URL on eBird's regional pages or in Data/ebird_states.rda. Note that "US" is by default modified to only include continental US.
user <- "Bart Wickel" # e.g., "Sam Safran" - this is typically your full name or username. Controls how you are identified in the map caption and is used in output file structure, so can't be empty.
user_short <- NA # e.g., "Sam" - optional to customize name in legend. Typically a first name. Leave this defined as NA and it will read "My potential lifers." Haven't figured out how to center name over legend for longer names, so this may not look great.
your_ebird_dat <- here("MyEBirdData.csv") # path to where your personal eBird data are stored
needs_list_to_use <- "regional" # set to "global" if you want to map true lifers (species you haven't observed anywhere); set to "regional" if you'd like to map needs for the specified region.
resolution <- "3km" # "3km", "9km", or "27km"
if (nchar(Sys.getenv("LIFR_RESOLUTION")) > 0) resolution <- Sys.getenv("LIFR_RESOLUTION")
annotate <- FALSE # If set to TRUE, needed species are labeled on the map at the location where they have the highest abundance each week. This makes the animated map look pretty bad (so it gets output at a much slower frame rate to compensate), but may be of interest to some. the "dark" color theme works best for this.
sp_annotation_threshold <- 0.01 # this controls how many species get annotated on the map if annotate is set to TRUE. A species will only be annotated if the grid cell where it is most abundant contains more than the set proportion of the total population. Lower values mean more species get annotated (though the marked locations will hold smaller and smaller percentages of the total population, which may make for some odd placements for widely dispersed species). Set to 0 to annotate all needed species. A value of 0.01 seems to keep things under control if there are many needed species. Note that this is different from the possible_occurrence_threshold, which sets the occurrence probability a species must exceed in a cell to be counted as a potential lifer.
theme <- "dark" # accepted values "light_blue", "dark", "light_green"

# API keys  -  loaded from config_local.R (gitignored, never committed).
# To set up your own keys:
#   1. eBird Status & Trends key: request at https://ebird.org/st/request
#   2. eBird API key: request at https://ebird.org/api/keygen
# Copy config_local.R.example to config_local.R and fill in your keys.
if (!file.exists(here("config_local.R"))) {
  stop("config_local.R not found. Copy config_local.R.example to config_local.R and add your API keys. See https://ebird.org/st/request and https://ebird.org/api/keygen")
}
source(here("config_local.R"))
set_ebirdst_access_key(ebirdst_key, overwrite = TRUE)

# Make directories to save outputs
user_file <- tolower(str_replace(user, " ", ""))
mainDir <- here("Results")
dir.create(file.path(mainDir, user_file, region, needs_list_to_use, resolution), recursive = TRUE, showWarnings = TRUE)
outputDir <- here("Results", user_file, region, needs_list_to_use, resolution)
subdirectories <- c("Weekly_maps", "Animated_map")
lapply(file.path(mainDir, user_file, region, needs_list_to_use, resolution, subdirectories), function(x) if (!dir.exists(x)) dir.create(x))

# Save region info in df for later use
region_info <- data.frame(region = region) %>%
  separate(region, into = c("country", "state"), sep = "-", remove = FALSE, fill = "right")

# Get full eBird taxonomy
sp_all <- rebird::ebirdtaxonomy("species") %>%
  rename(Common.Name = comName)

# User global life list
sp_user_all <- read.csv(your_ebird_dat) %>%
  select(Common.Name) %>%
  unique() %>%
  left_join(sp_all) %>%
  filter(category == "species")

# User regional list
sp_user_region <- read.csv(your_ebird_dat) %>%
  separate(State.Province, into = c("country", "state"), sep = "-", remove = FALSE) %>%
  filter(country == region_info$country)

if (!is.na(region_info$state)) {
  sp_user_region <- filter(sp_user_region, State.Province == region)
}

sp_user_region <- sp_user_region %>%
  select(Common.Name) %>%
  unique() %>%
  left_join(sp_all) %>%
  filter(category == "species")

# All species observed in region (by anyone)
sp_region <- ebirdregionspecies(region, key = ebird_api_key) %>%
  left_join(sp_all) %>%
  drop_na(Common.Name)
message(sprintf("[1/4] Species in %s regional checklist (eBird): %d", region, nrow(sp_region)))
message(sprintf("      User species seen in %s (%s list): %d",
  region, needs_list_to_use,
  if (needs_list_to_use == "global") nrow(sp_user_all) else nrow(sp_user_region)))

# User needs in region
if (needs_list_to_use == "global") {
  sp_needed <- setdiff(sp_region$Common.Name, sp_user_all$Common.Name) %>%
    as.data.frame() %>%
    rename(Common.Name = ".") %>%
    left_join(sp_all)
}

if (needs_list_to_use == "regional") {
  sp_needed <- setdiff(sp_region$Common.Name, sp_user_region$Common.Name) %>%
    as.data.frame() %>%
    rename(Common.Name = ".") %>%
    left_join(sp_all)
}
message(sprintf("[2/4] Needed species (%s): %d", needs_list_to_use, nrow(sp_needed)))

# All species with ebst data
sp_ebst <- ebirdst_runs %>%
  rename(Common.Name = common_name)

# All needed species with ebst data.
# Primary join on Common.Name (robust across taxonomy versions).
# Supplementary code join catches the rare cases where names differ between
# rebird and ebirdst (e.g. "Common Hoopoe" in rebird vs "Eurasian Hoopoe"
# in ebirdst_runs). The union then deduplicates by species_code.
sp_ebst_for_run <- bind_rows(
    inner_join(sp_ebst, sp_needed, by = "Common.Name"),
    inner_join(
      sp_ebst,
      sp_needed %>% filter(!is.na(speciesCode)) %>% distinct(speciesCode) %>%
        rename(species_code = speciesCode),
      by = "species_code"
    )
  ) %>%
  distinct(species_code, .keep_all = TRUE) %>%
  filter(!species_code %in% c("laugul", "rocpig", "compea", "yebsap-example"))
message(sprintf("[3/4] Needed species with eBird S&T model: %d  (no model for %d needed species)",
  nrow(sp_ebst_for_run), nrow(sp_needed) - nrow(sp_ebst_for_run)))

# Download occurrence data for needed sp. If annotating we also need species population proportion rasters.
# Skip species whose local .tif already exists AND is readable to avoid unnecessary network calls.
ebirdst_cache <- ebirdst_data_dir()
tif_paths <- file.path(ebirdst_cache, "2023", sp_ebst_for_run$species_code, "weekly",
  paste0(sp_ebst_for_run$species_code, "_occurrence_median_", resolution, "_2023.tif"))
is_valid_tif <- function(path) {
  if (!file.exists(path)) return(FALSE)
  tryCatch({ terra::rast(path); TRUE }, error = function(e) {
    message("Corrupt/unreadable cache file, will re-download: ", basename(path))
    file.remove(path)
    FALSE
  })
}
needs_download <- sp_ebst_for_run$species_code[!vapply(tif_paths, is_valid_tif, logical(1))]
if (length(needs_download) > 0) {
  sapply(needs_download, ebirdst_download_status,
         download_abundance = TRUE, download_occurrence = TRUE,
         pattern =
           if (annotate == TRUE) {
             paste0("occurrence_median_", resolution, "|", "proportion-population_median_", resolution)
           } else {
             paste0("occurrence_median_", resolution)
           },
         USE.NAMES = FALSE
  )
} else {
  message("All species data already cached, skipping download.")
}

# Minimum RAM needed for streaming approach: ~1 species raster at a time.
# 3km single species ~200 MB; 2 GB headroom is sufficient at any resolution.
mem_required_gb <- 2
ram_now <- get_available_ram_gb()
if (!is.na(ram_now)) {
  if (ram_now < mem_required_gb) {
    stop(sprintf("Insufficient RAM: %.1f GB available, need at least %d GB.", ram_now, mem_required_gb))
  }
  message(sprintf("[RAM check] %.0f GB available  -  streaming accumulation, peak ~1 species raster at a time.",
    ram_now))
} else {
  message("[RAM check] Could not detect available memory  -  proceeding with caution.")
}

# Disk space guard: need at least 2 GB for outputs
check_disk_space(min_gb = 2)

# Safe raster loader  -  logs a warning and returns NULL on failure instead of halting.
load_raster_safe <- function(sp_code, ...) {
  tryCatch(
    load_raster(sp_code, ...),
    error = function(e) {
      message("Skipping ", sp_code, "  -  could not load raster: ", conditionMessage(e))
      NULL
    }
  )
}

# Vector data for region (country/state polygons)
# Cache the NaturalEarth download locally to avoid re-downloading on each run.
ne_cache_path <- here("ne_admin1_large.rds")
if (file.exists(ne_cache_path)) {
  study_area <- readRDS(ne_cache_path)
} else {
  study_area <- ne_download("large", "admin_1_states_provinces", "cultural", returnclass = "sf")
  saveRDS(study_area, ne_cache_path)
}
study_area <- study_area[study_area$adm0_a3 == "USA", ]
if (!is.na(region_info$state)) {
  study_area <- study_area %>% filter(iso_3166_2 == .env$region)
}
if (!region %in% c("US-HI", "US-AK")) {
  study_area <- filter(study_area, !iso_3166_2 %in% c("US-HI", "US-AK"))
} # if region is US only mapping continental US

# Get CRS from the first cached tif without loading a full raster into memory
study_area <- st_transform(study_area, terra::crs(terra::rast(tif_paths[1])))

# Define occurrence threshold for when a species is "possible"
possible_occurrence_threshold <- 0.01 # minimum occurrence probability for a species to be considered "possible" at a given time/location.

# Size terra dynamically to whatever is actually available at runtime.
mem_total_kb <- as.numeric(system("awk '/MemTotal/{print $2}' /proc/meminfo", intern = TRUE))
mem_avail_kb <- as.numeric(system("awk '/MemAvailable/{print $2}' /proc/meminfo", intern = TRUE))
memfrac_safe  <- min(0.85, (mem_avail_kb / mem_total_kb) * 0.80)
nc <- max(1L, parallel::detectCores() - 2L)
terra::terraOptions(memfrac = memfrac_safe, threads = nc, progress = 0L)
message(sprintf("terra: memfrac=%.2f (%.1f GB of %.1f GB total), threads=%d",
  memfrac_safe, memfrac_safe * mem_total_kb / 1e6, mem_total_kb / 1e6, nc))

# ---------------------------------------------------------------------------
# Accumulation strategy
#   1. crop() to fixed extent (no polygon rasterization per species call)
#   2. terra::values() -> subset inside cells via !outside_mask (logical, fast)
#      -> free full float64 grid immediately (~664 MB at 3km)
#   3. Write uint8 .bin cache as side effect; reruns skip TIF entirely
#   4. Write .skip marker for below-threshold species; reruns skip those too
#      .skip files are invalidated automatically when threshold changes
#   5. Accumulate inside-only (n_inside x 52) -- no full-grid scatter per species
#   6. Wrap-back: one scatter (inside -> full grid) per week at the end
# ---------------------------------------------------------------------------

# Convert study_area to a terra SpatVector once; reused for the probe.
# (Re-created each chunk in the loop below to guard against gc() invalidation.)
study_area_vect <- terra::vect(study_area)

# Probe: load + crop the first valid species to get actual cropped dimensions.
probe_idx   <- which(vapply(tif_paths, file.exists, logical(1L)))[1L]
probe_code  <- sp_ebst_for_run$species_code[probe_idx]
r_probe <- tryCatch({
  rr <- load_raster_safe(probe_code, product = "occurrence", period = "weekly",
                         metric = "median", resolution = resolution)
  if (!is.null(rr)) terra::crop(rr, study_area_vect) else NULL
}, error = function(e) NULL)

n_cells_probe <- if (!is.null(r_probe)) terra::ncell(r_probe) else NA_integer_
n_weeks        <- if (!is.null(r_probe)) terra::nlyr(r_probe)  else 52L
sp_size_gb     <- if (!is.null(r_probe)) {
  (n_cells_probe * n_weeks * 4L) / 1e9   # float32
} else 0.5

if (!is.null(r_probe)) {
  message(sprintf("  Cropped species raster: %d cells x %d weeks = %.0f MB (float32)",
    n_cells_probe, n_weeks, sp_size_gb * 1000))
}

# Keep the probe as the spatial template for wrapping results back into a raster
# at the end.  Set all values to 0 so we have a clean geometry shell.
raster_template <- r_probe
if (!is.null(raster_template)) terra::values(raster_template) <- 0L
rm(r_probe)

# Pre-compute crop extent and outside-boundary mask ONCE.
# terra::mask() rasterizes the boundary polygon onto the raster grid each call.
# By doing it once here and applying as a logical vector in the loop we avoid
# ~500 polygon rasterization calls -- the dominant per-species overhead.
fixed_ext    <- if (!is.null(raster_template)) terra::ext(raster_template) else NULL
outside_mask <- NULL
if (!is.null(raster_template)) {
  r_tmp        <- terra::mask(raster_template[[1L]], study_area_vect)
  outside_mask <- is.na(terra::values(r_tmp)[, 1L])
  rm(r_tmp)
  message(sprintf("  Boundary mask: %d inside / %d total cells (%.0f%% inside boundary)",
    sum(!outside_mask), length(outside_mask), 100 * mean(!outside_mask)))
}

# Flat integer index of inside-boundary cells -- used to scatter/gather the cache.
inside_idx <- if (!is.null(outside_mask)) which(!outside_mask) else NULL

# Week dates from the probe raster layer names (needed even when every species
# is a cache hit and names(r) is never called inside the loop).
week_dates_probe <- if (!is.null(raster_template)) names(raster_template) else NULL

# Threshold in uint8 space (precomputed once; avoids per-species float multiply).
thresh_uint8 <- as.integer(round(possible_occurrence_threshold * 255))

# ---------------------------------------------------------------------------
# R species cache  (uint8 binary, built transparently on first run)
#
# Format: one <code>.bin per species  -  raw uint8 flat vector, row-major,
#   (n_inside x n_weeks), occurrence scaled to 0-255 (0.0-1.0).
# Meta: _meta.rds stores inside_idx + geometry fingerprint for validity.
#
# First run : reads TIF (332 MB) + writes 46 MB cache.  ~15% I/O overhead.
# Run 2+    : reads 46 MB cache only.  ~7x less I/O than float32 TIF.
# Cache is NOT annotation-aware -- annotation always uses the TIF slow path.
# .skip files are invalidated automatically when the threshold changes.
# ---------------------------------------------------------------------------
r_sp_cache_dir       <- here("data", "r_sp_cache", region, resolution, "2023")
r_sp_cache_meta_path <- file.path(r_sp_cache_dir, "_meta.rds")
dir.create(r_sp_cache_dir, recursive = TRUE, showWarnings = FALSE)
r_sp_cache_valid <- FALSE
if (!is.null(inside_idx)) {
  needs_new_meta <- FALSE
  if (!file.exists(r_sp_cache_meta_path)) {
    needs_new_meta <- TRUE
    message(sprintf("  R sp cache: new at %s  (will populate this run)", r_sp_cache_dir))
  } else {
    meta_chk <- tryCatch(readRDS(r_sp_cache_meta_path), error = function(e) NULL)
    if (is.null(meta_chk) ||
        meta_chk$n_cells != length(outside_mask) ||
        meta_chk$n_weeks != n_weeks) {
      message("  R sp cache: geometry mismatch -- clearing and rebuilding")
      invisible(file.remove(list.files(r_sp_cache_dir, full.names = TRUE)))
      needs_new_meta <- TRUE
    } else if (!isTRUE(all.equal(meta_chk$threshold, possible_occurrence_threshold))) {
      # Threshold changed: .bin files are still valid (raw uint8 data),
      # but .skip files are stale -- a species below the old threshold may
      # now exceed the new one.  Delete only .skip files and re-evaluate.
      skip_files <- list.files(r_sp_cache_dir, pattern = "\\.skip$", full.names = TRUE)
      if (length(skip_files) > 0) invisible(file.remove(skip_files))
      message(sprintf(
        "  R sp cache: threshold changed (%.4f -> %.4f) -- cleared %d stale .skip files",
        meta_chk$threshold, possible_occurrence_threshold, length(skip_files)))
      needs_new_meta <- TRUE
      r_sp_cache_valid <- TRUE
    } else {
      r_sp_cache_valid <- TRUE
      n_bin  <- length(list.files(r_sp_cache_dir, pattern = "\\.bin$"))
      n_skip <- length(list.files(r_sp_cache_dir, pattern = "\\.skip$"))
      message(sprintf(
        "  R sp cache: %d bin + %d skip / %d species  (%d uncached)",
        n_bin, n_skip, nrow(sp_ebst_for_run),
        nrow(sp_ebst_for_run) - n_bin - n_skip))
    }
  }
  if (needs_new_meta) {
    saveRDS(list(inside_idx = inside_idx, n_cells = length(outside_mask),
                 n_weeks = n_weeks, week_dates = week_dates_probe,
                 threshold = possible_occurrence_threshold),
            r_sp_cache_meta_path)
    if (!r_sp_cache_valid) r_sp_cache_valid <- TRUE  # cache is ready to populate this run
  }
}

# gc() cadence: every ~gc_every species.  Larger = fewer gc() calls = faster;
# smaller = lower peak RAM.  ~50 is a good balance at any resolution.
avail_gb_now <- tryCatch(
  as.numeric(system("awk '/MemAvailable/{print $2}' /proc/meminfo", intern = TRUE)) / 1e6,
  error = function(e) NA_real_)
gc_every <- if (!is.na(avail_gb_now)) {
  max(10L, min(100L, as.integer(avail_gb_now * 0.40 / (sp_size_gb * 2))))
} else 50L
message(sprintf("  gc() every %d species  (%.0f GB free)",
  gc_every, ifelse(is.na(avail_gb_now), -1, avail_gb_now)))

# Accumulator is inside-only (n_inside x n_weeks) -- no full-grid scatter per species.
# Lazy-init on first valid species.
accum          <- NULL
week_dates     <- week_dates_probe   # from probe; overwritten on first TIF slow path
sp_codes_in_region <- character(0)
if (annotate == TRUE) polys_list <- list()

message(sprintf("Accumulating %d species at %s (matrix mode)...",
  nrow(sp_ebst_for_run), resolution))
t_accum <- proc.time()["elapsed"]

for (sp_idx in seq_len(nrow(sp_ebst_for_run))) {
  # Recreate SpatVector periodically to guard against terra gc() invalidation.
  if (sp_idx %% gc_every == 1L) study_area_vect <- terra::vect(study_area)

  sp_code <- sp_ebst_for_run$species_code[sp_idx]

  sp_cache_path <- if (r_sp_cache_valid && annotate == FALSE)
    file.path(r_sp_cache_dir, paste0(sp_code, ".bin")) else NULL

  # Skip marker: this species was confirmed below threshold in a prior run.
  if (!is.null(sp_cache_path) && file.exists(paste0(sp_cache_path, ".skip"))) next

  if (!is.null(sp_cache_path) && file.exists(sp_cache_path)) {
    # ---- Fast path: 46 MB uint8 cache read vs 332 MB float32 TIF ----
    # readBin(integer(), size=1) decodes bytes directly to int in one allocation,
    # avoiding the intermediate raw vector that as.integer(readBin(raw())) would need.
    n_elems  <- length(inside_idx) * n_weeks
    int_vals <- tryCatch(
      readBin(sp_cache_path, integer(), n = n_elems, size = 1L, signed = FALSE),
      error = function(e) { message("  Cache read error: ", sp_code); NULL })
    cache_ok <- !is.null(int_vals) && length(int_vals) == n_elems
    if (!cache_ok) {
      if (!is.null(int_vals)) file.remove(sp_cache_path)  # remove corrupt file
      rm(int_vals)
    } else {
      m_inside <- matrix(int_vals, nrow = length(inside_idx), ncol = n_weeks)
      rm(int_vals)
      # Cache is only written for passing-threshold species; .skip handles the rest.
      # Skipping max() over 104 M cells per species is the main cached-run speedup.

      sp_codes_in_region <- c(sp_codes_in_region, sp_code)
      ind_inside <- m_inside > thresh_uint8  # logical; integer coercion on +
      rm(m_inside)
      if (is.null(accum)) accum <- matrix(0L, nrow = length(inside_idx), ncol = n_weeks)
      accum <- accum + ind_inside
      rm(ind_inside)
      if (sp_idx %% gc_every == 0L) gc()
      next
    }
  }

  # ---- Slow path: read float32 TIF; write uint8 cache for next run ----
  r <- load_raster_safe(sp_code, product = "occurrence", period = "weekly",
                        metric = "median", resolution = resolution)
  if (is.null(r)) next

  r <- terra::crop(r, fixed_ext)

  # terra::values() inflates float32 -> float64 (~664 MB at 3km).
  # Subset inside cells with logical mask (fast bulk copy vs integer index);
  # free the full grid immediately before any further allocations.
  vals_full <- terra::values(r)
  rm(r)
  inside_float <- vals_full[!outside_mask, , drop = FALSE]  # n_inside x n_weeks
  rm(vals_full)
  inside_float[is.na(inside_float)] <- 0

  if (max(inside_float) <= possible_occurrence_threshold) {
    rm(inside_float)
    # Write .skip marker so future runs bypass this TIF entirely.
    if (!is.null(sp_cache_path))
      file.create(paste0(sp_cache_path, ".skip"), showWarnings = FALSE)
    next
  }

  sp_codes_in_region <- c(sp_codes_in_region, sp_code)

  # Write uint8 cache: 2 allocations (×255 + as.integer), not 5.
  # Only for passing species; pmax not needed (occurrence >= 0 by definition).
  if (!is.null(sp_cache_path) && !file.exists(sp_cache_path))
    writeBin(as.raw(pmin(255L, as.integer(inside_float * 255))), sp_cache_path)

  # Accumulate inside-only -- no full-grid scatter per species.
  ind_inside <- inside_float > possible_occurrence_threshold  # logical; integer coercion on +
  rm(inside_float)

  if (is.null(accum)) accum <- matrix(0L, nrow = length(inside_idx), ncol = n_weeks)
  accum <- accum + ind_inside
  rm(ind_inside)

  # gc() every gc_every species to keep peak RAM bounded
  if (sp_idx %% gc_every == 0L) gc()

  # Annotation: per-species  -  unchanged
  if (annotate == TRUE) {
    p <- tryCatch(
      load_raster(sp_code, product = "proportion-population", period = "weekly",
                  metric = "median", resolution = resolution),
      error = function(e) NULL)
    if (!is.null(p)) {
      p <- terra::crop(p, fixed_ext)
      if (!is.null(outside_mask)) {
        pv <- terra::values(p); pv[outside_mask, ] <- NA_real_; terra::values(p) <- pv; rm(pv)
      }
      if (max(terra::minmax(p), na.rm = TRUE) > possible_occurrence_threshold) {
        max_val_cells <- terra::where.max(p, values = TRUE, list = FALSE) %>%
          as.data.frame() %>%
          dplyr::filter(value > 0)
        if (nrow(max_val_cells) > 0) {
          max_val_coords <- terra::xyFromCell(p, max_val_cells[, 2])
          polys_list[[sp_code]] <- sf::st_as_sf(
            data.frame(
              x   = max_val_coords[, 1],
              y   = max_val_coords[, 2],
              week = max_val_cells[, 1],
              sp  = sp_code,
              max_weekly_proportion = max_val_cells[, 3]),
            coords = c("x", "y"), crs = terra::crs(p))
        }
      }
      rm(p); gc()
    }
  }
}
gc()
message(sprintf("+ accumulation: %.1fs  [RAM] rss=%.1fGB avail=%.1fGB",
  proc.time()["elapsed"] - t_accum, get_process_rss_gb(), get_available_ram_gb()))

# Wrap the 52-column accumulator back into one SpatRaster per week.
# Each week is kept as a separate single-layer raster so terra never spills
# the full 52-layer stack to disk (which would make render reads slow).
if (is.null(accum) || is.null(raster_template)) {
  stop("Accumulation produced no valid rasters - check that species tifs exist and region/resolution are correct.")
}
template_single <- raster_template[[1L]]
n_cells_full    <- terra::ncell(template_single)
possible_lifers <- vector("list", n_weeks)
for (wk in seq_len(n_weeks)) {
  r_wk <- template_single
  v <- numeric(n_cells_full)
  v[inside_idx] <- accum[, wk]
  terra::values(r_wk) <- v
  names(r_wk) <- week_dates[wk]
  possible_lifers[[wk]] <- r_wk
}
rm(template_single, n_cells_full, v, accum, raster_template)

# New version of species data frame with only species meeting occ threshold
sp_ebst_for_run_in_region <- sp_ebst_for_run %>%
  dplyr::filter(species_code %in% sp_codes_in_region)
message(sprintf("[4/4] Species exceeding %.0f%% occurrence threshold in %s: %d  (dropped %d below threshold)",
  possible_occurrence_threshold * 100, region,
  length(sp_codes_in_region), nrow(sp_ebst_for_run) - length(sp_codes_in_region)))

if (annotate == TRUE) {
  polys <- do.call("rbind", polys_list) %>%
    dplyr::left_join(sp_ebst_for_run_in_region, by = c("sp" = "species_code"))
  polys <- sf::st_filter(polys, study_area)
  rm(polys_list); gc()
}

# Reproject, mask, and trim as a single 52-layer stack.
# 52 serial project() calls have per-call terra overhead (grid recomputation,
# PROJ initialisation, etc.) that dominates at fine resolutions.  Stacking the
# layers first reduces that to one call each for project/mask/trim, then split()
# returns the list of single-layer rasters the render loop expects.
# Stack size at 3km: ~114 MB (integer) -- well within terra memfrac; no disk spill.
message("Reprojecting 52 weekly rasters...")
t_reproj <- proc.time()["elapsed"]
study_area_5070 <- terra::project(study_area_vect, y = "epsg:5070")
stack_8857 <- terra::rast(possible_lifers)
rm(possible_lifers)
stack_5070 <- terra::project(stack_8857, y = "epsg:5070", method = "near")
rm(stack_8857)
stack_5070 <- terra::mask(stack_5070, mask = study_area_5070)
stack_5070 <- terra::trim(stack_5070)
possible_lifers <- lapply(seq_len(terra::nlyr(stack_5070)), function(i) stack_5070[[i]])
rm(stack_5070)
message(sprintf("+ reprojection: %.1fs  [RAM] rss=%.1fGB avail=%.1fGB",
  proc.time()["elapsed"] - t_reproj, get_process_rss_gb(), get_available_ram_gb()))
gc()

# polys was already finalised above

# Generate weekly maps
# Set theme colors
if (theme == "light_blue") {
  bg_color <- "azure2"
  font_color_light <- "grey50"
  font_color_dark <- "grey20"
}
if (theme == "light_green") {
  bg_color <- "#EBF5DF"
  font_color_light <- "#9CC185"
  font_color_dark <- "#141B0E"
}
if (theme == "dark") {
  bg_color <- viridisLite::turbo(1)
  font_color_light <- "white"
  font_color_dark <- "grey90"
}

# Pre-aggregate rasters to display resolution once before the render loop.
# tidyterra::geom_spatraster defaults to maxcell=5e5; without this it resamples
# independently on every one of the 52 frames.  One aggregate call here eliminates
# 52 per-frame terra resample ops and removes the "[SpatRaster] resampled to N cells"
# messages.  fun="max" preserves the highest lifer-count value in each merged cell
# so genuine hotspot peaks are not blurred.
display_maxcells <- 5e5L
n_cells_display  <- terra::ncell(possible_lifers[[1L]])
if (n_cells_display > display_maxcells) {
  agg_fact <- max(1L, floor(sqrt(n_cells_display / display_maxcells)))
  message(sprintf("  Pre-aggregating 52 rasters by factor %d for display (%d -> ~%d cells)...",
    agg_fact, n_cells_display, terra::ncell(terra::aggregate(possible_lifers[[1L]], fact = agg_fact))))
  possible_lifers <- lapply(possible_lifers, terra::aggregate, fact = agg_fact, fun = "max")
  gc()
}

# Get maximum lifer count (across all cells and weeks). Needed for legend.
max_val_possible <- lapply(possible_lifers, minmax) %>%
  sapply(max) %>%
  max()

# Pre-build all static ggplot components once — rebuilt 52x in the original loop.
legend_breaks     <- c(pretty(1:max_val_possible))
labels_fn <- function(x) {
  lab <- " species"
  x_last <- as.character(paste0(tail(x, n = 1), lab))
  x_last_pad <- str_pad(x_last, nchar(x_last) * 2 + nchar(tail(x, n = 1)) + 1, side = "left")
  c(x[1:(length(x) - 1)], x_last_pad)
}
legend_labels     <- labels_fn(legend_breaks)
legend_breaks_last <- last(legend_breaks)
legend_lab <- paste0(ifelse(is.na(user_short), "My", paste0(user_short, "'s")),
                     if (needs_list_to_use == "global") " potential lifers" else " regional needs")
caption_text <- paste0(
  "Lifers mapped for: ", user, ". \nLifer analysis and map by Sam Safran.\n\n",
  "A candidate lifer is considered `possible` if the species has a >",
  round(possible_occurrence_threshold * 100, 0),
  "% modeled occurrence probability at the location and date.\n\n",
  "Data from 2023 eBird Status & Trends products (https://ebird.org/science/status-and-trends): ",
  "Fink, D., T. Auer, A. Johnston, M. Strimas-Mackey, S. Ligocki, O. Robinson,\n",
  " W. Hochachka, L. Jaromczyk, C. Crowley, K. Dunham, A. Stillman, C. Davis, M. Stokowski, ",
  "A. Rodewald, V. Ruiz-Gutierrez, C. Wood. 2024. eBird Status and Trends, Data Version:\n",
  "2023; Released: 2025. Cornell Lab of Ornithology, Ithaca, New York. ",
  "https://doi.org/10.2173/ebirdst.2022. This material uses data from the eBird Status and Trends\n",
  " Project at the Cornell Lab of Ornithology, eBird.org. Any opinions, findings, and conclusions ",
  "or recommendations expressed in this material are those of the author(s)\n",
  "and do not necessarily reflect the views of the Cornell Lab of Ornithology.")

base_scale <- scale_fill_viridis_c(
  limits = c(0, legend_breaks_last), na.value = "transparent", option = "turbo",
  guide  = guide_colorbar(title.position = "top", title.hjust = .5),
  breaks = legend_breaks,
  labels = legend_labels)

base_theme <- ggthemes::theme_fivethirtyeight() +
  theme(
    rect             = element_rect(linetype = 1, colour = NA),
    plot.title       = element_text(size = 10, hjust = 0, face = "plain",
                                    color = font_color_light, margin = margin(0, 0, 15, 0)),
    plot.tag         = element_text(size = 10, face = "bold", color = font_color_dark),
    axis.title.y     = element_blank(),
    axis.title.x     = element_blank(),
    axis.text.x      = element_blank(),
    axis.text.y      = element_blank(),
    plot.caption     = element_text(size = 5, hjust = 0, color = font_color_light),
    plot.background  = element_rect(fill = bg_color),
    panel.background = element_rect(fill = bg_color),
    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank(),
    panel.border     = element_blank(),
    legend.title     = element_text(size = 10, face = "bold", color = font_color_dark),
    legend.text      = element_text(color = font_color_dark),
    legend.title.align    = 1,
    legend.direction      = "horizontal",
    legend.key.width      = unit(.32, "inch"),
    legend.key.height     = unit(.06, "inch"),
    legend.position       = c(.768, 1.03),
    plot.tag.position     = c(0.05, .94),
    legend.background     = element_rect(colour = NA, fill = NA, linetype = "solid"),
    legend.text.align     = 0.5)

# Generate and save map for each week.
message(sprintf("Rendering %d weekly maps...", length(possible_lifers)))
t_render <- proc.time()["elapsed"]
check_disk_space(min_gb = 1)
for (i in seq_along(possible_lifers)) {
  date     <- week_dates[i]
  png_path <- here(outputDir, "Weekly_maps", paste0(region, "_", date, ".png"))
  if (file.exists(png_path)) next
  week_plot <- ggplot() +
    geom_spatraster(data = possible_lifers[[i]], maxcell = Inf) +
    geom_sf(data = study_area, fill = NA, color = alpha("white", .3)) +
    {
      if (annotate == TRUE) {
        ggsflabel::geom_sf_text_repel(
          data = polys %>% filter(week == i & max_weekly_proportion > sp_annotation_threshold),
          aes(label = Common.Name),
          nudge_x = 4, nudge_y = 8, seed = 10,
          color = "white", size = 2.5, alpha = .8)
      }
    } +
    {
      if (annotate == TRUE) {
        geom_sf(
          data = polys %>% filter(week == i & max_weekly_proportion > sp_annotation_threshold),
          color = "white", shape = 1, size = 1.5)
      }
    } +
    base_scale +
    labs(
      title   = "Lifer finder: mapping the birds you've yet to meet",
      tag     = paste0(format(ymd(date), format = "%b-%d")),
      fill    = legend_lab,
      caption = caption_text) +
    base_theme
  week_plot
  ggsave(filename = png_path, plot = week_plot, bg = "white", width = 1920, height = 1600, units = "px")
  rm(week_plot)
  if (i %% 5L == 0L) gc()
}
message(sprintf("+ render: %.1fs  [RAM] rss=%.1fGB avail=%.1fGB",
  proc.time()["elapsed"] - t_render, get_process_rss_gb(), get_available_ram_gb()))
rm(possible_lifers)
gc()

# Generate animated gif (full size and smaller for sharing)
message("Assembling animated GIFs...")
check_disk_space(min_gb = 1)
check_memory_pressure("before GIF assembly")
t_gif <- proc.time()["elapsed"]
fps_val <- if (annotate == TRUE) 0.5 else 5
annotate_suffix <- if (annotate) "annotated_" else ""
image_path <- here(outputDir, "Animated_map", paste0(
  region, "_Animated_map_annual_", theme,
  "_hires_", annotate_suffix, user_file, ".gif"
))
image_path_lores <- here(outputDir, "Animated_map", paste0(
  region, "_Animated_map_annual_", theme,
  "_lores_", annotate_suffix, user_file, ".gif"
))

# gifski reads PNGs directly in Rust  -  no R image objects needed.
png_frames <- sort(list.files(here(outputDir, "Weekly_maps"), pattern = "\\.png$", full.names = TRUE))

if (length(png_frames) > 0) {
  both_exist <- file.exists(image_path) && file.exists(image_path_lores)
  if (both_exist) {
    message("  Animated GIFs already exist, skipping.")
  } else {
    # Read actual pixel dimensions from the first frame
    first_dim <- tryCatch(
      dim(png::readPNG(png_frames[1])),
      error = function(e) {
        message("  WARNING: could not read first PNG frame to detect dimensions -- using default 1920x1600")
        c(1600L, 1920L, 4L)
      })
    full_w <- first_dim[2]
    full_h <- first_dim[1]

    # Hi-res: pass native frame dimensions so gifski doesn't downscale
    if (!file.exists(image_path)) {
      tryCatch({
        gifski::gifski(png_files = png_frames, gif_file = image_path,
                       width = full_w, height = full_h,
                       delay = 1 / fps_val, loop = TRUE, progress = TRUE)
        message(sprintf("  Hi-res GIF: %s (%.1f MB)", basename(image_path),
                        file.info(image_path)$size / 1e6))
      }, error = function(e) {
        message("  WARNING: hi-res GIF failed: ", conditionMessage(e))
        if (file.exists(image_path) && file.info(image_path)$size == 0)
          file.remove(image_path)
      })
    }

    # Lo-res: gifski resizes internally in Rust
    if (!file.exists(image_path_lores)) {
      lores_w <- round(full_w * 0.38)
      lores_h <- round(full_h * 0.38)
      tryCatch({
        gifski::gifski(png_files = png_frames, gif_file = image_path_lores,
                       width = lores_w, height = lores_h,
                       delay = 1 / fps_val, loop = TRUE, progress = TRUE)
        message(sprintf("  Lo-res GIF: %s (%.1f MB)", basename(image_path_lores),
                        file.info(image_path_lores)$size / 1e6))
      }, error = function(e) {
        message("  WARNING: lo-res GIF failed: ", conditionMessage(e))
        if (file.exists(image_path_lores) && file.info(image_path_lores)$size == 0)
          file.remove(image_path_lores)
      })
    }
  }
} else {
  message("No PNG frames found, skipping GIF assembly.")
}
message(sprintf("+ gif: %.1fs  [RAM] rss=%.1fGB avail=%.1fGB",
  proc.time()["elapsed"] - t_gif, get_process_rss_gb(), get_available_ram_gb()))
