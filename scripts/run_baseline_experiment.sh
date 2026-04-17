#!/usr/bin/env bash
set -euo pipefail

# Experimental runner:
#  1) Start hot_cold
#  2) Let the baseline run without injected contention

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <kernel_mode>" >&2
  echo "  kernel_mode must be one of: tpp, colloid" >&2
  exit 1
fi

readonly KERNEL_MODE="$1"

if [[ "${KERNEL_MODE}" != "tpp" && "${KERNEL_MODE}" != "colloid" ]]; then
  echo "[error] invalid kernel_mode '${KERNEL_MODE}'. Expected 'tpp' or 'colloid'." >&2
  exit 1
fi

# -------------------------------------------------------------------
# Experiment output directory (human-readable timestamp)
# -------------------------------------------------------------------
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
EXP_DIR="experiments/numa_baseline_experiment-${TIMESTAMP}"
mkdir -p "${EXP_DIR}"

CSV_OUT="${EXP_DIR}/memory_usage.csv"
PARAMS_OUT="${EXP_DIR}/experimental_params.yaml"

HOT_COLD_BIN="${HOT_COLD_BIN:-./apps/hot_cold/hot_cold}"
HOT_COLD_MEM_MB="${HOT_COLD_MEM_MB:-16384}"
SLOW_NUMA_NODE="${SLOW_NUMA_NODE:-1}"
HOT_COLD_TOUCH_PERCENT="${HOT_COLD_TOUCH_PERCENT:-25}"
HOT_COLD_CMD="${HOT_COLD_CMD:-${HOT_COLD_BIN} ${HOT_COLD_MEM_MB} ${SLOW_NUMA_NODE} ${HOT_COLD_TOUCH_PERCENT}}"

BASELINE_DURATION="${BASELINE_DURATION:-60}"

# -------------------------------------------------------------------
# Logs (kept separate from experiment artifacts)
# -------------------------------------------------------------------
LOGDIR="${LOGDIR:-./exp_logs_${TIMESTAMP}}"
mkdir -p "$LOGDIR"

hc_log="$LOGDIR/hot_cold.log"
hc_pid=""

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
kernel_mode: $(yaml_quote "${KERNEL_MODE}")
logdir: $(yaml_quote "${LOGDIR}")
hot_cold_log: $(yaml_quote "${hc_log}")
hot_cold_mem_mb: ${HOT_COLD_MEM_MB}
slow_numa_node: ${SLOW_NUMA_NODE}
hot_cold_touch_percent: ${HOT_COLD_TOUCH_PERCENT}
hot_cold_cmd: $(yaml_quote "${HOT_COLD_CMD}")
baseline_duration: ${BASELINE_DURATION}
EOF
}

if [[ ! -x "${HOT_COLD_BIN}" ]]; then
  echo "[error] hot_cold binary not found or not executable at '${HOT_COLD_BIN}'." >&2
  echo "[error] build it first, for example: make -C apps/hot_cold" >&2
  exit 1
fi

cleanup() {
  echo "[cleanup] stopping background processes..."
  [[ -n "${hc_pid}" ]] && kill "${hc_pid}" 2>/dev/null || true

  sleep 1
  [[ -n "${hc_pid}" ]] && kill -9 "${hc_pid}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[info] experiment dir: ${EXP_DIR}"
echo "[info] logs: ${LOGDIR}"
write_params_yaml
echo "[info] params: ${PARAMS_OUT}"

echo "[step] starting hot_cold..."
( exec ${HOT_COLD_CMD} ) >"$hc_log" 2>&1 &
hc_pid=$!
echo "[info] hot_cold pid=$hc_pid"

echo "[step] leaving hot_cold running for ${BASELINE_DURATION}s..."
sleep "${BASELINE_DURATION}"

echo "[done] experiment complete."
echo "       CSV: ${CSV_OUT}"
echo "       Params: ${PARAMS_OUT}"
echo "       Logs: ${LOGDIR}"
