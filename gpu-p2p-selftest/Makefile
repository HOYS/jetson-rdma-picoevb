# Copyright (c) 2026, HOYS.  All rights reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms and conditions of the GNU General Public License,
# version 2, as published by the Free Software Foundation.
#
# This program is distributed in the hope it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.

KDIR ?= /lib/modules/$(shell uname -r)/build
NVCC ?= /usr/local/cuda/bin/nvcc
NVIDIA_SYMVERS := $(CURDIR)/nvidia.symvers

.PHONY: default modules clean
default: modules p2p-selftest-run

modules: $(NVIDIA_SYMVERS)
	$(MAKE) -C "$(KDIR)" "M=$(CURDIR)" "KBUILD_EXTRA_SYMBOLS=$(NVIDIA_SYMVERS)" modules

$(NVIDIA_SYMVERS): $(NVIDIA_KO) ../kernel-module/nvidia-ko-to-module-symvers
	../kernel-module/nvidia-ko-to-module-symvers "$<" "$@" "$(KDIR)"

p2p-selftest-run: p2p-selftest-run.cu p2p-selftest-ioctl.h Makefile
	$(NVCC) $(NVCCFLAGS) -o $@ $< -l cuda

clean:
	$(MAKE) -C "$(KDIR)" "M=$(CURDIR)" clean
	rm -f p2p-selftest-run $(NVIDIA_SYMVERS)
