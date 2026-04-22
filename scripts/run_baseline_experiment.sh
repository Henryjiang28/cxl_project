#!/usr/bin/env bash
set -euo pipefail

# Experimental runner:
#  1) Start hot_cold
#  2) Let the baseline run without injected contention

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <migration_mode> <GiB> <percent_hot> <touch_cycles>" >&2
  echo "  migration_mode must be 0 or 1" >&2
  echo "  GiB must be a positive integer" >&2
  echo "  percent_hot must be an integer in [0,100]" >&2
  echo "  touch_cycles must be -1 or a non-negative integer" >&2
  exit 1
fi

readonly MIGRATION_MODE="$1"
readonly HOT_COLD_MEM_GIB="$2"
readonly HOT_COLD_TOUCH_PERCENT="$3"
readonly HOT_COLD_TOUCH_CYCLES="$4"

if [[ "${MIGRATION_MODE}" != "0" && "${MIGRATION_MODE}" != "1" ]]; then
  echo "[error] invalid migration_mode '${MIGRATION_MODE}'. Expected '0' or '1'." >&2
  exit 1
fi

if ! [[ "${HOT_COLD_MEM_GIB}" =~ ^[0-9]+$ ]] || (( HOT_COLD_MEM_GIB == 0 )); then
  echo "[error] invalid GiB '${HOT_COLD_MEM_GIB}'. Expected a positive integer." >&2
  exit 1
fi

if ! [[ "${HOT_COLD_TOUCH_PERCENT}" =~ ^[0-9]+$ ]] || (( HOT_COLD_TOUCH_PERCENT < 0 || HOT_COLD_TOUCH_PERCENT > 100 )); then
  echo "[error] invalid percent_hot '${HOT_COLD_TOUCH_PERCENT}'. Expected an integer in [0,100]." >&2
  exit 1
fi

if ! [[ "${HOT_COLD_TOUCH_CYCLES}" =~ ^-?[0-9]+$ ]] || (( HOT_COLD_TOUCH_CYCLES < -1 )); then
  echo "[error] invalid touch_cycles '${HOT_COLD_TOUCH_CYCLES}'. Expected -1 or a non-negative integer." >&2
  exit 1
fi

# -------------------------------------------------------------------
# Experiment output directory (human-readable timestamp)
# -------------------------------------------------------------------
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
EXP_DIR="experiments/numa_baseline_experiment-${TIMESTAMP}"
mkdir -p "${EXP_DIR}"

CSV_OUT="${EXP_DIR}/memory_usage.csv"
PLOT_OUT="${EXP_DIR}/memory_usage.png"
PARAMS_OUT="${EXP_DIR}/experimental_params.yaml"

HOT_COLD_BIN="${HOT_COLD_BIN:-./workloads/hot_cold/hot_cold}"
readonly HOT_COLD_MEM_MB=$(( HOT_COLD_MEM_GIB * 1024 ))
SLOW_NUMA_NODE="${SLOW_NUMA_NODE:-1}"
HOT_COLD_CMD="${HOT_COLD_CMD:-${HOT_COLD_BIN} ${HOT_COLD_MEM_MB} ${SLOW_NUMA_NODE} ${HOT_COLD_TOUCH_PERCENT} ${HOT_COLD_TOUCH_CYCLES}}"
HOT_COLD_PROC_NAME="${HOT_COLD_PROC_NAME:-$(basename "${HOT_COLD_BIN}")}"

BASELINE_DURATION="${BASELINE_DURATION:-120}"
PLOTTER_SRC_DIR="${PLOTTER_SRC_DIR:-./tools/numa_mem_plot/src}"

# -------------------------------------------------------------------
# Logs (kept separate from experiment artifacts)
# -------------------------------------------------------------------
LOGDIR="${LOGDIR:-./exp_logs_${TIMESTAMP}}"
mkdir -p "$LOGDIR"

hc_log="$LOGDIR/hot_cold.log"
plotter_log="$LOGDIR/numa_mem_plot.log"
hc_pid=""
plotter_pid=""

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

write_params_yaml() {
  cat >"${PARAMS_OUT}" <<EOF
timestamp: $(yaml_quote "${TIMESTAMP}")
experiment_dir: $(yaml_quote "${EXP_DIR}")
csv_out: $(yaml_quote "${CSV_OUT}")
plot_out: $(yaml_quote "${PLOT_OUT}")
migration_mode: $(yaml_quote "${MIGRATION_MODE}")
logdir: $(yaml_quote "${LOGDIR}")
hot_cold_log: $(yaml_quote "${hc_log}")
plotter_log: $(yaml_quote "${plotter_log}")
hot_cold_mem_gib: ${HOT_COLD_MEM_GIB}
hot_cold_mem_mb: ${HOT_COLD_MEM_MB}
slow_numa_node: ${SLOW_NUMA_NODE}
hot_cold_touch_percent: ${HOT_COLD_TOUCH_PERCENT}
hot_cold_touch_cycles: ${HOT_COLD_TOUCH_CYCLES}
hot_cold_proc_name: $(yaml_quote "${HOT_COLD_PROC_NAME}")
hot_cold_cmd: $(yaml_quote "${HOT_COLD_CMD}")
baseline_duration: ${BASELINE_DURATION}
plotter_src_dir: $(yaml_quote "${PLOTTER_SRC_DIR}")
EOF
}

if [[ ! -x "${HOT_COLD_BIN}" ]]; then
  echo "[error] hot_cold binary not found or not executable at '${HOT_COLD_BIN}'." >&2
  echo "[error] build it first, for example: make -C apps/hot_cold" >&2
  exit 1
fi

if ! command -v numastat >/dev/null 2>&1; then
  echo "[error] numastat is not installed or not in PATH." >&2
  echo "[error] install dependencies first, for example: scripts/install_dependencies.sh" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[error] python3 is not installed or not in PATH." >&2
  echo "[error] install dependencies first, for example: scripts/install_dependencies.sh" >&2
  exit 1
fi

if [[ ! -f "${PLOTTER_SRC_DIR}/numa_mem_plot/__main__.py" ]]; then
  echo "[error] numa_mem_plot module not found at '${PLOTTER_SRC_DIR}'." >&2
  echo "[error] initialize submodules first, for example: git submodule update --init --recursive" >&2
  exit 1
fi

if ! python3 -c 'import matplotlib' >/dev/null 2>&1; then
  echo "[error] python3 matplotlib is not installed." >&2
  echo "[error] install dependencies first, for example: scripts/install_dependencies.sh" >&2
  exit 1
fi

cleanup() {
  echo "[cleanup] stopping background processes..."
  [[ -n "${plotter_pid}" ]] && kill "${plotter_pid}" 2>/dev/null || true
  [[ -n "${hc_pid}" ]] && kill "${hc_pid}" 2>/dev/null || true

  sleep 1
  [[ -n "${plotter_pid}" ]] && kill -9 "${plotter_pid}" 2>/dev/null || true
  [[ -n "${hc_pid}" ]] && kill -9 "${hc_pid}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

start_plotter() {
  mkdir -p "${EXP_DIR}/.matplotlib" "${EXP_DIR}/.cache"
  MPLCONFIGDIR="${EXP_DIR}/.matplotlib" \
    XDG_CACHE_HOME="${EXP_DIR}/.cache" \
    PYTHONPATH="${PLOTTER_SRC_DIR}${PYTHONPATH:+:${PYTHONPATH}}" \
    python3 -m numa_mem_plot \
      --proc "${HOT_COLD_PROC_NAME}" \
      --interval 1 \
      --duration "${BASELINE_DURATION}" \
      --csv "${CSV_OUT}" \
      --out "${PLOT_OUT}" \
      >"${plotter_log}" 2>&1 &
  plotter_pid=$!
}

echo "[info] experiment dir: ${EXP_DIR}"
echo "[info] logs: ${LOGDIR}"
write_params_yaml
echo "[info] params: ${PARAMS_OUT}"

echo "[step] starting hot_cold..."
( exec ${HOT_COLD_CMD} ) >"$hc_log" 2>&1 &
hc_pid=$!
echo "[info] hot_cold pid=$hc_pid"

echo "[step] starting NUMA memory plotter..."
start_plotter
echo "[info] plotter pid=$plotter_pid"

echo "[step] leaving hot_cold running for ${BASELINE_DURATION}s..."
sleep "${BASELINE_DURATION}"

wait "${plotter_pid}" 2>/dev/null || true
plotter_pid=""

echo "[done] experiment complete."
echo "       CSV: ${CSV_OUT}"
echo "       Plot: ${PLOT_OUT}"
echo "       Params: ${PARAMS_OUT}"
echo "       Logs: ${LOGDIR}"
