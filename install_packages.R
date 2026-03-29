# Install all R packages required by LifeR_US.R

# NOTE: mapview and the tidyverse meta-package require system libraries that must
# be installed first (with sudo):
#   sudo apt-get install -y libharfbuzz-dev libfribidi-dev
# Without those, install individual tidyverse component packages instead (done below).

# Use a writable user library
user_lib <- path.expand("~/R/library")
dir.create(user_lib, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(user_lib, .libPaths()))

cran_pkgs <- c(
  # Individual tidyverse components (replaces the 'tidyverse' meta-package,
  # which requires libharfbuzz-dev/libfribidi-dev for its 'ragg' dependency)
  "ggplot2", "dplyr", "tidyr", "stringr", "lubridate",
  "purrr", "tibble", "readr", "forcats",
  "here",
  "ebirdst",
  "rebird",
  "terra",
  "sf",
  "rnaturalearth",
  "tidyterra",
  "gifski",   # GIF assembly (replaces magick — no ImageMagick dep, no segfault)
  "png",      # read PNG dimensions for gifski hi-res output
  "ggthemes",
  "remotes"
)

install.packages(cran_pkgs, repos = "https://cloud.r-project.org", lib = user_lib)

# ggsflabel is GitHub-only (needed only when annotate = TRUE)
remotes::install_github("yutannihilation/ggsflabel")
