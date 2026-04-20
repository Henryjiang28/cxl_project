#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <GiB> <hundreds_of_lookups>" >&2
  echo "  GiB must be a positive integer" >&2
  echo "  hundreds_of_lookups must be a non-negative integer" >&2
  exit 1
fi

readonly MEMORY_GIB="$1"
readonly LOOKUP_HUNDREDS="$2"

if ! [[ "${MEMORY_GIB}" =~ ^[0-9]+$ ]] || (( MEMORY_GIB == 0 )); then
  echo "[error] invalid GiB '${MEMORY_GIB}'. Expected a positive integer." >&2
  exit 1
fi

if ! [[ "${LOOKUP_HUNDREDS}" =~ ^[0-9]+$ ]]; then
  echo "[error] invalid hundreds_of_lookups '${LOOKUP_HUNDREDS}'. Expected a non-negative integer." >&2
  exit 1
fi

readonly TARGET_CPU_NUMA_NODE=0
readonly TARGET_MEM_NUMA_NODE=1
readonly ELEMENTS_PER_GIB=8000000
readonly NUM_ELEMENTS=$(( MEMORY_GIB * ELEMENTS_PER_GIB ))
readonly NUM_LOOKUPS=$(( LOOKUP_HUNDREDS * 100 ))
readonly TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
readonly EXP_DIR="experiments/mitosis_btree_experiment-${TIMESTAMP}"
readonly CSV_OUT="${EXP_DIR}/numa_memory_usage.csv"
readonly PLOT_OUT="${EXP_DIR}/numa_memory_usage.png"
readonly JSON_OUT="${EXP_DIR}/timing.json"
readonly PARAMS_OUT="${EXP_DIR}/experimental_params.yaml"
readonly LOGDIR="./exp_logs_${TIMESTAMP}"
readonly WORKLOAD_BIN="${WORKLOAD_BIN:-./workloads/mitosis-workload-btree/bin/bench_btree_mt}"
readonly WORKLOAD_CMD="${WORKLOAD_CMD:-${WORKLOAD_BIN} -p ${TARGET_CPU_NUMA_NODE} -m {TARGET_MEM_NUMA_NODE} -- -n ${NUM_ELEMENTS} -l ${NUM_LOOKUPS}}"
readonly WORKLOAD_PROC_NAME="$(basename "${WORKLOAD_BIN}")"
readonly SAMPLE_INTERVAL_SECS="${SAMPLE_INTERVAL_SECS:-1}"
readonly PLOTTER_MAX_DURATION_SECS="${PLOTTER_MAX_DURATION_SECS:-86400}"
readonly PLOTTER_SRC_DIR="${PLOTTER_SRC_DIR:-./tools/numa_mem_plot/src}"

mkdir -p "${EXP_DIR}" "${LOGDIR}"

readonly WORKLOAD_LOG="${LOGDIR}/bench_btree_mt.log"
readonly PLOTTER_LOG="${LOGDIR}/numa_mem_plot.log"

workload_pid=""
sampler_pid=""
workload_exit_code=0

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
numa_csv_out: $(yaml_quote "${CSV_OUT}")
numa_plot_out: $(yaml_quote "${PLOT_OUT}")
timing_json_out: $(yaml_quote "${JSON_OUT}")
target_cpu_numa_node: ${TARGET_CPU_NUMA_NODE}
target_mem_numa_node: ${TARGET_MEM_NUMA_NODE}
memory_gib: ${MEMORY_GIB}
elements_per_gib: ${ELEMENTS_PER_GIB}
num_elements: ${NUM_ELEMENTS}
lookup_hundreds: ${LOOKUP_HUNDREDS}
num_lookups: ${NUM_LOOKUPS}
sample_interval_secs: ${SAMPLE_INTERVAL_SECS}
plotter_max_duration_secs: ${PLOTTER_MAX_DURATION_SECS}
workload_proc_name: $(yaml_quote "${WORKLOAD_PROC_NAME}")
plotter_src_dir: $(yaml_quote "${PLOTTER_SRC_DIR}")
workload_bin: $(yaml_quote "${WORKLOAD_BIN}")
workload_cmd: $(yaml_quote "${WORKLOAD_CMD}")
workload_log: $(yaml_quote "${WORKLOAD_LOG}")
plotter_log: $(yaml_quote "${PLOTTER_LOG}")
EOF
}

cleanup() {
  [[ -n "${sampler_pid}" ]] && kill "${sampler_pid}" 2>/dev/null || true
  [[ -n "${workload_pid}" ]] && kill "${workload_pid}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [[ ! -x "${WORKLOAD_BIN}" ]]; then
  echo "[error] workload binary not found or not executable at '${WORKLOAD_BIN}'." >&2
  echo "[error] build it first, for example: make -C workloads/mitosis-workload-btree" >&2
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

start_plotter() {
  mkdir -p "${EXP_DIR}/.matplotlib" "${EXP_DIR}/.cache"
  MPLCONFIGDIR="${EXP_DIR}/.matplotlib" \
    XDG_CACHE_HOME="${EXP_DIR}/.cache" \
    PYTHONPATH="${PLOTTER_SRC_DIR}${PYTHONPATH:+:${PYTHONPATH}}" \
    python3 -m numa_mem_plot \
      --proc "${WORKLOAD_PROC_NAME}" \
      --interval "${SAMPLE_INTERVAL_SECS}" \
      --duration "${PLOTTER_MAX_DURATION_SECS}" \
      --csv "${CSV_OUT}" \
      --out "${PLOT_OUT}" \
      >"${PLOTTER_LOG}" 2>&1 &
  sampler_pid=$!
}

write_params_yaml

echo "[info] experiment dir: ${EXP_DIR}"
echo "[info] logs: ${LOGDIR}"
echo "[info] params: ${PARAMS_OUT}"
echo "[info] running on NUMA node ${TARGET_CPU_NUMA_NODE}"
echo "[info] num_elements=${NUM_ELEMENTS} num_lookups=${NUM_LOOKUPS}"
echo "[info] plotting NUMA private memory via numa_mem_plot"

readonly START_EPOCH_SECS="$(date +%s)"
readonly START_EPOCH_NANOS="$(date +%s%N)"

( exec ${WORKLOAD_CMD} ) >"${WORKLOAD_LOG}" 2>&1 &
workload_pid=$!
echo "[info] workload pid=${workload_pid}"

start_plotter

if wait "${workload_pid}"; then
  workload_exit_code=0
else
  workload_exit_code=$?
fi

wait "${sampler_pid}" 2>/dev/null || true
sampler_pid=""

readonly END_EPOCH_NANOS="$(date +%s%N)"
readonly ELAPSED_NANOS=$(( END_EPOCH_NANOS - START_EPOCH_NANOS ))
readonly ELAPSED_SECS=$(( ELAPSED_NANOS / 1000000000 ))
readonly ELAPSED_MILLIS=$(( ELAPSED_NANOS / 1000000 ))
readonly ELAPSED_REMAINDER_MILLIS=$(( (ELAPSED_NANOS % 1000000000) / 1000000 ))

cat >"${JSON_OUT}" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "target_cpu_numa_node": "${TARGET_CPU_NUMA_NODE}",
  "target_mem_numa_node": "${TARGET_MEM_NUMA_NODE}",
  "memory_gib": ${MEMORY_GIB},
  "elements_per_gib": ${ELEMENTS_PER_GIB},
  "num_elements": ${NUM_ELEMENTS},
  "lookup_hundreds": ${LOOKUP_HUNDREDS},
  "num_lookups": ${NUM_LOOKUPS},
  "sample_interval_secs": ${SAMPLE_INTERVAL_SECS},
  "elapsed_seconds": ${ELAPSED_SECS},
  "elapsed_milliseconds": ${ELAPSED_MILLIS},
  "elapsed_pretty": "${ELAPSED_SECS}.$(printf '%03d' "${ELAPSED_REMAINDER_MILLIS}")",
  "exit_code": ${workload_exit_code},
  "workload_log": "${WORKLOAD_LOG}",
  "numa_csv": "${CSV_OUT}",
  "numa_plot": "${PLOT_OUT}",
  "plotter_log": "${PLOTTER_LOG}"
}
EOF

echo "[done] experiment complete."
echo "       Runtime: ${ELAPSED_SECS}.$(printf '%03d' "${ELAPSED_REMAINDER_MILLIS}") seconds"
echo "       Timing JSON: ${JSON_OUT}"
echo "       NUMA CSV: ${CSV_OUT}"
echo "       NUMA Plot: ${PLOT_OUT}"
echo "       Logs: ${LOGDIR}"

if (( workload_exit_code != 0 )); then
  echo "[error] workload exited with code ${workload_exit_code}. See ${WORKLOAD_LOG}." >&2
  exit "${workload_exit_code}"
fi
