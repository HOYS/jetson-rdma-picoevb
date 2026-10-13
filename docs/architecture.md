# Architecture: FPGA to GPU radar ingest over GPUDirect RDMA

This document explains how the streaming radar pipeline works and why each
piece is built the way it is. For setup steps see the
[bring-up guide](gpudirect-rdma-guide.md); for measured numbers see
[results](results.md). A rendered diagram is in
[pipeline-diagram.html](pipeline-diagram.html).

## The problem

A radar receiver produces IQ samples continuously at a fixed rate. They must
reach the processor without loss, be processed at least as fast as they
arrive, and produce detections with low, bounded latency. The usual PC
approach (device DMAs into host RAM, CPU or copy engine moves the data to the
GPU) costs host memory bandwidth twice per byte and adds a copy to the
latency. **GPUDirect RDMA** removes that: the device writes GPU memory
directly over PCIe.

The goal of this work was to show that architecture end to end, at the
hardware link's limit, with real-time guarantees that are measured rather
than assumed.

## Data path

```
  FPGA (Acorn CLE-215+)                      PCIe Gen2 x4            GPU (RTX A5000)
 +---------------------------------------+                      +---------------------------+
 | IQ generator --> RAM ring (1 MiB) ---|--> pacing gate -->   |  CPI buffer ring (N x 2 MiB)|
 |  375 MS/s       65,536 x 128-bit      |    XDMA engine ===== peer-to-peer write ====>     |
 |  4 samples/word written by port B     |    (circular        |  convert -> pulse compress  |
 |                                       |     descriptors)    |  -> corner turn -> Doppler  |
 +---------------------------------------+                      |  -> power + CA-CFAR         |
                                                                |  -> detection list          |
  Host CPU (control only, no sample data)                       +-------------+-------------+
   driver: pins GPU buffers, builds descriptor list, starts engine           |
   real-time loop: polls completion count, launches each CPI  <--------------+  detections
   scoring, telemetry thread -> dashboard server -> browser
```

Sample data crosses the PCIe link exactly once, from the FPGA into GPU
memory. The host CPU never touches it and host RAM never holds it.

## 1. The source: IQ generator (`fpga-acorn-cle215/iq_gen.v`)

The generator stands in for an ADC plus digital downconverter. Per 125 MHz
AXI clock it can emit one 128-bit word of four complex samples
(`{Q[15:0], I[15:0]}`, I in the low half), so up to 500 MS/s; `RATE_INC` sets
a fractional rate below that.

Each pulse of `2^LOG2N` samples contains up to two targets' echoes of a
512-sample LFM chirp (the same chirp the GPU's matched filter uses), at a
programmable delay (range), rotated each pulse by a programmable phase step
(Doppler), at a programmable amplitude, plus approximately Gaussian noise (sum
of four uniform xorshift64 outputs). A five-stage pipeline produces it; chirp
and sin/cos ROMs come from `gen-iq-roms.py`. The output is bit-exact against a
software model (`radar-bench stream --gen-check`).

It writes the samples into the FPGA's 1 MiB block RAM through the RAM's
second port, as a ring of 65,536 words (~0.7 ms at 375 MS/s). It keeps three
counters: `WRITE_WORDS` (written since enable), `READ_WORDS` (consumed), and
`OVERFLOWS` (words written while `WRITE_WORDS - READ_WORDS >= 65536`, that
is, samples lost). Like a real ADC, **it never stops for back-pressure**:
falling behind loses samples, and the counter says so.

Registers sit at BAR0 + 0x1000 (map in the header of `iq_gen.v`); the driver
`mmap`s BAR0 so user space can program and poll them with no system call.

## 2. The pacing gate (in `iq_gen.v`, wired in `top.v`)

The XDMA engine in AXI memory-mapped mode reads the RAM through an AXI4 bus.
Left alone it would read the ring as fast as it could, whether or not the
generator had filled it. The gate makes the engine read only data that
exists:

- With `CONTROL[2]` (DMA-paced) set and the generator running, each AXI read
  burst (`ARVALID`/`ARREADY`) is held until the generator has written all of
  its words: `written - granted >= ARLEN + 1`.
- `written` is `WRITE_WORDS` delayed by three clocks, because the RAM writes a
  word on the edge after it is counted and a granted read reaches the RAM at
  least one cycle after the grant.
- Each read data beat increments `READ_WORDS`, so the generator's overflow
  accounting tracks the DMA automatically.
- When the generator is stopped, bursts pass freely, so the engine can always
  be stopped (see the stop order below).

This turns a memory-mapped DMA engine into a streaming one without changing
the XDMA IP's mode, so the existing host-to-card and card-to-host tests keep
working.

## 3. The DMA engine and its descriptor list

The driver gives the engine's card-to-host (C2H) channel a **circular list of
descriptors** in host memory (`PICOEVB_IOC_C2H_STREAM_START`):

- Each descriptor copies a stretch of the FPGA ring (source, starting at RAM
  offset 0 and wrapping at the ring size) to a stretch of a pinned GPU buffer
  (destination, a bus address inside the GPU's BAR1).
- Descriptors are split wherever the ring wraps and wherever the GPU buffer's
  DMA mapping is not contiguous (GPU pages are 64 KiB; contiguous pages are
  merged). For 2 MiB CPI buffers and a 1 MiB ring this gives two descriptors
  per CPI.
- The last descriptor points back to the first, so the engine runs until it
  is told to stop. No interrupts are used.
- The total size of the GPU buffers must be a multiple of the ring size, so
  the source addresses line up on every lap.

Progress is the engine's **completed descriptor count**. It resets when the
engine starts; the driver also records a base count at start and reports
counts relative to it (`PICOEVB_IOC_C2H_STREAM_STATUS`). Buffer `b` of lap
`k` is complete when the count reaches `k * n_descs + last_desc[b] + 1`.

The host does **no work per transfer**. That is what moved the lossless limit
from 150 MS/s to the link's 375 MS/s: the earlier scheme issued one ioctl per
256 KiB region (~40 us each, with occasional ~1 ms outliers), which the
0.7 ms ring could not absorb.

## 4. PCIe and GPUDirect RDMA

The destination addresses are GPU memory exposed through the GPU's BAR1:

- The driver pins the CUDA allocation with `nvidia_p2p_get_pages()` and maps it
  for the FPGA with `nvidia_p2p_dma_map_pages()`, which returns one bus
  address per 64 KiB GPU page.
- The FPGA's writes are ordinary PCIe memory writes addressed to the GPU's
  BAR, routed peer-to-peer by the CPU's root complex. They never enter host
  memory.
- BAR1 must be large enough for everything pinned at once. Without Resizable
  BAR the A5000's BAR1 is 256 MiB; with it, 32 GB.
- The IOMMU must be off or in pass-through (`iommu=pt`).
- Only **writes** are used. This Z690 root complex, like many desktop ones,
  does not route peer-to-peer reads: the FPGA reading GPU memory fails with
  Unsupported Request or hangs the engine. A receive-only radar ingest needs
  only writes.

Gen2 x4 is 2 GB/s of raw bandwidth; after TLP overhead, 1.50 GB/s of payload
is sustained.

## 5. The driver (`kernel-module/picoevb-rdma.c`)

Responsibilities in the streaming path:

- **Pin/unpin** (`PICOEVB_IOC_PIN_CUDA`, `..._UNPIN_CUDA`): `nvidia_p2p_get_pages`
  with a free callback. Unpinning a buffer that a stream uses returns `EBUSY`.
- **Stream start/status/stop** (ioctls 7, 8, 9): map each buffer, build the
  descriptor list in coherent host memory, program the engine and set Run.
  One stream per device; single-transfer ioctls return `EBUSY` while it runs.
- **Lifetime safety:** the stream is stopped if its owning process closes the
  device or dies, and if the GPU memory is freed while pinned (NVIDIA's free
  callback). In that case the revoked buffer's mapping is released with
  `nvidia_p2p_free_dma_mapping` rather than unmapped. The engine is halted and
  its idle state confirmed before any mapping is released.
- **License constraint:** the driver uses no GPL-only kernel symbols, so it
  also loads against NVIDIA's proprietary modules on Linux 5.13+. This is why
  it uses `miscdevice` rather than `class_create`, its own timing helper
  rather than `ktime_get`, and so on.

## 6. The real-time host loop (`radar-bench stream`)

The host's job is to notice each completed CPI and hand it to the GPU:

```
for each CPI i (buffer b = i mod ring):
    if the GPU is still reading buffer b and the DMA has moved past CPI i-1:
        count an overrun (the DMA is overwriting data still being processed)
    wait for GPU work on buffer b from i-ring to finish, then score it
    poll the completed-descriptor count until CPI i is complete (20 us sleeps)
    enqueue CPI i's processing on CUDA stream b; record "consumed" and "done" events
```

Design points:

- **No flow control from GPU to DMA.** The DMA never waits, like a real
  receiver. If the GPU or host falls a whole ring behind, the loop detects
  and counts the overwritten CPIs. Ring depth is the stall tolerance:
  8 x 1.4 ms buffers ride out ~10 ms host stalls.
- **Real-time scheduling:** `SCHED_FIFO` on one CPU, but polling with short
  sleeps. A spinning real-time thread is throttled by the kernel for ~50 ms per
  second, which overran the 3-buffer ring every second until it was fixed.
- **Thread inheritance:** CUDA's host-callback thread and the telemetry thread
  are created before the loop becomes real-time; otherwise they inherit
  `SCHED_FIFO` on the same CPU and starve.
- **Scoring against truth:** every CPI's detections are matched against the
  targets the generator was programmed with *when that CPI was generated*.
  With moving targets (`--move`), the generator's registers change at CPI
  boundaries, and the two CPIs after a change are not scored (the change can
  land part-way through the next CPI).

## 7. The GPU pipeline (`process_cpi` in `radar-bench.cu`)

One CPI is M pulses of N range samples (default 4096 x 128 = 2 MiB of int16
IQ, 1.40 ms of data at 375 MS/s). Each ring slot has its own CUDA stream, cuFFT
plans and scratch buffers, so consecutive CPIs overlap.

| Step | Kernel / library | Notes |
| ---- | ---------------- | ----- |
| Convert | `k_convert` | int16 IQ to complex float |
| Pulse compression | cuFFT N-point, `k_matched`, inverse cuFFT | multiply by the conjugate spectrum of the Hamming-tapered 512-sample LFM chirp |
| Corner turn | `k_corner` | pulse-major to range-major, through shared memory, with a Hamming Doppler window |
| Doppler FFT | cuFFT M-point per range bin | |
| Detection | `k_power_cfar` (fused) | power and cell-averaging CFAR along range in shared memory (guard 2, train 16 each side, Pfa 1e-6), local-peak test, atomic append to a detection list |
| Output | async copy | detection count and list to pinned host memory |

The pipeline alone sustains ~6.5 GS/s on an A5000, so at 375 MS/s it is busy
about 6% of the time. Processing gain is about 48 dB: target echoes 6 dB below
the noise in the raw samples come out 27-37 dB above it.

## 8. Telemetry and dashboard (`radar-bench/dashboard/`)

About 15 times a second, the loop enqueues extra work on one CPI's stream:
a kernel (`k_thumb`) that max-pools the range-Doppler power map to 512 x M,
copies of that thumbnail and of 1,024 raw IQ samples, and a host callback that
copies the detection list. A normal-priority thread turns that into one JSON
line and sends it over TCP to `server.py`, which serves `index.html` and the
latest frame to browsers by long polling. If the sender is still busy, the
loop skips the frame; it never waits.

## Why not stage through host memory?

Measured on the same rig (see [results](results.md)): at 1.4 GB/s staging is
only slightly worse (it needs ~4x the host CPU and adds latency). But staging
moves every byte through host DRAM twice, so it is capped at half the host's
memory bandwidth: ~7.1 GB/s on this single-channel DDR4 host, where the
direct path ran to ~22.8 GB/s (the GPU's processing limit) in emulation.
GPUDirect RDMA's advantage grows with the data rate, which is exactly where
radar is heading (see the [RFSoC sizing](radar-context.md#scaling-to-an-rfsoc-front-end)).

## Start and stop sequences

Start:
1. Pin the CPI buffers (whole buffers, one handle each).
2. Program the generator (`gen_setup`); clear `READ_WORDS`.
3. Write `CONTROL = enable | full-rate? | paced`. The rising edge of enable
   zeroes the counters and starts generation; the gate is now active.
4. `C2H_STREAM_START` with the buffers and the ring size. The generator runs
   ahead by up to one ring meanwhile, which the gate releases as soon as the
   engine starts.

Stop:
1. `C2H_STREAM_STOP` while the generator still runs, so the engine's current
   descriptor completes with real data and the engine goes idle.
2. Clear `CONTROL`.

Reversing the stop order makes the gate pass reads freely while the engine is
still running, and it sweeps stale RAM through the GPU buffers.
