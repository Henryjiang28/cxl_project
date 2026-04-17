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

readonly TARGET_NUMA_NODE=1
readonly ELEMENTS_PER_GIB=8000000
readonly NUM_ELEMENTS=$(( MEMORY_GIB * ELEMENTS_PER_GIB ))
readonly NUM_LOOKUPS=$(( LOOKUP_HUNDREDS * 100 ))
readonly TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
readonly EXP_DIR="experiments/mitosis_btree_experiment-${TIMESTAMP}"
readonly CSV_OUT="${EXP_DIR}/numa_memory_usage.csv"
readonly JSON_OUT="${EXP_DIR}/timing.json"
readonly PARAMS_OUT="${EXP_DIR}/experimental_params.yaml"
readonly LOGDIR="./exp_logs_${TIMESTAMP}"
readonly WORKLOAD_BIN="${WORKLOAD_BIN:-./workloads/mitosis-workload-btree/bin/bench_btree_mt}"
readonly WORKLOAD_CMD="${WORKLOAD_CMD:-${WORKLOAD_BIN} -p ${TARGET_NUMA_NODE} -- -n ${NUM_ELEMENTS} -l ${NUM_LOOKUPS}}"
readonly SAMPLE_INTERVAL_SECS="${SAMPLE_INTERVAL_SECS:-1}"

mkdir -p "${EXP_DIR}" "${LOGDIR}"

readonly WORKLOAD_LOG="${LOGDIR}/bench_btree_mt.log"
readonly NUMASTAT_LOG="${LOGDIR}/numastat.log"

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
timing_json_out: $(yaml_quote "${JSON_OUT}")
target_numa_node: ${TARGET_NUMA_NODE}
memory_gib: ${MEMORY_GIB}
elements_per_gib: ${ELEMENTS_PER_GIB}
num_elements: ${NUM_ELEMENTS}
lookup_hundreds: ${LOOKUP_HUNDREDS}
num_lookups: ${NUM_LOOKUPS}
sample_interval_secs: ${SAMPLE_INTERVAL_SECS}
workload_bin: $(yaml_quote "${WORKLOAD_BIN}")
workload_cmd: $(yaml_quote "${WORKLOAD_CMD}")
workload_log: $(yaml_quote "${WORKLOAD_LOG}")
numastat_log: $(yaml_quote "${NUMASTAT_LOG}")
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

capture_numastat_sample() {
  local elapsed_secs="$1"
  local numastat_output
  local parsed_output

  if ! numastat_output="$(numastat -m 2>>"${NUMASTAT_LOG}")"; then
    echo "[warn] numastat sampling failed at t=${elapsed_secs}s" >>"${NUMASTAT_LOG}"
    return
  fi

  parsed_output="$(
    printf '%s\n' "${numastat_output}" | awk -v elapsed="${elapsed_secs}" '
      BEGIN {
        node_count = 0;
      }
      /^Per-node system memory usage/ {
        in_table = 1;
        next;
      }
      !in_table {
        next;
      }
      /^$/ {
        next;
      }
      /^-/ {
        next;
      }
      {
        if ($1 == "Node") {
          node_count = 0;
          for (i = 2; i <= NF; i++) {
            if ($i == "Total") {
              break;
            }
            nodes[node_count] = $i;
            node_count++;
          }
          next;
        }

        if ($1 == "MemTotal" || $1 == "MemFree" || $1 == "MemUsed") {
          metric = $1;
          for (i = 0; i < node_count; i++) {
            values[metric, nodes[i]] = $(i + 2);
          }
        }
      }
      END {
        for (i = 0; i < node_count; i++) {
          node = nodes[i];
          if (values["MemTotal", node] != "" && values["MemFree", node] != "" && values["MemUsed", node] != "") {
            printf "%s,%s,%s,%s,%s\n",
                   elapsed,
                   node,
                   values["MemTotal", node],
                   values["MemFree", node],
                   values["MemUsed", node];
          }
        }
      }
    '
  )"

  if [[ -z "${parsed_output}" ]]; then
    echo "[warn] unable to parse numastat output at t=${elapsed_secs}s" >>"${NUMASTAT_LOG}"
    printf '%s\n' "${numastat_output}" >>"${NUMASTAT_LOG}"
    return
  fi

  printf '%s\n' "${parsed_output}" >>"${CSV_OUT}"
}

sample_numastat_loop() {
  local start_epoch="$1"

  echo "elapsed_sec,node,memtotal_mb,memfree_mb,memused_mb" >"${CSV_OUT}"

  while kill -0 "${workload_pid}" 2>/dev/null; do
    local now_epoch
    local elapsed_secs
    now_epoch="$(date +%s)"
    elapsed_secs=$(( now_epoch - start_epoch ))
    capture_numastat_sample "${elapsed_secs}"
    sleep "${SAMPLE_INTERVAL_SECS}"
  done

  local final_epoch
  local final_elapsed_secs
  final_epoch="$(date +%s)"
  final_elapsed_secs=$(( final_epoch - start_epoch ))
  capture_numastat_sample "${final_elapsed_secs}"
}

write_params_yaml

echo "[info] experiment dir: ${EXP_DIR}"
echo "[info] logs: ${LOGDIR}"
echo "[info] params: ${PARAMS_OUT}"
echo "[info] running on NUMA node ${TARGET_NUMA_NODE}"
echo "[info] num_elements=${NUM_ELEMENTS} num_lookups=${NUM_LOOKUPS}"

readonly START_EPOCH_SECS="$(date +%s)"
readonly START_EPOCH_NANOS="$(date +%s%N)"

( exec ${WORKLOAD_CMD} ) >"${WORKLOAD_LOG}" 2>&1 &
workload_pid=$!
echo "[info] workload pid=${workload_pid}"

sample_numastat_loop "${START_EPOCH_SECS}" &
sampler_pid=$!

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
  "target_numa_node": ${TARGET_NUMA_NODE},
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
  "numa_csv": "${CSV_OUT}"
}
EOF

echo "[done] experiment complete."
echo "       Runtime: ${ELAPSED_SECS}.$(printf '%03d' "${ELAPSED_REMAINDER_MILLIS}") seconds"
echo "       Timing JSON: ${JSON_OUT}"
echo "       NUMA CSV: ${CSV_OUT}"
echo "       Logs: ${LOGDIR}"

if (( workload_exit_code != 0 )); then
  echo "[error] workload exited with code ${workload_exit_code}. See ${WORKLOAD_LOG}." >&2
  exit "${workload_exit_code}"
fi
