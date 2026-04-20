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
  pcm \
  python3 \
  python3-matplotlib \
  python3-pip \
  python3-venv

sudo modprobe msr

echo "Installed packages for:"
echo "- msr-tools"
echo "- pcm"
echo "- numactl and numastat"
echo "- libnuma development headers (numa.h)"
echo "- python3, pip, venv, and matplotlib"
