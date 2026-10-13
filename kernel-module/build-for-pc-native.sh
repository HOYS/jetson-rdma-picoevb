#!/bin/sh

# Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
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


export NV_BUILD_DGPU=1

# Prefer the headers and module of the NVIDIA driver that is actually loaded,
# in case several driver versions are installed.
nv_ver="$(cat /sys/module/nvidia/version 2>/dev/null || modinfo -F version nvidia 2>/dev/null || true)"
export NVIDIA_SRC_DIR="$(find /usr/src/nvidia-${nv_ver}* -name nv-p2p.h 2>/dev/null|head -1|xargs dirname 2>/dev/null)"
if [ ! -d "${NVIDIA_SRC_DIR}" ]; then
	echo "ERROR: Could not find nv-p2p.h"
	exit 1
fi

export NVIDIA_KO="$(modinfo -n nvidia 2>/dev/null)"
if [ ! -f "${NVIDIA_KO}" ]; then
	export NVIDIA_KO="$(find /lib/modules/$(uname -r)/ -name 'nvidia*.ko*'|grep -P 'nvidia(_[0-9]+)?\.ko'|head -1)"
fi
if [ ! -f "${NVIDIA_KO}" ]; then
	echo "ERROR: Could not find nvidia.ko"
	exit 1
fi

make || exit 1

# The NVIDIA dGPU driver is proprietary, and Linux 5.13+ refuses to load a
# module that uses both its symbols and EXPORT_SYMBOL_GPL symbols.
kdir="${KDIR:-/lib/modules/$(uname -r)/build}"
if [ -f "${kdir}/Module.symvers" ]; then
	imports="$(mktemp)"
	nm -u picoevb-rdma.ko | awk '{print $2}' | sort -u > "${imports}"
	gpl="$(awk -F'\t' '/EXPORT_SYMBOL_GPL/ {print $2}' "${kdir}/Module.symvers" | sort -u | comm -12 - "${imports}")"
	rm -f "${imports}"
	if [ -n "${gpl}" ]; then
		echo "ERROR: picoevb-rdma.ko uses GPL-only symbols, so will not load"
		echo "alongside the proprietary nvidia.ko:"
		echo "${gpl}"
		exit 1
	fi
fi
