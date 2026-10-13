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

#include <cuda.h>
#include <cuda_runtime_api.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "p2p-selftest-ioctl.h"

static int failures;

#define CHECK(cond, ...) do { \
	if (!(cond)) { \
		printf("  FAIL: "); \
		printf(__VA_ARGS__); \
		printf("\n"); \
		failures++; \
	} \
} while (0)

static int map_test(int fd, const char *gpu_bus_id, size_t alloc_size,
	size_t offset, size_t size)
{
	struct p2p_selftest_map p;
	unsigned int flag = 1;
	char *buf;
	cudaError_t ce;
	CUresult cr;
	int ret;

	ce = cudaMalloc((void **)&buf, alloc_size);
	if (ce != cudaSuccess) {
		printf("  FAIL: cudaMalloc(%zu): %s\n", alloc_size,
			cudaGetErrorString(ce));
		failures++;
		return -1;
	}
	cr = cuPointerSetAttribute(&flag, CU_POINTER_ATTRIBUTE_SYNC_MEMOPS,
		(CUdeviceptr)buf);
	CHECK(cr == CUDA_SUCCESS, "cuPointerSetAttribute: %d", cr);

	memset(&p, 0, sizeof(p));
	p.va = (__u64)(buf + offset);
	p.size = size;
	ret = ioctl(fd, P2P_SELFTEST_IOC_MAP, &p);
	if (ret && errno == ENOMEM && size > 64 * 1024 * 1024) {
		/* Pinned GPU memory is mapped through BAR1, which may be small */
		printf("  size %9zu: no room in the GPU's BAR1 (enable Resizable BAR in the BIOS to pin more)\n",
			size);
		ret = -ENOMEM;
	} else if (ret) {
		printf("  FAIL: size %zu offset %zu: ioctl(MAP): %s (see dmesg)\n",
			size, offset, strerror(errno));
		failures++;
	} else {
		uint64_t expect = ((offset & 0xffff) + size + 0xffff) / 0x10000;

		printf("  size %9zu offset %5zu: %4u x %uKB pages, dma 0x%llx-0x%llx%s, BAR1 of %s\n",
			size, offset, p.entries, p.page_size / 1024,
			(unsigned long long)p.first_dma,
			(unsigned long long)(p.last_dma + p.page_size - 1),
			p.contiguous ? " contiguous" : "",
			p.dma_in_bar ? p.gpu : "NONE");
		CHECK(p.dma_in_bar, "DMA addresses are not in any GPU's BAR1");
		CHECK(!strcasecmp(p.gpu, gpu_bus_id),
			"DMA addresses are in %s's BAR1, expected %s", p.gpu,
			gpu_bus_id);
		CHECK(p.page_size == 0x10000, "page size %u, expected 64KB",
			p.page_size);
		CHECK(p.entries == expect, "%u pages, expected %llu",
			p.entries, (unsigned long long)expect);
	}

	cudaFree(buf);
	return ret;
}

static void callback_test(int fd)
{
	struct p2p_selftest_hold h;
	unsigned int flag = 1;
	void *buf;
	int ret;

	if (cudaMalloc(&buf, 1 << 20) != cudaSuccess) {
		printf("  FAIL: cudaMalloc for callback test\n");
		failures++;
		return;
	}
	cuPointerSetAttribute(&flag, CU_POINTER_ATTRIBUTE_SYNC_MEMOPS,
		(CUdeviceptr)buf);

	h.va = (__u64)buf;
	h.size = 1 << 20;
	ret = ioctl(fd, P2P_SELFTEST_IOC_HOLD, &h);
	CHECK(ret == 0, "ioctl(HOLD): %s", strerror(errno));
	if (ret) {
		cudaFree(buf);
		return;
	}
	CHECK(ioctl(fd, P2P_SELFTEST_IOC_FREED) == 0,
		"free callback ran before cudaFree()");
	cudaFree(buf);
	ret = ioctl(fd, P2P_SELFTEST_IOC_FREED);
	printf("  cudaFree() of pinned buffer %s the free callback\n",
		ret == 1 ? "triggered" : "did NOT trigger");
	CHECK(ret == 1, "free callback did not run on cudaFree()");
	ioctl(fd, P2P_SELFTEST_IOC_RELEASE);
}

int main(int argc, char **argv)
{
	int fd, ndev, dev;
	const size_t mib = 1 << 20;

	fd = open("/dev/p2p-selftest", O_RDWR);
	if (fd < 0) {
		perror("open(/dev/p2p-selftest)");
		return 1;
	}

	if (cudaGetDeviceCount(&ndev) != cudaSuccess || !ndev) {
		printf("FAIL: no CUDA devices\n");
		return 1;
	}

	for (dev = 0; dev < ndev; dev++) {
		char bus_id[16];
		cudaDeviceProp prop;

		cudaSetDevice(dev);
		cudaGetDeviceProperties(&prop, dev);
		cudaDeviceGetPCIBusId(bus_id, sizeof(bus_id), dev);
		printf("CUDA device %d: %s at %s\n", dev, prop.name, bus_id);

		/* 64KiB: what the Acorn's 64KiB FPGA RAM gets per perf test */
		map_test(fd, bus_id, 64 * 1024, 0, 64 * 1024);
		/* 4MiB: rdma-cuda's 1024x1024x4-byte surfaces */
		map_test(fd, bus_id, 4 * mib, 0, 4 * mib);
		/* Unaligned within a 64KB GPU page, spanning pages */
		map_test(fd, bus_id, 4 * mib, 4096, 4 * mib - 8192);
		/* 256MiB: large pin; fall back to 64MiB if BAR1 is too small */
		if (map_test(fd, bus_id, 256 * mib, 0, 256 * mib) == -ENOMEM)
			map_test(fd, bus_id, 64 * mib, 0, 64 * mib);
		callback_test(fd);
	}

	close(fd);

	if (failures) {
		printf("RESULT: FAIL (%d failures)\n", failures);
		return 1;
	}
	printf("RESULT: PASS\n");
	return 0;
}
