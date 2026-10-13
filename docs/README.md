# Documentation

This repository started as NVIDIA's minimal GPUDirect RDMA demonstration
and now contains a working real-time radar ingest chain: an FPGA streams
16-bit IQ samples over PCIe directly into GPU memory, where a pulse-Doppler
pipeline turns them into detections, at 375 MS/s (1.50 GB/s, the link's
limit) with no samples lost over 47-minute runs.

## Reading order

| If you want to... | Read |
| ----------------- | ---- |
| Get oriented fast (AI agents start here) | [../AGENTS.md](../AGENTS.md) |
| See the whole system at a glance | [pipeline-diagram.html](pipeline-diagram.html) (open in a browser) |
| Understand how and why it works | [architecture.md](architecture.md) |
| Get GPUDirect RDMA working on your own device and platform | [gpudirect-rdma-guide.md](gpudirect-rdma-guide.md) |
| Relate it to radar, or size a different system | [radar-context.md](radar-context.md) |
| See what was measured, and reproduce it | [results.md](results.md) |
| Avoid the problems already solved | [lessons-learned.md](lessons-learned.md) |
| Pick up the next piece of work | [roadmap.md](roadmap.md) |
| Build, flash and run step by step | [../README.md](../README.md) |

## Key ideas, in one paragraph each

**Write, don't copy.** The FPGA's DMA engine writes GPU memory through the
GPU's BAR1 (GPUDirect RDMA, `nvidia_p2p_*`). Sample data crosses PCIe once and
never touches host memory, so host memory bandwidth (the limit of any staged
design) stops mattering. On this rig staging caps at ~7.1 GB/s; direct writes
ran to the GPU's ~22.8 GB/s processing limit in emulation.

**No per-transfer host work.** A circular descriptor list keeps the DMA
engine streaming a ring of GPU buffers forever. A small gate in the FPGA holds
each read until the data exists, so the engine runs exactly at the source
rate. The host only polls a completion counter. This took the lossless rate
from 150 MS/s to the link's 375 MS/s.

**Never wait, always count.** Like a real ADC, the source never stops for
back-pressure, and the DMA never waits for the GPU. Every stage that can fall
behind has a counter (FPGA ring overflows, GPU buffers overwritten), and
"real time" means those stay zero while every CPI's targets are found.

**Real time on Linux is configuration, not luck.** One pinned
`SCHED_FIFO` thread, no busy-spinning (or the kernel throttles it), helper
threads created before going real-time, and enough buffering (8 CPIs) to ride
out the host stalls that still happen.
