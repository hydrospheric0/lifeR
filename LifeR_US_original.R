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
library(magick)

here()

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
resolution <- "27km" # "3km", "9km", or "27km"
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

# Guard against OOM at 3km — loading all ~560 species at 3km requires ~500 GB RAM.
# Check available memory on Linux before proceeding; abort with a clear message if insufficient.
if (resolution == "3km" && file.exists("/proc/meminfo")) {
  mem_avail_kb <- as.numeric(sub(".*:\\s*(\\d+)\\s*kB.*", "\\1",
    grep("MemAvailable", readLines("/proc/meminfo"), value = TRUE)[1]))
  mem_avail_gb <- mem_avail_kb / 1e6
  mem_required_gb <- 150  # conservative floor; 3km OOM observed below this
  if (mem_avail_gb < mem_required_gb) {
    stop(sprintf(paste0(
      "3km loads ~9x more raster data than 9km.\n",
      "  Available RAM : %.0f GB\n",
      "  Required (est): %.0f GB\n",
      "Switch to resolution = '9km' or '27km', or run on a machine with more RAM."),
      mem_avail_gb, mem_required_gb))
  }
  message(sprintf("[RAM check] 3km: %.0f GB available — proceeding.", mem_avail_gb))
}

# Load occurrence rasters for all species in species list (skip any that fail to load)
load_raster_safe <- function(sp_code, ...) {
  tryCatch(
    load_raster(sp_code, ...),
    error = function(e) {
      message("Skipping ", sp_code, " — could not load raster: ", conditionMessage(e))
      NULL
    }
  )
}
occ_combined <- sapply(sp_ebst_for_run$species_code, load_raster_safe, product = "occurrence", period = "weekly", metric = "median", resolution = resolution)
occ_combined <- Filter(Negate(is.null), occ_combined)

# Load proportion population rasters for all species in species list
if (annotate == TRUE) {
  prop_combined <- sapply(sp_ebst_for_run$species_code, load_raster, product = "proportion-population", period = "weekly", metric = "median", resolution = resolution)
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
study_area <- st_transform(study_area, st_crs(occ_combined[[1]]))
if (requireNamespace("mapview", quietly = TRUE)) mapview::mapview(study_area)

# Define occurrence threshold for when a species is "possible"
possible_occurrence_threshold <- 0.01 # minimum occurrence probability for a species to be considered "possible" at a given time/location.

# Function used to drop rasters for species that do not meet occ threshold. This is to help save resources by filtering them out and not processing their layers.
filter_rasters_to_sp_above_threshold <- function(z) {
  sp_above_occ_threhsold <- sapply(z, minmax) %>%
    apply(2, max) %>%
    as.data.frame() %>%
    rownames_to_column("species_code") %>%
    rename("max_val" = ".") %>%
    left_join(sp_ebst_for_run) %>%
    filter(max_val > possible_occurrence_threshold) %>%
    pull(species_code)
  z <- z[names(z) %in% sp_above_occ_threhsold]
  z
}

# Crop the rasters using the vector extent
occ_crop_combined <- sapply(occ_combined, terra::crop, y = terra::vect(study_area))
occ_crop_combined <- filter_rasters_to_sp_above_threshold(occ_crop_combined) # drop species not meeting threshold
occ_crop_combined <- sapply(occ_crop_combined, terra::mask, mask = terra::vect(study_area))
occ_crop_combined <- filter_rasters_to_sp_above_threshold(occ_crop_combined) # drop species not meeting threshold
# occ_crop_combined <- sapply(occ_crop_combined, terra::trim)

if (annotate == TRUE) {
  prop_crop_combined <- sapply(prop_combined, terra::crop, y = terra::vect(study_area))
  prop_crop_combined <- filter_rasters_to_sp_above_threshold(prop_crop_combined) # drop species not meeting threshold
  prop_crop_combined <- sapply(prop_crop_combined, terra::mask, mask = terra::vect(study_area))
  prop_crop_combined <- filter_rasters_to_sp_above_threshold(prop_crop_combined) # drop species not meeting threshold
}

# New version of species data frame with only species meeting occ threshold
sp_ebst_for_run_in_region <- left_join(
  x = sapply(occ_crop_combined, minmax) %>%
    apply(2, max) %>%
    data.frame() %>%
    rownames_to_column("species_code") %>%
    rename("max_val" = "."),
  y = sp_ebst_for_run
)
message(sprintf("[4/4] Species exceeding %.0f%% occurrence threshold anywhere in %s: %d  (dropped %d below threshold)",
  possible_occurrence_threshold * 100, region,
  nrow(sp_ebst_for_run_in_region), nrow(sp_ebst_for_run) - nrow(sp_ebst_for_run_in_region)))

# Function for viewing summarized species rasters (not run)
view_sp <- function(x) {
  sp_max <- (raster::raster(max(occ_crop_combined[[x]])))
  mapview::mapview(sp_max)
}
view_sp("casspa")

# Sum number of "possible" species in each cell based on occurrence probability and the defined threshold. Each week stored as a single-layer SpatRaster in a list.
possible_lifers <- list()
for (i in 1:52) {
  week_slice <- lapply(occ_crop_combined, subset, subset = i)
  week_slice <- rast(week_slice)
  week_slice <- ifel(week_slice > possible_occurrence_threshold, 1, 0)
  week_slice <- sum(week_slice, na.rm = TRUE)
  possible_lifers[[i]] <- week_slice
}

# Reproject, mask, and trim weekly lifer count rasters for plotting
possible_lifers <- sapply(possible_lifers, terra::project, y = "epsg:5070", method = "near")
possible_lifers <- sapply(possible_lifers, terra::mask, mask = project(vect(study_area), y = "epsg:5070"))
possible_lifers <- sapply(possible_lifers, trim)

# Save week date labels before freeing raster stacks
week_dates <- names(occ_crop_combined[[1]])

# Free large raster stacks now that per-week summaries are built
if (annotate == FALSE) {
  rm(occ_combined, occ_crop_combined)
  gc()
}

# For each species and each week get point of highest abundance and add to an sf dataframe (for annotations)
if (annotate == TRUE) {
  polys <- st_sf(geometry = st_sfc(lapply(1:1, function(x) st_geometrycollection())), week = NA, sp = NA)
  polys <- st_set_crs(polys, crs(prop_crop_combined[[1]]))
  # polys <- data.frame(wk = 1:52, sp = NA)
  polys <- list()
  for (s in 1:length(prop_crop_combined)) {
    sp <- names(prop_crop_combined[s])
    max_val_cells <- where.max(prop_crop_combined[[sp]], values = TRUE, list = FALSE) %>%
      as.data.frame() %>%
      filter(value > 0)
    max_val_coords <- xyFromCell(prop_crop_combined[[sp]], max_val_cells[, 2])
    max_val_sf <- st_as_sf(max_val_coords %>% as.data.frame(), coords = c(1, 2), crs = crs(prop_crop_combined[[1]])) %>%
      mutate(
        week = max_val_cells[, 1],
        sp = sp,
        max_weekly_proportion = max_val_cells[, 3]
      )
    polys[[s]] <- max_val_sf
  }
  polys <- do.call("rbind", polys) %>%
    left_join(sp_ebst_for_run_in_region, by = c("sp" = "species_code"))
  
  polys <- st_filter(polys, study_area)
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
for (i in 1:length(possible_lifers)) {
  date <- week_dates[i]
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
  jpg_path <- here(outputDir, "Weekly_maps", paste0(region, "_", date, ".jpg"))
  if (!file.exists(jpg_path)) {
    ggsave(filename = jpg_path, plot = week_plot, bg = "white", height = 5.35, width = 6.6)
  }
  rm(week_plot)
  gc()
}
rm(possible_lifers)
gc()

# Generate animated gif (full size and smaller for sharing)
fps_val <- if (annotate == TRUE) 0.5 else 5
image_path <- here(outputDir, "Animated_map", paste0(
  region, "_Animated_map_annual_", theme,
  "_hires_", if (annotate) "annotated_", user_file, ".gif"
))
image_path_lores <- here(outputDir, "Animated_map", paste0(
  region, "_Animated_map_annual_", theme,
  "_lores_", if (annotate) "annotated_", user_file, ".gif"
))

if (!file.exists(image_path) || !file.exists(image_path_lores)) {
  imgs <- list.files(here(outputDir, "Weekly_maps"), full.names = T)
  img_joined <- image_join(lapply(imgs, image_read))

  # Use image_write_gif (gifski backend) to avoid ImageMagick segfault on large GIFs
  if (!file.exists(image_path)) {
    image_write_gif(img_joined, path = image_path, delay = 1 / fps_val)
  }

  # Scale down for sharing (from in-memory frames, avoid re-reading the large GIF)
  if (!file.exists(image_path_lores)) {
    lores <- image_scale(img_joined, geometry_size_percent(width = 38, height = NULL))
    rm(img_joined)
    gc()
    image_write_gif(lores, path = image_path_lores, delay = 1 / fps_val)
    rm(lores)
    gc()
  } else {
    rm(img_joined)
    gc()
  }
} else {
  message("Animated GIFs already exist, skipping.")
}
