#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

echo "Installing project dependencies..."

sudo apt-get update -y
sudo apt-get install -y \
  libnuma-dev \
  msr-tools \
  numactl \
  pcm

sudo modprobe msr

echo "Installed packages for:"
echo "- msr-tools"
echo "- pcm"
echo "- numactl and numastat"
echo "- libnuma development headers (numa.h)"
