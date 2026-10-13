# Introduction

This repository provides a minimal hardware-based demonstration of GPUDirect
RDMA. This feature allows a PCIe device to directly access CUDA memory, thus
allowing zero-copy sharing of data between CUDA and a PCIe device.

The code supports:
* NVIDIA Jetson AGX Xavier (Jetson) running Linux for Tegra (L4T).
* NVIDIA Drive AGX Xavier running Embedded Linux.
* A PC running the NVIDIA CUDA drivers and containing an NVIDIA RTX/Quadro or
  Tesla GPU; see [Discrete GPUs on a PC](#discrete-gpus-on-a-pc).

This fork extends the sample into a real-time radar ingest chain: an SQRL
Acorn CLE-215+ FPGA streams 16-bit IQ samples over PCIe directly into an RTX
A5000's memory, where a pulse-Doppler pipeline turns them into detections, at
375 MS/s (1.50 GB/s, the link's limit) with no samples lost. **Start with
[docs/README.md](docs/README.md)** for the architecture, a GPUDirect RDMA
bring-up guide, radar context, measured results, lessons learned and the
roadmap. AI agents: read [AGENTS.md](AGENTS.md) first.

A graphical representation of the system configuration created by the software
in this repository, and the data flow between components, is shown below:

![RDMA Configuration and Data Flow](rdma-flow.svg)

# PCIe Device

## Obtaining the Hardware

This project uses an FPGA as the PCIe device which accesses CUDA memory. The
following FPGA boards are supported:

* RHS Research PicoEVB.
* HiTech Global HTG-K800.
* SQRL Acorn CLE-215+ (also expected to work on the electrically identical
  RHS Research NiteFury).

The following sections detail how to obtain and program each board.

### RHS Research PicoEVB

#### FPGA Board

PicoEVB is an M.2 form-factor FPGA board which attaches to the host's PCIe
bus for application data transfer, and is programmed via the M.2 connector's
USB bus. It is available from:

* [picoevb.com](https://picoevb.com/).
* [Amazon](https://amazon.com/); search for ASIN "B0779PC8S4" or "PicoEVB".

#### PCIe Adapter Board

The PicoEVB board is a double-sided M.2 device. Jetson physically only supports
boards with a full-size PCIe connector, or single-sided M.2 devices. PCs
typically only support boards with a full-size PCIe connector. Some form of
adapter is required to connect the two in a mechanically reliable way.

A PCIe x16/x8/x4/x2/x1 to M.2 key E adapter may be used to plug the PicoEVB
board into a full-size PCIe slot on Jetson or a PC. One such adapter board may
be available from Amazon as ASIN B013U4401W, product name "Sourcingbay
M.2(NGFF) Wireless Card to PCI-e 1X Adapter".

The following pair of adapters may be used to connect the PicoEVB board to
Jetson's M.2 key E connector:

* M.2 2230 key E to Mini-PCIe adapter with cable. This may be available from
  Amazon as ASIN B07JFYSNVL, product name "M.2 (NGFF) Key A/E/A+E to Mini
  PCI-E Adapter with FFC Cable". Alternatively, this may be available from
  Amazon as ASIN B00JSBPF70, product name "Bplus: P15S-P15F, M.2 (NGFF) to
  mPCIe Extender Board".
* Mini-PCIe to M.2 2230 adapter board. This may be available from Amazon as
  ASIN B07D4FCD1K, product name "HLT M.2 (NGFF) to mPCIe (PCIe+USB) Adapter".

The following adapter may be used to connect the PicoEVB board to Drive AGX
Xavier's M.2 key M connector:

* M.2 KEY-M interface to M.2 KEY A-E or KEY E interface adapter. This may be
  available from AliExpress with product name as "M.2 Wifi Adapter M.2 M Key
  to A+E Key Slot Wifi Bluetooth Network Card NGFF NVMe PCI express SSD Port
  to E key Slot Wifi Adapter".

The set of available adapters and vendors is very variable over time. Some
searching may be required to locate suitable adapters, from either Amazon or
alternative websites.

### HiTech Global HTG-K800

#### FPGA Board

HTG-K800 is a full-size x16 PCIe card. This will fit directly into the full-
size PCIe connector on Jetson or a desktop PC. For more information, see:
http://www.hitechglobal.com/Boards/Kintex-UltraScale.htm

This project supports the XCKU-60 FPGA, although this should be easy to
change simply by changing the FPGA project properties and re-synthesizing the
provided Vivado project.

#### JTAG Programmer

You will need a Xilinx Platform Cable USB II to program the FPGA. For more
information, see:
https://www.xilinx.com/products/boards-and-kits/hw-usb-ii-g.html

### SQRL Acorn CLE-215+

#### FPGA Board

The Acorn CLE-215+ is an M.2 2280 key M form-factor board containing a Xilinx
Artix-7 XC7A200T-3FBG484 FPGA. It was sold as a cryptocurrency mining
accelerator, and is commonly available second-hand. It is the same PCB as the
RHS Research NiteFury; see
[NiteFury-and-LiteFury](https://github.com/RHSResearchLLC/NiteFury-and-LiteFury)
for schematics and the JTAG connector pinout.

The FPGA design in `fpga-acorn-cle215/` uses a PCIe Gen2 x4 link (128-bit
AXI at 125 MHz), the four on-board LEDs, the four FPGA I/Os on the P2 header,
and 1MiB of FPGA block RAM. The on-board DDR3 is not used. FPGA-to-GPU
transfers run at about 1.3-1.4 GB/s. The link also trains (at x1) in a
single-lane slot, since lane 0 is placed correctly.

The board routes the M.2 lanes to the FPGA's transceivers out of order (M.2
lanes 0-3 are MGTP channels 2, 0, 1, 3), which differs from the XDMA IP's
default lane placement. `acorn-cle215-early.xdc` places the lanes, and is
processed before the IP's own constraints so that it takes precedence; the
three resulting critical warnings from the IP's constraint file are expected.

The design identifies itself with PCI subsystem ID 0x0005, and includes an IQ
generator; see
[Real-time Streaming From the FPGA's IQ Generator](#real-time-streaming-from-the-fpgas-iq-generator).
The driver also supports the x4 design without the generator (subsystem
0x0004) and the earlier single-lane design with 64KiB of RAM (subsystem
0x0003).

At power-on the FPGA loads its 5 MB bitstream from flash (~115 ms, clocked by
the board's 90 MHz oscillator), which is later than PCIe allows. On a cold boot
the PCIe core then sometimes comes out of reset in a state from which it never
trains; the host's root port sits in Training, and the board doesn't
enumerate, while warm reboots work. `pcie_link_watchdog.v` fixes this. It runs
from the FPGA's internal configuration oscillator, and whenever PERST# is
deasserted but the link has been down for ~260 ms, it resets the PCIe core
again. The number of such resets since power-on is readable from the
generator's `LINK_RESETS` register (a cold boot typically needs a few;
`radar-bench stream` prints it).

While the link is down, the LEDs show diagnostics instead of the GPIO value:
LED 0 blinks if the PCIe core's clock is running (so the reference clock is
present and the transceiver PLL locked), LED 1 blinks from the configuration
oscillator, LED 2 is on while PERST# is deasserted, and LED 3 toggles on each
watchdog reset.

#### PCIe Adapter Board

Plug the Acorn into a motherboard M.2 key M slot that carries PCIe (not a
SATA-only slot), or use an M.2 key M to PCIe x4/x16 adapter card in a
full-size PCIe slot.

#### JTAG Programmer

Unlike PicoEVB, the Acorn cannot be programmed over the M.2 connector's USB
pins. A JTAG cable supported by Vivado is required, e.g. a Xilinx Platform
Cable USB II or Digilent JTAG-HS2/HS3, connected to the Acorn's JTAG header.
Alternatively, any cable exposed through a Xilinx Virtual Cable (XVC) server,
such as an FT2232H/FT232H board running xvcd, can be used.

## Obtaining FPGA Programming Software

### Xilinx Vivado Design Suite

This software must run on an x86 Linux PC.

Xilinx Vivado is used to compile the FPGA bitstream, and to program the
bitstream into the FPGA. The free "WebPACK Edition" is sufficient.
Obtain this software from [the Xilinx website](https://www.xilinx.com/).

The PicoEVB project requires Vivado 2018.3.

The HTG-K800 project requires Vivado 2018.1.

The Acorn CLE-215+ project requires Vivado 2018.3. The XC7A200T is supported by
the free WebPACK edition.

Newer versions of Vivado should be able to import these projects.

### xvcd

This software is only required for the PicoEVB board; the HTG-K800 board does
not need it. The Acorn CLE-215+ only needs it if you program it through an
FTDI-based JTAG adapter rather than a cable Vivado supports directly.

This software must run on the system that the PicoEVB FPGA card is plugged
into. This may be either an x86 Linux PC, or a Jetson system.

Note that Drive AGX Xavier's M.2 slot does support USB. Consequently, it is not
possible to program the FPGA when attached to this connector. The PicoEVB board
can be programmed on Linux PC or Jetson system instead, then connected to Drive
AGX Xavier once programmed.

Vivado relies upon a piece of software known as xvcd (Xilinx Virtual Cable
Daemon) to communicate with the PicoEVB board for programming purposes.
Obtain it from [github.com](https://github.com/RHSResearchLLC/xvcd). Execute
the commands below to download and compile the software:

```
sudo apt update
sudo apt install build-essential libftdi-dev
git clone https://github.com/RHSResearchLLC/xvcd.git
cd xvcd/
cd linux/src
make
```

## Generating the Bitstream

In the following text, `fpga-*/` refers to the FPGA project sub-directory. For
PicoEVB, this is `fpga-picoevb/`, for the HTG-K800, this is
`fpga-htg-k800/`, and for the Acorn CLE-215+, this is `fpga-acorn-cle215/`.

A pre-compiled bitstream is provided in this project; `fpga-*/*.mcs.bz2`. It is
not necessary to regenerate the bitstream. However, if you wish to do so,
follow these steps:

1. Open a shell prompt, and `cd` to the `fpga-*/` directory in this project.
2. Execute `./git-to-project.sh` to generate the Vivado project files. You may
   have to adjust the `vivado` variable in this script if the `vivado`
   executable is not in your `$PATH`, or the expected installation location.
3. Execute `./synthesize-fpga.sh` to synthesize and implement the FPGA. This
   will generate the FPGA bitstream. Alternatively, you may perform this step
   by opening `fpga-*/vivado-project/vivado-project.xpr` using the Vivado GUI,
   and requesting that it perform bitstream generation. Either way, this
   process will take from 5-60 minutes depending on the speed of your PC, and
   which FPGA project you're building.
4. Execute `./generate-cfgmem.sh` to generate the configuration memory image.

If you make modifications to the Vivado project, or any files or IP blocks it
contains or uses, and wish to commit those changes into source control, execute
`./project-to-git.sh` to regenerate the checked-in files `git-to-project.tcl`
and `git-to-ips.tcl`.

## Programming the FPGA

### RHS Research PicoEVB

Programming the FPGA requires Vivado installed on an x86 Linux PC, and xvcd
running on the system that contains the PicoEVB board.

If you run xvcd on Jetson, you must allow network connections from Vivado on
your x86 Linux PC to xvcd running on Jetson. The simplest way to do this is to
use `ssh`'s port-forwarding feature; on the x86 Linux PC, execute:

`ssh -L 2542:127.0.0.1:2542 ip_address_of_jetson`

To run xvcd, on the system containing the FPGA card, execute:

`sudo ./xvcd -P 0x6015`

On your x86 Linux PC, open a shell prompt, `cd` to the `fpga-*/` directory in
this project, and execute:

`program-fpga.sh`

The process of connecting Vivado's programming tools to the FPGA can be
unreliable. If the connection attempt fails, and the script exits without
programming the FPGA, you will need to execute the command again.

The programming process will take from 20 to 40 minutes. The programming
process generates no output for most of its operation, so may appear to have
hung, but is actually running.

### HiTech Global HTG-K800

Programming the FPGA requires Vivado installed on an x86 Linux PC with the
Xilinx platform cable attached.

On your x86 Linux PC, open a shell prompt, `cd` to the `fpga-*/` directory in
this project, and execute:

`program-fpga.sh`

The programming process will take a few minutes. The programming process
generates no output for most of its operation, so may appear to have hung,
but is actually running.

### SQRL Acorn CLE-215+

Programming the FPGA requires Vivado installed on an x86 Linux PC, with a JTAG
cable attached to the Acorn's JTAG header. The Acorn must be powered, i.e.
installed in a PC that is switched on. This may be the same PC that runs
Vivado.

Open a shell prompt, `cd` to `fpga-acorn-cle215/`, and execute:

`./program-fpga.sh`

To use an XVC server (e.g. xvcd driving an FTDI-based JTAG adapter) instead of
a locally attached cable, set `XVC_URL`, e.g.:

`XVC_URL=localhost:2542 ./program-fpga.sh`

The script writes the S25FL256S configuration flash, then reboots the FPGA
from it. Once programming completes, reboot the PC containing the Acorn so
that it enumerates the FPGA with the new design. The Acorn configures itself
from flash at power-on, so this only needs doing once.

# Linux Kernel Driver
## Note:
Please use rel-36+ branch for kernel 5.9+ version on Jetson. For PC (dGPU)
builds, this branch's driver supports newer kernels too.

## Building on Jetson/Drive AGX Xavier, to Run on Jetson/Drive AGX Xavier

To build the Linux kernel driver, execute:

```
sudo apt update
sudo apt install build-essential bc
cd /path/to/this/project/kernel-module/
./build-for-jetson-drive-igpu-native.sh
```

This will generate `picoevb-rdma.ko`.

## Building on an x86 Linux PC, to Run on Jetson/Drive AGX Xavier

The Linux kernel driver may alternatively be built (cross-compiled) on an x86
Linux PC. You will first need to obtain a copy of the "Linux headers" or
"kernel external module build tree" files from L4T; these may be found in
`/usr/src/` on Jetson/Drive AGX Xavier, or obtained from the L4T/Drive
downloads website.

To build the Linux kernel driver on a x86 Linux PC, execute:

```
sudo apt update
sudo apt install build-essential bc
cd /path/to/this/project/kernel-module/
# Adjust the KDIR value to match the exact path in your copy of the
# kernel headers
KDIR=/path/to/linux-headers-4.9.140-tegra-linux_x86_64/kernel-4.9/ ./build-for-jetson-drive-igpu-on-pc.sh
```

This will generate `picoevb-rdma.ko`. This file must be copied to Jetson/Drive
AGX Xavier.

## Building on an x86 Linux PC, to Run on That PC

```
sudo apt update
sudo apt install build-essential bc
cd /path/to/this/project/kernel-module/
./build-for-pc-native.sh
```

This will generate `picoevb-rdma.ko`. The NVIDIA driver must be installed and
loaded first; the script uses its `nv-p2p.h` (from `/usr/src/nvidia-*`) and
reads symbol versions from its `nvidia.ko`.

The NVIDIA dGPU driver is proprietary, and Linux 5.13 and later refuse to load
a module that uses both its symbols and GPL-only kernel symbols. The driver
avoids GPL-only kernel APIs for this reason, and the script fails with a list
of offending symbols if any are used.

## Loading the Module

To load the kernel module, execute:

```
sudo insmod ./picoevb-rdma.ko
```

Once the module is loaded, executing `lspci -v` should show that the module is
in use as the kernel driver for the FPGA board:

```
$ lspci -v
...
0003:01:00.0 Memory controller: NVIDIA Corporation Device 0001
	Subsystem: NVIDIA Corporation Device 0001
	Flags: bus master, fast devsel, latency 0, IRQ 36
	Memory at 34210000 (32-bit, non-prefetchable) [size=4K]
	Memory at 34200000 (32-bit, non-prefetchable) [size=64K]
	Capabilities: <access denied>
	Kernel driver in use: picoevb-rdma
```

The Acorn CLE-215+ shows `Subsystem: NVIDIA Corporation Device 0003`.

If the FPGA board does not appear in `lspci` at all, the FPGA was probably not
configured when the host enumerated PCIe; reboot the host, or execute
`echo 1 | sudo tee /sys/bus/pci/rescan`.

# User-space Applications

## Building on Jetson/Drive AGX Xavier, to Run on Jetson/Drive AGX Xavier

The client applications are best built on Jetson/Drive AGX Xavier itself. Make
sure you have the CUDA development tools installed, and execute:

```
sudo apt update
sudo apt install build-essential bc
cd /path/to/this/project/client-applications/
./build-for-jetson-drive-igpu-native.sh
```

## Building on an x86 Linux PC, to Run on Jetson/Drive AGX Xavier

Building (cross-compiling) the client applications on a x86 Linux PC is only
partially supported; the makefile does not yet support cross-compiling the CUDA
test application. However, the other applications may be cross-compiled by
executing:

```
sudo apt update
sudo apt install build-essential bc
cd /path/to/this/project/client-applications/
./build-for-jetson-drive-igpu-on-pc.sh
```

You may need to adjust the value of variable `CROSS_COMPILE` in script
`./build-for-jetson-drive-igpu-on-pc.sh` to match the configuration of your x86
Linux PC.

## Building on an x86 Linux PC, to Run on That PC

Make sure you have the CUDA development tools installed, and execute:

```
sudo apt update
sudo apt install build-essential bc
cd /path/to/this/project/client-applications/
./build-for-pc-native.sh
```

For a Tesla K80 (compute capability 3.7, which nvcc does not target by
default), execute `./build-for-pc-tesla-k80-native.sh` instead. This requires
CUDA 11.x; CUDA 12 dropped support for the K80. If nvcc rejects your host
compiler as too new, install gcc-10 (`sudo apt install g++-10`), which the
script then uses automatically.

## Running the Tests

### Data Access Tests

Two PCIe data access tests are provided; `rdma-malloc` and `rdma-cuda`. Both
tests are structurally identical, but allocate memory using different APIs; the
former using `malloc()`, and the latter via `cudaHostAlloc()` (Jetson/Drive AGX
Xavier) or `cudaMalloc()` (PC).

Both tests proceed as following:

1. Allocate source and destination memory.
2. In the CUDA case, prepare the memory for RDMA by calling
   `cuPointerSetAttribute(CU_POINTER_ATTRIBUTE_SYNC_MEMOPS)` and pinning it.
3. Fill the source surface with a known pattern.
4. Fill the destination surface with different values.
5. Use the FPGA to copy the source to the destination surface.
6. Validate that the data was correctly copied.

To run the tests, execute:

```
sudo ./rdma-malloc
sudo ./rdma-cuda
```

You can avoid the need to use `sudo` by applying appropriate permissions to the
kernel driver's device file, `/dev/picoevb`.

Internally to the kernel driver, the copy operation divides the surface into
64KiB chunks (or smaller, depending on memory alignment), and for each chunk
first copies that chunk's data from the source surface to the FPGA's internal
memory, then copies the data from the FPGA's internal memory to the destination
surface. This demonstrates both PCIe read and write access to CUDA GPU memory.
The requirement to divide the data into chunks is a limitation of the internal
memory size of the PicoEVB board's FPGA, and likely would not apply in a
production device.

Separate test applications exist to exercise the uni-directional copy feature
of the kernel driver, and to report transfer performance. Two versions of the
tests exist; one using `malloc()`'d memory on the host, and the other using
memory allocated via CUDA. To run these tests, execute:

```
sudo ./rdma-malloc-h2c-perf
sudo ./rdma-malloc-c2h-perf
sudo ./rdma-cuda-h2c-perf
sudo ./rdma-cuda-c2h-perf
```

### set-leds

This test sets the values of the three LEDs on the PicoEVB. It accepts a single
command-line parameter indicating the binary value to display on those LEDs.
The hardware inverts this value, so a parameter value of `0` turns on all LEDS,
and a parameter value of `7` turns off all LEDs. For example:

```
./set-leds 2
./set-leds 5
```

The Acorn CLE-215+ has four LEDs, so accepts values `0` (all on) to `15` (all
off).

# Discrete GPUs on a PC

GPUDirect RDMA (the `nvidia_p2p_*` kernel API this driver uses) is supported
on NVIDIA's professional and data center GPUs (NVIDIA RTX/Quadro, Tesla), not
on GeForce GPUs.

## Driver and CUDA

Use a current driver with NVIDIA's open kernel modules (Turing or newer GPUs),
e.g. on Ubuntu 24.04:

```
sudo apt install nvidia-driver-595-open nvidia-dkms-595-open
```

The open kernel modules are GPL-compatible, so `picoevb-rdma.ko` loads
alongside them without restriction. (With the proprietary modules, Linux 5.13+
refuses to load a module that uses both their symbols and GPL-only kernel
symbols, which is why the driver avoids GPL-only APIs.) The DKMS package
installs the driver source, including `nv-p2p.h`, which
`build-for-pc-native.sh` finds automatically. With Secure Boot enabled, sign
`picoevb-rdma.ko` after building it with the same key DKMS uses. DKMS rebuilds
the NVIDIA driver when the kernel is updated, but `picoevb-rdma.ko` must be
rebuilt and re-signed by hand; otherwise loading it fails with "disagrees
about version of symbol". To sign it:

```
sudo kmodsign sha512 /var/lib/shim-signed/mok/MOK.priv /var/lib/shim-signed/mok/MOK.der picoevb-rdma.ko
```

Any CUDA 13.x toolkit works with an R580 or newer driver. The build scripts
compile for the installed GPU (`nvcc -arch=native`).

## Platform

* **BIOS**: enable "Above 4G Decoding", and "Re-Size BAR Support" if
  available. Pinned GPU memory is mapped for the FPGA through the GPU's BAR1,
  which without Resizable BAR may be as small as 256 MiB (e.g. RTX A5000), and
  limits how much GPU memory can be pinned at once (`nvidia-smi -q -d MEMORY`
  shows "BAR1 Memory Usage").
* **IOMMU**: GPUDirect RDMA requires the IOMMU to be disabled or in
  pass-through mode. Add `iommu=pt` (or `intel_iommu=off` / `amd_iommu=off`)
  to the kernel command line if DMA to GPU memory fails.
* **Slot placement**: the FPGA's accesses to GPU memory are peer-to-peer PCIe
  transactions through the CPU's root complex. Attach the FPGA to a CPU root
  port (e.g. the CPU-connected M.2 slot), not a chipset one, and keep the FPGA
  and the GPU on the same CPU socket. `lspci -tv` shows where each device is
  attached.
* **Peer-to-peer reads**: many desktop root complexes route peer-to-peer
  writes but not reads. On an Intel Core i9-12900K (Z690) system, the FPGA
  writing GPU memory works (`rdma-cuda-c2h-verify`, ~1.3 GB/s on PCIe Gen2
  x4), but the FPGA reading GPU memory does not: the read fails with an
  Unsupported Request error, or with `no_relaxed_ordering=1`, the read data
  never returns and the DMA engine stays stuck until the next reboot. Tests
  that read GPU memory (`rdma-cuda`, `rdma-cuda-h2c-perf`) fail on such
  systems.

## Testing

Before an FPGA is installed, `gpu-p2p-selftest/` can check the GPU side of
GPUDirect RDMA: it pins CUDA memory and DMA-maps it for a stand-in peer device
(any PCI device attached where the FPGA will be), checks that the addresses
lie within each GPU's BAR1, and tests the callback that fires when pinned
memory is freed. No DMA is performed:

```
sudo ./gpu-p2p-selftest/run-selftest.sh 0000:02:00.0
```

To check that GPUDirect RDMA works, run `rdma-cuda-c2h-verify` on each GPU.
It has the FPGA write a known pattern directly into GPU memory, then checks
every word, without ever having the FPGA read GPU memory:

```
sudo ./rdma-cuda-c2h-verify
sudo CUDA_VISIBLE_DEVICES=1 ./rdma-cuda-c2h-verify
```

On platforms that also route peer-to-peer reads, `sudo ./rdma-cuda` tests both
directions.

The driver gives up on a DMA transfer after 5 seconds and logs the DMA
engine's status register, e.g. `H2C DMA failed, status 0x00000200`. The
`no_relaxed_ordering=1` module parameter clears the FPGA's Relaxed Ordering
and No Snoop TLP attributes, for diagnosing peer-to-peer problems.

## Tesla K80

The Tesla K80 (Kepler) also supports GPUDirect RDMA, but:

* It needs the R470 driver, which is only available as proprietary kernel
  modules, limits how new a kernel you can use, and supports at most CUDA
  11.4. Build the client applications with
  `./build-for-pc-tesla-k80-native.sh`, which targets compute capability 3.7
  and uses gcc-10.
* It is passively cooled, and needs forced airflow outside a server chassis.
* A K80 that isn't fully seated or supported can pass link training at boot,
  then drop off the bus under load, failing with `RmInitAdapter failed` and
  sometimes hanging the machine. After any hang, remove power from the PSU,
  not just with the front button, before rebooting: the K80 keeps its bad
  state through a warm reset.
* A K80 appears as two CUDA devices. The tests use the default device, CUDA
  device 0.

# Radar Processing Benchmark

`radar-bench/` emulates 16-bit I/16-bit Q samples arriving in GPU memory from
the FPGA, and measures how fast the GPU can process them through a typical
pulse-Doppler radar pipeline:

1. int16 IQ to complex float.
2. Pulse compression: FFT of each pulse, multiplication by the conjugate
   spectrum of a Hamming-tapered LFM chirp, inverse FFT.
3. Corner turn, with a Hamming Doppler window.
4. Doppler FFT across the pulses of each CPI.
5. Power, and cell-averaging CFAR along range with a local peak test,
   compacted into a detection list that is copied to the host.

Samples arrive continuously at a rate Fs, so a CPI of M pulses of N range
samples arrives in N\*M/Fs seconds; the GPU processes in real time if its
sustained throughput is at least Fs.

```
cd radar-bench
make
./radar-bench verify --N 4096 --M 128 --L 512
./radar-bench gpu --N 4096 --M 256 --L 512
sudo ./radar-bench fpga --N 4096 --M 128 --L 512
```

* `verify` processes a synthetic CPI with targets at known range and Doppler
  bins, and checks that they are detected.
* `gpu` processes synthetic CPIs already resident in GPU memory, as if just
  written by the FPGA, and reports the sustained throughput, i.e. the largest
  real-time sample rate, plus per-stage times and CPI latency.
* `fpga` loads synthetic IQ into the FPGA's RAM, has the FPGA write it into a
  ring of GPU buffers via GPUDirect RDMA while the GPU processes each
  completed CPI, and reports the end-to-end rate and whether the GPU kept up.

On an RTX A5000 (driver 595, CUDA 13.4), the sustained rate is about
6.5 GS/s (26 GB/s of int16 IQ) for CPIs from 4096x64 to 16384x1024, peaking at
7.5 GS/s; very small CPIs are limited by kernel launch overhead and 65536-point
pulses by FFT efficiency (~5 GS/s). Pulse compression takes about 40-50% of
the time. The Acorn CLE-215+ design's PCIe Gen2 x4 link delivers about
350 MS/s (1.4 GB/s) into the GPU end-to-end, with the GPU keeping up with no
stalls, which uses about 5% of the GPU's capacity.

## Real-time Streaming From the FPGA's IQ Generator

The Acorn CLE-215+ design (subsystem 0x0005) contains a free-running radar IQ
generator, `fpga-acorn-cle215/iq_gen.v`, emulating an ADC: it produces 16-bit
I/16-bit Q samples at a programmable rate (up to 500 MS/s), in pulses of N
samples containing echoes of the same LFM chirp the GPU's matched filter uses
from up to two targets (programmable range, Doppler and amplitude), plus
approximately Gaussian noise. It writes them into the FPGA's 1 MiB RAM as a
ring, and counts overflows: samples overwritten before the host consumed them.
Its registers are at BAR0 offset 0x1000 (see `iq_gen.v`); the driver lets
user space `mmap()` BAR0.

`radar-bench stream` programs the generator, streams the ring into a ring of
GPU buffers (one CPI each) via GPUDirect RDMA, processes every CPI on the GPU,
and checks every CPI's detections against the programmed targets:

```
sudo ./radar-bench stream --N 4096 --M 128 --L 512 --rate-msps 375 --cpis 43000
sudo ./radar-bench stream --N 4096 --M 128 --L 512 --rate-msps 50 --gen-check
```

`--gen-check` compares one noiseless CPI from the hardware bit-for-bit with a
software model of the generator. The streaming loop runs at real-time priority
on one CPU (`--rt-cpu`).

### Continuous, FPGA-paced DMA

By default (`--dma stream`) the host does no per-transfer work. The driver
(`PICOEVB_IOC_C2H_STREAM_START`) gives the XDMA engine a circular list of
descriptors that copies the FPGA ring, in order, into the GPU buffers, over
and over. With the generator's DMA-paced mode (`CONTROL[2]`), the FPGA holds
each of the engine's AXI read bursts until the generator has written its data,
and counts the words read as consumed, so the engine streams at exactly the
generator's rate. The host only polls the engine's completed-descriptor count
(`PICOEVB_IOC_C2H_STREAM_STATUS`) to learn when each CPI is in GPU memory, and
counts a CPI as lost if the DMA comes back round to its buffer before the GPU
has finished with it. The driver stops the stream if its owner exits, or if
the GPU memory is freed.

With the Acorn's Gen2 x4 link and an RTX A5000, streaming is lossless at
375 MS/s (1.50 GB/s) for 60 s: 22.5 billion samples with no overflows, both
targets detected in all 43000 CPIs, and 0.19 ms (median) from a CPI's arrival
to its detections. That is the link's limit: from 380 MS/s the DMA can't keep
up and the ring overflows.

The previous scheme (`--dma ioctl`), one host-issued DMA per region of the
ring (`--region-kb`), is lossless only up to 150 MS/s: each DMA costs ~40 us
of host overhead, and the ring holds ~1 ms of samples, so an occasional slow
DMA (up to ~1 ms) overflows it.

The streaming loop polls the DMA's progress every ~20 us rather than spinning:
Linux throttles a real-time thread that uses more than 95% of a CPU
(`sched_rt_runtime_us`) by stopping it for ~50 ms each second, which is
longer than the ring of GPU buffers lasts.

### Live dashboard

`radar-bench/dashboard/` shows a running stream in a web browser: the
range-Doppler map of a recent CPI with its CFAR detections and the true
target positions, range profiles through the targets, the raw IQ from the
FPGA (in which, at the default noise level, the targets' echoes are 6 dB
below the noise and invisible), detection rates, and range and Doppler
detection histories. With `--move`, the generator's targets move during the
run (one closing, one opening), so the detections should trace their tracks.

```
radar-bench/dashboard/start.sh        # then open http://<host>:8080/
```

`start.sh` starts `dashboard/server.py` (Python standard library only), and a
375 MS/s stream run with `--telemetry 127.0.0.1:7700 --move 60`; pass other
`radar-bench stream` options to replace those defaults. Ctrl-C ends the run.
About 15 times a second, the streaming loop has the GPU reduce one CPI's
range-Doppler map to a 512 x M thumbnail and copy it out with a slice of raw
IQ; a separate, non-real-time thread sends it to the server as JSON, and the
loop never waits for it. Browsers long-poll the server for each frame.

To test a new bitstream without rebooting (which avoids both firmware and
power-on link training), remove the device, load the bitstream over JTAG, and
rescan. The link usually retrains by itself; if it doesn't (the device is
missing after the rescan), a warm reboot brings it up, as the FPGA keeps its
configuration:

```
sudo rmmod picoevb_rdma
echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove
vivado -mode batch -source jprog.tcl -tclargs top.bit   # program over JTAG
echo 1 | sudo tee /sys/bus/pci/rescan
sudo insmod picoevb-rdma.ko
```

## GPUDirect RDMA Versus Staging Through Host Memory

`radar-bench` can also compare how samples reach the GPU:

```
sudo sysctl vm.nr_hugepages=256   # 2 MB pages for host staging buffers
sudo ./radar-bench ingest
sudo ./radar-bench fpga --N 4096 --M 256 --L 512 --path rdma
sudo ./radar-bench fpga --N 4096 --M 256 --L 512 --path staged
sudo ./radar-bench fpga --N 4096 --M 256 --L 512 --path zerocopy
```

* `rdma`: the FPGA writes GPU memory directly (GPUDirect RDMA).
* `staged`: the FPGA writes pinned host memory, and each chunk is copied to
  the GPU with `cudaMemcpyAsync` as it arrives.
* `zerocopy`: the FPGA writes pinned host memory, and the GPU reads its input
  directly from host memory.
* `ingest` measures transport only, including FPGA-to-host-RAM as a
  reference, and serial and pipelined staging.

Host staging buffers use 2 MB huge pages when reserved, so that each FPGA DMA
into host memory is physically contiguous; with 4 KiB pages, the driver issues
one DMA per page, which is much slower.

Results with the Acorn CLE-215+ Gen2 x4 design and an RTX A5000 (Gen4 x16), in
1 MiB DMAs:

| Transport (`ingest`)                  | MB/s | Latency p50 | Host CPU |
| ------------------------------------- | ---- | ----------- | -------- |
| GPUDirect RDMA                        | 1401 | 747 us      | 4%       |
| FPGA to host RAM only (reference)     | 1390 | 754 us      | 4%       |
| Staged, pipelined                     | 1344 | 880 us      | 17%      |
| Staged, serial                        | 1253 | 831 us      | 13%      |

End to end (CPI 4096x256), all paths keep up with the FPGA with no GPU stalls:
`rdma` sustains ~343 MS/s with 0.40 ms from a CPI's last sample to its
detections, `staged` ~326-336 MS/s and 0.41-0.44 ms, and `zerocopy` ~340 MS/s
but 0.67 ms, since the GPU reads the whole CPI from host memory only after it
has arrived.

At this link speed, GPUDirect RDMA is ahead on every measure, but modestly:
the FPGA link (~1.4 GB/s) is far slower than the GPU's (~25 GB/s), so the extra
copy through host memory is cheap.

### Higher ingest rates (emulated source)

`radar-bench emulate` replaces the FPGA with a paced source at `--rate` GB/s,
to compare the two approaches at rates the Acorn cannot reach. With
`--path staged`, source threads write each chunk into pinned huge-page host
memory with non-temporal stores (which, like DMA, bypass the CPU caches), and
each chunk is copied to the GPU as it arrives. With `--path direct`, each
chunk is written straight into GPU memory with no host involvement, like
GPUDirect RDMA writes. At 1.4 GB/s the emulation reproduces the Acorn
measurements to within ~5%.

```
sudo sysctl vm.nr_hugepages=256
./radar-bench emulate --N 16384 --M 256 --L 2048 --ring 4 --path direct --rate 12 --cpis 720
./radar-bench emulate --N 16384 --M 256 --L 2048 --ring 4 --path staged --rate 12 --cpis 720 --writers 8
```

Results (16 MiB CPIs, RTX A5000, host with one DDR4-2133 DIMM):

| Rate     | Direct (RDMA)                      | Staged through host memory             |
| -------- | ---------------------------------- | -------------------------------------- |
| 1.4-6    | keeps up, 0.8-1.1 ms latency       | keeps up, 0.9-1.15 ms latency          |
| 9 GB/s   | keeps up, 0.87 ms                  | **7.1 GB/s max**, overruns, 8.4 ms     |
| 12 GB/s  | keeps up, 0.78 ms                  | 7.2 GB/s max, overruns                 |
| 20 GB/s  | keeps up, 0.78 ms                  | 7.2 GB/s max, overruns                 |
| 24+ GB/s | ~22.8 GB/s max (GPU processing)    | 7.2 GB/s max                           |

Staging moves every byte through host DRAM twice (written by the device, then
read by the GPU's copy engine), so it is limited to about half the host's
memory bandwidth. On this host that is ~15.5 GB/s in total (measured), hence
the ~7.1 GB/s limit. GPUDirect RDMA does not use host memory at all, and runs
until the GPU's processing is the limit. A host with more memory bandwidth
(e.g. more channels, faster DIMMs) raises the staged limit, but staging still
consumes twice the ingest rate in host memory bandwidth.

The CFAR threshold uses the textbook cell-averaging formula, which assumes
independent noise in the training cells. The range and Doppler windows
correlate neighboring cells, so the false alarm rate runs a few times higher
than `--pfa` requests; pass a smaller `--pfa` to compensate if that
matters.
