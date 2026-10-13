/*
 * Copyright (c) 2026, HOYS.  All rights reserved.
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

/*
 * Exercises the GPU side of GPUDirect RDMA on a dGPU without any FPGA: pins
 * CUDA memory with nvidia_p2p_get_pages() and DMA-maps it for a stand-in peer
 * PCI device with nvidia_p2p_dma_map_pages(), exactly as picoevb-rdma does,
 * and checks that the resulting bus addresses lie within the GPU's BAR1. No
 * DMA is ever performed.
 *
 * Like picoevb-rdma, this avoids GPL-only kernel symbols, since it imports
 * symbols from the proprietary nvidia.ko.
 */

#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include <nv-p2p.h>

#include "p2p-selftest-ioctl.h"

#define GPU_PAGE_SHIFT	16
#define GPU_PAGE_SIZE	(((u64)1) << GPU_PAGE_SHIFT)
#define GPU_PAGE_OFFSET	(GPU_PAGE_SIZE - 1)
#define GPU_PAGE_MASK	(~GPU_PAGE_OFFSET)

static char *peer = "";
module_param(peer, charp, 0444);
MODULE_PARM_DESC(peer, "PCI name (e.g. 0000:05:00.0) of the stand-in peer device");

static struct pci_dev *peer_pdev;

/* State for the HOLD/FREED/RELEASE free-callback test */
static DEFINE_MUTEX(hold_lock);
static struct nvidia_p2p_page_table *hold_table;
static u64 hold_va;
static bool hold_freed;

static const char *page_size_str(u32 type)
{
	switch (type) {
	case NVIDIA_P2P_PAGE_SIZE_4KB:
		return "4KB";
	case NVIDIA_P2P_PAGE_SIZE_64KB:
		return "64KB";
	case NVIDIA_P2P_PAGE_SIZE_128KB:
		return "128KB";
	default:
		return "?";
	}
}

static u32 page_size_bytes(u32 type)
{
	switch (type) {
	case NVIDIA_P2P_PAGE_SIZE_4KB:
		return SZ_4K;
	case NVIDIA_P2P_PAGE_SIZE_64KB:
		return SZ_64K;
	case NVIDIA_P2P_PAGE_SIZE_128KB:
		return SZ_128K;
	default:
		return 0;
	}
}

/* Find the NVIDIA GPU whose BAR1 contains [start, end) */
static struct pci_dev *find_gpu_bar1(u64 start, u64 end)
{
	struct pci_dev *pdev = NULL;

	while ((pdev = pci_get_device(PCI_VENDOR_ID_NVIDIA, PCI_ANY_ID, pdev))) {
		resource_size_t s = pci_resource_start(pdev, 1);
		resource_size_t e = pci_resource_end(pdev, 1);

		if ((pdev->class >> 16) != PCI_BASE_CLASS_DISPLAY)
			continue;
		if (s && start >= s && end - 1 <= e)
			return pdev; /* caller must pci_dev_put() */
	}

	return NULL;
}

static void free_callback_map(void *data)
{
	/* Only reached if the CUDA buffer is freed during IOC_MAP; ignore */
	pr_warn("p2p-selftest: unexpected free callback during map test\n");
}

static int ioctl_map(unsigned long arg)
{
	struct p2p_selftest_map p;
	struct nvidia_p2p_page_table *table = NULL;
	struct nvidia_p2p_dma_mapping *map = NULL;
	struct pci_dev *gpu;
	u64 va, offset, len, lo = ~0ULL, hi = 0;
	u32 psize;
	int ret, i;

	if (copy_from_user(&p, (void __user *)arg, sizeof(p)))
		return -EFAULT;

	va = p.va & GPU_PAGE_MASK;
	offset = p.va & GPU_PAGE_OFFSET;
	len = (offset + p.size + GPU_PAGE_SIZE - 1) & GPU_PAGE_MASK;

	ret = nvidia_p2p_get_pages(0, 0, va, len, &table, free_callback_map,
		NULL);
	if (ret) {
		pr_err("p2p-selftest: nvidia_p2p_get_pages(0x%llx, 0x%llx): %d\n",
			va, len, ret);
		return ret;
	}

	ret = nvidia_p2p_dma_map_pages(peer_pdev, table, &map);
	if (ret) {
		pr_err("p2p-selftest: nvidia_p2p_dma_map_pages(%s): %d\n",
			pci_name(peer_pdev), ret);
		goto put_pages;
	}

	psize = page_size_bytes(map->page_size_type);
	memset(&p.gpu, 0, sizeof(p.gpu));
	strscpy(p.peer, pci_name(peer_pdev), sizeof(p.peer));
	p.page_size = psize;
	p.entries = map->entries;
	p.first_phys = table->pages[0]->physical_address;
	p.first_dma = map->dma_addresses[0];
	p.last_dma = map->dma_addresses[map->entries - 1];
	p.contiguous = 1;
	for (i = 0; i < map->entries; i++) {
		u64 a = map->dma_addresses[i];

		if (i && a != map->dma_addresses[i - 1] + psize)
			p.contiguous = 0;
		lo = min(lo, a);
		hi = max(hi, a + psize);
	}

	gpu = find_gpu_bar1(lo, hi);
	p.dma_in_bar = !!gpu;
	if (gpu) {
		strscpy(p.gpu, pci_name(gpu), sizeof(p.gpu));
		pci_dev_put(gpu);
	}

	pr_info("p2p-selftest: va 0x%llx size 0x%llx: %u x %s pages, phys 0x%llx, dma 0x%llx-0x%llx%s, %s BAR1 %s\n",
		p.va, p.size, p.entries, page_size_str(map->page_size_type),
		p.first_phys, lo, hi - 1, p.contiguous ? " (contiguous)" : "",
		p.dma_in_bar ? "in" : "NOT in", p.dma_in_bar ? p.gpu : "");

	nvidia_p2p_dma_unmap_pages(peer_pdev, table, map);
put_pages:
	nvidia_p2p_put_pages(0, 0, va, table);
	/* As in picoevb-rdma: dGPU put_pages doesn't call the callback */
	nvidia_p2p_free_page_table(table);

	if (ret)
		return ret;
	if (copy_to_user((void __user *)arg, &p, sizeof(p)))
		return -EFAULT;
	return 0;
}

static void free_callback_hold(void *data)
{
	mutex_lock(&hold_lock);
	pr_info("p2p-selftest: free callback for held va 0x%llx\n", hold_va);
	if (hold_table) {
		nvidia_p2p_free_page_table(hold_table);
		hold_table = NULL;
	}
	hold_freed = true;
	mutex_unlock(&hold_lock);
}

static int ioctl_hold(unsigned long arg)
{
	struct p2p_selftest_hold h;
	struct nvidia_p2p_page_table *table;
	u64 va, len;
	int ret;

	if (copy_from_user(&h, (void __user *)arg, sizeof(h)))
		return -EFAULT;

	va = h.va & GPU_PAGE_MASK;
	len = ((h.va & GPU_PAGE_OFFSET) + h.size + GPU_PAGE_SIZE - 1) &
		GPU_PAGE_MASK;

	mutex_lock(&hold_lock);
	if (hold_table) {
		mutex_unlock(&hold_lock);
		return -EBUSY;
	}
	hold_freed = false;
	hold_va = va;
	mutex_unlock(&hold_lock);

	/* The callback may run as soon as this returns, so set state first */
	ret = nvidia_p2p_get_pages(0, 0, va, len, &table, free_callback_hold,
		NULL);
	if (ret)
		return ret;

	mutex_lock(&hold_lock);
	if (!hold_freed)
		hold_table = table;
	mutex_unlock(&hold_lock);

	return 0;
}

static int ioctl_release(void)
{
	mutex_lock(&hold_lock);
	if (hold_table) {
		nvidia_p2p_put_pages(0, 0, hold_va, hold_table);
		nvidia_p2p_free_page_table(hold_table);
		hold_table = NULL;
	}
	hold_freed = false;
	mutex_unlock(&hold_lock);

	return 0;
}

static long p2p_selftest_ioctl(struct file *filep, unsigned int cmd,
	unsigned long arg)
{
	int ret;

	switch (cmd) {
	case P2P_SELFTEST_IOC_MAP:
		return ioctl_map(arg);
	case P2P_SELFTEST_IOC_HOLD:
		return ioctl_hold(arg);
	case P2P_SELFTEST_IOC_FREED:
		mutex_lock(&hold_lock);
		ret = hold_freed;
		mutex_unlock(&hold_lock);
		return ret;
	case P2P_SELFTEST_IOC_RELEASE:
		return ioctl_release();
	default:
		return -EINVAL;
	}
}

static int p2p_selftest_release(struct inode *inode, struct file *filep)
{
	return ioctl_release();
}

static const struct file_operations p2p_selftest_fops = {
	.owner		= THIS_MODULE,
	.release	= p2p_selftest_release,
	.unlocked_ioctl	= p2p_selftest_ioctl,
};

static struct miscdevice p2p_selftest_misc = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "p2p-selftest",
	.fops	= &p2p_selftest_fops,
};

static int __init p2p_selftest_init(void)
{
	unsigned int domain, bus, slot, fn;
	int ret;

	if (sscanf(peer, "%x:%x:%x.%x", &domain, &bus, &slot, &fn) != 4) {
		pr_err("p2p-selftest: set peer=DDDD:BB:SS.F\n");
		return -EINVAL;
	}
	peer_pdev = pci_get_domain_bus_and_slot(domain, bus,
		PCI_DEVFN(slot, fn));
	if (!peer_pdev) {
		pr_err("p2p-selftest: no PCI device %s\n", peer);
		return -ENODEV;
	}

	ret = misc_register(&p2p_selftest_misc);
	if (ret)
		pci_dev_put(peer_pdev);
	return ret;
}
module_init(p2p_selftest_init);

static void __exit p2p_selftest_exit(void)
{
	misc_deregister(&p2p_selftest_misc);
	pci_dev_put(peer_pdev);
}
module_exit(p2p_selftest_exit);

MODULE_AUTHOR("NVIDIA");
MODULE_LICENSE("GPL v2");
