# Results

Every number here was measured on the reference rig; nothing is projected
unless marked as emulated. Re-run the listed command to reproduce a result.

**Rig:** SQRL Acorn CLE-215+ (Artix-7, PCIe Gen2 x4) in the CPU-attached M.2
slot; NVIDIA RTX A5000 (Gen4 x16, Resizable BAR, BAR1 32 GB); Intel Core
i9-12900K on Z690 with one DDR4-2133 DIMM (~15.5 GB/s measured memory
bandwidth); Ubuntu 24.04, kernel 6.8; driver 595 (open modules), CUDA 13.4;
`iommu=pt`. Radar parameters N = 4096, M = 128, L = 512 unless stated.

## Headline

| Measure | Result |
| ------- | ------ |
| Lossless real-time streaming rate | **375 MS/s** of 16-bit IQ (**1.50 GB/s**), the Gen2 x4 link's limit; 380 MS/s overflows |
| Long soak at 375 MS/s, 8 GPU buffers | **47 min, 0 samples lost, 0 buffers overwritten, both targets detected in 1,916,668 / 1,916,668 scored CPIs** |
| CPI in GPU memory -> detections | 0.13-0.19 ms median, ~0.24 ms p99 |
| Generator vs software model | bit-exact: 0 of 524,288 samples differ |
| GPU pipeline capacity (A5000) | ~6.5 GS/s sustained, so ~6% busy at 375 MS/s |

## FPGA to GPU streaming (`radar-bench stream`)

Continuous FPGA-paced DMA (`--dma stream`, the default), 3,000-5,000 CPIs per
rate:

| Rate | Throughput | Samples lost | Result |
| ---- | ---------- | ------------ | ------ |
| 150-375 MS/s | 0.6-1.50 GB/s | 0 | PASS at every rate tested |
| 380-500 MS/s | 1.52-2.0 GB/s | ring overflows | FAIL: link-limited |

Soaks:

| Run | CPIs | Lost | Overwritten | Targets detected | Latency median / p99 |
| --- | ---- | ---- | ----------- | ---------------- | -------------------- |
| 350 MS/s, 60 s, ring 3 | 40,000 | 0 | 0 | 40,000 / 40,000 | 0.134 / 0.247 ms |
| 375 MS/s, 60 s, ring 3 | 43,000 | 0 | 0 | 43,000 / 43,000 | 0.186 / 0.239 ms |
| 375 MS/s, 47 min, ring 3, moving targets | 2,000,000 | 0 | 12 | 1,916,668 / 1,916,668 | 0.135 / 0.233 ms |
| 375 MS/s, 47 min, ring 8, moving targets | 2,000,000 | 0 | **0** | 1,916,668 / 1,916,668 | |

"Overwritten" counts CPIs whose GPU buffer the DMA reached again before the
GPU finished with it, caused by occasional host stalls longer than the ring
covers (3 buffers = ~2.8 ms of slack; 8 buffers = ~10 ms). Moving-target runs
don't score the two CPIs after each target move, hence 1,916,668 scored of
2,000,000.

```bash
sudo ./radar-bench stream --N 4096 --M 128 --L 512 --rate-msps 375 --ring 8 --cpis 43000
sudo ./radar-bench stream --N 4096 --M 128 --L 512 --rate-msps 50 --gen-check
```

### Host-driven DMA, for comparison (`--dma ioctl`)

One ioctl per 256 KiB region of the FPGA ring:

| Rate | Result |
| ---- | ------ |
| 150 MS/s, 60 s | lossless, 17,166 / 17,166 CPIs with both targets detected, 0.17 ms latency |
| 200 MS/s and up | samples lost: ~40 us of fixed cost per DMA, occasional ~1 ms DMAs, 0.7-1 ms of FPGA buffering |

Moving the transfer scheduling into the FPGA and a circular descriptor list
raised the lossless rate 2.5x, to the link limit.

## Link and transport (`radar-bench ingest`, `rdma-cuda-c2h-verify`)

1 MiB DMAs, Gen2 x4:

| Transport | MB/s | Latency p50 | Host CPU |
| --------- | ---- | ----------- | -------- |
| GPUDirect RDMA (FPGA -> GPU) | 1401 | 747 us | 4% |
| FPGA -> host RAM only (reference) | 1390 | 754 us | 4% |
| Staged through host RAM, pipelined | 1344 | 880 us | 17% |
| Staged through host RAM, serial | 1253 | 831 us | 13% |

The same design trained at x1 delivered ~81 MS/s end to end; at x4, ~350 MS/s
with the original host-driven DMA and 375 MS/s with continuous DMA.

End to end, CPI 4096 x 256, all paths keep up with the FPGA: `rdma` ~343 MS/s
and 0.40 ms from a CPI's last sample to its detections; `staged` ~326-336 MS/s
and 0.41-0.44 ms; `zerocopy` (GPU reads host memory) ~340 MS/s but 0.67 ms.

## Higher rates, emulated source (`radar-bench emulate`)

A paced software source writes either straight into GPU memory (`direct`, like
RDMA) or into pinned huge-page host memory followed by a copy (`staged`). At
1.4 GB/s it reproduces the real FPGA measurements within ~5%. CPI 16384 x 256:

| Rate | Direct (RDMA-like) | Staged through host memory |
| ---- | ------------------ | -------------------------- |
| 1.4-6 GB/s | keeps up, 0.8-1.1 ms latency | keeps up, 0.9-1.15 ms |
| 9 GB/s | keeps up, 0.87 ms | 7.1 GB/s max, overruns |
| 12-20 GB/s | keeps up, ~0.78 ms | 7.2 GB/s max, overruns |
| 24+ GB/s | ~22.8 GB/s max (GPU processing limit) | 7.2 GB/s max |

Staging moves each byte through host DRAM twice, capping it at about half
the host's memory bandwidth (~15.5 GB/s here). GPUDirect RDMA does not use
host memory and runs until the GPU is the limit.

## GPU pipeline alone (`radar-bench gpu`)

| GPU | CPI | Sustained |
| --- | --- | --------- |
| RTX A5000 | 4096 x 64 to 16384 x 1024 | ~6.5 GS/s (26 GB/s of int16 IQ) |
| RTX A5000 | 1024 x 256 | 7.5 GS/s (peak) |
| RTX A5000 | 1024 x 64 | 3.6 GS/s (kernel launch overhead) |
| RTX A5000 | 65536-point pulses | ~5 GS/s (FFT efficiency) |
| Tesla K80 (per GPU, earlier) | typical CPIs | ~1.0 GS/s |

Pulse compression takes 40-50% of the time. Fusing power and CFAR into one
shared-memory kernel gained 18% over separate kernels, with identical
detections.

## Board bring-up

| Item | Result |
| ---- | ------ |
| FPGA configuration from flash | 5.17 MB compressed bitstream, ~115 ms at 90 MHz quad SPI |
| Cold boot before the link watchdog | link stuck in Training (or x1); board missing |
| Cold boot with the watchdog | x4 at 5 GT/s after 3 watchdog resets |
| Warm reboots | always x4 |
| Dashboard | 15 frames/s to a browser on the LAN (671 frames in 45 s), no effect on the real-time loop |
