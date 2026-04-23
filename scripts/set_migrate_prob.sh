#!/bin/bash

# Set the NUMA balancing migration probability.
set -o errexit
set -o pipefail
set -o nounset

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <migrate_prob>" >&2
    echo "  migrate_prob must be an integer in [0,100]" >&2
    exit 1
fi

if ! [[ "$1" =~ ^[0-9]+$ ]] || (( $1 < 0 || $1 > 100 )); then
    echo "[error] invalid migrate_prob '$1'. Expected an integer in [0,100]." >&2
    exit 1
fi

echo "$1" | sudo tee /proc/sys/kernel/numa_balancing_migrate_probability
echo "Migration probability set to $1"
