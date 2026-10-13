#!/bin/sh

# Copyright (c) 2026, HOYS. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.


# Exercise the GPU side of GPUDirect RDMA (pinning CUDA memory and DMA-mapping
# it for a peer device) without an FPGA. No DMA is performed.
#
# usage: sudo ./run-selftest.sh PEER_PCI_NAME
#
# PEER_PCI_NAME (e.g. 0000:05:00.0) is any PCI device attached where the FPGA
# will be, e.g. an NVMe drive in the same M.2 slot or behind the same root
# port. Mapping only computes addresses for it; nothing is sent to it.

set -e
cd "$(dirname "$0")"

peer="$1"
if [ -z "${peer}" ] || [ ! -e "/sys/bus/pci/devices/${peer}" ]; then
	echo "usage: $0 PEER_PCI_NAME   (e.g. 0000:05:00.0; see lspci -D)"
	exit 1
fi

nv_ver="$(cat /sys/module/nvidia/version 2>/dev/null || modinfo -F version nvidia 2>/dev/null || true)"
export NVIDIA_SRC_DIR="$(find /usr/src/nvidia-${nv_ver}* -name nv-p2p.h 2>/dev/null|head -1|xargs dirname 2>/dev/null)"
export NVIDIA_KO="$(modinfo -n nvidia 2>/dev/null)"
if [ ! -d "${NVIDIA_SRC_DIR}" ] || [ ! -f "${NVIDIA_KO}" ]; then
	echo "ERROR: NVIDIA driver sources or nvidia.ko not found"
	exit 1
fi

# Tesla K80 (sm_37) needs explicit nvcc flags, and CUDA 11.4 needs gcc <= 10
if [ -z "${NVCCFLAGS}" ] && nvidia-smi -L 2>/dev/null | grep -q "K80"; then
	NVCCFLAGS="-gencode arch=compute_37,code=sm_37 -Wno-deprecated-gpu-targets"
	if command -v g++-10 > /dev/null; then
		NVCCFLAGS="${NVCCFLAGS} -ccbin g++-10"
	fi
elif [ -z "${NVCCFLAGS}" ]; then
	# Otherwise build for the installed GPU(s)
	NVCCFLAGS="-arch=native"
fi
make NVCCFLAGS="${NVCCFLAGS}"

# Linux 5.13+ won't load a module using both nvidia.ko's and GPL-only symbols
kdir="${KDIR:-/lib/modules/$(uname -r)/build}"
imports="$(mktemp)"
nm -u p2p-selftest.ko | awk '{print $2}' | sort -u > "${imports}"
gpl="$(awk -F'\t' '/EXPORT_SYMBOL_GPL/ {print $2}' "${kdir}/Module.symvers" | sort -u | comm -12 - "${imports}")"
rm -f "${imports}"
if [ -n "${gpl}" ]; then
	echo "ERROR: p2p-selftest.ko uses GPL-only symbols: ${gpl}"
	exit 1
fi

# Sign with the Ubuntu DKMS key if Secure Boot is on (it must be enrolled)
mok=/var/lib/shim-signed/mok
if mokutil --sb-state 2>/dev/null | grep -q enabled && [ -f "${mok}/MOK.priv" ]; then
	kmodsign sha512 "${mok}/MOK.priv" "${mok}/MOK.der" p2p-selftest.ko
fi

rmmod p2p_selftest 2>/dev/null || true
insmod ./p2p-selftest.ko peer="${peer}"
trap 'rmmod p2p_selftest' EXIT
./p2p-selftest-run
