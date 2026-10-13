/*
 * Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms and conditions of the GNU General Public License,
 * version 2, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 */

#ifndef __PICOEVB_RDMA_IOCTL_H__
#define __PICOEVB_RDMA_IOCTL_H__

#include <linux/types.h>

struct picoevb_rdma_pin_cuda {
	/* In */
	__u64 va;
	__u64 size;
	/* Out */
	__u32 handle;
};

struct picoevb_rdma_unpin_cuda {
	/* In */
	__u32 handle;
};

struct picoevb_rdma_h2c2h_dma {
	/* In */
	/* Malloc: Pointer, CUDA: Handle from IOC_PIN_CUDA */
	__u64 src;
	/* Malloc: Pointer, CUDA: Handle from IOC_PIN_CUDA */
	__u64 dst;
	__u64 len;
	__u64 flags;
	/* Out */
	__u64 dma_time_ns;
};
#define PICOEVB_H2C2H_DMA_FLAG_SRC_IS_CUDA (1 << 0)
#define PICOEVB_H2C2H_DMA_FLAG_DST_IS_CUDA (1 << 1)

struct picoevb_rdma_card_info {
	/* Out */
	__u64 fpga_ram_size;
};

struct picoevb_rdma_h2c_dma {
	/* In */
	/* Malloc: Pointer, CUDA: Handle from IOC_PIN_CUDA */
	__u64 src;
	/* RAM buffer offset */
	__u64 dst;
	__u64 len;
	__u64 flags;
	/* Out */
	__u64 dma_time_ns;
};
#define PICOEVB_H2C_DMA_FLAG_SRC_IS_CUDA (1 << 0)

struct picoevb_rdma_c2h_dma {
	/* In */
	/* Malloc: Pointer, CUDA: Handle from IOC_PIN_CUDA */
	__u64 dst;
	/* RAM buffer offset */
	__u64 src;
	__u64 len;
	__u64 flags;
	/* Out */
	__u64 dma_time_ns;
};
#define PICOEVB_C2H_DMA_FLAG_DST_IS_CUDA (1 << 0)

/*
 * Continuous C2H streaming into a ring of pinned CUDA buffers: the DMA engine
 * runs a circular descriptor list that copies the FPGA RAM, used as a ring of
 * ring_size bytes from offset 0, into the buffers in order, forever, until
 * IOC_C2H_STREAM_STOP. The FPGA paces it (see iq_gen.v), so there is no
 * per-transfer host work; the host polls IOC_C2H_STREAM_STATUS to see how
 * far it has got. Buffer b is complete once completed_descs, which counts
 * from 0 at IOC_C2H_STREAM_START, reaches lap * n_descs + last_desc[b] + 1.
 */
struct picoevb_rdma_c2h_stream_buf {
	/* In: handle from IOC_PIN_CUDA; the whole pinned buffer is used */
	__u64 handle;
	/* Out: index of the buffer's last descriptor in the list */
	__u32 last_desc;
	__u32 pad;
};

struct picoevb_rdma_c2h_stream_start {
	/* In */
	__u64 bufs;	/* pointer to n_bufs struct picoevb_rdma_c2h_stream_buf */
	__u32 n_bufs;
	__u32 flags;	/* must be 0 */
	/* FPGA RAM ring size; must divide the buffers' total size */
	__u64 ring_size;
	/* Out */
	__u32 n_descs;
	__u32 pad;
};

struct picoevb_rdma_c2h_stream_status {
	/* Out */
	__u32 completed_descs;	/* wraps at 2^32 */
	__u32 status;		/* DMA engine status register */
};

#define PICOEVB_IOC_LED		_IOW('P', 0, __u32)
#define PICOEVB_IOC_PIN_CUDA	_IOWR('P', 1, struct picoevb_rdma_pin_cuda)
#define PICOEVB_IOC_UNPIN_CUDA	_IOW('P', 2, struct picoevb_rdma_unpin_cuda)
#define PICOEVB_IOC_H2C2H_DMA	_IOWR('P', 3, struct picoevb_rdma_h2c2h_dma)
#define PICOEVB_IOC_CARD_INFO	_IOR('P', 4, struct picoevb_rdma_card_info)
#define PICOEVB_IOC_H2C_DMA	_IOWR('P', 5, struct picoevb_rdma_h2c_dma)
#define PICOEVB_IOC_C2H_DMA	_IOWR('P', 6, struct picoevb_rdma_c2h_dma)
#define PICOEVB_IOC_C2H_STREAM_START \
	_IOWR('P', 7, struct picoevb_rdma_c2h_stream_start)
#define PICOEVB_IOC_C2H_STREAM_STATUS \
	_IOR('P', 8, struct picoevb_rdma_c2h_stream_status)
#define PICOEVB_IOC_C2H_STREAM_STOP	_IO('P', 9)

#endif
