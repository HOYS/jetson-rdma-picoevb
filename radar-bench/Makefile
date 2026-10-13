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


NVCC ?= /usr/local/cuda/bin/nvcc
# Build for the installed GPU(s). For a Tesla K80 with CUDA 11.4, use e.g.
# make NVCCFLAGS="-O3 -std=c++14 -gencode arch=compute_37,code=sm_37 -ccbin g++-10"
NVCCFLAGS ?= -O3 -std=c++17 -arch=native

radar-bench: radar-bench.cu ../kernel-module/picoevb-rdma-ioctl.h Makefile
	$(NVCC) $(NVCCFLAGS) -o $@ $< -lcufft -lcuda -lpthread

clean:
	rm -f radar-bench
