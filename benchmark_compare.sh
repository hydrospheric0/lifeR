#!/usr/bin/env bash
# benchmark_compare.sh — compare timing and RAM between the original Sam Safran
# script (lifeR_original_runnable.R) and the current optimised version (LifeR_US.R).
#
# Usage:
#   ./benchmark_compare.sh                     # default: 27km, both scripts
#   ./benchmark_compare.sh 9km                 # run at 9km
#   ./benchmark_compare.sh 27km original       # run only original
#   ./benchmark_compare.sh 27km current        # run only current
#
# Output:
#   benchmark_results/YYYY-MM-DD_HH-MM/original_<res>.log
#   benchmark_results/YYYY-MM-DD_HH-MM/current_<res>.log
#   benchmark_results/YYYY-MM-DD_HH-MM/ram_sample_*.tsv   (sampled every 2s)
#   benchmark_results/YYYY-MM-DD_HH-MM/summary.txt

set -euo pipefail

RESOLUTION="${1:-27km}"
WHICH="${2:-both}"        # "original", "current", or "both"
RSCRIPT="${RSCRIPT:-Rscript}"
BENCH_STAMP="$(date +%Y-%m-%d_%H-%M)"
OUT_DIR="benchmark_results/${BENCH_STAMP}"
mkdir -p "${OUT_DIR}"

echo "============================================================"
echo "  LifeR benchmark — ${BENCH_STAMP}"
echo "  Resolution : ${RESOLUTION}"
echo "  Running    : ${WHICH}"
echo "  Output dir : ${OUT_DIR}"
echo "============================================================"

# ── Helper: sample /proc/meminfo every 2s into a TSV while a PID is alive ───
sample_ram() {
  local pid=$1
  local out=$2
  printf "elapsed_s\tMemAvailable_GB\tMemUsed_GB\n" >"${out}"
  local t0
  t0=$(date +%s)
  while kill -0 "${pid}" 2>/dev/null; do
    local now elapsed avail total used
    now=$(date +%s)
    elapsed=$(( now - t0 ))
    avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    used=$(( total - avail ))
    printf "%d\t%.2f\t%.2f\n" "${elapsed}" "$(echo "$avail/1000000" | bc -l)" "$(echo "$used/1000000" | bc -l)" >>"${out}"
    sleep 2
  done
}

# ── Helper: run one script, capture log + peak RSS ────────────────────────────
run_script() {
  local label=$1       # "original" | "current"
  local script=$2      # path to .R file
  local logfile="${OUT_DIR}/${label}_${RESOLUTION}.log"
  local ram_tsv="${OUT_DIR}/ram_sample_${label}_${RESOLUTION}.tsv"
  local time_out="${OUT_DIR}/time_${label}_${RESOLUTION}.txt"

  echo ""
  echo "── Running: ${label} (${RESOLUTION}) ──────────────────────────────"
  echo "   Script : ${script}"
  echo "   Log    : ${logfile}"

  export BENCH_RESOLUTION="${RESOLUTION}"

  # Start background RAM sampler — we'll inject the PID after Rscript starts.
  # Use a wrapper: run Rscript under /usr/bin/time -v, capture stderr to logfile.
  # /usr/bin/time -v writes its summary to stderr; Rscript messages also go to stderr.
  # We split them by post-processing.

  /usr/bin/time -v \
    "${RSCRIPT}" --vanilla "${script}" \
    2>&1 | tee "${logfile}" &
  local rscript_pid=$!

  # Start RAM sampler against the same shell group (best effort)
  sample_ram "${rscript_pid}" "${ram_tsv}" &
  local sampler_pid=$!

  # Wait for Rscript to finish
  wait "${rscript_pid}" || true
  wait "${sampler_pid}" 2>/dev/null || true

  echo "   Done. Log: ${logfile}"
}

# ── Extract summary stats from a log file ────────────────────────────────────
summarise_log() {
  local label=$1
  local logfile="${OUT_DIR}/${label}_${RESOLUTION}.log"
  local ram_tsv="${OUT_DIR}/ram_sample_${label}_${RESOLUTION}.tsv"
  [ -f "${logfile}" ] || { echo "  [missing] ${logfile}"; return; }

  echo ""
  echo "── ${label} (${RESOLUTION}) ──────────────────────────────────────"

  # Wall time from /usr/bin/time -v
  local wall elapsed_user elapsed_sys peak_rss
  wall=$(grep "Elapsed (wall clock)" "${logfile}" | tail -1 | sed 's/.*: //')
  elapsed_user=$(grep "User time" "${logfile}" | tail -1 | sed 's/.*: //')
  elapsed_sys=$(grep "System time" "${logfile}" | tail -1 | sed 's/.*: //')
  peak_rss=$(grep "Maximum resident set size" "${logfile}" | tail -1 | sed 's/.*: //;s/ kbytes//')

  echo "  Wall time   : ${wall:-n/a}"
  echo "  User CPU    : ${elapsed_user:-n/a}"
  echo "  System CPU  : ${elapsed_sys:-n/a}"
  if [ -n "${peak_rss}" ] && [ "${peak_rss}" != "n/a" ]; then
    local peak_gb
    peak_gb=$(echo "${peak_rss}/1000000" | bc -l 2>/dev/null | xargs printf "%.1f")
    echo "  Peak RSS    : ${peak_gb} GB  (${peak_rss} KB)"
  else
    echo "  Peak RSS    : n/a"
  fi

  # [BENCH] checkpoints from the R scripts
  echo "  Phase breakdown:"
  grep "\[BENCH\]" "${logfile}" | while IFS= read -r line; do
    echo "    ${line}"
  done

  # Peak sampled RAM usage
  if [ -f "${ram_tsv}" ] && [ "$(wc -l < "${ram_tsv}")" -gt 1 ]; then
    local peak_used
    peak_used=$(awk 'NR>1{if($3>max)max=$3}END{printf "%.1f GB", max}' "${ram_tsv}")
    echo "  Peak RAM used (sampled): ${peak_used}"
  fi

  # Exit code
  if grep -q "Execution halted" "${logfile}"; then
    echo "  STATUS: *** FAILED (Execution halted) ***"
  elif grep -q "Error:" "${logfile}"; then
    echo "  STATUS: *** FAILED (Error found in log) ***"
  else
    echo "  STATUS: OK"
  fi
}

# ── Main ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${WHICH}" == "both" || "${WHICH}" == "original" ]]; then
  run_script "original" "${SCRIPT_DIR}/lifeR_original_runnable.R"
fi

if [[ "${WHICH}" == "both" || "${WHICH}" == "current" ]]; then
  run_script "current"  "${SCRIPT_DIR}/LifeR_US.R"
fi

# ── Summary report ────────────────────────────────────────────────────────────
SUMMARY="${OUT_DIR}/summary.txt"
{
  echo "LifeR benchmark summary — ${BENCH_STAMP}"
  echo "Resolution: ${RESOLUTION}"
  echo ""
  if [[ "${WHICH}" == "both" || "${WHICH}" == "original" ]]; then
    summarise_log "original"
  fi
  if [[ "${WHICH}" == "both" || "${WHICH}" == "current" ]]; then
    summarise_log "current"
  fi
} | tee "${SUMMARY}"

echo ""
echo "Full logs in: ${OUT_DIR}"
