/*
 * Copyright (c) 2026, HOYS. All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

/*
 * Verifies the FPGA -> GPU (C2H) GPUDirect RDMA path in isolation:
 * 1. Fill the FPGA RAM with a known pattern from host memory (H2C, malloc).
 * 2. Fill a CUDA buffer with a different pattern.
 * 3. Have the FPGA write its RAM directly into the CUDA buffer (C2H, CUDA).
 * 4. Copy the CUDA buffer back with cudaMemcpy() and check every word.
 *
 * Unlike rdma-cuda, this never has the FPGA read GPU memory, so it works on
 * platforms that route peer-to-peer writes but not peer-to-peer reads.
 */

#include <cuda.h>
#include <cuda_runtime_api.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "../kernel-module/picoevb-rdma-ioctl.h"

int main(int argc, char **argv)
{
	struct picoevb_rdma_card_info card_info;
	struct picoevb_rdma_pin_cuda pin_params;
	struct picoevb_rdma_unpin_cuda unpin_params;
	struct picoevb_rdma_h2c_dma h2c_params;
	struct picoevb_rdma_c2h_dma c2h_params;
	uint32_t *src, *dst, *buf_d;
	unsigned int flag = 1;
	size_t size, i, words;
	int fd, ret, bad = 0;

	if (argc != 1) {
		fprintf(stderr, "usage: rdma-cuda-c2h-verify\n");
		return 1;
	}

	fd = open("/dev/picoevb", O_RDWR);
	if (fd < 0) {
		perror("open() failed");
		return 1;
	}

	ret = ioctl(fd, PICOEVB_IOC_CARD_INFO, &card_info);
	if (ret != 0) {
		perror("ioctl(CARD_INFO) failed");
		return 1;
	}
	size = card_info.fpga_ram_size;
	words = size / sizeof(uint32_t);

	src = (uint32_t *)malloc(size);
	dst = (uint32_t *)malloc(size);
	if (!src || !dst) {
		fprintf(stderr, "malloc() failed\n");
		return 1;
	}
	for (i = 0; i < words; i++)
		src[i] = 0xa5000000U ^ (uint32_t)(i * 2654435761U);

	/* 1. Host -> FPGA RAM */
	h2c_params.src = (__u64)src;
	h2c_params.dst = 0;
	h2c_params.len = size;
	h2c_params.flags = 0;
	ret = ioctl(fd, PICOEVB_IOC_H2C_DMA, &h2c_params);
	if (ret != 0) {
		perror("ioctl(H2C_DMA) failed");
		return 1;
	}

	/* 2. CUDA buffer with a different pattern */
	if (cudaMalloc(&buf_d, size) != cudaSuccess) {
		fprintf(stderr, "cudaMalloc() failed\n");
		return 1;
	}
	if (cudaMemset(buf_d, 0x5a, size) != cudaSuccess ||
	    cudaDeviceSynchronize() != cudaSuccess) {
		fprintf(stderr, "cudaMemset() failed\n");
		return 1;
	}
	if (cuPointerSetAttribute(&flag, CU_POINTER_ATTRIBUTE_SYNC_MEMOPS,
			(CUdeviceptr)buf_d) != CUDA_SUCCESS) {
		fprintf(stderr, "cuPointerSetAttribute() failed\n");
		return 1;
	}
	pin_params.va = (__u64)buf_d;
	pin_params.size = size;
	ret = ioctl(fd, PICOEVB_IOC_PIN_CUDA, &pin_params);
	if (ret != 0) {
		perror("ioctl(PIN_CUDA) failed");
		return 1;
	}

	/* 3. FPGA RAM -> GPU, peer-to-peer */
	c2h_params.src = 0;
	c2h_params.dst = pin_params.handle;
	c2h_params.len = size;
	c2h_params.flags = PICOEVB_C2H_DMA_FLAG_DST_IS_CUDA;
	ret = ioctl(fd, PICOEVB_IOC_C2H_DMA, &c2h_params);
	if (ret != 0) {
		perror("ioctl(C2H_DMA) failed");
		return 1;
	}

	/* 4. Check */
	if (cudaMemcpy(dst, buf_d, size, cudaMemcpyDeviceToHost) !=
			cudaSuccess) {
		fprintf(stderr, "cudaMemcpy() failed\n");
		return 1;
	}
	for (i = 0; i < words; i++) {
		if (dst[i] != src[i]) {
			if (bad < 10)
				fprintf(stderr, "word 0x%zx is 0x%08x not 0x%08x\n",
					i, dst[i], src[i]);
			bad++;
		}
	}

	unpin_params.handle = pin_params.handle;
	ioctl(fd, PICOEVB_IOC_UNPIN_CUDA, &unpin_params);
	cudaFree(buf_d);
	free(dst);
	free(src);
	close(fd);

	if (bad) {
		printf("FAIL: %d of %zu words wrong\n", bad, words);
		return 1;
	}
	printf("PASS: %zu bytes written FPGA -> GPU in %llu ns, all correct\n",
		size, (unsigned long long)c2h_params.dma_time_ns);
	return 0;
}
