#!/usr/bin/env bash
# benchmark.sh — Run LifeR_US.R at 27km, 9km, and 3km, collecting wall time
#                and peak RSS for each resolution.
#
# Usage:
#   ./benchmark.sh              # all three resolutions
#   ./benchmark.sh 9km          # single resolution
#   ./benchmark.sh 27km 9km     # specific resolutions
#
# Outputs:
#   benchmark_results/<timestamp>/  — per-resolution logs
#   BENCHMARK_RESULTS.md            — appended summary table

set -euo pipefail

cd "$(dirname "$0")"

RESOLUTIONS=("${@:-27km 9km 3km}")
if [ "$#" -eq 0 ]; then
  RESOLUTIONS=("27km" "9km" "3km")
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT_DIR="benchmark_results/${TIMESTAMP}"
TIME_BIN="/usr/bin/time"

if ! [ -x "$TIME_BIN" ]; then
  echo "ERROR: /usr/bin/time not found (install with: sudo apt-get install time)"
  exit 1
fi

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
parse_wall() {
  grep -i "Elapsed (wall clock)" "$1" 2>/dev/null | awk '{print $NF}' | head -1 || echo "N/A"
}
wall_to_sec() {
  local t="$1"
  [[ "$t" == "N/A" ]] && echo "N/A" && return
  IFS=: read -r -a parts <<< "$t"
  local n=${#parts[@]}
  if   [[ $n -eq 3 ]]; then echo $(( parts[0]*3600 + parts[1]*60 + ${parts[2]%.*} ))
  elif [[ $n -eq 2 ]]; then echo $(( parts[0]*60   + ${parts[1]%.*} ))
  else echo "${parts[0]%.*}"
  fi
}
parse_rss_mb() {
  local kb
  kb=$(grep -i "Maximum resident set size" "$1" 2>/dev/null | awk '{print $NF}' | head -1) || true
  [[ -z "$kb" || "$kb" == "N/A" ]] && echo "N/A" && return
  awk "BEGIN {printf \"%.0f MB\", $kb / 1024}"
}
parse_rss_gb() {
  local kb
  kb=$(grep -i "Maximum resident set size" "$1" 2>/dev/null | awk '{print $NF}' | head -1) || true
  [[ -z "$kb" || "$kb" == "N/A" ]] && echo "N/A" && return
  awk "BEGIN {printf \"%.1f GB\", $kb / 1048576}"
}
count_frames() {
  local jpg png
  jpg=$(find "$1" -maxdepth 1 -name "*.jpg" 2>/dev/null | wc -l)
  png=$(find "$1" -maxdepth 1 -name "*.png" 2>/dev/null | wc -l)
  echo $(( jpg + png ))
}

# Scripts to benchmark: original (committed) and current (with enhancements)
SCRIPTS=("LifeR_US_original.R" "LifeR_US.R")
SCRIPT_LABELS=("original" "current")

if [ ! -f "LifeR_US_original.R" ]; then
  echo "ERROR: LifeR_US_original.R not found. Extract it first with:"
  echo "  git show HEAD:LifeR_US.R > LifeR_US_original.R"
  exit 1
fi

echo "╔══════════════════════════════════════════════════════════╗"
printf "║  lifeR+ benchmark  •  %-33s║\n" "$(date '+%Y-%m-%d %H:%M')  "
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Resolutions: ${RESOLUTIONS[*]}"
echo "║  Scripts:     ${SCRIPT_LABELS[*]}"
echo "║  Log dir:     $OUT_DIR"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

declare -a MD_ROWS=()

for SCRIPT_IDX in "${!SCRIPTS[@]}"; do
  SCRIPT="${SCRIPTS[$SCRIPT_IDX]}"
  LABEL="${SCRIPT_LABELS[$SCRIPT_IDX]}"

  echo ""
  echo "██████████████████████████████████████████████████████████████"
  echo "  Script: ${LABEL} (${SCRIPT})"
  echo "██████████████████████████████████████████████████████████████"

  for RES in "${RESOLUTIONS[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ${LABEL} @ ${RES}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  RES_LOG="${OUT_DIR}/${LABEL}_${RES}"
  mkdir -p "$RES_LOG"

  STDOUT_LOG="${RES_LOG}/stdout.txt"
  TIME_LOG="${RES_LOG}/time.txt"

  # Clean previous results for this resolution so we get a fresh timed run
  rm -rf "Results/bartwickel/US/regional/${RES}/Weekly_maps"/*.jpg 2>/dev/null || true
  rm -rf "Results/bartwickel/US/regional/${RES}/Weekly_maps"/*.png 2>/dev/null || true
  rm -rf "Results/bartwickel/US/regional/${RES}/Animated_map"/*.gif 2>/dev/null || true

  # Create a temporary wrapper that overrides resolution in the target script
  WRAPPER="${RES_LOG}/run_${LABEL}_${RES}.R"
  LIFER_DIR="$(pwd)"
  cat > "$WRAPPER" <<EOF
# Benchmark wrapper — sets resolution then sources ${SCRIPT}
.libPaths(c(path.expand("~/R/library"), .libPaths()))
t_total_start <- proc.time()["elapsed"]
# Override resolution before sourcing
local({
  lines <- readLines("${LIFER_DIR}/${SCRIPT}")
  idx <- grep('^resolution <- ', lines)
  if (length(idx) > 0) {
    lines[idx[1]] <- 'resolution <- "${RES}"'
  }
  tmp <- tempfile(fileext = ".R")
  writeLines(lines, tmp)
  source(tmp, local = FALSE)
})
cat(sprintf("\\n[TOTAL] %s wall time: %.1fs\\n", "${RES}", proc.time()["elapsed"] - t_total_start))
EOF

  # Redirect: stdout+R-messages → stdout.txt, /usr/bin/time stats → time.txt
  # Use a wrapper fd trick: R's stderr (messages) merges with stdout into stdout.txt,
  # while /usr/bin/time writes to fd3 redirected to time.txt.
  "$TIME_BIN" -v -o "$TIME_LOG" Rscript "$WRAPPER" > "$STDOUT_LOG" 2>&1 || true

  WALL=$(parse_wall "$TIME_LOG")
  SEC=$(wall_to_sec "$WALL")
  RSS_MB=$(parse_rss_mb "$TIME_LOG")
  RSS_GB=$(parse_rss_gb "$TIME_LOG")
  WEEKLY_DIR="Results/bartwickel/US/regional/${RES}/Weekly_maps"
  N_FRAMES=$(count_frames "$WEEKLY_DIR" 2>/dev/null || echo "0")

  echo "  Wall: $WALL ($SEC s)  Peak RSS: $RSS_MB  Frames: $N_FRAMES"
  echo ""

  MD_ROWS+=("| ${LABEL} | ${RES} | ${WALL} | ${SEC} | ${RSS_GB} | ${N_FRAMES} frames |")

  # Extract phase timings from stdout
  grep -E "complete in|Loaded .* rasters in" "$STDOUT_LOG" 2>/dev/null | sed 's/^/  /' > "${RES_LOG}/phases.txt" || true
  cat "${RES_LOG}/phases.txt"
  echo ""
  done
done

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  SUMMARY                                                        ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
for row in "${MD_ROWS[@]}"; do
  printf "║  %-64s║\n" "$row"
done
echo "╚══════════════════════════════════════════════════════════════════╝"

# Append to markdown results file
{
  echo ""
  echo "## Run: ${TIMESTAMP} — lifeR+ benchmark (original vs current)"
  echo ""
  echo "| Script | Resolution | Wall time | Seconds | Peak RSS | Output |"
  echo "|--------|-----------|----------|---------|----------|--------|"
  for row in "${MD_ROWS[@]}"; do
    echo "$row"
  done
  echo ""
  for SCRIPT_IDX in "${!SCRIPTS[@]}"; do
    LABEL="${SCRIPT_LABELS[$SCRIPT_IDX]}"
    for RES in "${RESOLUTIONS[@]}"; do
      PFILE="${OUT_DIR}/${LABEL}_${RES}/phases.txt"
      if [ -f "$PFILE" ] && [ -s "$PFILE" ]; then
        echo "**${LABEL} ${RES} phases:**"
        cat "$PFILE"
        echo ""
      fi
    done
  done
  echo "---"
} >> "BENCHMARK_RESULTS.md"

echo ""
echo "Results appended to BENCHMARK_RESULTS.md"
echo "Logs in $OUT_DIR/"
