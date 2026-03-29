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

# ---------------------------------------------------------------------------
# Portability: detect hardware and set safe defaults
# ---------------------------------------------------------------------------
n_cores_physical <- max(1L, parallel::detectCores(logical = FALSE))
n_cores_logical  <- max(1L, parallel::detectCores(logical = TRUE))
# Leave at least 2 physical cores free for OS / other tasks
n_workers <- max(1L, n_cores_physical - 2L)

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
message(sprintf("[hardware] %d physical cores, %d logical | %.0f GB RAM available | %.0f GB disk free",
  n_cores_physical, n_cores_logical,
  ifelse(is.na(ram_gb), -1, ram_gb),
  ifelse(is.na(disk_gb), -1, disk_gb)))
message(sprintf("[hardware] Using %d workers for parallel operations", n_workers))

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
annotate <- FALSE # If set to TRUE, needed species are labeled on the map at the location where they have the highest abundance each week. This makes the animated map look pretty bad (so it gets output at a much slower frame rate to compensate), but may be of interest to some. the "dark" color theme works best for this.
sp_annotation_threshold <- 0.01 # this controls how many species get annotated on the map if annotate is set to TRUE. A species will only be annotated if the grid cell where it is most abundant contains more than the set proportion of the total population. Lower values mean more species get annotated (though the marked locations will hold smaller and smaller percentages of the total population, which may make for some odd placements for widely dispersed species). Set to 0 to annotate all needed species. A value of 0.01 seems to keep things under control if there are many needed species. Note that this is different from the possible_occurrence_threshold, which sets the occurrence probability a species must exceed in a cell to be counted as a potential lifer.
theme <- "dark" # accepted values "light_blue", "dark", "light_green"

# API keys — loaded from config_local.R (gitignored, never committed).
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
  message(sprintf("[RAM check] %.0f GB available — streaming accumulation, peak ~1 species raster at a time.",
    ram_now))
} else {
  message("[RAM check] Could not detect available memory — proceeding with caution.")
}

# Disk space guard: need at least 2 GB for outputs
check_disk_space(min_gb = 2)

# Safe raster loader — logs a warning and returns NULL on failure instead of halting.
load_raster_safe <- function(sp_code, ...) {
  tryCatch(
    load_raster(sp_code, ...),
    error = function(e) {
      message("Skipping ", sp_code, " — could not load raster: ", conditionMessage(e))
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
# Auto-sized chunked accumulation — adapts to available RAM at runtime.
#
# chunk_size=1   → streaming: 1 species at a time, minimum RAM, any machine.
# chunk_size=N   → batch N species per round: faster via vectorised terra sum.
# chunk_size=all → full batch (original approach): maximum speed, maximum RAM.
#
# The speedup from larger chunks comes from terra's vectorised C++ sum:
#   terra::app(n_species_stack, sum)  — one pass regardless of n_species.
# Streaming does N separate + operations; batch does one. Disk I/O is identical.
# Typical speedup vs streaming: ~20–40% at 9km, ~30–50% at 3km.
# ---------------------------------------------------------------------------

# Convert study_area to a terra SpatVector once; reused throughout.
study_area_vect <- terra::vect(study_area)

# Probe: load + crop the first valid species to get actual cropped dimensions.
probe_idx   <- which(vapply(tif_paths, file.exists, logical(1L)))[1L]
probe_code  <- sp_ebst_for_run$species_code[probe_idx]
r_probe <- tryCatch({
  rr <- load_raster_safe(probe_code, product = "occurrence", period = "weekly",
                         metric = "median", resolution = resolution)
  if (!is.null(rr)) terra::crop(rr, study_area_vect) else NULL
}, error = function(e) NULL)

sp_size_gb <- if (!is.null(r_probe)) {
  (terra::ncell(r_probe) * terra::nlyr(r_probe) * 4L) / 1e9   # float32
} else 0.5   # conservative fallback

if (!is.null(r_probe)) {
  message(sprintf("  Cropped species raster: %d cells × %d weeks = %.0f MB (float32)",
    terra::ncell(r_probe), terra::nlyr(r_probe), sp_size_gb * 1000))
}
rm(r_probe); gc()

avail_gb_now <- tryCatch(
  as.numeric(system("awk '/MemAvailable/{print $2}' /proc/meminfo", intern = TRUE)) / 1e6,
  error = function(e) NA_real_)

chunk_size <- if (!is.na(avail_gb_now)) {
  # Budget: 40% of free RAM; factor ×3 for raw raster + indicator copy + accumulator delta
  cs <- max(1L, floor(avail_gb_now * 0.40 / (sp_size_gb * 3)))
  min(cs, nrow(sp_ebst_for_run))
} else 1L   # can't detect RAM → safe streaming default

message(sprintf(
  "  [chunk] chunk_size=%d  RAM mode: %s",
  chunk_size,
  if (chunk_size >= nrow(sp_ebst_for_run)) "full batch (all species in RAM)"
  else if (chunk_size == 1L) "streaming (min RAM)"
  else sprintf("chunked (~%.0f GB per chunk)", chunk_size * sp_size_gb * 3)))

# Pre-allocate output structure: one SpatRaster per week, lazy-init below.
possible_lifers    <- vector("list", 52L)
week_dates         <- NULL
sp_codes_in_region <- character(0)
if (annotate == TRUE) polys_list <- list()

sp_chunks <- split(seq_len(nrow(sp_ebst_for_run)),
                   ceiling(seq_len(nrow(sp_ebst_for_run)) / chunk_size))

message(sprintf("Accumulating %d species in %d chunk(s) at %s…",
  nrow(sp_ebst_for_run), length(sp_chunks), resolution))
t_accum <- proc.time()["elapsed"]

for (chunk_i in seq_along(sp_chunks)) {
  idx_range <- sp_chunks[[chunk_i]]
  if (length(sp_chunks) > 1L)
    message(sprintf("  Chunk %d/%d — species %d–%d of %d",
      chunk_i, length(sp_chunks), min(idx_range), max(idx_range), nrow(sp_ebst_for_run)))

  chunk_rasters <- list()

  for (sp_idx in idx_range) {
    sp_code <- sp_ebst_for_run$species_code[sp_idx]

    # Per-species RAM report only in streaming mode (chunk_size=1)
    if (chunk_size == 1L) {
      mem_now <- tryCatch(
        as.numeric(system("awk '/MemAvailable/{print $2}' /proc/meminfo", intern = TRUE)) / 1e6,
        error = function(e) NA_real_)
      message(sprintf("    [%d/%d] %s  (%.1f GB free)",
        sp_idx, nrow(sp_ebst_for_run), sp_code, ifelse(is.na(mem_now), -1, mem_now)))
    }

    r <- load_raster_safe(sp_code, product = "occurrence", period = "weekly",
                          metric = "median", resolution = resolution)
    if (is.null(r)) next

    r <- terra::crop(r, study_area_vect)
    r <- terra::mask(r, study_area_vect)
    if (max(terra::minmax(r)) <= possible_occurrence_threshold) { rm(r); gc(); next }

    sp_codes_in_region <- c(sp_codes_in_region, sp_code)
    if (is.null(week_dates)) week_dates <- names(r)

    # Threshold to 0/1 indicator and store in chunk
    chunk_rasters[[sp_code]] <- terra::ifel(r > possible_occurrence_threshold, 1L, 0L)
    rm(r); gc()

    # Annotation: per-species — cannot be chunked
    if (annotate == TRUE) {
      p <- tryCatch(
        load_raster(sp_code, product = "proportion-population", period = "weekly",
                    metric = "median", resolution = resolution),
        error = function(e) NULL)
      if (!is.null(p)) {
        p <- terra::crop(p, study_area_vect)
        p <- terra::mask(p, study_area_vect)
        if (max(terra::minmax(p)) > possible_occurrence_threshold) {
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

  if (length(chunk_rasters) == 0L) next

  # --- Vectorised week summation across all species in this chunk -----------
  # For each of 52 weeks, stack the week-i layer from every species in the
  # chunk and call terra::app(sum). terra's C++ runs this in one pass.
  # With chunk_size=1 there is only one layer so app() reduces to a copy.
  n_wk <- terra::nlyr(chunk_rasters[[1L]])
  for (wk in seq_len(n_wk)) {
    wk_layers <- terra::rast(lapply(chunk_rasters, terra::subset, subset = wk))
    wk_sum <- if (terra::nlyr(wk_layers) == 1L) {
      wk_layers            # trivial single-species case — skip app() overhead
    } else {
      terra::app(wk_layers, fun = sum, na.rm = TRUE)
    }
    rm(wk_layers)
    possible_lifers[[wk]] <- if (is.null(possible_lifers[[wk]])) {
      wk_sum
    } else {
      possible_lifers[[wk]] + wk_sum
    }
    rm(wk_sum)
  }
  rm(chunk_rasters); gc()
  check_memory_pressure(sprintf("after chunk %d/%d", chunk_i, length(sp_chunks)))
}

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

# Reproject, mask, and trim weekly lifer count rasters for plotting
message("Reprojecting 52 weekly rasters…")
t_reproj <- proc.time()["elapsed"]
study_area_5070 <- terra::project(study_area_vect, y = "epsg:5070")
possible_lifers <- lapply(possible_lifers, function(r) {
  r <- terra::project(r, y = "epsg:5070", method = "near")
  r <- terra::mask(r, mask = study_area_5070)
  terra::trim(r)
})
message(sprintf("  Reprojection complete in %.1fs", proc.time()["elapsed"] - t_reproj))
gc()

# Finalise annotation data frame (polys_list was built per-species in the chunk loop above)
if (annotate == TRUE) {
  polys <- do.call("rbind", polys_list) %>%
    dplyr::left_join(sp_ebst_for_run_in_region, by = c("sp" = "species_code"))
  polys <- sf::st_filter(polys, study_area)
  rm(polys_list); gc()
}

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

# Get maximum lifer count (across all cells and weeks). Needed for legend.
max_val_possible <- lapply(possible_lifers, minmax) %>%
  sapply(max) %>%
  max()

# Get legend breaks/labels/range based on maximum count.
legend_breaks <- c(pretty(1:max_val_possible))
labels <- function(x) {
  lab <- " species"
  chars <- nchar(paste0(tail(x, n = 1), lab))
  x_last <- as.character(paste0(tail(x, n = 1), lab))
  x_last_pad <- str_pad(x_last, nchar(x_last) * 2 + nchar(tail(x, n = 1)) + 1, side = "left")
  c(x[1:(length(x) - 1)], x_last_pad)
}
legend_labels <- labels(legend_breaks)
legend_breaks_last <- last(legend_breaks)

# Generate and save map for each week.
# Rendering stays sequential because ggplot + ggsave use terra SpatRasters internally.
message(sprintf("Rendering %d weekly maps…", length(possible_lifers)))
t_render <- proc.time()["elapsed"]
check_disk_space(min_gb = 1)
for (i in seq_along(possible_lifers)) {
  date <- week_dates[i]
  png_path <- here(outputDir, "Weekly_maps", paste0(region, "_", date, ".png"))
  if (file.exists(png_path)) next
  if (needs_list_to_use == "global") {
    legend_lab <- paste0(ifelse(is.na(user_short), paste0("My"), paste0(user_short, "'s")), " potential lifers")
  }
  if (needs_list_to_use == "regional") {
    legend_lab <- paste0(ifelse(is.na(user_short), paste0("My"), paste0(user_short, "'s")), " regional needs")
  }
  week_plot <- ggplot() +
    geom_spatraster(data = possible_lifers[[i]]) +
    geom_sf(data = study_area, fill = NA, color = alpha("white", .3)) +
    
    # Add annotation if option is turned on
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
    scale_fill_viridis_c(
      limits = c(0, legend_breaks_last), na.value = "transparent", option = "turbo",
      guide = guide_colorbar(title.position = "top", title.hjust = .5),
      breaks = legend_breaks,
      labels = legend_labels
    ) +
    labs(
      title = "Lifer finder: mapping the birds you've yet to meet",
      tag = paste0(format(ymd(date), format = "%b-%d")),
      # subtitle = "Mapping the birds you've yet to meet",
      fill = legend_lab,
      caption = paste0("Lifers mapped for: ", user, ". \nLifer analysis and map by Sam Safran.\n\nA candidate lifer is considered `possible` if the species has a >", round(possible_occurrence_threshold * 100, 0), "% modeled occurrence probability at the location and date.\n
Data from 2022 eBird Status & Trends products (https://ebird.org/science/status-and-trends): Fink, D., T. Auer, A. Johnston, M. Strimas-Mackey, S. Ligocki, O. Robinson,\n W. Hochachka, L. Jaromczyk, C. Crowley, K. Dunham, A. Stillman, I. Davies, A. Rodewald, V. Ruiz-Gutierrez, C. Wood. 2023. eBird Status and Trends, Data Version:\n2022; Released: 2023. Cornell Lab of Ornithology, Ithaca, New York. https://doi.org/10.2173/ebirdst.2022. This material uses data from the eBird Status and Trends\n Project at the Cornell Lab of Ornithology, eBird.org. Any opinions, findings, and conclusions or recommendations expressed in this material are those of the author(s)\nand do not necessarily reflect the views of the Cornell Lab of Ornithology.")
    ) +
    ggthemes::theme_fivethirtyeight() +
    theme(
      rect = element_rect(linetype = 1, colour = NA),
      plot.title = element_text(
        size = 10, hjust = 0, face = "plain", color = font_color_light,
        margin = margin(0, 0, 15, 0)
      ),
      plot.tag = element_text(size = 10, face = "bold", color = font_color_dark),
      axis.title.y = element_blank(),
      axis.title.x = element_blank(),
      axis.text.x = element_blank(),
      axis.text.y = element_blank(),
      plot.caption = element_text(size = 5, hjust = 0, color = font_color_light),
      plot.background = element_rect(fill = bg_color),
      panel.background = element_rect(fill = bg_color),
      panel.grid.major = element_blank(),
      panel.grid.minor = element_blank(),
      panel.border = element_blank(),
      legend.title = element_text(size = 10, face = "bold", color = font_color_dark),
      legend.text = element_text(color = font_color_dark),
      legend.title.align = 1,
      legend.direction = "horizontal",
      legend.key.width = unit(.32, "inch"),
      legend.key.height = unit(.06, "inch"),
      legend.position = c(.768, 1.03),
      plot.tag.position = c(0.05, .94),
      legend.background = element_rect(colour = NA, fill = NA, linetype = "solid"),
      legend.text.align = 0.5
    )
  week_plot
  ggsave(filename = png_path, plot = week_plot, bg = "white", width = 1920, height = 1600, units = "px")
  rm(week_plot)
  gc()
}
message(sprintf("  Rendering complete in %.1fs", proc.time()["elapsed"] - t_render))
rm(possible_lifers)
gc()

# Generate animated gif (full size and smaller for sharing)
message("Assembling animated GIFs…")
check_disk_space(min_gb = 1)
check_memory_pressure("before GIF assembly")
t_gif <- proc.time()["elapsed"]
fps_val <- if (annotate == TRUE) 0.5 else 5
image_path <- here(outputDir, "Animated_map", paste0(
  region, "_Animated_map_annual_", theme,
  "_hires_", if (annotate) "annotated_", user_file, ".gif"
))
image_path_lores <- here(outputDir, "Animated_map", paste0(
  region, "_Animated_map_annual_", theme,
  "_lores_", if (annotate) "annotated_", user_file, ".gif"
))

# gifski reads PNGs directly in Rust — no R image objects needed.
png_frames <- sort(list.files(here(outputDir, "Weekly_maps"), pattern = "\\.png$", full.names = TRUE))

if (length(png_frames) > 0) {
  # Read actual pixel dimensions from the first frame
  first_dim <- dim(png::readPNG(png_frames[1]))  # height × width × channels
  full_w <- first_dim[2]
  full_h <- first_dim[1]

  # Hi-res: pass native frame dimensions so gifski doesn't downscale
  if (!file.exists(image_path)) {
    gifski::gifski(png_files = png_frames, gif_file = image_path,
                   width = full_w, height = full_h,
                   delay = 1 / fps_val, loop = TRUE, progress = TRUE)
    message(sprintf("  Hi-res GIF: %s (%.1f MB)", basename(image_path),
                    file.info(image_path)$size / 1e6))
  }

  # Lo-res: gifski resizes internally in Rust
  if (!file.exists(image_path_lores)) {
    lores_w <- round(full_w * 0.38)
    lores_h <- round(full_h * 0.38)
    gifski::gifski(png_files = png_frames, gif_file = image_path_lores,
                   width = lores_w, height = lores_h,
                   delay = 1 / fps_val, loop = TRUE, progress = TRUE)
    message(sprintf("  Lo-res GIF: %s (%.1f MB)", basename(image_path_lores),
                    file.info(image_path_lores)$size / 1e6))
  }
} else {
  message("No PNG frames found, skipping GIF assembly.")
}

if (file.exists(image_path) && file.exists(image_path_lores)) {
  message("Animated GIFs already exist, skipping.")
}
message(sprintf("  GIF assembly complete in %.1fs", proc.time()["elapsed"] - t_gif))
