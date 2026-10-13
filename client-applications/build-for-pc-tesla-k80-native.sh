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


# Tesla K80 is compute capability 3.7, which CUDA 11.x still supports (with a
# deprecation warning) but does not build for by default. CUDA 12 dropped it.
#
# CUDA 11.4 (the newest the K80's R470 driver supports) rejects gcc newer than
# 10, so use g++-10 if it is installed.
export NV_BUILD_DGPU=1
ccbin=
if command -v g++-10 > /dev/null; then
	ccbin="-ccbin g++-10"
fi
exec make NVCCFLAGS="-gencode arch=compute_37,code=sm_37 -Wno-deprecated-gpu-targets ${ccbin} ${NVCCFLAGS}"
