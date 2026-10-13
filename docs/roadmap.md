# Roadmap: where this leaves off

The FPGA to GPU streaming architecture is proven at the reference board's
link limit. This document lists what is unfinished, and the two directions
planned next: making the rig a standards-conformant sensor and skill (AMS GRA
RF MEL), and replacing the IQ generator with a real RF front end (RFSoC).

## Open items in this repository

| Item | Why it matters | Notes |
| ---- | -------------- | ----- |
| Calibrate the CFAR threshold | False alarms run above the design Pfa (window-correlated training cells) | Measure the noise distribution on target-free CPIs (`--noise` with target amplitudes 0) and fit alpha per Pfa |
| Package the driver with DKMS, with signing | Every kernel update currently needs a manual rebuild and `kmodsign` | DKMS can sign with the MOK automatically |
| Default `--ring` to 8 in `stream` mode | 3 buffers overwrote a CPI every few minutes under host stalls | Costs 10 MiB more GPU memory |
| Descriptor prefetch (`nxt_adj`) | Descriptors are fetched one at a time; fine at 1 MiB descriptors, may matter with small ones | Adjacent descriptors must not cross a 4 KiB boundary |
| Engine write-back of progress | The host polls an MMIO register (~1-2 us per poll) | XDMA can write its completed count to host memory |
| Hot-remove / reflash leaves the slot in reset | Needs a warm reboot | Platform firmware behaviour; no OS-side fix found |
| Commit history | All work is currently uncommitted on `master` | Commit on a feature branch before further changes |

## Direction 1: AMS GRA RF MEL integration

The Agile Mission Suite Government Reference Architecture (AMS GRA) splits a
mission system into **sensors**, which expose RF hardware through the RF MEL
C++ API (a `librf_mel.so` loaded through a factory/registry), and **skills**,
which consume sensor data and publish UCI messages. Its starter kit adds an
environment simulator (Supercell: an ownship and two bandit aircraft over
Kitty Hawk, NC) and a 3D viewer (Worldview).

Repositories (all public, Apache 2.0, under
[github.com/open-arsenal](https://github.com/open-arsenal)):

| Repository | Role |
| ---------- | ---- |
| `ams-gra-hello-world-sk-interfaces-rf-mel` | RF MEL API headers (C++20, header-only) |
| `ams-gra-hello-world-sk-interfaces-common-mel` | Common MEL base (`RequestFor`, versioning) |
| `ams-gra-hello-world-sk-libraries-ams-vita` | AMS VITA 49.2 packet views, builders, fixed-size storage |
| `ams-gra-hello-world-sk-libraries-ams-math` | Math support library |
| `ams-gra-hello-world-sk-sensors-squall` | Reference sensor backend (simulated RF, RTL-SDR/HackRF) |
| `ams-gra-hello-world-sk-skills-rf-fm-demod` | Reference RF skill: `ComplexINT16` in via `ProductRxEndpoint`, UCI `SignalReport` out |
| `ams-gra-hello-world-sk-getting-started` | Starter kit: podman-compose deployment, Supercell, Worldview |

### Why it fits

`DataMEL::createProductRxEndpoint(JobDataFormat, regionSizeBytes,
regionAddress)` explicitly allows `regionAddress` to be GPU memory from
`cudaMalloc`, with RDMA as the transport, and `JobDataFormat::ComplexINT16`
is exactly this pipeline's sample format. The RF MEL boundary falls where the
PCIe link meets GPU memory today.

### API mapping

| RF MEL | This repository |
| ------ | --------------- |
| `DataMEL::createProductRxEndpoint(ComplexINT16, size, gpuPtr)` | `PICOEVB_IOC_PIN_CUDA` on the skill's buffer, then `C2H_STREAM_START` |
| `ProductRxEndpoint::setDataReadyCallback(cb)` | The real-time loop's per-CPI completion (descriptor count reaching `end(i)`) |
| Callback arguments: metadata, `MELComplex<int16_t>*`, element count | CPI buffer pointer and N x M |
| `ProductRxMetadata`: job/interval IDs, receive events, first receive time (UTC), stream IDs | CPI index, generator word count; real timestamps need a time reference |
| `RDMAMemoryRegionParams` | Pinned buffer address/size (the BAR1 mapping stays inside the driver) |
| `C2MEL` job request (waveform, chirp, intervals) | `gen_setup`: rate, N (`LOG2N`), chirp, targets |
| `JobDataFormat::AMSVitaExtraLarge` (32 KiB VITA 49.2 packets) | Not yet: would need an FPGA packetizer |
| `RDMAExternalEndpointParams` (MAC, subnet, queue pair, remote key) | RoCE path for an RFSoC over 100 GbE (Direction 2) |

### Steps

1. **Acorn + GPU as an RF MEL sensor.** Implement `DataMEL` and `C2MEL` over
   the `picoevb-rdma` driver as `librf_mel.so`, shaped after Squall. Any AMS
   GRA RF skill could then receive IQ from this hardware.
2. **The radar pipeline as an RF MEL skill.** Wrap `process_cpi` behind a
   `ProductRxEndpoint` callback and publish detections as UCI messages over
   OMS, modelled on `rf-fm-demod`, so they appear in Worldview.
3. **Scenario-driven targets.** Convert the bandits' range and radial velocity
   relative to the ownship (from Supercell) into the generator's `T*_DELAY`,
   `T*_DINC` and `T*_AMP` registers, making the FPGA a hardware-in-the-loop
   radar target simulator. The per-CPI truth tracking in `radar-bench` already
   handles targets that move during a run.
4. **VITA 49.2 framing in the FPGA (optional).** Base Set signal data packets:
   stream ID, picosecond timestamp of the first sample, trailer with the
   sample-loss indicator. 32 KiB packets carry 8,184 IQ samples (0.1%
   overhead); payload format `0x200003CF` is complex int16.

To settle first: the waveform. Scenario geometry needs kilometres of range
and jet-speed Dopplers; see the
[waveform trade-off](radar-context.md#the-waveform-trade-off).

## Direction 2: RFSoC front end

Replace the generator with an RFSoC digitizing real RF: 3 channels at 5 GS/s,
receiving 20-50% of each pulse repetition interval, over PCIe Gen4 x8 or
100 GbE RoCEv2. The full sizing is in
[radar-context.md](radar-context.md#scaling-to-an-rfsoc-front-end). In short:

- 20-35% duty fits either link as 16-bit samples; 50% needs 12-bit packing or
  both links.
- The FPGA must buffer the 30 GB/s burst during each receive window: on-chip
  RAM for short windows, FPGA DDR4 (bandwidth-limited) for long ones.
- One A5000 handles 20-35% comfortably; 50% needs more GPU.
- A workstation or server platform is needed for enough CPU PCIe lanes, with
  the NIC and GPU under one switch for the RoCE path.

What carries over unchanged: the GPU pipeline, the CPI buffer ring and
real-time loop, the never-wait/count-losses flow control, the telemetry and
dashboard, and the RF MEL plan. What is replaced: the source (ADC + DDC
instead of the generator, which stays as a test mode), the DMA engine (QDMA
streaming queues, or RoCE through `nvidia-peermem`), and the timing system
(pulse sequencer, multi-tile sync, a disciplined time reference).
