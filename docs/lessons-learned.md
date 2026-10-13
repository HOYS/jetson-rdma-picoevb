# Lessons learned

Problems hit while building this, with the symptom, the actual cause, how it
was established, and the fix. Dead ends are included: they are often the
most useful part. Grouped by area, roughly in the order they were met.

## Method

- **Don't conclude a platform limit from a plausible theory.** Early host
  hangs during peer-to-peer tests looked like an Alder Lake limitation. They
  were a Tesla K80 that wasn't fully seated: it passed link training, then
  dropped off the bus under load. Reseated, peer-to-peer writes worked. Later,
  a cold-boot link failure looked like "the FPGA configures too slowly", but a
  faster configuration clock didn't fix it; resetting the PCIe core did.
- **Read the registers before theorising.** Root-port `LnkSta` distinguished
  "training forever" (0x1801: Training bit set) from "no link attempt"
  (0x1001), and that pointed at the endpoint rather than the host.
- **Change one variable at a time, and keep a known-good fallback** (here, a
  warm reboot that always restored the link).

## GPU and driver

| Symptom | Cause | Fix |
| ------- | ----- | ---- |
| Module refused at load with NVIDIA's proprietary driver | Linux 5.13+ forbids a module using both proprietary-module symbols and GPL-only kernel symbols | Removed all GPL-only APIs from the driver (`class_create`, `idr`, `devm_*`, `ktime_get`...); build script now fails on any GPL-only import |
| modpost CRC mismatches for `nvidia_p2p_*` | Symvers generated in the wrong field format; CRC storage changed in Linux 5.19 | Rewrote `nvidia-ko-to-module-symvers`: decompresses modules, reads CRCs from absolute symbols or section data, matches the kernel's own `Module.symvers` format |
| "disagrees about version of symbol" one morning | Unattended kernel upgrade; DKMS rebuilt NVIDIA's modules, not ours | Rebuild and re-sign after kernel updates (consider packaging with DKMS) |
| "Key was rejected by service" | Secure Boot; unsigned rebuild | `kmodsign` with the enrolled MOK after every build |
| DMA from GPU memory to the FPGA fails or hangs the engine | Z690 root complex doesn't route peer-to-peer reads | Ingest needs only writes; added `rdma-cuda-c2h-verify`, a write-only verification |
| Large pins fail with `-ENOMEM` | BAR1 was 256 MiB without Resizable BAR | Enabled Resizable BAR (BAR1 = 32 GB) |
| Tesla K80 hangs and `RmInitAdapter failed` under load | Not fully seated; later unstable anyway | Replaced with an RTX A5000. After a hang, power-cycle from the PSU: the K80 kept its bad state through a warm reset |

## FPGA board (Acorn CLE-215+)

| Symptom | Cause | Fix |
| ------- | ----- | ---- |
| x4 build rejected lane constraints | The board routes M.2 lanes 0-3 to transceivers 2, 0, 1, 3; the XDMA IP's own constraints place lanes in order and override ordinary user constraints | `acorn-cle215-early.xdc` with `PROCESSING_ORDER EARLY` places the lanes; three critical warnings about overridden IP constraints are expected. Polarity swaps on some lanes need no constraint: PCIe receivers invert polarity automatically |
| Cold boot: board missing, or trained at x1 | The 5 MB bitstream loads ~115 ms after power-good, later than PCIe allows; the PCIe core then sometimes came out of reset unable to train (root port stuck in Training) | `pcie_link_watchdog.v`: on the configuration oscillator (CFGMCLK, independent of PCIe clocks), re-reset the PCIe core if the link is still down ~260 ms after PERST# releases. Cold boots now come up x4 after a few resets |
| Faster configuration (90 MHz EMCCLK instead of ~33 MHz) | Cut load time from ~313 ms to ~115 ms | Necessary but not sufficient on its own |
| Diagnostic LED tied to the PCIe reference clock via `IBUFDS_GTE2.ODIV2` -> BUFG | Made the reference clock net unroutable | Blink from the PCIe core's user clock instead (proves reference clock + PLL lock) |
| After hot-removing the device or reflashing, the link stays down | The slot's PERST# remained asserted; this board's ACPI gives the OS no power/reset methods for the slot | A warm reboot always recovers (the FPGA keeps its configuration). A kernel module to retrain the root port (Retrain Link, Link Disable toggle, secondary bus reset) did not help and was removed |
| JTAG hot-swap at 2.5 GT/s left BARs reading 0xffffffff | Not fully diagnosed | Warm reboot after JTAG loading; don't rely on hot-swap for testing |

## Streaming and real time

| Symptom | Cause | Fix |
| ------- | ----- | ---- |
| Losses above 150 MS/s with host-issued DMAs | ~40 us fixed cost per ioctl plus occasional ~1 ms DMAs, against ~1 ms of FPGA buffering | Circular descriptor list plus an FPGA pacing gate: no per-transfer host work. Lossless to 375 MS/s |
| Real-time loop livelocked at start | CUDA's host-callback thread, created lazily after the loop switched to `SCHED_FIFO`, inherited real-time priority on the same CPU | Launch a dummy host function before switching to real time, so the callback thread is created at normal priority |
| ~125 CPIs overwritten about 1 s into every run | Real-time throttling: a `SCHED_FIFO` thread busy-polling at 100% CPU is stopped ~50 ms per second (`sched_rt_runtime_us` = 950000) | Poll the completion count with 20 us sleeps |
| Overrun detector fired with the GPU idle | Checked an event recorded after a host callback; host callbacks run on a separate thread with its own latency | Separate event recorded right after the GPU kernels |
| Suspected stale completion counts | Hypothesis: XDMA's completed-descriptor count doesn't reset on Run | Measured: it does reset. The driver reports counts relative to a base read at start anyway |
| Reported throughput wrong on a 60 s run | 32-bit word counter wrapped between reads | Read it every CPI |
| A few CPIs overwritten per 47 minutes (12 in 2 M) | Host stalls longer than 3 CPI buffers (~2.8 ms of slack) | `--ring 8` (~10 ms of slack): 0 in 2 M |
| Overflow counts in the hundreds of millions just above the link limit (380 MS/s) | Once the DMA falls a whole ring behind it never catches up, so nearly every later word counts as lost | Expected behaviour, not a bug: treat any nonzero overflow as failure. The limit is ~1.50 GB/s |

## Tooling and environment

| Symptom | Cause | Fix |
| ------- | ----- | ---- |
| SSH session killed by its own `pkill` | `pkill -f pattern` matched the remote shell's command line | Bracket patterns: `pkill -f "[r]adar-bench stream"` |
| Unrelated packages removed | `apt autoremove` after removing an old driver | Always dry-run (`apt -s autoremove`) |
| Generated code corrupted (`\n` became a newline; `1'b0` mangled) | Shell heredoc and quoting | Write patch scripts as files; use an editor tool for small edits |
| `setpci` writes and `dynamic_debug` don't work | Kernel lockdown under Secure Boot | Build diagnostics into the driver and FPGA: status registers, counters, temporary `dev_info` |
| Dashboard showed 1-2 frames in 30 s in headless Chrome | Headless `--screenshot` mode freezes the page after load (not the server) | Drive Chrome over the DevTools protocol for checks; long-polling instead of Server-Sent Events also avoids proxies and filters that buffer streams |
| Host-staged path capped at ~7.1 GB/s (emulated) | One DDR4-2133 DIMM: ~15.5 GB/s of memory bandwidth, and staging uses it twice | Inherent to staging; GPUDirect RDMA avoids it |
