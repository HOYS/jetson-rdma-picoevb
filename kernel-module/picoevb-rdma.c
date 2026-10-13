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

#include <linux/delay.h>
#include <linux/interrupt.h>
#include <linux/list.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mm.h>
#include <linux/pagemap.h>
#include <linux/pci.h>
#include <linux/sched.h>
#include <linux/sizes.h>
#include <linux/timekeeping.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#ifndef NV_BUILD_NO_CUDA
#ifdef NV_BUILD_DGPU
#include <nv-p2p.h>
#else
#include <linux/nv-p2p.h>
#endif
#endif

#include "picoevb-rdma-ioctl.h"
#include "picoevb-rdma.h"

#define MODULENAME	"picoevb-rdma"

#define BAR_GPIO	0
#define BAR_DMA		1

#define PEVB_DMA_TIMEOUT_MS	5000

#ifdef NV_BUILD_DGPU
#define GPU_PAGE_SHIFT	16
#else
#define GPU_PAGE_SHIFT	12
#endif
#define GPU_PAGE_SIZE	(((u64)1) << GPU_PAGE_SHIFT)
#define GPU_PAGE_OFFSET	(GPU_PAGE_SIZE - 1)
#define GPU_PAGE_MASK	(~GPU_PAGE_OFFSET)

struct pevb_drvdata {
	u32 num_h2c_chans;
	u64 fpga_ram_size;
};

/*
 * When built against NVIDIA's proprietary dGPU driver (NV_BUILD_DGPU), this
 * module imports nvidia_p2p_*() from a proprietary module. Since Linux 5.13,
 * such a module may not also use EXPORT_SYMBOL_GPL symbols, or it fails to
 * load. Hence this driver avoids GPL-only kernel APIs (class_create(),
 * device_create(), idr_*(), devm_kmalloc(), ktime_get(), ...) entirely.
 */

struct pevb {
	struct pci_dev			*pdev;
	struct device			*dev;
	const struct pevb_drvdata	*drvdata;
	struct miscdevice		misc;
	struct device_dma_parameters	dma_params;
	void __iomem * const		*iomap;
	struct semaphore		sem;
	void				*descs_ptr;
	dma_addr_t			descs_dma_addr;
	struct completion		dma_xfer_cmpl;
	bool				h2c_error;
	bool				c2h_error;
	u32				h2c_status;
	u32				c2h_status;
	/* Continuous C2H stream, if running; changed with sem held */
	struct pevb_stream		*stream;
};

struct pevb_file {
	struct pevb	*pevb;
	struct mutex	lock;
	struct list_head cuda_surfaces;
	int		next_handle;
};

#ifndef NV_BUILD_NO_CUDA
struct pevb_cuda_surface {
	struct list_head		node;
	struct pevb_file		*pevb_file;
	u64				va;
	u64				offset;
	u64				len;
	int				handle;
	struct nvidia_p2p_page_table	*page_table;
};
#endif

struct pevb_userbuf_dma {
	dma_addr_t	addr;
	u64		len;
};

struct pevb_userbuf {
#ifndef NV_BUILD_NO_CUDA
	bool cuda;
#endif
	int n_dmas;
	struct pevb_userbuf_dma *dmas;

	union {
		struct {
			int to_dev;
			int pagecount;
			struct page **pages;
			struct sg_table *sgt;
			int map_ret;
		} pages;
#ifndef NV_BUILD_NO_CUDA
		struct {
			struct pevb_cuda_surface *cusurf;
			struct nvidia_p2p_dma_mapping *map;
		} cuda;
#endif
	} priv;
};

struct pevb_stream {
	struct pevb_file	*owner;
	int			n_bufs;
	struct pevb_userbuf	*ubufs;
	struct xlnx_dma_desc	*descs;
	dma_addr_t		descs_dma_addr;
	size_t			descs_size;
	u32			n_descs;
	/* completed descriptor count when the engine started */
	u32			base_count;
};

#ifndef NV_BUILD_NO_CUDA
static bool pevb_stream_uses(struct pevb_file *pevb_file,
	struct pevb_cuda_surface *cusurf);
static void pevb_stream_stop(struct pevb_file *pevb_file,
	struct pevb_cuda_surface *revoked);
#endif

static bool no_relaxed_ordering;
module_param(no_relaxed_ordering, bool, 0444);
MODULE_PARM_DESC(no_relaxed_ordering,
	"Disable the FPGA's Relaxed Ordering and No Snoop TLP attributes");

static u64 pevb_time_ns(void)
{
	struct timespec64 ts;

	/* ktime_get_ns() and ktime_get_ts64() are GPL-only; this isn't */
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 18, 0)
	getrawmonotonic64(&ts);
#else
	ktime_get_raw_ts64(&ts);
#endif
	return timespec64_to_ns(&ts);
}

static u32 pevb_readl(struct pevb *pevb, int bar, u32 reg)
{
	u32 val;

	dev_dbg(&pevb->pdev->dev, "readl(0x%08x)\n", reg);
	val = readl(pevb->iomap[bar] + reg);
	dev_dbg(&pevb->pdev->dev, "readl(0x%08x) -> 0x%08x\n", reg, val);
	return val;
}

static void pevb_writel(struct pevb *pevb, int bar, u32 val, u32 reg)
{
	dev_dbg(&pevb->pdev->dev, "write(0x%08x, 0x%08x)\n", val, reg);
	writel(val, pevb->iomap[bar] + reg);
}

static int pevb_fops_open(struct inode *inode, struct file *filep)
{
	/* misc_open() points private_data at our struct miscdevice */
	struct pevb *pevb = container_of(filep->private_data, struct pevb,
		misc);
	struct pevb_file *pevb_file;

	pevb_file = kzalloc(sizeof(*pevb_file), GFP_KERNEL);
	if (!pevb_file)
		return -ENOMEM;

	pevb_file->pevb = pevb;
	mutex_init(&pevb_file->lock);
	INIT_LIST_HEAD(&pevb_file->cuda_surfaces);

	filep->private_data = pevb_file;

	return 0;
}

#ifndef NV_BUILD_NO_CUDA
/* Must be called with pevb_file->lock held */
static struct pevb_cuda_surface *pevb_find_cuda_surface(
	struct pevb_file *pevb_file, int handle)
{
	struct pevb_cuda_surface *cusurf;

	list_for_each_entry(cusurf, &pevb_file->cuda_surfaces, node)
		if (cusurf->handle == handle)
			return cusurf;

	return NULL;
}

static void pevb_p2p_free_callback(void *data)
{
	struct pevb_cuda_surface *cusurf = data;
	struct pevb_file *pevb_file = cusurf->pevb_file;

	mutex_lock(&pevb_file->lock);
	/* The GPU memory is going away: stop streaming into it first */
	if (pevb_stream_uses(pevb_file, cusurf))
		pevb_stream_stop(pevb_file, cusurf);
	if (cusurf->handle >= 0) {
		list_del(&cusurf->node);
		cusurf->handle = -1;
	}
	mutex_unlock(&pevb_file->lock);

	nvidia_p2p_free_page_table(cusurf->page_table);
#ifndef NV_BUILD_DGPU
	kfree(cusurf->page_table);
#endif
	kfree(cusurf);
}
#endif

static int pevb_fops_release(struct inode *inode, struct file *filep)
{
	struct pevb_file *pevb_file = filep->private_data;

#ifndef NV_BUILD_NO_CUDA
	mutex_lock(&pevb_file->lock);
	pevb_stream_stop(pevb_file, NULL);
	mutex_unlock(&pevb_file->lock);

	for (;;) {
		struct pevb_cuda_surface *cusurf;

		mutex_lock(&pevb_file->lock);

		cusurf = list_first_entry_or_null(&pevb_file->cuda_surfaces,
			struct pevb_cuda_surface, node);
		if (!cusurf) {
			mutex_unlock(&pevb_file->lock);
			break;
		}

		list_del(&cusurf->node);
		cusurf->handle = -1;

		mutex_unlock(&pevb_file->lock);

		nvidia_p2p_put_pages(
#ifdef NV_BUILD_DGPU
			0, 0, cusurf->va,
#endif
			cusurf->page_table);
#ifdef NV_BUILD_DGPU
		pevb_p2p_free_callback(cusurf);
#else
		/*
		 * nvidia_p2p_put_pages() calls pevb_p2p_free_callback() which
		 * frees cusurf.
		 */
#endif
	}
#endif

	kfree(pevb_file);

	return 0;
}

static int pevb_ioctl_led(struct pevb_file *pevb_file, unsigned long arg)
{
	struct pevb *pevb = pevb_file->pevb;

	pevb_writel(pevb, BAR_GPIO, arg, 0);
	return 0;
}

#ifndef NV_BUILD_NO_CUDA
static int pevb_ioctl_pin_cuda(struct pevb_file *pevb_file, unsigned long arg)
{
	void __user *argp = (void __user *)arg;
	struct picoevb_rdma_pin_cuda pin_params;
	struct pevb_cuda_surface *cusurf;
	u64 aligned_len;
	int ret;

	if (copy_from_user(&pin_params, argp, sizeof(pin_params)))
		return -EFAULT;

	cusurf = kzalloc(sizeof(*cusurf), GFP_KERNEL);
	if (!cusurf)
		return -ENOMEM;

	cusurf->pevb_file = pevb_file;
	cusurf->va = pin_params.va & GPU_PAGE_MASK;
	cusurf->offset = pin_params.va & GPU_PAGE_OFFSET;
	cusurf->len = pin_params.size;
	aligned_len = (cusurf->offset + cusurf->len + GPU_PAGE_SIZE - 1) &
		GPU_PAGE_MASK;

	ret = nvidia_p2p_get_pages(
#ifdef NV_BUILD_DGPU
		0, 0,
#endif
		cusurf->va, aligned_len, &cusurf->page_table,
		pevb_p2p_free_callback, cusurf);
	if (ret < 0) {
		kfree(cusurf);
		return ret;
	}

	mutex_lock(&pevb_file->lock);
	/* Handles must fit the 0xefffffff mask in pevb_get_userbuf_cuda() */
	cusurf->handle = pevb_file->next_handle;
	pevb_file->next_handle = (pevb_file->next_handle + 1) & 0x0fffffff;
	list_add_tail(&cusurf->node, &pevb_file->cuda_surfaces);
	mutex_unlock(&pevb_file->lock);

	pin_params.handle = cusurf->handle;

	ret = copy_to_user(argp, &pin_params, sizeof(pin_params));
	if (ret)
		goto put_pages;

	return 0;

put_pages:
	nvidia_p2p_put_pages(
#ifdef NV_BUILD_DGPU
		0, 0, cusurf->va,
#endif
		cusurf->page_table);
#ifdef NV_BUILD_DGPU
	pevb_p2p_free_callback(cusurf);
#else
	/*
	 * nvidia_p2p_put_pages() calls pevb_p2p_free_callback() which
	 * frees cusurf.
	 */
#endif

	return ret;
}

static int pevb_ioctl_unpin_cuda(struct pevb_file *pevb_file, unsigned long arg)
{
	void __user *argp = (void __user *)arg;
	struct picoevb_rdma_unpin_cuda unpin_params;
	struct pevb_cuda_surface *cusurf;

	if (copy_from_user(&unpin_params, argp, sizeof(unpin_params)))
		return -EFAULT;

	mutex_lock(&pevb_file->lock);
	cusurf = pevb_find_cuda_surface(pevb_file, unpin_params.handle);
	if (!cusurf) {
		mutex_unlock(&pevb_file->lock);
		return -EINVAL;
	}
	if (pevb_stream_uses(pevb_file, cusurf)) {
		mutex_unlock(&pevb_file->lock);
		return -EBUSY;
	}
	list_del(&cusurf->node);
	cusurf->handle = -1;
	mutex_unlock(&pevb_file->lock);

	nvidia_p2p_put_pages(
#ifdef NV_BUILD_DGPU
		0, 0, cusurf->va,
#endif
		cusurf->page_table);
#ifdef NV_BUILD_DGPU
	pevb_p2p_free_callback(cusurf);
#else
	/*
	 * nvidia_p2p_put_pages() calls pevb_p2p_free_callback() which
	 * frees cusurf.
	 */
#endif

	return 0;
}
#endif

static void pevb_userbuf_add_dma_chunk(struct pevb_userbuf *ubuf,
	dma_addr_t addr, u64 len)
{
	struct pevb_userbuf_dma *dma;
	dma_addr_t end;

	if (ubuf->n_dmas) {
		dma = &ubuf->dmas[ubuf->n_dmas - 1];
		end = dma->addr + dma->len;
		if (addr == end) {
			dma->len += len;
			return;
		}
	}

	dma = &ubuf->dmas[ubuf->n_dmas];
	dma->addr = addr;
	dma->len = len;
	ubuf->n_dmas++;
}

#ifndef NV_BUILD_NO_CUDA
static int pevb_get_userbuf_cuda(struct pevb_file *pevb_file,
	struct pevb_userbuf *ubuf, __u64 handle64, __u64 len, int to_dev)
{
	struct pevb *pevb = pevb_file->pevb;
	int id, ret, i;
	struct pevb_cuda_surface *cusurf;
	u64 offset, len_left;

	ubuf->cuda = true;

	if (handle64 & ~0xefffffffU)
		return -EINVAL;
	id = handle64 & 0xefffffffU;

	cusurf = pevb_find_cuda_surface(pevb_file, id);
	if (!cusurf)
		return -EINVAL;
	ubuf->priv.cuda.cusurf = cusurf;

	if (len > cusurf->len)
		return -EINVAL;

#ifdef NV_BUILD_DGPU
	ret = nvidia_p2p_dma_map_pages(pevb->pdev, cusurf->page_table,
		&ubuf->priv.cuda.map);
#else
	ret = nvidia_p2p_dma_map_pages(&pevb->pdev->dev, cusurf->page_table,
		&ubuf->priv.cuda.map, to_dev ? DMA_TO_DEVICE : DMA_FROM_DEVICE);
#endif
	if (ret < 0)
		return ret;

	ubuf->dmas = kmalloc_array(ubuf->priv.cuda.map->entries,
		sizeof(*ubuf->dmas), GFP_KERNEL);
	if (!ubuf->dmas)
		return -ENOMEM;

	offset = cusurf->offset;
	len_left = cusurf->len;
	for (i = 0; i < ubuf->priv.cuda.map->entries; i++) {
#ifdef NV_BUILD_DGPU
		dma_addr_t dma_this = ubuf->priv.cuda.map->dma_addresses[i];
		u64 len_this = min(GPU_PAGE_SIZE - offset, len_left);
#else
		dma_addr_t dma_this = ubuf->priv.cuda.map->hw_address[i];
		u64 len_this = ubuf->priv.cuda.map->hw_len[i];
#endif

		dma_this += offset;
		pevb_userbuf_add_dma_chunk(ubuf, dma_this, len_this);

		if (len_this >= len_left)
			break;
		len_left -= len_this;
		offset = 0;
	}

	return 0;
}
#endif

static int pevb_get_userbuf_pages(struct pevb *pevb, struct pevb_userbuf *ubuf,
	__u64 src, __u64 len, int to_dev)
{
	unsigned long offset;
	unsigned long start;
	unsigned long end;
	int nr_pages, ret, i;
	struct scatterlist *sg;

#ifndef NV_BUILD_NO_CUDA
	ubuf->cuda = false;
#endif

	ubuf->priv.pages.to_dev = to_dev;

	offset = offset_in_page(src);
	start = src - offset;
	end = src + len;
	nr_pages = (end - start + PAGE_SIZE - 1) >> PAGE_SHIFT;

	ubuf->priv.pages.pages = kmalloc_array(nr_pages,
		sizeof(*ubuf->priv.pages.pages), GFP_KERNEL);
	if (!ubuf->priv.pages.pages)
		return -ENOMEM;

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
	down_read(&current->mm->mmap_sem);
#else
	mmap_read_lock(current->mm);
#endif
	ubuf->priv.pages.pagecount = get_user_pages(
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 6, 0)
		current, current->mm,
#endif
		start, nr_pages,
		to_dev ? 0 : FOLL_WRITE,
#if 0 /* CentOS 6 backport; can't be detected via kernel version */
                0, /* force */
#endif
		ubuf->priv.pages.pages
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 5, 0)
		, NULL
#endif
		);
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
	up_read(&current->mm->mmap_sem);
#else
	mmap_read_unlock(current->mm);
#endif
	if (ubuf->priv.pages.pagecount != nr_pages) {
		if (ubuf->priv.pages.pagecount < 0)
			return ubuf->priv.pages.pagecount;
		else
			return -EFAULT;
	}

	ubuf->priv.pages.sgt = kzalloc(sizeof(*ubuf->priv.pages.sgt),
		GFP_KERNEL);
	if (!ubuf->priv.pages.sgt)
		return -ENOMEM;

	ret = sg_alloc_table_from_pages(ubuf->priv.pages.sgt,
		ubuf->priv.pages.pages, nr_pages, offset, len, GFP_KERNEL);
	if (ret)
		return ret;

	ubuf->priv.pages.map_ret = dma_map_sg(&pevb->pdev->dev,
		ubuf->priv.pages.sgt->sgl, ubuf->priv.pages.sgt->nents,
		to_dev ? DMA_TO_DEVICE : DMA_FROM_DEVICE);
	if (!ubuf->priv.pages.map_ret)
		return -EFAULT;

	ubuf->dmas = kmalloc_array(ubuf->priv.pages.map_ret,
		sizeof(*ubuf->dmas), GFP_KERNEL);
	if (!ubuf->dmas)
		return -ENOMEM;

	for_each_sg(ubuf->priv.pages.sgt->sgl, sg, ubuf->priv.pages.map_ret, i)
		pevb_userbuf_add_dma_chunk(ubuf, sg_dma_address(sg),
			sg_dma_len(sg));

	return 0;
}

static void pevb_put_userbuf_pages(struct pevb *pevb, struct pevb_userbuf *ubuf)
{
	if (ubuf->priv.pages.map_ret)
		dma_unmap_sg(&pevb->pdev->dev, ubuf->priv.pages.sgt->sgl,
			ubuf->priv.pages.sgt->nents,
			ubuf->priv.pages.to_dev ?
				DMA_TO_DEVICE : DMA_FROM_DEVICE);
	if (ubuf->priv.pages.sgt)
		sg_free_table(ubuf->priv.pages.sgt);
	release_pages(ubuf->priv.pages.pages, ubuf->priv.pages.pagecount
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 15, 0)
		, 0
#endif
	);
	kfree(ubuf->priv.pages.pages);
}

#ifndef NV_BUILD_NO_CUDA
static void pevb_put_userbuf_cuda(struct pevb *pevb, struct pevb_userbuf *ubuf)
{
	if (ubuf->priv.cuda.map)
#ifdef NV_BUILD_DGPU
		nvidia_p2p_dma_unmap_pages(pevb->pdev,
			ubuf->priv.cuda.cusurf->page_table,
			ubuf->priv.cuda.map);
#else
		nvidia_p2p_dma_unmap_pages(ubuf->priv.cuda.map);
#endif
}
#endif

static void pevb_put_userbuf(struct pevb *pevb, struct pevb_userbuf *ubuf)
{
#ifndef NV_BUILD_NO_CUDA
	if (ubuf->cuda)
		pevb_put_userbuf_cuda(pevb, ubuf);
	else
#endif
		pevb_put_userbuf_pages(pevb, ubuf);
	kfree(ubuf->dmas);
}

static irqreturn_t pevb_irq_handler(int irq, void *data)
{
	struct pevb *pevb = data;
	u32 reg, status;
	irqreturn_t ret = IRQ_NONE;
	const u32 bad_status =
		(XLNX_DMA_H2C_STATUS_DESC_ERR_MASK <<
			XLNX_DMA_H2C_STATUS_DESC_ERR_SHIFT) |
		(XLNX_DMA_H2C_STATUS_WRITE_ERR_MASK <<
			XLNX_DMA_H2C_STATUS_WRITE_ERR_SHIFT) |
		(XLNX_DMA_H2C_STATUS_READ_ERR_MASK <<
			XLNX_DMA_H2C_STATUS_READ_ERR_SHIFT) |
		XLNX_DMA_H2C_STATUS_IDLE_STOPPED |
		XLNX_DMA_H2C_STATUS_INVALID_LEN |
		XLNX_DMA_H2C_STATUS_MAGIC_STOPPED |
		XLNX_DMA_H2C_STATUS_ALIGN_MISMATCH;

	dev_dbg(&pevb->pdev->dev, "%s()\n", __func__);
	reg = XLNX_REG(H2C, 0, H2C_STATUS_RD_CLR);
	status = pevb_readl(pevb, BAR_DMA, reg);
	status &= ~XLNX_DMA_H2C_STATUS_BUSY;
	if (status) {
		dev_dbg(&pevb->pdev->dev, "H2C status 0x%08x\n", status);
		pevb->h2c_status = status;
		pevb->h2c_error = !!(status & bad_status);
		complete(&pevb->dma_xfer_cmpl);
		ret = IRQ_HANDLED;
	}

	reg = XLNX_REG(C2H, 0, H2C_STATUS_RD_CLR);
	status = pevb_readl(pevb, BAR_DMA, reg);
	status &= ~XLNX_DMA_H2C_STATUS_BUSY;
	if (status) {
		dev_dbg(&pevb->pdev->dev, "C2H status 0x%08x\n", status);
		pevb->c2h_status = status;
		pevb->c2h_error = !!(status & bad_status);
		complete(&pevb->dma_xfer_cmpl);
		ret = IRQ_HANDLED;
	}

	return ret;
}

static int pevb_dma(struct pevb *pevb, bool c2h)
{
	u32 chan_offset, irq_int_en_bit_offset, sgma_ctrl_bit;
	u32 reg, val;
	long tret;
	int ret;

	if (c2h) {
		chan_offset = XLNX_REG(C2H, 0, H2C_CTRL) -
			XLNX_REG(H2C, 0, H2C_CTRL);
		irq_int_en_bit_offset =
			XLNX_DMA_IRQ_CH_C2H_BIT(0, pevb->drvdata->num_h2c_chans) -
			XLNX_DMA_IRQ_CH_H2C_BIT(0);
		sgma_ctrl_bit = XLNX_DMA_SGDMA_CTRL_C2H_DSC_HALT_SHIFT;
	} else {
		chan_offset = 0;
		irq_int_en_bit_offset = 0;
		sgma_ctrl_bit = XLNX_DMA_SGDMA_CTRL_H2C_DSC_HALT_SHIFT;
	}

	/* The C2H engine is busy streaming */
	if (pevb->stream)
		return -EBUSY;

	reinit_completion(&pevb->dma_xfer_cmpl);

	/* Program descriptor location */
	reg = XLNX_REG(H2C_SGDMA, 0, H2C_SGDMA_DESC_LOW_ADDR) + chan_offset;
	val = pevb->descs_dma_addr & 0xffffffffU;
	pevb_writel(pevb, BAR_DMA, val, reg);
	reg = XLNX_REG(H2C_SGDMA, 0, H2C_SGDMA_DESC_HIGH_ADDR) + chan_offset;
	val = pevb->descs_dma_addr >> 32;
	pevb_writel(pevb, BAR_DMA, val, reg);
	reg = XLNX_REG(H2C_SGDMA, 0, H2C_SGDMA_DESC_ADJACENT) + chan_offset;
	pevb_writel(pevb, BAR_DMA, 0, reg);
	/* Clear any pending status */
	reg = XLNX_REG(H2C, 0, H2C_STATUS_RD_CLR) + chan_offset;
	pevb_readl(pevb, BAR_DMA, reg);
	/* Enable all IRQs in channel */
	reg = XLNX_REG(H2C, 0, H2C_INT_EN) + chan_offset;
	pevb_writel(pevb, BAR_DMA, 0xffffffffU, reg);
	/* Enable channel IRQ at top level */
	reg = XLNX_REG(IRQ, 0, IRQ_CH_INT_EN_W1S);
	val = XLNX_DMA_IRQ_CH_H2C_BIT(irq_int_en_bit_offset);
	pevb_writel(pevb, BAR_DMA, val, reg);
	/* Arm perf counters */
	reg = XLNX_REG(H2C, 0, H2C_PERF_CTRL) + chan_offset;
	val = XLNX_DMA_H2C_PERF_CTRL_RUN | XLNX_DMA_H2C_PERF_CTRL_AUTO_STOP;
	pevb_writel(pevb, BAR_DMA, val, reg);
	/* Start DMA */
	reg = XLNX_REG(H2C, 0, H2C_CTRL) + chan_offset;
	val = (XLNX_DMA_H2C_CTRL_IE_DESC_ERR_MASK <<
			XLNX_DMA_H2C_CTRL_IE_DESC_ERR_SHIFT) |
		(XLNX_DMA_H2C_CTRL_IE_WRITE_ERR_MASK <<
			XLNX_DMA_H2C_CTRL_IE_WRITE_ERR_SHIFT) |
		(XLNX_DMA_H2C_CTRL_IE_READ_ERR_MASK <<
			XLNX_DMA_H2C_CTRL_IE_READ_ERR_SHIFT) |
		XLNX_DMA_H2C_CTRL_IE_IDLE_STOPPED |
		XLNX_DMA_H2C_CTRL_IE_INVALID_LEN |
		XLNX_DMA_H2C_CTRL_IE_MAGIC_STOPPED |
		XLNX_DMA_H2C_CTRL_IE_ALIGN_MISMATCH |
		XLNX_DMA_H2C_CTRL_IE_DESC_COMPLETED |
		XLNX_DMA_H2C_CTRL_IE_DESC_STOPPED |
		XLNX_DMA_H2C_CTRL_RUN;
	/*
	 * Ensure all memory writes for descriptor and configuration registers
	 * have completed before triggering the DMA operation.
	 */
	wmb();
	pevb_writel(pevb, BAR_DMA, val, reg);
	/*
	 * Wait for DMA completion (via IRQ). Time out rather than hang if e.g.
	 * the platform can't route peer-to-peer traffic to a GPU.
	 */
	tret = wait_for_completion_interruptible_timeout(&pevb->dma_xfer_cmpl,
		msecs_to_jiffies(PEVB_DMA_TIMEOUT_MS));
	if (tret < 0) {
		dev_err(&pevb->pdev->dev, "DMA interrupted\n");
		ret = tret;
	} else if (!tret) {
		reg = XLNX_REG(H2C, 0, H2C_STATUS) + chan_offset;
		dev_err(&pevb->pdev->dev, "%s DMA timed out, status 0x%08x\n",
			c2h ? "C2H" : "H2C", pevb_readl(pevb, BAR_DMA, reg));
		ret = -ETIMEDOUT;
	} else {
		ret = 0;
		val = c2h ? pevb->c2h_error : pevb->h2c_error;
		if (val) {
			dev_err(&pevb->pdev->dev, "%s DMA failed, status 0x%08x\n",
				c2h ? "C2H" : "H2C",
				c2h ? pevb->c2h_status : pevb->h2c_status);
			ret = -EIO;
		}
	}
	/* Disable channel IRQ at top level */
	reg = XLNX_REG(IRQ, 0, IRQ_CH_INT_EN_W1C);
	val = XLNX_DMA_IRQ_CH_H2C_BIT(irq_int_en_bit_offset);
	pevb_writel(pevb, BAR_DMA, val, reg);
	/* Disable all IRQs in channel */
	reg = XLNX_REG(H2C, 0, H2C_INT_EN) + chan_offset;
	pevb_writel(pevb, BAR_DMA, 0, reg);
	/* Cancel descriptor fetches */
	reg = XLNX_REG(SGDMA, 0, SGDMA_CTRL_W1S);
	val = BIT(sgma_ctrl_bit);
	pevb_writel(pevb, BAR_DMA, val, reg);
	reg = XLNX_REG(SGDMA, 0, SGDMA_CTRL_W1C);
	pevb_writel(pevb, BAR_DMA, val, reg);
	/* Cancel channel operation */
	reg = XLNX_REG(H2C, 0, H2C_CTRL) + chan_offset;
	pevb_writel(pevb, BAR_DMA, 0, reg);
	/* Dump performance counters */
	reg = XLNX_REG(H2C, 0, H2C_PERF_CYC_HIGH) + chan_offset;
	val = pevb_readl(pevb, BAR_DMA, reg);
	dev_dbg(&pevb->pdev->dev, "CYC_HIGH 0x%08x\n", val);
	reg = XLNX_REG(H2C, 0, H2C_PERF_CYC_LOW) + chan_offset;
	val = pevb_readl(pevb, BAR_DMA, reg);
	dev_dbg(&pevb->pdev->dev, "CYC_LOW  0x%08x\n", val);
	reg = XLNX_REG(H2C, 0, H2C_PERF_DAT_HIGH) + chan_offset;
	val = pevb_readl(pevb, BAR_DMA, reg);
	dev_dbg(&pevb->pdev->dev, "DAT_HIGH 0x%08x\n", val);
	reg = XLNX_REG(H2C, 0, H2C_PERF_DAT_LOW) + chan_offset;
	val = pevb_readl(pevb, BAR_DMA, reg);
	dev_dbg(&pevb->pdev->dev, "DAT_LOW  0x%08x\n", val);

	return ret;
}

static int pevb_dma_h2c_single(struct pevb *pevb, dma_addr_t pcie_addr,
	unsigned long ram_offset, unsigned long len)
{
	struct xlnx_dma_desc *desc;

	dev_dbg(&pevb->pdev->dev, "DMA H2C PCI:0x%llx -> BUF:0%04lx +0x%lx\n",
		pcie_addr, ram_offset, len);

	/* Create descriptor */
	desc = pevb->descs_ptr;
	desc->control = XLNX_DMA_DESC_CONTROL_MAGIC |
		XLNX_DMA_DESC_CONTROL_EOP |
		XLNX_DMA_DESC_CONTROL_COMPLETED |
		XLNX_DMA_DESC_CONTROL_STOP;
	desc->len = len;
	desc->src_adr = pcie_addr & 0xffffffffU;
	desc->src_adr_hi = pcie_addr >> 32;
	desc->dst_adr = ram_offset & 0xffffffffU;
	desc->dst_adr_hi = ram_offset >> 32;
	desc->nxt_adr = 0;
	desc->nxt_adr_hi = 0;

	return pevb_dma(pevb, false);
}

static int pevb_dma_c2h_single(struct pevb *pevb, dma_addr_t pcie_addr,
	unsigned long ram_offset, unsigned long len)
{
	struct xlnx_dma_desc *desc;

	dev_dbg(&pevb->pdev->dev, "DMA C2H BUF:0x%04lx -> PCI:0x%llx +0x%lx\n",
		ram_offset, pcie_addr, len);

	/* Create descriptor */
	desc = pevb->descs_ptr;
	desc->control = XLNX_DMA_DESC_CONTROL_MAGIC |
		XLNX_DMA_DESC_CONTROL_EOP |
		XLNX_DMA_DESC_CONTROL_COMPLETED |
		XLNX_DMA_DESC_CONTROL_STOP;
	desc->len = len;
	desc->src_adr = ram_offset & 0xffffffffU;
	desc->src_adr_hi = ram_offset >> 32;
	desc->dst_adr = pcie_addr & 0xffffffffU;
	desc->dst_adr_hi = pcie_addr >> 32;
	desc->nxt_adr = 0;
	desc->nxt_adr_hi = 0;

	return pevb_dma(pevb, true);
}

static int pevb_dma_h2c2h_multi(struct pevb *pevb, struct pevb_userbuf *src,
	struct pevb_userbuf *dst, u64 len)
{
	int ret;
	u64 overall_len_remaining = len;
	int src_idx = -1, dst_idx = -1;
	dma_addr_t src_addr, dst_addr;
	u64 src_len_remaining = 0, dst_len_remaining = 0;
	u64 len_chunk;

	if (down_interruptible(&pevb->sem))
		return -ERESTARTSYS;

	while (overall_len_remaining) {
		if (!src_len_remaining) {
			src_idx++;
			if (src_idx >= src->n_dmas) {
				ret = -EINVAL;
				goto unlock;
			}
			src_addr = src->dmas[src_idx].addr;
			src_len_remaining = src->dmas[src_idx].len;
		}
		if (!dst_len_remaining) {
			dst_idx++;
			if (dst_idx >= dst->n_dmas) {
				ret = -EINVAL;
				goto unlock;
			}
			dst_addr = dst->dmas[dst_idx].addr;
			dst_len_remaining = dst->dmas[dst_idx].len;
		}

		len_chunk = min_t(u64, src_len_remaining, dst_len_remaining);
		len_chunk = min_t(u64, len_chunk, pevb->drvdata->fpga_ram_size);
		len_chunk = min_t(u64, len_chunk, XLNX_DMA_DESC_LEN_MAX_WORD_ALIGNED);
		len_chunk = min_t(u64, len_chunk, overall_len_remaining);

		ret = pevb_dma_h2c_single(pevb, src_addr, 0, len_chunk);
		if (ret)
			goto unlock;

		ret = pevb_dma_c2h_single(pevb, dst_addr, 0, len_chunk);
		if (ret)
			goto unlock;

		overall_len_remaining -= len_chunk;
		src_len_remaining -= len_chunk;
		dst_len_remaining -= len_chunk;
		src_addr += len_chunk;
		dst_addr += len_chunk;
	}

	ret = 0;

unlock:
	up(&pevb->sem);

	return ret;
}

static int pevb_dma_h2c_multi(struct pevb *pevb, struct pevb_userbuf *src,
	u64 dst_offset, u64 len)
{
	int ret;
	u64 overall_len_remaining = len;
	int src_idx = -1;
	dma_addr_t src_addr;
	u64 src_len_remaining = 0;
	u64 len_chunk;

	if (down_interruptible(&pevb->sem))
		return -ERESTARTSYS;

	while (overall_len_remaining) {
		if (!src_len_remaining) {
			src_idx++;
			if (src_idx >= src->n_dmas) {
				ret = -EINVAL;
				goto unlock;
			}
			src_addr = src->dmas[src_idx].addr;
			src_len_remaining = src->dmas[src_idx].len;
		}

		/*
		 * We assume the caller has verified that dst_offset/len don't
		 * exceed FPGA RAM capacity.
		 */
		len_chunk = min_t(u64, src_len_remaining,
			XLNX_DMA_DESC_LEN_MAX_WORD_ALIGNED);
		len_chunk = min_t(u64, len_chunk, overall_len_remaining);

		/*
		 * FIXME: We should really generate a list of descriptors, and
		 * send them to the HW all at once, to avoid IRQ latency
		 * between transfers, when mulitple are needed. This is
		 * possible for h2c or c2h transfers, since there's no
		 * contention for FPGA RAM locations, unlike h2c2h transfers
		 * where each separate transfer re-uses the RAM. However, this
		 * makes no difference if the host has an IOMMU and hence
		 * always presents a large contiguous mapping of the buffer.
		 */
		ret = pevb_dma_h2c_single(pevb, src_addr, dst_offset, len_chunk);
		if (ret)
			goto unlock;

		overall_len_remaining -= len_chunk;
		src_len_remaining -= len_chunk;
		src_addr += len_chunk;
		dst_offset += len_chunk;
	}

	ret = 0;

unlock:
	up(&pevb->sem);

	return ret;
}

static int pevb_dma_c2h_multi(struct pevb *pevb, u64 src_offset,
	struct pevb_userbuf *dst, u64 len)
{
	int ret;
	u64 overall_len_remaining = len;
	int dst_idx = -1;
	dma_addr_t dst_addr;
	u64 dst_len_remaining = 0;
	u64 len_chunk;

	if (down_interruptible(&pevb->sem))
		return -ERESTARTSYS;

	while (overall_len_remaining) {
		if (!dst_len_remaining) {
			dst_idx++;
			if (dst_idx >= dst->n_dmas) {
				ret = -EINVAL;
				goto unlock;
			}
			dst_addr = dst->dmas[dst_idx].addr;
			dst_len_remaining = dst->dmas[dst_idx].len;
		}

		/*
		 * We assume the caller has verified that dst_offset/len don't
		 * exceed FPGA RAM capacity.
		 */
		len_chunk = min_t(u64, dst_len_remaining,
			XLNX_DMA_DESC_LEN_MAX_WORD_ALIGNED);
		len_chunk = min_t(u64, len_chunk, overall_len_remaining);

		/*
		 * FIXME: We should really generate a list of descriptors, and
		 * send them to the HW all at once, to avoid IRQ latency
		 * between transfers, when mulitple are needed. This is
		 * possible for h2c or c2h transfers, since there's no
		 * contention for FPGA RAM locations, unlike h2c2h transfers
		 * where each separate transfer re-uses the RAM. However, this
		 * makes no difference if the host has an IOMMU and hence
		 * always presents a large contiguous mapping of the buffer.
		 */
		ret = pevb_dma_c2h_single(pevb, dst_addr, src_offset, len_chunk);
		if (ret)
			goto unlock;

		overall_len_remaining -= len_chunk;
		dst_len_remaining -= len_chunk;
		src_offset += len_chunk;
		dst_addr += len_chunk;
	}

	ret = 0;

unlock:
	up(&pevb->sem);

	return ret;
}

#define H2C2H_VALID_FLAGS ( \
	PICOEVB_H2C2H_DMA_FLAG_SRC_IS_CUDA | \
	PICOEVB_H2C2H_DMA_FLAG_DST_IS_CUDA \
)

static int pevb_ioctl_h2c2h_dma(struct pevb_file *pevb_file, unsigned long arg)
{
	struct pevb *pevb = pevb_file->pevb;
	void __user *argp = (void __user *)arg;
	struct picoevb_rdma_h2c2h_dma dma_params;
	struct pevb_userbuf src_ubuf = {0}, dst_ubuf = {0};
	int ret;
	u64 ts, te;

	if (copy_from_user(&dma_params, argp, sizeof(dma_params)))
		return -EFAULT;

	if (dma_params.flags & ~H2C2H_VALID_FLAGS)
		return -EINVAL;

	mutex_lock(&pevb_file->lock);

	if (dma_params.flags & PICOEVB_H2C2H_DMA_FLAG_SRC_IS_CUDA)
#ifndef NV_BUILD_NO_CUDA
		ret = pevb_get_userbuf_cuda(pevb_file, &src_ubuf,
			dma_params.src, dma_params.len, 1);
#else
		ret = -EINVAL;
#endif
	else
		ret = pevb_get_userbuf_pages(pevb, &src_ubuf, dma_params.src,
			dma_params.len, 1);
	if (ret)
		goto put_userbuf_src;

	if (dma_params.flags & PICOEVB_H2C2H_DMA_FLAG_DST_IS_CUDA)
#ifndef NV_BUILD_NO_CUDA
		ret = pevb_get_userbuf_cuda(pevb_file, &dst_ubuf,
			dma_params.dst, dma_params.len, 0);
#else
		ret = -EINVAL;
#endif
	else
		ret = pevb_get_userbuf_pages(pevb, &dst_ubuf, dma_params.dst,
			dma_params.len, 0);
	if (ret)
		goto put_userbuf_dst;

	ts = pevb_time_ns();
	ret = pevb_dma_h2c2h_multi(pevb, &src_ubuf, &dst_ubuf, dma_params.len);
	te = pevb_time_ns();
	if (ret)
		goto put_userbuf_dst;

	dma_params.dma_time_ns = te - ts;
	ret = copy_to_user(argp, &dma_params, sizeof(dma_params));

	/* fall-through for cleanup */

put_userbuf_dst:
	pevb_put_userbuf(pevb, &dst_ubuf);
put_userbuf_src:
	pevb_put_userbuf(pevb, &src_ubuf);
	mutex_unlock(&pevb_file->lock);

	return ret;
}

static int pevb_ioctl_card_info(struct pevb_file *pevb_file, unsigned long arg)
{
	struct pevb *pevb = pevb_file->pevb;
	void __user *argp = (void __user *)arg;
	struct picoevb_rdma_card_info card_info_params = {0};
	int ret;

	card_info_params.fpga_ram_size = pevb->drvdata->fpga_ram_size;

	ret = copy_to_user(argp, &card_info_params, sizeof(card_info_params));
	if (ret)
		return ret;

	return 0;
}

#define H2C_VALID_FLAGS ( \
	PICOEVB_H2C_DMA_FLAG_SRC_IS_CUDA \
)

static int pevb_ioctl_h2c_dma(struct pevb_file *pevb_file, unsigned long arg)
{
	struct pevb *pevb = pevb_file->pevb;
	void __user *argp = (void __user *)arg;
	struct picoevb_rdma_h2c_dma dma_params;
	struct pevb_userbuf src_ubuf = {0};
	int ret;
	u64 ts, te;

	if (copy_from_user(&dma_params, argp, sizeof(dma_params)))
		return -EFAULT;

	if (dma_params.flags & ~H2C_VALID_FLAGS)
		return -EINVAL;

	if (dma_params.dst + dma_params.len > pevb->drvdata->fpga_ram_size)
		return -EINVAL;

	mutex_lock(&pevb_file->lock);

	if (dma_params.flags & PICOEVB_H2C_DMA_FLAG_SRC_IS_CUDA)
#ifndef NV_BUILD_NO_CUDA
		ret = pevb_get_userbuf_cuda(pevb_file, &src_ubuf,
			dma_params.src, dma_params.len, 1);
#else
		ret = -EINVAL;
#endif
	else
		ret = pevb_get_userbuf_pages(pevb, &src_ubuf, dma_params.src,
			dma_params.len, 1);
	if (ret)
		goto put_userbuf_src;

	ts = pevb_time_ns();
	ret = pevb_dma_h2c_multi(pevb, &src_ubuf, dma_params.dst, dma_params.len);
	te = pevb_time_ns();
	if (ret)
		goto put_userbuf_src;

	dma_params.dma_time_ns = te - ts;
	ret = copy_to_user(argp, &dma_params, sizeof(dma_params));

	/* fall-through for cleanup */

put_userbuf_src:
	pevb_put_userbuf(pevb, &src_ubuf);
	mutex_unlock(&pevb_file->lock);

	return ret;
}

#define C2H_VALID_FLAGS ( \
	PICOEVB_C2H_DMA_FLAG_DST_IS_CUDA \
)

static int pevb_ioctl_c2h_dma(struct pevb_file *pevb_file, unsigned long arg)
{
	struct pevb *pevb = pevb_file->pevb;
	void __user *argp = (void __user *)arg;
	struct picoevb_rdma_c2h_dma dma_params;
	struct pevb_userbuf dst_ubuf = {0};
	int ret;
	u64 ts, te;

	if (copy_from_user(&dma_params, argp, sizeof(dma_params)))
		return -EFAULT;

	if (dma_params.flags & ~C2H_VALID_FLAGS)
		return -EINVAL;

	if (dma_params.src + dma_params.len > pevb->drvdata->fpga_ram_size)
		return -EINVAL;

	mutex_lock(&pevb_file->lock);

	if (dma_params.flags & PICOEVB_C2H_DMA_FLAG_DST_IS_CUDA)
#ifndef NV_BUILD_NO_CUDA
		ret = pevb_get_userbuf_cuda(pevb_file, &dst_ubuf,
			dma_params.dst, dma_params.len, 0);
#else
		ret = -EINVAL;
#endif
	else
		ret = pevb_get_userbuf_pages(pevb, &dst_ubuf, dma_params.dst,
			dma_params.len, 0);
	if (ret)
		goto put_userbuf_dst;

	ts = pevb_time_ns();
	ret = pevb_dma_c2h_multi(pevb, dma_params.src, &dst_ubuf, dma_params.len);
	te = pevb_time_ns();
	if (ret)
		goto put_userbuf_dst;

	dma_params.dma_time_ns = te - ts;
	ret = copy_to_user(argp, &dma_params, sizeof(dma_params));

	/* fall-through for cleanup */

put_userbuf_dst:
	pevb_put_userbuf(pevb, &dst_ubuf);
	mutex_unlock(&pevb_file->lock);

	return ret;
}

#ifndef NV_BUILD_NO_CUDA
/*
 * Continuous C2H streaming (PICOEVB_IOC_C2H_STREAM_*): a circular list of
 * descriptors copies the FPGA RAM, as a ring, into a ring of CUDA buffers.
 * The engine runs until stopped; the FPGA paces it by holding its reads until
 * the data is there. Only one stream runs at a time, owned by one open file.
 */

#define PEVB_STREAM_MAX_BUFS	1024
#define PEVB_STREAM_MAX_DESCS	65536
#define PEVB_STREAM_DESC_MAX	SZ_128M

static void pevb_c2h_engine_halt(struct pevb *pevb)
{
	u32 reg, val;
	int i;

	reg = XLNX_REG(C2H, 0, H2C_CTRL);
	pevb_writel(pevb, BAR_DMA, 0, reg);
	reg = XLNX_REG(SGDMA, 0, SGDMA_CTRL_W1S);
	val = BIT(XLNX_DMA_SGDMA_CTRL_C2H_DSC_HALT_SHIFT);
	pevb_writel(pevb, BAR_DMA, val, reg);
	reg = XLNX_REG(SGDMA, 0, SGDMA_CTRL_W1C);
	pevb_writel(pevb, BAR_DMA, val, reg);

	/* The engine finishes its current descriptor before going idle */
	reg = XLNX_REG(C2H, 0, H2C_STATUS);
	for (i = 0; i < 100; i++) {
		val = pevb_readl(pevb, BAR_DMA, reg);
		if (!(val & XLNX_DMA_H2C_STATUS_BUSY))
			break;
		msleep(1);
	}
	if (val & XLNX_DMA_H2C_STATUS_BUSY)
		dev_err(&pevb->pdev->dev,
			"C2H stream: engine still busy after stop, status 0x%08x\n",
			val);
	pevb_readl(pevb, BAR_DMA, XLNX_REG(C2H, 0, H2C_STATUS_RD_CLR));
}

/* Must be called with pevb_file->lock held */
static bool pevb_stream_uses(struct pevb_file *pevb_file,
	struct pevb_cuda_surface *cusurf)
{
	struct pevb_stream *stream = pevb_file->pevb->stream;
	int i;

	if (!stream || stream->owner != pevb_file)
		return false;
	for (i = 0; i < stream->n_bufs; i++)
		if (stream->ubufs[i].priv.cuda.cusurf == cusurf)
			return true;
	return false;
}

/*
 * Stop this file's stream, if it has one, and release its mappings. If the
 * GPU driver is revoking one of the buffers (its free callback), that
 * buffer's mapping must be freed rather than unmapped. Must be called with
 * pevb_file->lock held.
 */
static void pevb_stream_stop(struct pevb_file *pevb_file,
	struct pevb_cuda_surface *revoked)
{
	struct pevb *pevb = pevb_file->pevb;
	struct pevb_stream *stream;
	int i;

	down(&pevb->sem);
	stream = pevb->stream;
	if (!stream || stream->owner != pevb_file) {
		up(&pevb->sem);
		return;
	}
	pevb_c2h_engine_halt(pevb);
	pevb->stream = NULL;
	up(&pevb->sem);

	for (i = 0; i < stream->n_bufs; i++) {
		struct pevb_userbuf *ubuf = &stream->ubufs[i];

		if (revoked && ubuf->priv.cuda.cusurf == revoked &&
				ubuf->priv.cuda.map) {
#ifdef NV_BUILD_DGPU
			nvidia_p2p_free_dma_mapping(ubuf->priv.cuda.map);
#else
			nvidia_p2p_dma_unmap_pages(ubuf->priv.cuda.map);
#endif
			ubuf->priv.cuda.map = NULL;
		}
		pevb_put_userbuf(pevb, ubuf);
	}
	kfree(stream->ubufs);
	dma_free_coherent(&pevb->pdev->dev, stream->descs_size, stream->descs,
		stream->descs_dma_addr);
	kfree(stream);
}

/*
 * Walk the buffers' DMA chunks, splitting them into descriptors that don't
 * cross the end of the FPGA ring. With descs == NULL, just count them.
 */
static u32 pevb_stream_build(struct pevb_stream *stream,
	struct picoevb_rdma_c2h_stream_buf *bufs, u64 ring_size,
	struct xlnx_dma_desc *descs, dma_addr_t descs_dma_addr)
{
	u64 src = 0;
	u32 n = 0;
	int b, j;

	for (b = 0; b < stream->n_bufs; b++) {
		struct pevb_userbuf *ubuf = &stream->ubufs[b];

		for (j = 0; j < ubuf->n_dmas; j++) {
			dma_addr_t dst = ubuf->dmas[j].addr;
			u64 left = ubuf->dmas[j].len;

			while (left) {
				u64 len = min_t(u64, left, ring_size - src);

				len = min_t(u64, len, PEVB_STREAM_DESC_MAX);
				if (descs) {
					struct xlnx_dma_desc *d = &descs[n];

					d->control = XLNX_DMA_DESC_CONTROL_MAGIC;
					d->len = len;
					d->src_adr = src & 0xffffffffU;
					d->src_adr_hi = src >> 32;
					d->dst_adr = dst & 0xffffffffU;
					d->dst_adr_hi = dst >> 32;
				}
				n++;
				dst += len;
				left -= len;
				src = (src + len) % ring_size;
			}
		}
		bufs[b].last_desc = n - 1;
	}

	/* Make the list circular */
	if (descs) {
		u32 i;

		for (i = 0; i < n; i++) {
			dma_addr_t next = descs_dma_addr +
				((i + 1) % n) * sizeof(*descs);

			descs[i].nxt_adr = next & 0xffffffffU;
			descs[i].nxt_adr_hi = next >> 32;
		}
	}
	return n;
}

static int pevb_ioctl_c2h_stream_start(struct pevb_file *pevb_file,
	unsigned long arg)
{
	struct pevb *pevb = pevb_file->pevb;
	void __user *argp = (void __user *)arg;
	struct picoevb_rdma_c2h_stream_start params;
	struct picoevb_rdma_c2h_stream_buf *bufs;
	struct pevb_stream *stream;
	u64 total = 0;
	u32 reg, val;
	int ret, b;

	if (copy_from_user(&params, argp, sizeof(params)))
		return -EFAULT;
	if (params.flags || !params.n_bufs ||
			params.n_bufs > PEVB_STREAM_MAX_BUFS ||
			!params.ring_size || params.ring_size % SZ_4K ||
			params.ring_size > pevb->drvdata->fpga_ram_size)
		return -EINVAL;

	bufs = kmalloc_array(params.n_bufs, sizeof(*bufs), GFP_KERNEL);
	if (!bufs)
		return -ENOMEM;
	if (copy_from_user(bufs, u64_to_user_ptr(params.bufs),
			params.n_bufs * sizeof(*bufs))) {
		kfree(bufs);
		return -EFAULT;
	}

	stream = kzalloc(sizeof(*stream), GFP_KERNEL);
	if (!stream) {
		kfree(bufs);
		return -ENOMEM;
	}
	stream->owner = pevb_file;
	stream->ubufs = kcalloc(params.n_bufs, sizeof(*stream->ubufs),
		GFP_KERNEL);
	if (!stream->ubufs) {
		ret = -ENOMEM;
		goto free_stream;
	}

	mutex_lock(&pevb_file->lock);

	for (b = 0; b < params.n_bufs; b++) {
		struct pevb_cuda_surface *cusurf;
		u64 len;

		if (bufs[b].handle & ~0xefffffffU) {
			ret = -EINVAL;
			goto put_bufs;
		}
		cusurf = pevb_find_cuda_surface(pevb_file, bufs[b].handle);
		if (!cusurf) {
			ret = -EINVAL;
			goto put_bufs;
		}
		len = cusurf->len;
		if (len % SZ_4K || cusurf->offset % SZ_4K) {
			ret = -EINVAL;
			goto put_bufs;
		}
		ret = pevb_get_userbuf_cuda(pevb_file, &stream->ubufs[b],
			bufs[b].handle, len, 0);
		stream->n_bufs = b + 1;
		if (ret)
			goto put_bufs;
		total += len;
	}
	if (total % params.ring_size) {
		ret = -EINVAL;
		goto put_bufs;
	}

	stream->n_descs = pevb_stream_build(stream, bufs, params.ring_size,
		NULL, 0);
	if (stream->n_descs > PEVB_STREAM_MAX_DESCS) {
		ret = -E2BIG;
		goto put_bufs;
	}
	stream->descs_size = stream->n_descs * sizeof(*stream->descs);
	stream->descs = dma_alloc_coherent(&pevb->pdev->dev, stream->descs_size,
		&stream->descs_dma_addr, GFP_KERNEL);
	if (!stream->descs) {
		ret = -ENOMEM;
		goto put_bufs;
	}
	pevb_stream_build(stream, bufs, params.ring_size, stream->descs,
		stream->descs_dma_addr);

	if (down_interruptible(&pevb->sem)) {
		ret = -ERESTARTSYS;
		goto free_descs;
	}
	if (pevb->stream) {
		up(&pevb->sem);
		ret = -EBUSY;
		goto free_descs;
	}

	reg = XLNX_REG(C2H_SGDMA, 0, H2C_SGDMA_DESC_LOW_ADDR);
	pevb_writel(pevb, BAR_DMA, stream->descs_dma_addr & 0xffffffffU, reg);
	reg = XLNX_REG(C2H_SGDMA, 0, H2C_SGDMA_DESC_HIGH_ADDR);
	pevb_writel(pevb, BAR_DMA, stream->descs_dma_addr >> 32, reg);
	reg = XLNX_REG(C2H_SGDMA, 0, H2C_SGDMA_DESC_ADJACENT);
	pevb_writel(pevb, BAR_DMA, 0, reg);
	pevb_readl(pevb, BAR_DMA, XLNX_REG(C2H, 0, H2C_STATUS_RD_CLR));
	/* No interrupts: the owner polls IOC_C2H_STREAM_STATUS */
	pevb_writel(pevb, BAR_DMA, 0, XLNX_REG(C2H, 0, H2C_INT_EN));
	/* Descriptors must be visible before the engine starts */
	wmb();
	reg = XLNX_REG(C2H, 0, H2C_COMPLETED_DESC_COUNT);
	val = pevb_readl(pevb, BAR_DMA, reg);
	pevb_writel(pevb, BAR_DMA, XLNX_DMA_H2C_CTRL_RUN,
		XLNX_REG(C2H, 0, H2C_CTRL));
	/*
	 * Take the count as of now as the base (whether or not the engine
	 * zeroes it on Run): no descriptor can complete this quickly.
	 */
	stream->base_count = pevb_readl(pevb, BAR_DMA, reg);
	dev_dbg(&pevb->pdev->dev, "C2H stream: count %u before Run, %u after\n",
		val, stream->base_count);
	pevb->stream = stream;
	up(&pevb->sem);

	mutex_unlock(&pevb_file->lock);

	params.n_descs = stream->n_descs;
	ret = 0;
	if (copy_to_user(u64_to_user_ptr(params.bufs), bufs,
			params.n_bufs * sizeof(*bufs)) ||
			copy_to_user(argp, &params, sizeof(params))) {
		mutex_lock(&pevb_file->lock);
		pevb_stream_stop(pevb_file, NULL);
		mutex_unlock(&pevb_file->lock);
		ret = -EFAULT;
	}
	kfree(bufs);
	return ret;

free_descs:
	dma_free_coherent(&pevb->pdev->dev, stream->descs_size, stream->descs,
		stream->descs_dma_addr);
put_bufs:
	for (b = 0; b < stream->n_bufs; b++)
		pevb_put_userbuf(pevb, &stream->ubufs[b]);
	mutex_unlock(&pevb_file->lock);
	kfree(stream->ubufs);
free_stream:
	kfree(stream);
	kfree(bufs);
	return ret;
}

static int pevb_ioctl_c2h_stream_status(struct pevb_file *pevb_file,
	unsigned long arg)
{
	struct pevb *pevb = pevb_file->pevb;
	struct picoevb_rdma_c2h_stream_status status;
	struct pevb_stream *stream;
	int ret = 0;

	/* Hold sem so the stream can't be stopped and freed meanwhile */
	if (down_interruptible(&pevb->sem))
		return -ERESTARTSYS;
	stream = pevb->stream;
	if (!stream) {
		up(&pevb->sem);
		return -ENODATA;
	}
	status.completed_descs = pevb_readl(pevb, BAR_DMA,
		XLNX_REG(C2H, 0, H2C_COMPLETED_DESC_COUNT)) - stream->base_count;
	status.status = pevb_readl(pevb, BAR_DMA, XLNX_REG(C2H, 0, H2C_STATUS));
	up(&pevb->sem);
	if (copy_to_user((void __user *)arg, &status, sizeof(status)))
		ret = -EFAULT;
	return ret;
}

static int pevb_ioctl_c2h_stream_stop(struct pevb_file *pevb_file)
{
	mutex_lock(&pevb_file->lock);
	pevb_stream_stop(pevb_file, NULL);
	mutex_unlock(&pevb_file->lock);
	return 0;
}
#endif

static long pevb_fops_unlocked_ioctl(struct file *filep, unsigned int cmd,
	unsigned long arg)
{
	struct pevb_file *pevb_file = filep->private_data;

	switch (cmd) {
	case PICOEVB_IOC_LED:
		return pevb_ioctl_led(pevb_file, arg);
#ifndef NV_BUILD_NO_CUDA
	case PICOEVB_IOC_PIN_CUDA:
		return pevb_ioctl_pin_cuda(pevb_file, arg);
	case PICOEVB_IOC_UNPIN_CUDA:
		return pevb_ioctl_unpin_cuda(pevb_file, arg);
#endif
	case PICOEVB_IOC_H2C2H_DMA:
		return pevb_ioctl_h2c2h_dma(pevb_file, arg);
	case PICOEVB_IOC_CARD_INFO:
		return pevb_ioctl_card_info(pevb_file, arg);
	case PICOEVB_IOC_H2C_DMA:
		return pevb_ioctl_h2c_dma(pevb_file, arg);
	case PICOEVB_IOC_C2H_DMA:
		return pevb_ioctl_c2h_dma(pevb_file, arg);
#ifndef NV_BUILD_NO_CUDA
	case PICOEVB_IOC_C2H_STREAM_START:
		return pevb_ioctl_c2h_stream_start(pevb_file, arg);
	case PICOEVB_IOC_C2H_STREAM_STATUS:
		return pevb_ioctl_c2h_stream_status(pevb_file, arg);
	case PICOEVB_IOC_C2H_STREAM_STOP:
		return pevb_ioctl_c2h_stream_stop(pevb_file);
#endif
	default:
		return -EINVAL;
	}
}

/*
 * Map BAR0 (the FPGA's AXI-Lite registers: GPIO, and the IQ generator on
 * designs that have one) into user space, so that applications can poll
 * registers without a system call.
 */
static int pevb_fops_mmap(struct file *filep, struct vm_area_struct *vma)
{
	struct pevb_file *pevb_file = filep->private_data;
	struct pci_dev *pdev = pevb_file->pevb->pdev;

	if (vma->vm_pgoff)
		return -EINVAL;
	vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
	return vm_iomap_memory(vma, pci_resource_start(pdev, BAR_GPIO),
		pci_resource_len(pdev, BAR_GPIO));
}

static const struct file_operations pevb_fops = {
	.owner		= THIS_MODULE,
	.open		= pevb_fops_open,
	.release	= pevb_fops_release,
	.unlocked_ioctl	= pevb_fops_unlocked_ioctl,
	.mmap		= pevb_fops_mmap,
};

static int pevb_probe(struct pci_dev *pdev, const struct pci_device_id *ent)
{
	struct pevb *pevb;
	int ret;

	pevb = kzalloc(sizeof(*pevb), GFP_KERNEL);
	if (!pevb)
		return -ENOMEM;
	pci_set_drvdata(pdev, pevb);
	pevb->pdev = pdev;
	pevb->drvdata = (const struct pevb_drvdata *)ent->driver_data;

	/*
	 * In practice, there is a limit of FPGA_RAM_SIZE. However, since every
	 * DMA operation actually consists of two copies (H2C and C2H) that are
	 * interleaved together in FPGA_RAM_SIZE chunks, and the src and dst
	 * IOVA mappings may not be identically aligned due to user-space not
	 * enforcing any particular alignment of the memory allocations, and
	 * hence may not be identically chunked into <=FPGA_RAM_SIZE segment
	 * sizes by dma_map_sg(), we cannot rely on dma_map_sg()'s chunking in
	 * this case. Instead, this driver must handle the chunking itself, and
	 * so can accept arbitrarily long IOVA chunks in sg lists.
	 */
	pevb->dma_params.max_segment_size = UINT_MAX;
	pdev->dev.dma_parms = &pevb->dma_params;

	sema_init(&pevb->sem, 1);
	init_completion(&pevb->dma_xfer_cmpl);

	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
	if (ret) {
		dev_err(&pdev->dev, "dma_set_mask_and_coherent(): %d\n", ret);
		goto err_free_pevb;
	}

	pevb->descs_ptr = dmam_alloc_coherent(&pdev->dev, SZ_4K,
		&pevb->descs_dma_addr, GFP_KERNEL);
	if (!pevb->descs_ptr) {
		dev_err(&pdev->dev,
			"dma_alloc_coherent(descriptors): failed\n");
		ret = -ENOMEM;
		goto err_free_pevb;
	}

	ret = pcim_enable_device(pdev);
	if (ret < 0) {
		dev_err(&pdev->dev, "pci_enable_device(): %d\n", ret);
		goto err_free_pevb;
	}

	ret = pcim_iomap_regions(pdev, BIT(BAR_GPIO) | BIT(BAR_DMA),
		MODULENAME);
	if (ret < 0) {
		dev_err(&pdev->dev, "pcim_iomap_regions(): %d\n", ret);
		goto err_free_pevb;
	}
	pevb->iomap = pcim_iomap_table(pdev);

	pci_set_master(pdev);

	if (no_relaxed_ordering) {
		pcie_capability_clear_word(pdev, PCI_EXP_DEVCTL,
			PCI_EXP_DEVCTL_RELAX_EN | PCI_EXP_DEVCTL_NOSNOOP_EN);
		dev_info(&pdev->dev, "Relaxed Ordering and No Snoop disabled\n");
	}

	ret = request_irq(pdev->irq, pevb_irq_handler, IRQF_SHARED,
		dev_name(&pdev->dev), pevb);
	if (ret) {
		dev_err(&pdev->dev, "request_irq(): %d\n", ret);
		goto err_clear_master;
	}

	pevb->misc.minor = MISC_DYNAMIC_MINOR;
	pevb->misc.name = "picoevb";
	pevb->misc.fops = &pevb_fops;
	pevb->misc.parent = &pdev->dev;
	ret = misc_register(&pevb->misc);
	if (ret) {
		dev_err(&pdev->dev, "misc_register(): %d\n", ret);
		goto err_free_irq;
	}

	return 0;

err_free_irq:
	free_irq(pdev->irq, pevb);
err_clear_master:
	pci_clear_master(pdev);
err_free_pevb:
	pdev->dev.dma_parms = NULL;
	kfree(pevb);
	return ret;
}

static void pevb_remove(struct pci_dev *pdev)
{
	struct pevb *pevb = pci_get_drvdata(pdev);

	misc_deregister(&pevb->misc);
	free_irq(pdev->irq, pevb);
	pci_clear_master(pdev);
	pdev->dev.dma_parms = NULL;
	kfree(pevb);
}

static void pevb_shutdown(struct pci_dev *pdev)
{
}

static const struct pevb_drvdata drvdata_picoevb = {
	.num_h2c_chans = 1,
	.fpga_ram_size = SZ_64K,
};

static const struct pevb_drvdata drvdata_htg_k800 = {
	.num_h2c_chans = 1,
	.fpga_ram_size = SZ_2G,
};

static const struct pevb_drvdata drvdata_acorn_cle215 = {
	.num_h2c_chans = 1,
	.fpga_ram_size = SZ_64K,
};

static const struct pevb_drvdata drvdata_acorn_cle215_x4 = {
	.num_h2c_chans = 1,
	.fpga_ram_size = SZ_1M,
};

#define PCI_ENTRY(sub_dev_id, data) \
	{ \
		PCI_DEVICE_SUB( \
			PCI_VENDOR_ID_NVIDIA, 0x0001, \
			PCI_VENDOR_ID_NVIDIA, sub_dev_id), \
	        .driver_data = (unsigned long)&drvdata_##data, \
	}

static const struct pci_device_id pevb_pci_ids[] = {
	PCI_ENTRY(0x0001, picoevb),
	PCI_ENTRY(0x0002, htg_k800),
	PCI_ENTRY(0x0003, acorn_cle215),
	PCI_ENTRY(0x0004, acorn_cle215_x4),
	PCI_ENTRY(0x0005, acorn_cle215_x4),	/* x4 with IQ generator */
	{ },
};
MODULE_DEVICE_TABLE(pci, pevb_pci_ids);

static struct pci_driver pevb_driver = {
	.name		= MODULENAME,
	.id_table	= pevb_pci_ids,
	.probe		= pevb_probe,
	.remove		= pevb_remove,
	.shutdown	= pevb_shutdown,
};

static int __init pevb_init(void)
{
	return pci_register_driver(&pevb_driver);
}
module_init(pevb_init);

static void __exit pevb_exit(void)
{
	pci_unregister_driver(&pevb_driver);
}
module_exit(pevb_exit);

/*
 * For questions, comments, or support, visit:
 *     http://developer.nvidia.com/embedded-computing
 * To report specific verified bugs, visit:
 *     https://github.com/NVIDIA/jetson-rdma-picoevb/issues
 */
MODULE_AUTHOR("NVIDIA");
MODULE_LICENSE("GPL v2");
