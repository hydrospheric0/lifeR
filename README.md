# lifeR

---

This R script was developed by Samuel Safran to generate personal maps of potential lifer birds using ebirdst and terra. See his post here for overview: https://smsfrn.github.io/posts/2024/01/lifer-mapper/

This repository is a fork of [smsfrn/lifeR](https://github.com/smsfrn/lifeR).

---

## Files

| File | Description |
|------|-------------|
| `LifeR_US.R` | Current working version — all improvements applied, US/CONUS |
| `LifeR_NL.R` | Netherlands adaptation of the same improved script |
| `lifeR_original_runnable.R` | Sam Safran's original code adapted for unattended runs (magick→gifski, interactive calls removed); useful as a benchmark baseline |
| `install_packages.R` | Standalone R package installer |
| `config_local.R.example` | Template for local API key config (copy → `config_local.R`) |
| `benchmark_compare.sh` | Shell script to time-and-RAM compare original vs current at any resolution |

---

## Changes from upstream

All changes are relative to [`lifeR_original.R`](lifeR_original.R) (Sam Safran's original code).

### Setup & portability
- **User R library path** — added `.libPaths()` so packages installed to `~/R/library` are found without modifying system R
- **API keys removed from source** — keys are now loaded from a gitignored `config_local.R` (see setup below); no credentials are ever committed
- **Project-local eBird S&T cache** — `EBIRDST_DATA_DIR` set to `data/ebirdst/` inside the project folder so rasters are shared with any Python tools in the same workspace; not stored in the hidden per-user R directory
- **NaturalEarth data cached locally** — `ne_download()` result saved to `ne_admin1_large.rds` on first run and reloaded instantly on reruns; avoids repeated network calls
- **`install_packages.R`** — standalone installer script listing all required packages and system library dependencies

### Correctness & compatibility fixes
- **`separate(..., fill = "right")`** — suppresses spurious NA warning for country-only region codes (e.g. `"US"`)
- **`mapview::mapview()` call removed** — was interactive-only; blocked unattended/scripted runs
- **Robust species matching** — `sp_ebst_for_run` is now built with a union join on both common name and species code, then deduplicated; catches taxonomy mismatches between `rebird` and `ebirdst_runs` (e.g. "Common Hoopoe" vs "Eurasian Hoopoe")
- **Additional exclusions** — `rocpig` and `compea` excluded from runs in addition to `laugul` and `yebsap-example`; these are introduced/domestic species with eBird S&T models that are not meaningful lifers
- **Week date labels decoupled from raster objects** — saved to a character vector before rasters are freed, so the rendering loop does not rely on a live `SpatRaster` object

### Memory management
- **RAM availability check** — aborts before loading rasters if available RAM is below a resolution-dependent threshold (150 GB for 3km, 20 GB for 9km, 4 GB for 27km); prevents OOM crashes
- **`terraOptions(memfrac = 0.7)`** — limits terra's in-process memory ceiling to 70% of total RAM
- **`check_memory_pressure()` watchdog** — checked at three points (after raster load, after crop+mask, after accumulation); raises an error with a clear message if RSS exceeds 85% of total RAM
- **Free large raster stacks after accumulation** — `rm(occ_combined, occ_crop_combined); gc()` releases ~40–120 GB (resolution-dependent) before the rendering loop; the original code held all species rasters in memory for the full duration of the run
- **Disk space guard** — aborts if free disk space is below 2 GB before rendering begins

### Performance
- **eBird S&T download skip** — validates that the local `.tif` is present and readable before attempting any download; completely skips species already cached
- **Combined crop+mask in one pass** — single `terra::mask(terra::crop(...))` call per species instead of two sequential `sapply` passes
- **Hardware detection** — physical and logical core count detected at startup; `n_workers` computed for future parallel steps
- **Skip existing outputs** — weekly PNG frames and the final animated GIF are skipped if they already exist; safe to resume interrupted runs or rerun at a different resolution

### Error recovery & observability
- **`load_raster_safe()`** — wraps `load_raster()` in a `tryCatch`; logs a warning and skips the species instead of halting the whole run if a raster fails to load
- **Elapsed-time logging** — all major phases (raster load, crop+mask, accumulation, reprojection, rendering) are timed and printed
- **Progress messages throughout** — step counts, species totals, and memory/disk status printed at each stage

### GIF generation
- **`magick` replaced by `gifski`** — `image_write_gif()` (gifski backend) instead of `image_animate()` + `image_write()`; eliminates an ImageMagick segfault and pixel-cache exhaustion that occurs when assembling large animated GIFs
- **`mapview` removed** — interactive call was removed; no longer a dependency

### New regions
- **`LifeR_NL.R`** — Netherlands adaptation; uses NL regional checklist and appropriate CRS/boundary

---

## Setup

### 1. System dependencies (Ubuntu/Debian)

```bash
sudo apt-get install -y libharfbuzz-dev libfribidi-dev
```

### 2. R packages

```r
source("install_packages.R")
```

### 3. API keys

You need two keys:

| Key | Purpose | Request at |
|-----|---------|------------|
| eBird Status & Trends key | Download occurrence rasters | https://ebird.org/st/request |
| eBird API key | Fetch regional species lists via `rebird` | https://ebird.org/api/keygen |

Copy `config_local.R.example` to `config_local.R` and fill in your keys:

```bash
cp config_local.R.example config_local.R
```

Then edit `config_local.R`:

```r
ebirdst_key   <- "YOUR_EBIRDST_KEY_HERE"
ebird_api_key <- "YOUR_EBIRD_API_KEY_HERE"
```

`config_local.R` is gitignored and will never be committed.

### 4. eBird personal data

Export your eBird data from https://ebird.org/downloadMyData and place the CSV as `MyEBirdData.csv` in the project directory.

---

## Running

Edit the parameters at the top of `LifeR_US.R` (region, resolution, theme, etc.), then:

```bash
Rscript LifeR_US.R
```

Output is saved to `Results/<username>/<region>/<needs_type>/<resolution>/`.

---

## Credits

Original code by **Sam Safran** — https://github.com/smsfrn/lifeR  
Fork maintained by [@hydrospheric0](https://github.com/hydrospheric0)
