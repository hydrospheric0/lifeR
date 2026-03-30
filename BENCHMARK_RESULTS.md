# lifeR Benchmark Results

Machine: 48-core / 255 GB RAM, NVMe SSD, Linux  
Scripts: `lifeR_original_runnable.R` (Sam's original, adapted for unattended run) vs `LifeR_US.R` (this fork)  
Region: US (CONUS), 561 species with S&T models, regional needs list  
All data cached locally (no network I/O). Frames skipped if already on disk.

---

## Summary: current script across all resolutions

| Resolution | Run type | Wall time | Accumulation | Peak RSS |
|-----------|----------|-----------|-------------|---------|
| 27km | cold (no cache) | **3:12** | 1:04 | 0.9 GB |
| 27km | warm (cache hit) | **1:30** | 0:38 | 1.4 GB |
| 9km  | cold (no cache) | **8:49** | 7:44 | 1.5 GB |
| 3km  | cold (no cache) | **~30:xx** | ~27:xx | ~7 GB |
| 3km  | warm (cache hit)| **~4:xx**  | ~2:xx  | ~7 GB |

3km warm-cache estimate based on 9km ratio (~5× faster accumulation on cache hits).  
Cold run: reads TIFs + writes .bin cache + creates .skip markers (one-time overhead).  
Warm run: reads .bin files only (194 × ~46 MB vs 561 × 332 MB TIFs).

---

## Original vs current: 27km

| Metric | Original (Sam's) | Current (cold) | Current (warm) |
|--------|-----------------|----------------|----------------|
| Wall time | 1:26 | 3:12 | **1:30** |
| Accumulation | 25s | 1:04 | 0:38 |
| Reproject | 7s | 6s | 6s |
| Frame render | ~0s (cached) | 30s | ~0s (cached) |
| **Peak RSS** | **7.4 GB** | **0.9 GB** | **1.4 GB** |

---

## Original vs current: 9km

| Metric | Original (Sam's) | Current (cold) | Current (warm) |
|--------|-----------------|----------------|----------------|
| Wall time | 5:37 | **8:49** | **~2:xx** |
| Accumulation | 1:26 | 7:44 | ~1:xx |
| Peak at crop+mask | **71.4 GB** | n/a | n/a |
| Reproject | 13s | 12s | 12s |
| Frame render | ~0s (cached) | 40s | ~0s (cached) |
| **Peak RSS** | **64.2 GB** | **1.5 GB** | **1.5 GB** |

Original peaks at 64 GB during batch crop+mask. OOMs on any machine <70 GB.  
Current streams one species at a time; stays under 2 GB throughout.

---

## Original vs current: 3km

| Metric | Original (Sam's) | Current (cold) | Current (warm) |
|--------|-----------------|----------------|----------------|
| Wall time | OOM / untested | **~30 min** | **~4 min** |
| Peak RSS | OOM (est. >>200 GB) | **~7 GB** | **~7 GB** |

Original would load 561 × 332 MB = ~186 GB simultaneously before crop+mask. Not runnable on any machine <200 GB RAM.

---

## Key optimizations in this fork

| Optimization | Effect |
|-------------|--------|
| **Boundary mask pre-computed once** | Eliminates ~500 polygon rasterizations; reused as logical vector |
| **Logical mask subsetting** | `vals[!outside_mask,]` bulk copy vs `vals[inside_idx,]` fancy indexing — substantially faster |
| **Inside-only accumulator** | `(n_inside × 52)` not `(n_cells × 52)`; no full-grid scatter per species |
| **uint8 .bin cache (side effect)** | Written on first run; reruns read 46 MB instead of 332 MB TIF — ~7× less I/O |
| **.skip marker for below-threshold** | Future runs skip 367 TIF reads entirely (species confirmed absent in region) |
| **Single wrap-back scatter** | One `v[inside_idx] <- accum[,wk]` per week at end, not per species |
| **Peak RSS: float64 freed immediately** | `rm(vals_full)` before any further allocations keeps peak under 2 GB |
| **Single-layer raster template** | `raster_template[[1L]]` prevents 52-layer copies into possible_lifers list |
| **gifski replaces magick** | Rust GIF encoder — no ImageMagick pixel-cache OOM, no segfault on large frames |
| **Cached NaturalEarth boundaries** | `ne_admin1_large.rds` — skips network call on reruns |
| **Frame/GIF skip if exists** | Resume-safe: reruns skip already-rendered PNGs and existing GIFs |

---

## Phase timeline (9km, cold cache)

```
  0s   START              (packages loaded, hardware detected)
  6s   species_discovery  (eBird API + taxonomy join: 561 modelled needs)
  8s   download_check     (all TIFs cached, no downloads)
464s   after_accumulation (streaming: 561 species, 194 pass threshold)
477s   after_reproject    (52 rasters EPSG:8857 -> EPSG:5070)
517s   after_frame_render (52 PNG frames @ 1920x1600)
529s   DONE               (hi-res + lo-res GIF assembled)
```


---

## Summary: current script (LifeR_US.R) across all resolutions

| Resolution | Wall time | Accumulation | Reproject | Frame render | GIF assembly | Peak RSS |
|-----------|-----------|-------------|-----------|-------------|-------------|---------|
| 27km | **3:12** | 2:20 | 6s | 30s | 6s | 3.1 GB |
| 9km  | **9:08** | 8:11 | 12s | 39s | 6s | 18.7 GB |
| 3km  | **30:40** | 28:00 | 52s | 1:40 | 7s | 41.0 GB |

Accumulation dominates — 78-91% of total wall time at all resolutions.  
3km is runnable on any machine with >=50 GB RAM; 9km needs ~20 GB.

---

## Original vs current: 27km

| Metric | Original (Sam's) | Current (this fork) | Change |
|--------|-----------------|---------------------|--------|
| Wall time | 1:26 | 3:12 | +2x wall* |
| Batch load | 12s | n/a (streaming) | |
| Crop + mask | 41s | included in accum | |
| Accumulation | 25s | 2:20 | |
| Reproject | 7s | 6s | ~same |
| Frame render | ~0s (cached) | 30s | |
| GIF assembly | ~0s (cached) | 6s | |
| **Peak RSS** | **7.4 GB** | **3.1 GB** | **-2.4x RAM** |

*Original loaded all 561 species into RAM at once (fast at 27km), frames were already cached from a prior run. Fair comparison on core computation (excluding cached frames): original ~85s total vs current ~155s — original batch faster at 27km because terra's vectorised sum over tiny rasters outweighs streaming overhead.

---

## Original vs current: 9km

| Metric | Original (Sam's) | Current (this fork) | Change |
|--------|-----------------|---------------------|--------|
| Wall time | 5:37 | 9:08 | +1.6x wall* |
| Batch load | 12s | n/a (streaming) | |
| Crop + mask | **3:45** | included in accum | |
| Accumulation | 1:26 | 8:11 | |
| RAM peak at crop+mask | **71.4 GB** | n/a (peak at accum) | |
| Reproject | 13s | 12s | ~same |
| Frame render | ~0s (cached) | 39s | |
| GIF assembly | ~0s (cached) | 6s | |
| **Peak RSS** | **64.2 GB** | **18.7 GB** | **-3.4x RAM** |

*Frames were cached for the original script run. Core computation (excl. frames/GIF): original ~336s vs current ~540s — original batch faster when it fits in RAM.

**The critical point:** original peaks at 64 GB during a single crop+mask pass over all 561 species held simultaneously in RAM. On a 32 GB machine it would OOM here. Current script streams one species at a time, staying under 20 GB throughout.

---

## Original vs current: 3km

| Metric | Original (Sam's) | Current (this fork) |
|--------|-----------------|---------------------|
| Wall time | OOM / untested | 30:40 |
| Peak RSS | OOM (estimated >>200 GB) | **41.0 GB** |

Original would load 561 species x 332 MB each = ~186 GB of float32 rasters simultaneously before the crop+mask pass. Not runnable on any machine <200 GB RAM.

---

## Key optimizations in this fork

| Optimization | Effect |
|-------------|--------|
| **Chunked streaming accumulation** | Never holds >1 week-layer per species in RAM; peak RSS scales with chunk size not total species count |
| **Auto-sized chunks** | `chunk_size = floor(avail_RAM * 0.40 / (sp_size_GB * 3))` — fills available RAM without exceeding it |
| **Vectorised week sum via terra::app()** | Within each chunk: one C++ pass over N species instead of N sequential `+` operations |
| **rm() + gc() after each chunk** | Releases raster memory immediately; OS can reclaim before next chunk |
| **terra memfrac set dynamically** | `min(0.85, avail/total * 0.80)` at runtime rather than fixed 0.6 default |
| **SpatRaster freed before rendering** | `rm(possible_lifers); gc()` releases accumulator stack before frame loop |
| **Probe-based raster sizing** | Crops first species to get actual cell count; drives chunk_size without guessing |
| **magick replaced by gifski** | Rust-based GIF encoder: no ImageMagick pixel-cache OOM, no segfault on large frames |
| **Cached NaturalEarth boundaries** | `ne_admin1_large.rds` — skips network call on all reruns |
| **Frame skip if exists** | Resume-safe: reruns skip already-rendered PNGs and existing GIFs |
| **study_area_vect recreated per chunk** | Guards against terra invalidating gc()-collected SpatVector backing |

---

## Phase timeline (9km, latest run)

```
  0s   START          (packages loaded, hardware detected)
  6s   species_discovery  (eBird API + taxonomy join: 561 modelled needs)
  8s   download_check     (all 561 tifs cached, no downloads)
 490s  after_accumulation (streaming crop+mask+sum: 561 species, 6 chunks)
 503s  after_reproject    (52 rasters EPSG:8857 -> EPSG:5070)
 542s  after_frame_render (52 PNG frames @ 1920x1600)
 548s  DONE               (hi-res + lo-res GIF assembled)
```
