# Sam Safran's original LifeR script — adapted minimally for non-interactive benchmarking.
#
# Changes from LifeR_US_original.R (all marked BENCH-MOD):
#   1. library(magick) replaced with library(gifski) + library(png) — magick segfaults on large GIFs
#   2. mapview::mapview(study_area) call removed — blocks non-interactive session
#   3. view_sp("casspa") call removed — interactive + requires raster package
#   4. GIF assembly replaces magick pipeline with gifski (JPG→PNG conversion in tempdir)
#   5. Timing/RAM checkpoints added throughout for benchmarking
#
# Core accumulation logic (batch sapply load → crop → mask → week loop) is UNCHANGED.

# Ensure user library is on the path (packages installed via install_packages.R)
.libPaths(c(path.expand("~/R/library"), .libPaths()))

# ── BENCH-MOD: benchmark helpers ──────────────────────────────────────────────
.bench_t0 <- proc.time()["elapsed"]
bench_checkpoint <- function(label) {
  elapsed <- proc.time()["elapsed"] - .bench_t0
  mem_avail_kb <- tryCatch(
    as.numeric(system("awk '/MemAvailable/{print $2}' /proc/meminfo", intern = TRUE)),
    error = function(e) NA_real_)
  mem_used_kb <- tryCatch(
    as.numeric(system("awk '/MemTotal/{print $2}' /proc/meminfo", intern = TRUE)),
    error = function(e) NA_real_) - mem_avail_kb
  message(sprintf("[BENCH] %s | elapsed=%.1fs | RAM_used=%.1f GB",
    label, elapsed, mem_used_kb / 1e6))
}
# ──────────────────────────────────────────────────────────────────────────────

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
library(gifski)  # BENCH-MOD: replaces magick
library(png)     # BENCH-MOD: for frame reading

here()

# Store S&T rasters in the project folder (data/ebirdst/) rather than the
# hidden R per-user directory.  Python scripts and R scripts share this path.
# Must be set before any ebirdst function is called.
ebirdst_cache_dir <- here("data", "ebirdst")
dir.create(ebirdst_cache_dir, recursive = TRUE, showWarnings = FALSE)
Sys.setenv(EBIRDST_DATA_DIR = ebirdst_cache_dir)

# Set parameters
region <- "US"
user <- "Bart Wickel"
user_short <- NA
your_ebird_dat <- here("MyEBirdData.csv")
needs_list_to_use <- "regional"
resolution <- "27km"   # ← set via benchmark_compare.sh env var if desired
annotate <- FALSE
sp_annotation_threshold <- 0.01
theme <- "dark"

# Override resolution from environment if set by benchmark harness
if (!is.na(Sys.getenv("BENCH_RESOLUTION", unset = NA))) {
  resolution <- Sys.getenv("BENCH_RESOLUTION")
  message(sprintf("[BENCH] resolution overridden to '%s' by BENCH_RESOLUTION env var", resolution))
}

# API keys
if (!file.exists(here("config_local.R"))) {
  stop("config_local.R not found.")
}
source(here("config_local.R"))
set_ebirdst_access_key(ebirdst_key, overwrite = TRUE)

# Make directories
user_file <- tolower(str_replace(user, " ", ""))
mainDir <- here("Results")
outputDir <- here("Results", user_file, region, needs_list_to_use, paste0(resolution, "_original"))
subdirectories <- c("Weekly_maps", "Animated_map")
lapply(
  file.path(outputDir, subdirectories),
  function(x) if (!dir.exists(x)) dir.create(x, recursive = TRUE))

region_info <- data.frame(region = region) %>%
  separate(region, into = c("country", "state"), sep = "-", remove = FALSE, fill = "right")

bench_checkpoint("START")

# ── Species discovery ─────────────────────────────────────────────────────────
sp_all <- rebird::ebirdtaxonomy("species") %>%
  rename(Common.Name = comName)

sp_user_all <- read.csv(your_ebird_dat) %>%
  select(Common.Name) %>%
  unique() %>%
  left_join(sp_all) %>%
  filter(category == "species")

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

sp_region <- ebirdregionspecies(region, key = ebird_api_key) %>%
  left_join(sp_all) %>%
  drop_na(Common.Name)
message(sprintf("[1/4] Species in %s regional checklist (eBird): %d", region, nrow(sp_region)))

if (needs_list_to_use == "global") {
  sp_needed <- setdiff(sp_region$Common.Name, sp_user_all$Common.Name) %>%
    as.data.frame() %>% rename(Common.Name = ".") %>% left_join(sp_all)
}
if (needs_list_to_use == "regional") {
  sp_needed <- setdiff(sp_region$Common.Name, sp_user_region$Common.Name) %>%
    as.data.frame() %>% rename(Common.Name = ".") %>% left_join(sp_all)
}
message(sprintf("[2/4] Needed species (%s): %d", needs_list_to_use, nrow(sp_needed)))

sp_ebst <- ebirdst_runs %>% rename(Common.Name = common_name)
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
message(sprintf("[3/4] Needed species with S&T model: %d", nrow(sp_ebst_for_run)))

bench_checkpoint("species_discovery")

# ── Download / validate tifs ───────────────────────────────────────────────────
ebirdst_cache <- ebirdst_data_dir()
tif_paths <- file.path(ebirdst_cache, "2023", sp_ebst_for_run$species_code, "weekly",
  paste0(sp_ebst_for_run$species_code, "_occurrence_median_", resolution, "_2023.tif"))
is_valid_tif <- function(path) {
  if (!file.exists(path)) return(FALSE)
  tryCatch({ terra::rast(path); TRUE }, error = function(e) {
    file.remove(path); FALSE })
}
needs_download <- sp_ebst_for_run$species_code[!vapply(tif_paths, is_valid_tif, logical(1))]
if (length(needs_download) > 0) {
  sapply(needs_download, ebirdst_download_status,
         download_abundance = TRUE, download_occurrence = TRUE,
         pattern = paste0("occurrence_median_", resolution),
         USE.NAMES = FALSE)
} else {
  message("All tifs already cached.")
}

bench_checkpoint("after_download_check")

# ── Original RAM guard (hard limit) ──────────────────────────────────────────
if (resolution == "3km" && file.exists("/proc/meminfo")) {
  mem_avail_kb <- as.numeric(sub(".*:\\s*(\\d+)\\s*kB.*", "\\1",
    grep("MemAvailable", readLines("/proc/meminfo"), value = TRUE)[1]))
  if (mem_avail_kb / 1e6 < 150) {
    stop(sprintf("Insufficient RAM for 3km: %.0f GB available, need ≥150 GB.", mem_avail_kb / 1e6))
  }
}

# ── ORIGINAL BATCH LOAD (unchanged from Sam's script) ─────────────────────────
load_raster_safe <- function(sp_code, ...) {
  tryCatch(load_raster(sp_code, ...), error = function(e) {
    message("Skipping ", sp_code, ": ", conditionMessage(e)); NULL })
}

message("Loading all occurrence rasters (batch) …")
occ_combined <- sapply(sp_ebst_for_run$species_code, load_raster_safe,
  product = "occurrence", period = "weekly", metric = "median", resolution = resolution)
occ_combined <- Filter(Negate(is.null), occ_combined)

bench_checkpoint("after_batch_load")

# ── Vector boundary ────────────────────────────────────────────────────────────
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
}
study_area <- st_transform(study_area, st_crs(occ_combined[[1]]))
# BENCH-MOD: mapview::mapview(study_area) removed — interactive

possible_occurrence_threshold <- 0.01

# ── ORIGINAL CROP / MASK (unchanged) ──────────────────────────────────────────
filter_rasters_to_sp_above_threshold <- function(z) {
  sp_above <- sapply(z, minmax) %>%
    apply(2, max) %>%
    as.data.frame() %>%
    rownames_to_column("species_code") %>%
    rename("max_val" = ".") %>%
    left_join(sp_ebst_for_run) %>%
    filter(max_val > possible_occurrence_threshold) %>%
    pull(species_code)
  z[names(z) %in% sp_above]
}

message("Cropping and masking to study area …")
occ_crop_combined <- sapply(occ_combined, terra::crop, y = terra::vect(study_area))
occ_crop_combined <- filter_rasters_to_sp_above_threshold(occ_crop_combined)
occ_crop_combined <- sapply(occ_crop_combined, terra::mask, mask = terra::vect(study_area))
occ_crop_combined <- filter_rasters_to_sp_above_threshold(occ_crop_combined)

bench_checkpoint("after_crop_mask")

sp_ebst_for_run_in_region <- left_join(
  x = sapply(occ_crop_combined, minmax) %>%
    apply(2, max) %>%
    data.frame() %>%
    rownames_to_column("species_code") %>%
    rename("max_val" = "."),
  y = sp_ebst_for_run)
message(sprintf("[4/4] Species above threshold in %s: %d", region, nrow(sp_ebst_for_run_in_region)))

# BENCH-MOD: view_sp("casspa") removed — interactive + requires raster package

# ── ORIGINAL WEEK ACCUMULATION LOOP (unchanged) ────────────────────────────────
message("Accumulating weekly lifer counts …")
possible_lifers <- list()
for (i in 1:52) {
  week_slice <- lapply(occ_crop_combined, subset, subset = i)
  week_slice <- rast(week_slice)
  week_slice <- ifel(week_slice > possible_occurrence_threshold, 1, 0)
  week_slice <- sum(week_slice, na.rm = TRUE)
  possible_lifers[[i]] <- week_slice
}

bench_checkpoint("after_week_loop")

possible_lifers <- sapply(possible_lifers, terra::project, y = "epsg:5070", method = "near")
possible_lifers <- sapply(possible_lifers, terra::mask, mask = project(vect(study_area), y = "epsg:5070"))
possible_lifers <- sapply(possible_lifers, trim)

week_dates <- names(occ_crop_combined[[1]])
rm(occ_combined, occ_crop_combined); gc()

bench_checkpoint("after_reproject_free")

# ── Map rendering (unchanged theme logic; PNG output for gifski) ──────────────
mem_total_kb <- as.numeric(system("awk '/MemTotal/{print $2}' /proc/meminfo", intern = TRUE))
mem_avail_kb <- as.numeric(system("awk '/MemAvailable/{print $2}' /proc/meminfo", intern = TRUE))
memfrac_safe  <- min(0.85, (mem_avail_kb / mem_total_kb) * 0.80)
nc <- max(1L, parallel::detectCores() - 2L)
terra::terraOptions(memfrac = memfrac_safe, threads = nc, progress = 0L)

if (theme == "light_blue")  { bg_color <- "azure2";   font_color_light <- "grey50"; font_color_dark <- "grey20" }
if (theme == "light_green") { bg_color <- "#EBF5DF";  font_color_light <- "#9CC185"; font_color_dark <- "#141B0E" }
if (theme == "dark")        { bg_color <- viridisLite::turbo(1); font_color_light <- "white"; font_color_dark <- "grey90" }

max_val_possible <- lapply(possible_lifers, minmax) %>% sapply(max) %>% max()
legend_breaks <- c(pretty(1:max_val_possible))
labels <- function(x) {
  lab <- " species"
  x_last_pad <- str_pad(paste0(tail(x,1), lab),
    nchar(paste0(tail(x,1), lab)) * 2 + nchar(tail(x,1)) + 1, side = "left")
  c(x[seq_len(length(x)-1)], x_last_pad)
}
legend_labels <- labels(legend_breaks)
legend_breaks_last <- last(legend_breaks)

message("Rendering weekly frames …")
for (i in seq_along(possible_lifers)) {
  date <- week_dates[i]
  legend_lab <- paste0(ifelse(is.na(user_short), "My", paste0(user_short, "'s")),
    if (needs_list_to_use == "global") " potential lifers" else " regional needs")
  # BENCH-MOD: save as PNG (gifski native format) instead of JPG
  png_path <- here(outputDir, "Weekly_maps", paste0(region, "_", date, ".png"))
  if (file.exists(png_path)) next
  week_plot <- ggplot() +
    geom_spatraster(data = possible_lifers[[i]]) +
    geom_sf(data = study_area %>% st_transform("epsg:5070"), fill = NA, color = alpha("white", .3)) +
    scale_fill_viridis_c(
      limits = c(0, legend_breaks_last), na.value = "transparent", option = "turbo",
      guide = guide_colorbar(title.position = "top", title.hjust = .5),
      breaks = legend_breaks, labels = legend_labels) +
    labs(
      title = "Lifer finder: mapping the birds you've yet to meet",
      tag   = format(ymd(date), format = "%b-%d"),
      fill  = legend_lab,
      caption = paste0("Lifers mapped for: ", user, ".\nOriginal script by Sam Safran.")) +
    ggthemes::theme_fivethirtyeight() +
    theme(
      rect = element_rect(linetype = 1, colour = NA),
      plot.title    = element_text(size=10, hjust=0, face="plain", color=font_color_light, margin=margin(0,0,15,0)),
      plot.tag      = element_text(size=10, face="bold", color=font_color_dark),
      axis.title.y  = element_blank(), axis.title.x = element_blank(),
      axis.text.x   = element_blank(), axis.text.y  = element_blank(),
      plot.caption  = element_text(size=5, hjust=0, color=font_color_light),
      plot.background  = element_rect(fill=bg_color),
      panel.background = element_rect(fill=bg_color),
      panel.grid.major = element_blank(), panel.grid.minor = element_blank(), panel.border = element_blank(),
      legend.title      = element_text(size=10, face="bold", color=font_color_dark),
      legend.text       = element_text(color=font_color_dark),
      legend.title.align = 1, legend.direction = "horizontal",
      legend.key.width   = unit(.32, "inch"), legend.key.height = unit(.06, "inch"),
      legend.position    = c(.768, 1.03),
      plot.tag.position  = c(0.05, .94),
      legend.background = element_rect(colour=NA, fill=NA, linetype="solid"),
      legend.text.align  = 0.5)
  ggsave(filename = png_path, plot = week_plot, bg = "white", width = 1920, height = 1600, units = "px")
  rm(week_plot); gc()
}

bench_checkpoint("after_frame_render")

rm(possible_lifers); gc()

# ── GIF assembly via gifski (BENCH-MOD: replaces magick pipeline) ─────────────
fps_val <- if (annotate) 0.5 else 5
image_path <- here(outputDir, "Animated_map", paste0(
  region, "_Animated_map_annual_", theme, "_hires_", user_file, ".gif"))
image_path_lores <- here(outputDir, "Animated_map", paste0(
  region, "_Animated_map_annual_", theme, "_lores_", user_file, ".gif"))

png_frames <- sort(list.files(here(outputDir, "Weekly_maps"), pattern = "\\.png$", full.names = TRUE))

if (length(png_frames) > 0) {
  first_dim <- dim(png::readPNG(png_frames[1]))   # height × width × channels
  frame_h <- first_dim[1]; frame_w <- first_dim[2]

  if (!file.exists(image_path)) {
    message("Building hi-res GIF …")
    gifski::gifski(png_files = png_frames, gif_file = image_path,
      width = frame_w, height = frame_h, delay = 1 / fps_val, progress = FALSE)
  }
  if (!file.exists(image_path_lores)) {
    message("Building lo-res GIF …")
    gifski::gifski(png_files = png_frames, gif_file = image_path_lores,
      width = round(frame_w * 0.38), height = round(frame_h * 0.38),
      delay = 1 / fps_val, progress = FALSE)
  }
}

bench_checkpoint("DONE")
message("Output: ", outputDir)
