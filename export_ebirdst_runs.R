# export_ebirdst_runs.R — run once to export the ebirdst species table for Python.
# Output: ebirdst_runs.csv in the project root.
# The Python downloader (download_ebirdst.py) reads this to know which species
# have eBird Status & Trends models without needing the R ebirdst package.

.libPaths(c(path.expand("~/R/library"), .libPaths()))
library(ebirdst)
library(readr)
library(dplyr)
library(here)

out_path <- here("ebirdst_runs.csv")
ebirdst_runs %>%
  select(species_code, common_name, scientific_name) %>%
  write_csv(out_path)

message(sprintf("Exported %d modeled species to %s", nrow(ebirdst_runs), out_path))
