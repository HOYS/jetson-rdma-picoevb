# AGENTS.md

Orientation for AI coding agents (and humans) picking up this repository.
Read this first, then [docs/README.md](docs/README.md).

## What this repository is

NVIDIA's `jetson-rdma-picoevb` sample, a minimal demonstration of **GPUDirect
RDMA** (a PCIe device reading and writing CUDA memory directly), extended into
a working **real-time radar ingest and processing chain**:

```
FPGA IQ generator -> FPGA RAM ring -> DMA pacing gate -> XDMA engine
   -> PCIe peer-to-peer write into GPU memory (no host RAM, no CPU copy)
   -> GPU pulse-Doppler pipeline (pulse compression, Doppler FFT, CFAR)
   -> detections -> scoring + live web dashboard
```

Measured on the reference rig: **375 MS/s of 16-bit IQ (1.50 GB/s, the PCIe
Gen2 x4 link's limit), lossless for 47 minutes, both targets detected in all
1,916,668 scored CPIs, ~0.14 ms from a CPI landing in GPU memory to its
detections.** See [docs/results.md](docs/results.md).

The original Jetson/PicoEVB/HTG-K800 support is still present and documented
in [README.md](README.md); the additions focus on a discrete GPU on an x86
PC and the SQRL Acorn CLE-215+ FPGA board.

## Reference hardware and software

| Item | Value |
| ---- | ----- |
| FPGA | SQRL Acorn CLE-215+ (Artix-7 XC7A200T-3FBG484, M.2), PCIe Gen2 x4, 1 MiB BRAM ring |
| GPU | NVIDIA RTX A5000 (Ampere, 24 GB), PCIe Gen4 x16, Resizable BAR (BAR1 = 32 GB) |
| Host | Intel Core i9-12900K, Z690, one DDR4-2133 DIMM, Ubuntu 24.04, kernel 6.8 |
| GPU driver | `nvidia-driver-595-open` (open kernel modules), CUDA 13.4 |
| Platform settings | Above 4G decoding, Resizable BAR, `iommu=pt`, Secure Boot on (MOK-signed modules) |
| FPGA tools | Vivado 2018.3 (WebPACK covers the XC7A200T), Xilinx Platform Cable USB II |

GeForce GPUs do not support GPUDirect RDMA; use RTX/Quadro or data center GPUs.

## Repository map

| Path | What it is |
| ---- | ---------- |
| `kernel-module/picoevb-rdma.c` | The driver: pins CUDA memory (`nvidia_p2p_*`), runs XDMA transfers, continuous C2H streaming (`PICOEVB_IOC_C2H_STREAM_*`), `mmap` of BAR0 |
| `kernel-module/picoevb-rdma-ioctl.h` | User/kernel ABI (ioctls 0-9) |
| `kernel-module/build-for-pc-native.sh` | Builds against the running NVIDIA driver; fails if GPL-only symbols are imported |
| `kernel-module/nvidia-ko-to-module-symvers` | Extracts `nvidia_p2p_*` CRCs from `nvidia.ko` for modpost |
| `fpga-acorn-cle215/` | Acorn FPGA design: `top.v`, `iq_gen.v` (generator + DMA pacing gate + AXI-Lite splitter), `pcie_link_watchdog.v`, constraints, build/flash scripts, prebuilt `acorn-cle215.mcs.bz2` |
| `radar-bench/radar-bench.cu` | GPU radar pipeline and all benchmarks (`verify`, `gpu`, `fpga`, `ingest`, `emulate`, `stream`) |
| `radar-bench/dashboard/` | Live web dashboard: `server.py` (stdlib), `index.html`, `start.sh` |
| `client-applications/` | Original GPUDirect tests, plus `rdma-cuda-c2h-verify` (write-only check for platforms without peer-to-peer reads) |
| `gpu-p2p-selftest/` | Kernel module that checks the GPU side of GPUDirect RDMA before an FPGA is installed |
| `fpga-picoevb/`, `fpga-htg-k800/` | Original NVIDIA FPGA designs (unchanged) |
| `docs/` | Architecture, bring-up guide, radar context, results, lessons learned, roadmap |

## Build, load, verify

```bash
# Driver (rebuild + re-sign after every kernel update)
cd kernel-module && ./build-for-pc-native.sh
sudo kmodsign sha512 /var/lib/shim-signed/mok/MOK.priv /var/lib/shim-signed/mok/MOK.der picoevb-rdma.ko
sudo insmod picoevb-rdma.ko

# Radar pipeline and benchmarks
cd radar-bench && make

# Verification ladder, cheapest first
sudo ./gpu-p2p-selftest/run-selftest.sh 0000:02:00.0       # GPU side only, no DMA
sudo ./client-applications/rdma-cuda-c2h-verify            # FPGA writes GPU memory, checked word by word
sudo ./radar-bench/radar-bench stream --N 4096 --M 128 --L 512 --rate-msps 50 --gen-check   # bit-exact vs model
sudo ./radar-bench/radar-bench stream --N 4096 --M 128 --L 512 --rate-msps 375 --ring 8 --cpis 43000  # real-time soak

# Live dashboard (then open http://<host>:8080/)
radar-bench/dashboard/start.sh --rate-msps 375 --move 60 --ring 8 --cpis 2000000
```

FPGA build and flash (`fpga-acorn-cle215/`): `./git-to-project.sh`,
`./synthesize-fpga.sh`, `./generate-cfgmem.sh`, `./program-fpga.sh`. The x4
build emits three expected critical warnings (lane placement overridden by
`acorn-cle215-early.xdc`). Confirm timing is met (WNS >= 0) after each build.

## Invariants: do not break these

1. **No GPL-only kernel symbols in the driver.** Built against NVIDIA's
   proprietary modules, Linux 5.13+ refuses a module importing both
   `nvidia_p2p_*` and `EXPORT_SYMBOL_GPL` symbols. `build-for-pc-native.sh`
   checks this; keep the check passing even though the open modules don't need it.
2. **The FPGA only writes GPU memory (C2H).** Desktop root complexes, this one
   included, route peer-to-peer writes but not reads. Anything that has the
   FPGA read GPU memory (H2C from a CUDA buffer) fails or hangs the DMA engine.
3. **Stream start order:** program the generator, set `CONTROL = enable |
   paced` (enable's rising edge zeroes the counters), *then*
   `C2H_STREAM_START`. Descriptor sources start at FPGA RAM offset 0, and the
   GPU buffers' total size must be a multiple of the FPGA ring size.
4. **Stream stop order:** `C2H_STREAM_STOP` *while the generator is still
   running*, then clear `CONTROL`. The gate passes reads freely once the
   generator stops, and a still-running engine would sweep stale RAM into the
   GPU buffers.
5. **The pacing gate compares against `write_words` delayed 3 cycles**
   (`iq_gen.v`): the RAM writes a word one edge after it is counted. Removing
   the delay lets a granted read see stale data.
6. **Completion is the engine's completed-descriptor count**, which the driver
   reports relative to stream start. A CPI is in GPU memory when the count
   reaches `lap * n_descs + last_desc[b] + 1`.
7. **The real-time loop must not spin.** `SCHED_FIFO` threads that use >95% of a
   CPU are frozen ~50 ms every second (`sched_rt_runtime_us`). Poll with short
   sleeps (20 us). Create helper threads (CUDA's callback thread, telemetry)
   *before* switching to `SCHED_FIFO`, or they inherit it and starve.
8. **Ring depth sets stall tolerance.** The DMA never waits for the GPU; with 3
   CPI buffers (~4 ms at 375 MS/s) a host stall occasionally overwrote a buffer
   before processing (12 in 47 min). `--ring 8` gave 0.
9. **Nothing in the streaming loop may block on telemetry.** The dashboard
   path drops frames rather than wait.

## Working on the reference host: gotchas

- Kernel **lockdown** (Secure Boot) blocks `setpci` writes, `dynamic_debug`, and
  `mmap` of `/sys/bus/pci/.../resource*`. The driver exposes BAR0 via its own
  `mmap`; use `dev_info` temporarily if you need kernel log output.
- After a **kernel update** the driver fails with "disagrees about version of
  symbol": rebuild and re-sign it. DKMS only rebuilds NVIDIA's modules.
- **Cold boot** works because of `pcie_link_watchdog.v`. After hot-removing the
  device or reflashing, the link may not come back on a rescan; a **warm
  reboot** always recovers it (the FPGA keeps its configuration).
- `pkill -f`/`pgrep -f` over SSH can match the SSH session's own command line
  and kill it. Use bracket patterns (`"[r]adar-bench stream"`).
- `apt autoremove` once removed unrelated packages. Dry-run first (`-s`).
- Shell heredocs mangled `\n` and Verilog `1'b0` in generated code. Write patch
  scripts to files instead of piping them through the shell.
- Headless Chrome's `--screenshot` mode freezes the page after load; to check
  the dashboard, drive Chrome over the DevTools protocol instead.

## How to work here

- **Verify before concluding a hardware limit.** Twice in this project a
  plausible "the platform can't do this" was wrong (an unseated GPU; a link
  that needed a reset, not a faster FPGA). Check registers, logs and error
  sources, change one variable at a time, and say what is proven vs inferred.
- **Measure, then claim.** Every number in `docs/results.md` came from a run;
  keep it that way, and record the command and conditions with any new result.
- **Keep the GPU pipeline honest.** `radar-bench verify` and `--gen-check`
  (bit-exact against a software model of the generator) are the regression
  tests. Run them after touching the pipeline, the generator, or the DMA path.

## Where things stand and what's next

Done and verified: everything in the pipeline above, cold boot, 47-minute
lossless soak at the link limit, live dashboard. Open items and the planned
direction (AMS GRA RF MEL integration, an RFSoC front end at 5 GS/s over PCIe
Gen4 x8 or 100 GbE RoCE) are in [docs/roadmap.md](docs/roadmap.md).
