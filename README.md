# lifeR

---

This R script was developed by Samuel Safran to generate personal maps of potential lifer birds using ebirdst and terra. See his post here for overview: https://smsfrn.github.io/posts/2024/01/lifer-mapper/

This repository is a fork of [smsfrn/lifeR](https://github.com/smsfrn/lifeR). Changes made in this fork are documented in the commit history and summarized below.

---

## Changes from upstream

- **User R library path** — added `.libPaths()` so packages installed to `~/R/library` are found without modifying system R
- **API keys removed from source** — keys are now loaded from a gitignored `config_local.R` file (see setup below); no credentials are ever committed
- **`separate()` warning fix** — added `fill = "right"` to suppress spurious NA warning for country-only region codes (e.g. `"US"`)
- **NaturalEarth data cached** — `ne_download()` result is saved to `ne_admin1_large.rds` on first run and reloaded instantly on subsequent runs
- **eBird S&T download skip** — species whose local `.tif` already exists are skipped entirely, avoiding redundant network calls on reruns
- **GIF generation fixed** — replaced `image_animate()` + `image_write()` with `image_write_gif()` (gifski backend) to avoid an ImageMagick segfault and pixel-cache exhaustion when writing large animated GIFs
- **No overwriting of existing outputs** — weekly map JPEGs and animated GIFs are skipped if they already exist; safe to rerun at a different resolution without touching prior results
- **`install_packages.R`** — added a standalone installer script with notes on required system libraries

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
