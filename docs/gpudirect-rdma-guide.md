# GPUDirect RDMA bring-up guide (discrete GPU on a PC)

How to get a custom PCIe device writing GPU memory directly, what has to be
true of the GPU, driver, platform and kernel, how to verify each layer, and
how failures look. Written from bringing up an FPGA (SQRL Acorn CLE-215+)
with a Tesla K80 and then an RTX A5000 on a Z690 desktop. Step-by-step build
commands are in the main [README](../README.md#discrete-gpus-on-a-pc).

## What GPUDirect RDMA is, mechanically

A CUDA allocation lives in GPU memory. The GPU exposes a window onto its
memory through a PCI BAR (BAR1). The NVIDIA kernel driver can **pin** an
allocation (stop it moving) and **map** it into that window for a given peer
device, returning bus addresses. The peer's DMA engine then issues ordinary
PCIe memory reads/writes to those addresses, and the root complex (or a PCIe
switch) routes them peer to peer to the GPU. No host memory, no CPU copy.

Two kernel-level routes exist:

| Peer device | Kernel API | Notes |
| ----------- | ---------- | ----- |
| Custom device with its own driver (FPGA, ADC card) | `nvidia_p2p_get_pages` / `nvidia_p2p_dma_map_pages` (`nv-p2p.h`) | What this repo uses |
| RDMA NIC (ConnectX, for RoCE/InfiniBand) | `nvidia-peermem` module + verbs `ibv_reg_mr` on CUDA memory | The route for 100 GbE RoCE ingest; see the [roadmap](roadmap.md) |

## Requirements checklist

| Layer | Requirement | How to check |
| ----- | ----------- | ------------ |
| GPU | RTX/Quadro or data center GPU (Kepler or newer). **Not GeForce.** | `nvidia-smi -L` |
| Driver | Open kernel modules preferred (Turing+): `nvidia-driver-XXX-open` + DKMS, which also installs the source containing `nv-p2p.h` | `modinfo nvidia \| grep license` (Dual MIT/GPL) |
| BAR1 | Large enough for all memory pinned at once. Enable "Above 4G decoding" and "Re-Size BAR" in the BIOS | `nvidia-smi -q -d MEMORY` -> BAR1 Memory Usage |
| IOMMU | Off or pass-through | `cat /proc/cmdline` contains `iommu=pt` |
| Topology | Device and GPU both on CPU root ports of the same socket (or under one PCIe switch) | `lspci -tv` |
| Direction | The platform must route peer-to-peer **writes**; reads are often unsupported on desktops | `rdma-cuda-c2h-verify` (writes only) vs `rdma-cuda` (both) |
| Secure Boot | Sign your module with an enrolled key | `mokutil --sb-state` |

## The driver pattern

The essential sequence, as implemented in `kernel-module/picoevb-rdma.c`:

```c
/* user space: cudaMalloc(&p, len); cuPointerSetAttribute(SYNC_MEMOPS, p);
 * then ioctl(PIN_CUDA, {va = p, size = len}) */

/* Pin: va and length aligned to the 64 KiB GPU page */
nvidia_p2p_get_pages(0, 0, va, aligned_len, &page_table,
                     free_callback, ctx);

/* Map for this PCI device: one bus address per GPU page */
nvidia_p2p_dma_map_pages(pdev, page_table, &map);
for (i = 0; i < map->entries; i++)
        program_dma(map->dma_addresses[i], 64 KiB);   /* merge contiguous pages */

/* Teardown, normal path */
nvidia_p2p_dma_unmap_pages(pdev, page_table, map);
nvidia_p2p_put_pages(0, 0, va, page_table);

/* free_callback(ctx): the GPU memory is being freed under you (cudaFree,
 * process exit). Stop all DMA to it first, then
 * nvidia_p2p_free_dma_mapping(map) and nvidia_p2p_free_page_table(pt);
 * do not call put_pages from here. */
```

Rules learned the hard way:

- **Stop DMA before any mapping goes away**, including when the owning process
  dies (`release`) and in the free callback. A running engine writing to a
  revoked mapping corrupts GPU memory.
- **No GPL-only kernel symbols** if the module may be built against NVIDIA's
  proprietary modules (Linux 5.13+ refuses the combination at load time). Use
  `misc_register`, plain `kmalloc`, `ktime_get_raw_ts64`, etc.
  `build-for-pc-native.sh` fails the build if any GPL-only import slips in.
- **Symbol versions:** with `CONFIG_MODVERSIONS`, modpost needs the CRCs of the
  `nvidia_p2p_*` symbols. `nvidia-ko-to-module-symvers` extracts them from the
  installed `nvidia.ko` (compressed or not; CRCs as absolute symbols before
  Linux 5.19, as section data after) in the kernel's own `Module.symvers` field
  format. Add any new `nvidia_p2p_*` function you call to its list.
- **Rebuild and re-sign after every kernel update.** DKMS rebuilds NVIDIA's
  modules, not yours; the stale module fails with "disagrees about version of
  symbol".

## Verification ladder

Run from cheapest to most complete; each step isolates one more layer.

1. **GPU side only, no device needed:** `sudo ./gpu-p2p-selftest/run-selftest.sh <peer BDF>`
   pins CUDA memory, maps it for a stand-in PCI device, checks the bus
   addresses lie inside BAR1, and exercises the free callback. It also finds
   the BAR1 limit (it falls back to 64 MiB pins when BAR1 is small).
2. **Device writes GPU memory:** `sudo ./client-applications/rdma-cuda-c2h-verify`
   fills the FPGA's RAM from the host, has the FPGA write it into GPU memory,
   and checks every word. It never has the device read GPU memory, so it works
   on platforms without peer-to-peer reads.
3. **Both directions** (only where the platform routes reads):
   `sudo ./client-applications/rdma-cuda`.
4. **Bit-exact streaming:** `radar-bench stream --gen-check` compares a CPI
   streamed by the continuous DMA path with a software model of the FPGA
   generator, sample by sample.
5. **Sustained real time:** `radar-bench stream --rate-msps <rate> --ring 8
   --cpis <many>` and check: 0 samples lost, 0 buffers overwritten, all
   targets detected.

## Failure signatures

| Symptom | Likely cause | What to do |
| ------- | ------------ | ---------- |
| `insmod`: "Unknown symbol" / GPL-related refusal | GPL-only symbol used with proprietary NVIDIA modules | Remove the GPL-only API; use the open modules |
| `insmod`: "disagrees about version of symbol" | Kernel updated, module stale | Rebuild and re-sign |
| `insmod`: "Key was rejected by service" | Secure Boot, unsigned module | `kmodsign` with the enrolled MOK |
| `nvidia_p2p_get_pages` returns `-ENOMEM` for large pins | BAR1 exhausted | Enable Resizable BAR, or pin less |
| DMA times out; status `0x00000200`-style read error from the engine | Device reading GPU memory on a platform that doesn't route peer reads | Use device-to-GPU writes only |
| DMA engine stuck until reboot after a read attempt with `no_relaxed_ordering=1` | Same, read completions never return | Same |
| Writes land but data looks stale or shifted | Missing completion semantics: processing started before the transfer completed | Wait on the engine's completion (status or completed-descriptor count) before launching GPU work |
| Host hangs or GPU drops off the bus under load, `RmInitAdapter failed` | Hardware: GPU not fully seated or powered (seen with a K80) | Reseat; power-cycle from the PSU; prove it before blaming the platform |
| Device enumerates at reduced width/speed | Lane placement, or late FPGA configuration at power-on | See the [lessons learned](lessons-learned.md) |

## Platform notes from this rig

- Intel Z690 / i9-12900K: peer-to-peer **writes** from a CPU-attached M.2 slot
  to a GPU in the CPU x16 slot work at full link rate; **reads** do not.
  Chipset-attached slots and an M.2-to-PCIe adapter failed for the FPGA.
- `iommu=pt` was required. ACS was not an obstacle with the device and GPU on
  separate CPU root ports.
- With the device on a CPU M.2 slot and the GPU at x16, both run at full
  width. Adding a second large device (a Gen4 x8 RFSoC or a 100 GbE NIC) would
  force an x8/x8 split on this desktop CPU; plan a workstation or server
  platform with more CPU lanes, or a PCIe switch, for that.
- Kernel lockdown (Secure Boot) blocks `setpci` writes and `dynamic_debug`,
  which removes two common debugging tools. Plan diagnostics into the driver
  and the FPGA (status registers, counters) instead.

## Porting to another device

What carries over unchanged: the pin/map/free-callback pattern, the stream
lifetime rules, and the user-space pattern (pin whole buffers, start a
continuous stream, poll a completion counter, launch GPU work per buffer).

What to replace:

- **The DMA engine programming.** XDMA in AXI-MM mode with circular
  descriptors is specific to this design. A QDMA (UltraScale+) or AXI-Stream
  XDMA design streams natively with completion rings, so the pacing gate
  becomes unnecessary; keep an overflow counter at the source either way.
- **Completion signalling.** Polling a counter register over MMIO costs ~1-2 us
  per poll here. An engine that writes back its progress to host memory lets the
  host poll memory instead.
- **For a NIC (100 GbE RoCE):** no custom kernel driver. Load
  `nvidia-peermem`, register CUDA buffers with `ibv_reg_mr`, and have the
  sender (an RFSoC's RoCE engine) RDMA-write into them; the AMS GRA RF MEL
  `RDMAExternalEndpointParams` (MAC, queue pair, remote key) describe exactly
  this.
