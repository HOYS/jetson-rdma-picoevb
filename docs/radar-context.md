# Radar context and sizing

What the GPU pipeline computes, how sample rate and CPI shape translate into
radar performance and data rates, and how the architecture scales to a real
RF front end. Formulas are given so the numbers can be recomputed for other
parameters.

## Pulse-Doppler processing in one page

A pulse-Doppler radar transmits a train of pulses and records the echoes
after each one. One **CPI** (coherent processing interval) is M pulses of N
complex samples each, stored as an N x M matrix (fast time = range, slow time
= pulse number).

1. **Pulse compression (range).** Each pulse is a chirp of L samples
   (linear frequency modulation). Correlating each received pulse with the
   chirp (multiply by its conjugate spectrum in the frequency domain) squeezes
   each echo into a sharp peak at its delay, gaining ~L in SNR (the
   time-bandwidth product). A Hamming taper on the reference chirp lowers the
   range sidelobes at a small cost in gain and resolution.
2. **Corner turn.** Transpose so each range bin's M samples (one per pulse)
   are contiguous. A Hamming window across pulses lowers Doppler sidelobes.
3. **Doppler processing.** An M-point FFT across pulses for each range bin
   separates targets by radial velocity: a moving target's echo rotates in
   phase from pulse to pulse, and the FFT integrates its M echoes coherently
   (~M in SNR).
4. **Detection (CFAR).** Constant false alarm rate detection compares each
   cell's power with the average of training cells around it (excluding guard
   cells) times a threshold factor chosen for the desired false-alarm
   probability. Cell-averaging CFAR along range:
   `alpha = 2T (Pfa^(-1/(2T)) - 1)` for T training cells each side.

The output is a list of detections: (range bin, Doppler bin, power, local
noise estimate).

## The parameters used here

| Parameter | Value | Meaning |
| --------- | ----- | ------- |
| fs | 375 MS/s complex | Sample rate (link-limited) |
| N | 4096 | Range samples per pulse |
| M | 128 | Pulses per CPI |
| L | 512 | Chirp length (samples) |
| CPI | N x M = 524,288 samples = 2 MiB = 1.40 ms | |
| CFAR | guard 2, train 16 each side, Pfa 1e-6 | |
| Targets | amplitude 150 and 60 counts, Doppler bins +17 and -7 | |
| Noise | sigma 300 counts per component | |

The generator sends pulses back to back (no transmit gap), so the pulse
repetition interval is N / fs.

## Sizing formulas

With c = 3e8 m/s and carrier wavelength lambda:

| Quantity | Formula | At fs = 375 MS/s, N = 4096, M = 128 |
| -------- | ------- | ----------------------------------- |
| Range bin | c / (2 fs) | 0.40 m |
| Range coverage | (N - L + 1) x range bin | 3,585 bins = 1.43 km |
| Pulse repetition frequency | fs / N (back-to-back pulses) | 91.6 kHz |
| Doppler bin | PRF / M | 715 Hz |
| Velocity per Doppler bin | (lambda / 2) x PRF / M | 10.7 m/s at X-band (10 GHz) |
| Unambiguous velocity | +/- (lambda / 4) x PRF | +/- 687 m/s at X-band |
| Data rate | fs x 4 bytes x channels x duty cycle | 1.50 GB/s |
| Processing gain | ~10 log10(L x M), less window losses | ~48 dB |
| GPU load | data rate / pipeline throughput (~6.5 GS/s) | ~6% |

Observed processing gain: target echoes at half the noise sigma in the raw
samples (invisible on the dashboard's IQ plot) come out 27-37 dB above the
local noise estimate.

### The waveform trade-off

Range coverage, range resolution and unambiguous velocity pull against each
other through fs and N:

| fs | Range bin | Coverage (N = 4096) | PRF | Unambiguous velocity, X-band | S-band (3 GHz) |
| -- | --------- | ------------------- | --- | ---------------------------- | -------------- |
| 375 MS/s | 0.4 m | 1.4 km | 91.6 kHz | +/- 687 m/s | +/- 2,290 m/s |
| 25 MS/s | 6 m | ~24 km | 6.1 kHz | +/- 46 m/s | +/- 153 m/s |

A realistic air-surveillance waveform therefore needs a deliberate choice:
lower carrier frequency, longer N, a medium-PRF design with ambiguity
resolution across several CPIs, or a dead time between pulses (which lowers
the duty cycle and data rate).

### CFAR calibration (open)

The textbook threshold assumes independent noise in the training cells. The
range and Doppler windows correlate neighbouring cells, so false alarms run
above the design rate. With ~457,000 cells per CPI, Pfa 1e-6 predicts ~0.46
false alarms per CPI; the pipeline reports ~3.3 "other" detections per CPI,
which also includes range sidelobes of the two targets. Calibrating alpha
empirically from target-free CPIs is an open item.

## Scaling to an RFSoC front end

The planned next step replaces the IQ generator with a Xilinx RFSoC
digitizing real RF. Scenario analysed: **3 channels at the full 5 GS/s**,
receiving during **20-50% of each pulse repetition interval**, over **PCIe
Gen4 x8** or **100 GbE RoCEv2**.

Each channel at 5 GS/s produces 10 GB/s while receiving (real int16 at
5 GS/s, or the RFSoC's digital downconverter in complex mode at decimation 2,
2.5 GS/s complex: the same bytes). Three channels burst at **30 GB/s**; the
duty cycle sets the average:

| Duty cycle | Average (3 ch) | PCIe Gen4 x8 (~12.5 GB/s usable) | 100 GbE RoCE (~11.5 GB/s usable) |
| ---------- | -------------- | -------------------------------- | -------------------------------- |
| 20% | 6 GB/s | fits | fits |
| 30% | 9 GB/s | fits | fits |
| 40% | 12 GB/s | at the limit | over |
| 50% | 15 GB/s | over by ~20% | over by ~30% |

Usable link rates assume the ~85% DMA efficiency measured on Gen2 here, and
Ethernet/IP/UDP/RoCE header overhead at a 4 KB MTU.

**Burst buffering.** The link carries the average; the FPGA absorbs the
burst excess, (30 - 12.5) = 17.5 GB/s, for the duration of the receive window:

- Short receive windows (high PRF): 50 us needs ~0.9 MB, 200 us ~3.5 MB. That
  fits in on-chip block RAM and UltraRAM, the same idea as the 1 MiB ring here.
- Long windows (low PRF): 1 ms at 50% needs ~17 MB, so FPGA-attached DDR4.
  There, write bandwidth (17.5 GB/s is about the practical limit of one 64-bit
  DDR4-2400 interface) becomes the constraint before capacity does.

**Making 50% fit:**
1. Pack samples to 12 bits (the ADC is 14-bit): 15 -> 11.3 GB/s, fits Gen4 x8.
   14-bit packing loses nothing: 13.1 GB/s, marginal.
2. Use both links: two channels on PCIe and one on 100 GbE, ~24 GB/s capacity.
3. Send only the range gates that are processed.
4. Avoid 8-bit IQ: the dynamic range loss is too costly for radar.

**GPU load.** In complex samples the average is 1.5 GS/s (20%) to 3.75 GS/s
(50%). The A5000 pipeline sustains ~6.5 GS/s on 4096 x 128 CPIs but ~5 GS/s with
64K-point pulses, and a 50 us window at 2.5 GS/s is 125,000 samples per
pulse. So 20-35% is comfortable on one A5000; 50% leaves little room for
beamforming or clutter filtering, so plan a second or larger GPU.

**Platform.** The test desktop's CPU has 16 general-purpose PCIe lanes, so
an RFSoC card or NIC plus the GPU would split to x8/x8 (capping GPU ingest
around 13 GB/s). Use a workstation or server platform with x16 slots for both,
or put the NIC and GPU under one PCIe switch, the topology NVIDIA recommends
for GPUDirect RDMA.

### What changes with real RF

- **Timing becomes the hard problem:** transmit pulse, receive window, T/R
  switching and timestamps locked to one clock (multi-tile sync, SYSREF, a
  PPS/GPS-disciplined time reference for VITA 49.2 picosecond timestamps).
- **The DMA can't pause the source**, which this design already models: the
  generator never waits, and losses are counted.
- **Real signals need calibration and clutter handling:** channel gain/phase
  calibration, MTI or clutter filtering, CFAR tuning, and multi-channel
  digital beamforming on the GPU.
- **Transmitting needs a licence or a test range.** Cabled loopback (DAC
  through attenuators or a delay line into the ADC), or passive radar using a
  broadcast transmitter, avoid radiating. The IQ generator remains useful as a
  built-in test and target-injection mode.
