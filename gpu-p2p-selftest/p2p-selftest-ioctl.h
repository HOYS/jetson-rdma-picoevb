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

#ifndef __P2P_SELFTEST_IOCTL_H__
#define __P2P_SELFTEST_IOCTL_H__

#include <linux/types.h>

/*
 * Pin a CUDA allocation, DMA-map it for the peer PCI device given as the
 * module's "peer" parameter, check the mapping, then unmap and unpin it.
 */
struct p2p_selftest_map {
	/* In: CUDA virtual address and size, as passed to PIN_CUDA */
	__u64 va;
	__u64 size;
	/* Out: results */
	__u32 page_size;	/* bytes */
	__u32 entries;		/* GPU pages pinned/mapped */
	__u64 first_phys;	/* GPU physical address of first page */
	__u64 first_dma;	/* peer-visible bus address of first page */
	__u64 last_dma;
	__u32 dma_in_bar;	/* 1 if every DMA address is in the GPU's BAR1 */
	__u32 contiguous;	/* 1 if the DMA addresses form one range */
	char gpu[16];		/* PCI name of the GPU whose BAR1 holds them */
	char peer[16];		/* PCI name of the peer device */
};

/* Pin a CUDA allocation and keep it pinned, to test the free callback */
struct p2p_selftest_hold {
	__u64 va;
	__u64 size;
};

#define P2P_SELFTEST_IOC_MAP		_IOWR('Q', 0, struct p2p_selftest_map)
#define P2P_SELFTEST_IOC_HOLD		_IOW('Q', 1, struct p2p_selftest_hold)
/* Returns 1 if the held pages' free callback has run, else 0 */
#define P2P_SELFTEST_IOC_FREED		_IO('Q', 2)
#define P2P_SELFTEST_IOC_RELEASE	_IO('Q', 3)

#endif
