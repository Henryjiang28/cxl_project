#!/bin/bash

# Toggle page demotion and NUMA load balancing for TPP functionality.
set -o errexit
set -o pipefail
set -o nounset

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <0|1>" >&2
    exit 1
fi

case "$1" in
    1)
        sudo swapoff -a
        echo 1 | sudo tee /sys/kernel/mm/numa/demotion_enabled >/dev/null
        echo 1 | sudo tee /proc/sys/kernel/numa_balancing >/dev/null
        echo "Migration enabled"
        ;;
    0)
        echo 0 | sudo tee /sys/kernel/mm/numa/demotion_enabled >/dev/null
        echo 0 | sudo tee /proc/sys/kernel/numa_balancing >/dev/null
        echo "Migration disabled"
        ;;
    *)
        echo "Usage: $0 <0|1>" >&2
        exit 1
        ;;
esac
