/*
 * Copyright (c) 2026, HOYS. All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

/*
 * Pulse-Doppler radar processing benchmark for 16-bit IQ samples delivered
 * into GPU memory by an FPGA via GPUDirect RDMA.
 *
 * Input: one CPI (coherent processing interval) of M pulses x N range
 * samples, as interleaved int16 I/Q (4 bytes per complex sample), sampled
 * continuously at Fs, so a CPI spans N*M/Fs seconds.
 *
 * Pipeline, per CPI:
 *   1. int16 IQ -> complex float
 *   2. Pulse compression: FFT(N) per pulse, multiply by conj(FFT(chirp)),
 *      IFFT(N). The reference chirp is Hamming tapered.
 *   3. Corner turn (pulse-major -> range-major) with a Hamming Doppler window
 *   4. Doppler FFT(M) per range bin
 *   5. Power |x|^2
 *   6. Cell-averaging CFAR along range, plus a local peak test, compacted
 *      into a detection list that is copied to the host
 *
 * Modes:
 *   gpu   Synthetic CPIs are resident in GPU memory, as if just written by
 *         the FPGA. Measures the sustained processing rate, i.e. the largest
 *         real-time sample rate, on one or more GPUs.
 *   fpga  The FPGA's RAM is loaded with synthetic IQ, which the FPGA then
 *         writes into a ring of GPU buffers via GPUDirect RDMA while the GPU
 *         processes completed CPIs. Measures end-to-end ingest + processing.
 *   verify  Process one synthetic CPI and check that the injected targets
 *         are detected at the right range/Doppler bins.
 */

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <mutex>
#include <thread>
#include <vector>

#include <cuda.h>
#include <cuda_runtime.h>
#include <cufft.h>
#include <immintrin.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

#include "../kernel-module/picoevb-rdma-ioctl.h"

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
	fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, #x, \
		cudaGetErrorString(e_)); exit(1); } } while (0)
#define CKF(x) do { cufftResult r_ = (x); if (r_ != CUFFT_SUCCESS) { \
	fprintf(stderr, "%s:%d: %s: cufft error %d\n", __FILE__, __LINE__, \
		#x, (int)r_); exit(1); } } while (0)

struct Config {
	std::string mode = "gpu";
	int N = 4096;		/* range samples per pulse (FFT size) */
	int M = 128;		/* pulses per CPI */
	int L = 512;		/* chirp length, samples */
	int gpus = 1;
	int streams = 3;
	int cpis = 200;		/* CPIs timed (per run, all GPUs together) */
	int warmup = 10;
	int guard = 2;		/* CFAR guard cells each side */
	int train = 16;		/* CFAR training cells each side */
	double pfa = 1e-6;
	int ring = 3;		/* fpga mode: CPI buffers in the GPU ring */
	bool csv = false;
	bool fused_cfar = true;	/* fused power+CFAR kernel */
	std::string path = "rdma";	/* fpga mode: rdma|staged|zerocopy */
	int ingest_mb = 512;	/* ingest mode: MiB per path */
	double rate_gbs = 1.4;	/* emulate mode: source rate, GB/s */
	int chunk_kb = 1024;	/* emulate mode: chunk size */
	int writers = 4;	/* emulate mode: source threads (staged) */
	double gen_msps = 250;	/* stream mode: generator rate, MS/s */
	double noise = 300;	/* stream mode: noise sigma, counts */
	bool gen_check = false;	/* stream mode: bit-exact generator check */
	int region_kb = 0;	/* stream mode: DMA region size (0 = half RAM) */
	int rt_cpu = 2;		/* stream mode: SCHED_FIFO on this CPU (-1 = off) */
	std::string dma = "stream";	/* stream mode: stream|ioctl */
	std::string telemetry;	/* stream mode: dashboard server ip:port */
	double tele_hz = 15;	/* stream mode: dashboard frames per second */
	double move = 0;	/* stream mode: target speed, range bins/s */
};

struct Det {
	int range;
	int doppler;
	float power;
	float noise;
};

static const int MAX_DETS = 4096;
static const int CFAR_SEG = 64;

/* ---------------------------------------------------------------- kernels */

__global__ void k_convert(const short2 *in, cufftComplex *out, size_t n,
	float scale)
{
	for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n;
			i += (size_t)gridDim.x * blockDim.x) {
		short2 v = in[i];
		out[i] = make_cuFloatComplex(v.x * scale, v.y * scale);
	}
}

/* data[p][k] *= H[k]; grid.y = pulse */
__global__ void k_matched(cufftComplex *data, const cufftComplex *H, int N)
{
	int k = blockIdx.x * blockDim.x + threadIdx.x;
	if (k >= N)
		return;
	size_t i = (size_t)blockIdx.y * N + k;
	data[i] = cuCmulf(data[i], H[k]);
}

/* in[M][N] (pulse-major) -> out[N][M] (range-major), times Doppler window */
__global__ void k_corner(const cufftComplex *in, cufftComplex *out,
	const float *w, int N, int M)
{
	__shared__ cufftComplex tile[32][33];
	int r = blockIdx.x * 32 + threadIdx.x;
	int p0 = blockIdx.y * 32;

	for (int j = threadIdx.y; j < 32; j += blockDim.y) {
		int p = p0 + j;
		if (r < N && p < M) {
			cufftComplex v = in[(size_t)p * N + r];
			float ww = w[p];
			v.x *= ww;
			v.y *= ww;
			tile[j][threadIdx.x] = v;
		}
	}
	__syncthreads();
	int p = p0 + threadIdx.x;
	for (int j = threadIdx.y; j < 32; j += blockDim.y) {
		int rr = blockIdx.x * 32 + j;
		if (rr < N && p < M)
			out[(size_t)rr * M + p] = tile[threadIdx.x][j];
	}
}

__global__ void k_power(const cufftComplex *in, float *out, size_t n)
{
	for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n;
			i += (size_t)gridDim.x * blockDim.x) {
		cufftComplex v = in[i];
		out[i] = v.x * v.x + v.y * v.y;
	}
}

/*
 * CA-CFAR along range on P[N][M] (range-major). Each thread handles one
 * Doppler bin over a CFAR_SEG-long segment of range, with sliding sums of the
 * leading and lagging training cells. Requires r_begin >= G+T and
 * r_end + G + T < N.
 */
__global__ void k_cfar(const float *P, int M, int r_begin, int r_end, int G,
	int T, float alpha, Det *dets, unsigned *ndets)
{
	int d = blockIdx.x * blockDim.x + threadIdx.x;
	int r0 = r_begin + blockIdx.y * CFAR_SEG;
	int r1 = min(r0 + CFAR_SEG, r_end);
	if (d >= M || r0 >= r1)
		return;

	float lead = 0, lag = 0;
	for (int k = r0 - G - T; k < r0 - G; k++)
		lead += P[(size_t)k * M + d];
	for (int k = r0 + G + 1; k <= r0 + G + T; k++)
		lag += P[(size_t)k * M + d];

	const float inv = 1.0f / (2 * T);
	const int dm = (d + M - 1) % M, dp = (d + 1) % M;
	for (int r = r0; r < r1; r++) {
		float p = P[(size_t)r * M + d];
		float noise = (lead + lag) * inv;
		if (p > alpha * noise &&
				p >= P[(size_t)(r - 1) * M + d] &&
				p >= P[(size_t)(r + 1) * M + d] &&
				p >= P[(size_t)r * M + dm] &&
				p >= P[(size_t)r * M + dp]) {
			unsigned i = atomicAdd(ndets, 1);
			if (i < MAX_DETS) {
				Det x = { r, d, p, noise };
				dets[i] = x;
			}
		}
		lead += P[(size_t)(r - G) * M + d] - P[(size_t)(r - G - T) * M + d];
		lag += P[(size_t)(r + G + T + 1) * M + d] -
			P[(size_t)(r + G + 1) * M + d];
	}
}

/*
 * Fused power + CA-CFAR on the complex Doppler-FFT output X[N][M]. Each block
 * covers 32 Doppler bins x (blockDim.y * CFAR_SEG) range cells: it loads that
 * tile plus a halo (G+T rows above/below, one Doppler bin either side) into
 * shared memory as |x|^2, then each thread slides the CFAR window down one
 * CFAR_SEG-long column segment from shared memory.
 */
#define FC_COLS 32
#define FC_SEGS 4
__global__ void k_power_cfar(const cufftComplex *X, int M, int r_begin,
	int r_end, int G, int T, float alpha, Det *dets, unsigned *ndets)
{
	extern __shared__ float sp[];	/* [rows][FC_COLS + 2] */
	const int W = FC_COLS + 2;
	const int halo = G + T;
	const int rb = r_begin + blockIdx.y * FC_SEGS * CFAR_SEG;
	const int re = min(rb + FC_SEGS * CFAR_SEG, r_end);
	const int d0 = blockIdx.x * FC_COLS;
	if (rb >= re)
		return;
	/* rows [rb - halo, re + halo] inclusive */
	const int rows = (re - rb) + 2 * halo + 1;
	const int tid = threadIdx.y * blockDim.x + threadIdx.x;
	const int nthr = blockDim.x * blockDim.y;
	for (int i = tid; i < rows * W; i += nthr) {
		int rr = i / W, cc = i % W;
		int r = rb - halo + rr;
		int d = (d0 - 1 + cc + M) % M;
		cufftComplex v = X[(size_t)r * M + d];
		sp[i] = v.x * v.x + v.y * v.y;
	}
	__syncthreads();

	const int d = d0 + threadIdx.x;
	const int r0 = rb + threadIdx.y * CFAR_SEG;
	const int r1 = min(r0 + CFAR_SEG, re);
	if (d >= M || r0 >= r1)
		return;
	const int c = threadIdx.x + 1;
#define SP(r) sp[((r) - (rb - halo)) * W + c]
	float lead = 0, lag = 0;
	for (int k = r0 - G - T; k < r0 - G; k++)
		lead += SP(k);
	for (int k = r0 + G + 1; k <= r0 + G + T; k++)
		lag += SP(k);
	const float inv = 1.0f / (2 * T);
	for (int r = r0; r < r1; r++) {
		float p = SP(r);
		float noise = (lead + lag) * inv;
		int base = (r - (rb - halo)) * W;
		if (p > alpha * noise && p >= SP(r - 1) && p >= SP(r + 1) &&
				p >= sp[base + c - 1] && p >= sp[base + c + 1]) {
			unsigned i = atomicAdd(ndets, 1);
			if (i < MAX_DETS) {
				Det x = { r, d, p, noise };
				dets[i] = x;
			}
		}
		lead += SP(r - G) - SP(r - G - T);
		lag += SP(r + G + T + 1) - SP(r + G + 1);
	}
#undef SP
}

/* ------------------------------------------------------- synthetic data */

struct Target {
	int range;	/* range bin (delay in samples) */
	int doppler;	/* Doppler bin, 0..M-1 */
	float amp;	/* echo amplitude, ADC counts */
};

static std::vector<Target> default_targets(const Config &c)
{
	std::vector<Target> t;
	int nv = c.N - c.L + 1;
	t.push_back({ nv / 8, 3, 120.0f });
	t.push_back({ nv / 3, c.M / 4, 60.0f });
	t.push_back({ nv / 2, c.M - 5, 200.0f });	/* negative Doppler */
	t.push_back({ (nv * 3) / 4, c.M / 2 - 7, 40.0f });
	return t;
}

static void chirp(int L, std::vector<std::complex<double>> &out)
{
	/* LFM sweeping 80% of the sampling bandwidth */
	const double bw = 0.8;
	out.resize(L);
	for (int n = 0; n < L; n++) {
		double t = n - L / 2.0;
		out[n] = std::polar(1.0, M_PI * bw * t * t / L);
	}
}

/*
 * One CPI of int16 IQ, pulse-major [M][N]: Gaussian noise (sigma counts per
 * I/Q component) plus chirp echoes from the targets.
 */
static void make_cpi(const Config &c, const std::vector<Target> &targets,
	double sigma, unsigned seed, std::vector<short2> &out)
{
	std::vector<std::complex<double>> ch;
	chirp(c.L, ch);
	std::mt19937 rng(seed);
	std::normal_distribution<double> g(0.0, sigma);
	out.resize((size_t)c.N * c.M);
	std::vector<std::complex<double>> pulse(c.N);
	for (int p = 0; p < c.M; p++) {
		for (int n = 0; n < c.N; n++)
			pulse[n] = std::complex<double>(g(rng), g(rng));
		for (const Target &t : targets) {
			std::complex<double> dop = std::polar(1.0,
				2 * M_PI * t.doppler * p / (double)c.M);
			for (int n = 0; n < c.L && t.range + n < c.N; n++)
				pulse[t.range + n] += (double)t.amp * ch[n] * dop;
		}
		for (int n = 0; n < c.N; n++) {
			auto q = [](double v) {
				return (short)std::max(-32768.0,
					std::min(32767.0, std::round(v)));
			};
			out[(size_t)p * c.N + n] =
				make_short2(q(pulse[n].real()), q(pulse[n].imag()));
		}
	}
}

/* conj(FFT_N(hamming * chirp)) / N */
static void make_filter(const Config &c, std::vector<cufftComplex> &H)
{
	std::vector<std::complex<double>> ch;
	chirp(c.L, ch);
	std::vector<cufftComplex> ref(c.N);
	for (int n = 0; n < c.N; n++)
		ref[n] = make_cuFloatComplex(0, 0);
	for (int n = 0; n < c.L; n++) {
		double w = 0.54 - 0.46 * cos(2 * M_PI * n / (c.L - 1));
		ref[n] = make_cuFloatComplex(w * ch[n].real(), w * ch[n].imag());
	}
	cufftComplex *d;
	cufftHandle plan;
	CK(cudaMalloc(&d, c.N * sizeof(cufftComplex)));
	CK(cudaMemcpy(d, ref.data(), c.N * sizeof(cufftComplex),
		cudaMemcpyHostToDevice));
	CKF(cufftPlan1d(&plan, c.N, CUFFT_C2C, 1));
	CKF(cufftExecC2C(plan, d, d, CUFFT_FORWARD));
	H.resize(c.N);
	CK(cudaMemcpy(H.data(), d, c.N * sizeof(cufftComplex),
		cudaMemcpyDeviceToHost));
	cufftDestroy(plan);
	cudaFree(d);
	for (auto &h : H)
		h = make_cuFloatComplex(h.x / c.N, -h.y / c.N);
}

/* ------------------------------------------------------- GPU pipeline */

struct Lane {			/* one CUDA stream's private resources */
	cudaStream_t s;
	cufftHandle plan_r, plan_d;
	cufftComplex *a, *b;
	float *pw;
	Det *dets;
	unsigned *ndets;
	Det *h_dets;		/* pinned host */
	unsigned *h_ndets;
};

struct Gpu {
	int dev;
	Config c;
	cufftComplex *H;
	float *wdop;
	std::vector<Lane> lanes;
	int r_begin, r_end;
	float alpha;
};

static void gpu_init(Gpu &g, int dev, const Config &c)
{
	g.dev = dev;
	g.c = c;
	CK(cudaSetDevice(dev));
	std::vector<cufftComplex> H;
	make_filter(c, H);
	CK(cudaMalloc(&g.H, c.N * sizeof(cufftComplex)));
	CK(cudaMemcpy(g.H, H.data(), c.N * sizeof(cufftComplex),
		cudaMemcpyHostToDevice));
	std::vector<float> w(c.M);
	for (int p = 0; p < c.M; p++)
		w[p] = 0.54 - 0.46 * cos(2 * M_PI * p / (c.M - 1));
	CK(cudaMalloc(&g.wdop, c.M * sizeof(float)));
	CK(cudaMemcpy(g.wdop, w.data(), c.M * sizeof(float),
		cudaMemcpyHostToDevice));

	int nvalid = c.N - c.L + 1;
	g.r_begin = c.guard + c.train;
	g.r_end = std::min(nvalid, c.N - 1 - c.guard - c.train);
	/* CA-CFAR: alpha = 2T (Pfa^(-1/2T) - 1) */
	g.alpha = 2 * c.train * (pow(c.pfa, -1.0 / (2 * c.train)) - 1);

	size_t n = (size_t)c.N * c.M;
	g.lanes.resize(c.streams);
	for (Lane &l : g.lanes) {
		CK(cudaStreamCreateWithFlags(&l.s, cudaStreamNonBlocking));
		CKF(cufftPlan1d(&l.plan_r, c.N, CUFFT_C2C, c.M));
		CKF(cufftPlan1d(&l.plan_d, c.M, CUFFT_C2C, c.N));
		CKF(cufftSetStream(l.plan_r, l.s));
		CKF(cufftSetStream(l.plan_d, l.s));
		CK(cudaMalloc(&l.a, n * sizeof(cufftComplex)));
		CK(cudaMalloc(&l.b, n * sizeof(cufftComplex)));
		CK(cudaMalloc(&l.pw, n * sizeof(float)));
		CK(cudaMalloc(&l.dets, MAX_DETS * sizeof(Det)));
		CK(cudaMalloc(&l.ndets, sizeof(unsigned)));
		CK(cudaMallocHost(&l.h_dets, MAX_DETS * sizeof(Det)));
		CK(cudaMallocHost(&l.h_ndets, sizeof(unsigned)));
	}
}

static void gpu_free(Gpu &g)
{
	CK(cudaSetDevice(g.dev));
	for (Lane &l : g.lanes) {
		cufftDestroy(l.plan_r);
		cufftDestroy(l.plan_d);
		cudaFree(l.a);
		cudaFree(l.b);
		cudaFree(l.pw);
		cudaFree(l.dets);
		cudaFree(l.ndets);
		cudaFreeHost(l.h_dets);
		cudaFreeHost(l.h_ndets);
		cudaStreamDestroy(l.s);
	}
	cudaFree(g.H);
	cudaFree(g.wdop);
}

/*
 * Enqueue processing of one CPI on lane l. If ev is non-null, it receives
 * events marking the end of each stage (7 events, ev[0] = start).
 */
static void process_cpi(Gpu &g, Lane &l, const short2 *raw, bool copy_all,
	cudaEvent_t *ev)
{
	const Config &c = g.c;
	size_t n = (size_t)c.N * c.M;
	int e = 0;
	if (ev)
		CK(cudaEventRecord(ev[e++], l.s));
	k_convert<<<1024, 256, 0, l.s>>>(raw, l.a, n, 1.0f);
	if (ev)
		CK(cudaEventRecord(ev[e++], l.s));
	CKF(cufftExecC2C(l.plan_r, l.a, l.a, CUFFT_FORWARD));
	k_matched<<<dim3((c.N + 255) / 256, c.M), 256, 0, l.s>>>(l.a, g.H, c.N);
	CKF(cufftExecC2C(l.plan_r, l.a, l.a, CUFFT_INVERSE));
	if (ev)
		CK(cudaEventRecord(ev[e++], l.s));
	k_corner<<<dim3((c.N + 31) / 32, (c.M + 31) / 32), dim3(32, 8), 0,
		l.s>>>(l.a, l.b, g.wdop, c.N, c.M);
	if (ev)
		CK(cudaEventRecord(ev[e++], l.s));
	CKF(cufftExecC2C(l.plan_d, l.b, l.b, CUFFT_FORWARD));
	if (ev)
		CK(cudaEventRecord(ev[e++], l.s));
	CK(cudaMemsetAsync(l.ndets, 0, sizeof(unsigned), l.s));
	if (c.fused_cfar) {
		int span = FC_SEGS * CFAR_SEG;
		dim3 grid((c.M + FC_COLS - 1) / FC_COLS,
			(g.r_end - g.r_begin + span - 1) / span);
		size_t shm = (span + 2 * (c.guard + c.train) + 1) *
			(FC_COLS + 2) * sizeof(float);
		k_power_cfar<<<grid, dim3(FC_COLS, FC_SEGS), shm, l.s>>>(l.b,
			c.M, g.r_begin, g.r_end, c.guard, c.train, g.alpha,
			l.dets, l.ndets);
	} else {
		k_power<<<1024, 256, 0, l.s>>>(l.b, l.pw, n);
		int bx = std::min(c.M, 64);
		dim3 grid((c.M + bx - 1) / bx,
			(g.r_end - g.r_begin + CFAR_SEG - 1) / CFAR_SEG);
		k_cfar<<<grid, bx, 0, l.s>>>(l.pw, c.M, g.r_begin, g.r_end,
			c.guard, c.train, g.alpha, l.dets, l.ndets);
	}
	if (ev)
		CK(cudaEventRecord(ev[e++], l.s));
	CK(cudaMemcpyAsync(l.h_ndets, l.ndets, sizeof(unsigned),
		cudaMemcpyDeviceToHost, l.s));
	if (copy_all)
		CK(cudaMemcpyAsync(l.h_dets, l.dets, MAX_DETS * sizeof(Det),
			cudaMemcpyDeviceToHost, l.s));
	if (ev)
		CK(cudaEventRecord(ev[e++], l.s));
}

static double now_s()
{
	return std::chrono::duration<double>(
		std::chrono::steady_clock::now().time_since_epoch()).count();
}

/* ---------------------------------------------------------------- verify */

static int run_verify(const Config &c)
{
	Gpu g;
	Config c1 = c;
	c1.streams = 1;
	gpu_init(g, 0, c1);
	auto targets = default_targets(c);
	std::vector<short2> h;
	make_cpi(c, targets, 300.0, 1, h);
	short2 *raw;
	CK(cudaMalloc(&raw, h.size() * sizeof(short2)));
	CK(cudaMemcpy(raw, h.data(), h.size() * sizeof(short2),
		cudaMemcpyHostToDevice));
	Lane &l = g.lanes[0];
	process_cpi(g, l, raw, true, nullptr);
	CK(cudaStreamSynchronize(l.s));
	unsigned nd = std::min<unsigned>(*l.h_ndets, MAX_DETS);
	printf("verify: N=%d M=%d L=%d, CFAR alpha=%.2f (Pfa %.0e), %u detections\n",
		c.N, c.M, c.L, g.alpha, c.pfa, *l.h_ndets);
	std::vector<Det> d(l.h_dets, l.h_dets + nd);
	std::sort(d.begin(), d.end(),
		[](const Det &a, const Det &b) { return a.power > b.power; });
	int found = 0;
	for (const Target &t : targets) {
		bool ok = false;
		for (const Det &x : d)
			if (abs(x.range - t.range) <= 1 && x.doppler == t.doppler) {
				printf("  target range %5d doppler %4d amp %5.0f: detected at (%d, %d), SNR %.1f dB\n",
					t.range, t.doppler, t.amp, x.range, x.doppler,
					10 * log10(x.power / x.noise));
				ok = true;
				break;
			}
		if (!ok)
			printf("  target range %5d doppler %4d amp %5.0f: MISSED\n",
				t.range, t.doppler, t.amp);
		found += ok;
	}
	/*
	 * Classify the other detections: within a few range bins of a target
	 * (any Doppler) or in a target's Doppler bin (any range) are sidelobes
	 * of that target; anything else is a false alarm.
	 */
	int sidelobes = 0, false_alarms = 0;
	for (const Det &x : d) {
		bool is_target = false, near = false;
		for (const Target &t : targets) {
			int dr = abs(x.range - t.range);
			int dd = std::min(abs(x.doppler - t.doppler),
				c.M - abs(x.doppler - t.doppler));
			if (dr <= 1 && dd == 0)
				is_target = true;
			else if (dr <= 8 || dd <= 1)
				near = true;
		}
		if (is_target)
			continue;
		if (near)
			sidelobes++;
		else
			false_alarms++;
	}
	int cells = (g.r_end - g.r_begin) * c.M;
	printf("  %d/%zu targets detected; %d target sidelobe detections, %d false alarms (expected ~%.1f at Pfa %.0e over %d cells)\n",
		found, targets.size(), sidelobes, false_alarms, c.pfa * cells,
		c.pfa, cells);
	cudaFree(raw);
	gpu_free(g);
	return found == (int)targets.size() ? 0 : 1;
}

/* ------------------------------------------------------------- gpu mode */

struct GpuResult {
	double elapsed;
	int cpis;
	std::vector<float> latency_ms;
	float stage_ms[6];
};

static void gpu_worker(int dev, Config c, int ncpis,
	std::atomic<int> *ready, std::atomic<bool> *go, GpuResult *res)
{
	Gpu g;
	gpu_init(g, dev, c);
	/* A few distinct synthetic CPIs, resident in GPU memory */
	const int nunique = 4;
	size_t n = (size_t)c.N * c.M;
	short2 *raw;
	CK(cudaMalloc(&raw, nunique * n * sizeof(short2)));
	for (int i = 0; i < nunique; i++) {
		std::vector<short2> h;
		make_cpi(c, default_targets(c), 300.0, 100 * dev + i, h);
		CK(cudaMemcpy(raw + i * n, h.data(), n * sizeof(short2),
			cudaMemcpyHostToDevice));
	}

	/* Per-stage breakdown: one lane, events between stages */
	{
		Lane &l = g.lanes[0];
		cudaEvent_t ev[7];
		for (auto &e : ev)
			CK(cudaEventCreate(&e));
		for (int i = 0; i < 3; i++)
			process_cpi(g, l, raw, false, nullptr);
		double acc[6] = { 0 };
		const int reps = 20;
		for (int i = 0; i < reps; i++) {
			process_cpi(g, l, raw + (i % nunique) * n, false, ev);
			CK(cudaEventSynchronize(ev[6]));
			for (int s = 0; s < 6; s++) {
				float ms;
				CK(cudaEventElapsedTime(&ms, ev[s], ev[s + 1]));
				acc[s] += ms;
			}
		}
		for (int s = 0; s < 6; s++)
			res->stage_ms[s] = acc[s] / reps;
		for (auto &e : ev)
			cudaEventDestroy(e);
	}

	/* Sustained throughput: CPIs round-robin over lanes */
	std::vector<cudaEvent_t> t0(ncpis), t1(ncpis);
	for (int i = 0; i < ncpis; i++) {
		CK(cudaEventCreate(&t0[i]));
		CK(cudaEventCreate(&t1[i]));
	}
	for (int i = 0; i < c.warmup; i++)
		process_cpi(g, g.lanes[i % c.streams], raw + (i % nunique) * n,
			false, nullptr);
	CK(cudaDeviceSynchronize());

	ready->fetch_add(1);
	while (!go->load())
		;
	double start = now_s();
	for (int i = 0; i < ncpis; i++) {
		Lane &l = g.lanes[i % c.streams];
		CK(cudaEventRecord(t0[i], l.s));
		process_cpi(g, l, raw + (i % nunique) * n, false, nullptr);
		CK(cudaEventRecord(t1[i], l.s));
	}
	CK(cudaDeviceSynchronize());
	res->elapsed = now_s() - start;
	res->cpis = ncpis;
	for (int i = 0; i < ncpis; i++) {
		float ms;
		CK(cudaEventElapsedTime(&ms, t0[i], t1[i]));
		res->latency_ms.push_back(ms);
		cudaEventDestroy(t0[i]);
		cudaEventDestroy(t1[i]);
	}
	cudaFree(raw);
	gpu_free(g);
}

static int run_gpu(const Config &c)
{
	int ndev;
	CK(cudaGetDeviceCount(&ndev));
	int ng = std::min(c.gpus, ndev);
	std::vector<GpuResult> res(ng);
	std::vector<std::thread> th;
	std::atomic<int> ready(0);
	std::atomic<bool> go(false);
	for (int d = 0; d < ng; d++)
		th.emplace_back(gpu_worker, d, c, c.cpis / ng, &ready, &go,
			&res[d]);
	while (ready.load() < ng)
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	go = true;
	for (auto &t : th)
		t.join();

	double elapsed = 0;
	long cpis = 0;
	std::vector<float> lat;
	for (auto &r : res) {
		elapsed = std::max(elapsed, r.elapsed);
		cpis += r.cpis;
		lat.insert(lat.end(), r.latency_ms.begin(), r.latency_ms.end());
	}
	std::sort(lat.begin(), lat.end());
	double samples = (double)cpis * c.N * c.M;
	double rate = samples / elapsed;			/* complex samples/s */
	double cpi_ms = 1e3 * c.N * (double)c.M / rate;	/* CPI duration at that rate */
	const char *stage[6] = { "convert", "pulse-comp", "corner-turn",
		"doppler-fft", "power+cfar", "det-copy" };
	if (c.csv) {
		printf("%d,%d,%d,%d,%d,%.1f,%.1f,%.3f,%.3f\n", c.N, c.M, c.L, ng,
			c.streams, rate / 1e6, rate * 4 / 1e6,
			lat[lat.size() / 2], lat.back());
		return 0;
	}
	printf("gpu mode: N=%d M=%d L=%d, %d GPU(s), %d streams, %ld CPIs\n",
		c.N, c.M, c.L, ng, c.streams, cpis);
	printf("  per-CPI stage times (GPU 0, isolated):");
	float tot = 0;
	for (int s = 0; s < 6; s++) {
		printf(" %s %.3f", stage[s], res[0].stage_ms[s]);
		tot += res[0].stage_ms[s];
	}
	printf(" = %.3f ms\n", tot);
	printf("  sustained: %.1f Msamples/s complex (%.1f MB/s of int16 IQ)\n",
		rate / 1e6, rate * 4 / 1e6);
	printf("  => max real-time Fs %.1f MS/s; CPI %.3f ms, PRF %.0f Hz at that Fs\n",
		rate / 1e6, cpi_ms, rate / c.N);
	printf("  CPI latency (queued, all streams busy): median %.3f ms, max %.3f ms\n",
		lat[lat.size() / 2], lat.back());
	return 0;
}

/* ------------------------------------------------------- FPGA access */

struct Fpga {
	int fd = -1;
	size_t chunk = 0;	/* FPGA RAM size = largest single DMA */
};

static bool fpga_open(Fpga &f)
{
	f.fd = open("/dev/picoevb", O_RDWR);
	if (f.fd < 0) {
		perror("open(/dev/picoevb)");
		return false;
	}
	struct picoevb_rdma_card_info ci;
	if (ioctl(f.fd, PICOEVB_IOC_CARD_INFO, &ci)) {
		perror("ioctl(CARD_INFO)");
		return false;
	}
	f.chunk = ci.fpga_ram_size;
	return true;
}

/* Fill the FPGA RAM (the emulated ADC) from host memory */
static void fpga_load(const Fpga &f, const void *src)
{
	struct picoevb_rdma_h2c_dma h2c = {};
	h2c.src = (__u64)src;
	h2c.len = f.chunk;
	if (ioctl(f.fd, PICOEVB_IOC_H2C_DMA, &h2c)) {
		perror("ioctl(H2C_DMA) loading FPGA RAM");
		exit(1);
	}
}

/* FPGA RAM -> pinned GPU memory chunk (GPUDirect RDMA) */
static void fpga_c2h_cuda(const Fpga &f, __u32 handle)
{
	struct picoevb_rdma_c2h_dma c2h = {};
	c2h.dst = handle;
	c2h.len = f.chunk;
	c2h.flags = PICOEVB_C2H_DMA_FLAG_DST_IS_CUDA;
	if (ioctl(f.fd, PICOEVB_IOC_C2H_DMA, &c2h)) {
		perror("ioctl(C2H_DMA to GPU)");
		exit(1);
	}
}

/* FPGA RAM -> host memory */
static void fpga_c2h_host(const Fpga &f, void *dst)
{
	struct picoevb_rdma_c2h_dma c2h = {};
	c2h.dst = (__u64)dst;
	c2h.len = f.chunk;
	if (ioctl(f.fd, PICOEVB_IOC_C2H_DMA, &c2h)) {
		perror("ioctl(C2H_DMA to host)");
		exit(1);
	}
}

/* Pin each FPGA-RAM-sized chunk of a GPU buffer for GPUDirect writes */
static std::vector<__u32> pin_chunks(const Fpga &f, void *gpu, size_t bytes,
	size_t piece = 0)
{
	if (!piece)
		piece = f.chunk;
	unsigned flag = 1;
	if (cuPointerSetAttribute(&flag, CU_POINTER_ATTRIBUTE_SYNC_MEMOPS,
			(CUdeviceptr)gpu) != CUDA_SUCCESS) {
		fprintf(stderr, "cuPointerSetAttribute failed\n");
		exit(1);
	}
	std::vector<__u32> h;
	for (size_t off = 0; off < bytes; off += piece) {
		struct picoevb_rdma_pin_cuda pin = {};
		pin.va = (__u64)((char *)gpu + off);
		pin.size = piece;
		if (ioctl(f.fd, PICOEVB_IOC_PIN_CUDA, &pin)) {
			perror("ioctl(PIN_CUDA)");
			exit(1);
		}
		h.push_back(pin.handle);
	}
	return h;
}

static void unpin_chunks(const Fpga &f, const std::vector<__u32> &h)
{
	for (__u32 x : h) {
		struct picoevb_rdma_unpin_cuda up = { x };
		ioctl(f.fd, PICOEVB_IOC_UNPIN_CUDA, &up);
	}
}

/*
 * Host staging memory, registered with CUDA. Backed by 2 MB huge pages if any
 * are reserved (vm.nr_hugepages), so that each FPGA DMA into it is one
 * physically contiguous transfer; otherwise transparent huge pages are
 * requested, and the DMA may be split at 4 KiB page boundaries.
 */
struct HostBuf {
	void *p = nullptr;
	size_t size = 0;
	bool huge = false;
};

static const size_t HUGE_2M = 2u << 20;

static HostBuf host_alloc(size_t size, unsigned reg_flags)
{
	HostBuf b;
	b.size = (size + HUGE_2M - 1) & ~(HUGE_2M - 1);
	b.p = mmap(nullptr, b.size, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_POPULATE, -1, 0);
	if (b.p != MAP_FAILED) {
		b.huge = true;
	} else {
		if (posix_memalign(&b.p, HUGE_2M, b.size)) {
			fprintf(stderr, "posix_memalign failed\n");
			exit(1);
		}
		madvise(b.p, b.size, MADV_HUGEPAGE);
		memset(b.p, 0, b.size);
	}
	CK(cudaHostRegister(b.p, b.size, reg_flags));
	return b;
}

static void host_free(HostBuf &b)
{
	cudaHostUnregister(b.p);
	if (b.huge)
		munmap(b.p, b.size);
	else
		free(b.p);
}

static void CUDART_CB stamp_now(void *p)
{
	*(double *)p = now_s();
}

static double cpu_s()
{
	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
	return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec * 1e-6 +
		ru.ru_stime.tv_sec + ru.ru_stime.tv_usec * 1e-6;
}

static double percentile(std::vector<double> v, double q)
{
	if (v.empty())
		return 0;
	std::sort(v.begin(), v.end());
	return v[std::min(v.size() - 1, (size_t)(q * v.size()))];
}

/* ---------------------------------------------------------- ingest mode */

/*
 * Transport only: move ingest_mb of FPGA data into GPU memory, chunk by chunk,
 * via each path, and report throughput, per-chunk latency (DMA start -> data
 * usable in GPU memory) and host CPU time. Data is verified for every path.
 */
static int run_ingest(const Config &c)
{
	Fpga f;
	if (!fpga_open(f))
		return 1;
	CK(cudaSetDevice(0));
	const size_t chunk = f.chunk;
	const int R = 4;			/* ring slots */
	const int warm = 8;
	const int total = std::max(16, (int)(((size_t)c.ingest_mb << 20) / chunk));

	std::vector<uint8_t> pat(chunk);
	std::mt19937 rng(42);
	for (auto &x : pat)
		x = rng();
	fpga_load(f, pat.data());

	char *gpu;
	CK(cudaMalloc(&gpu, R * chunk));
	std::vector<__u32> handles = pin_chunks(f, gpu, R * chunk);
	HostBuf hb = host_alloc(R * chunk, cudaHostRegisterDefault);
	char *host = (char *)hb.p;
	cudaStream_t s;
	CK(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking));
	std::vector<cudaEvent_t> slot_free(R);
	for (auto &e : slot_free)
		CK(cudaEventCreateWithFlags(&e, cudaEventDisableTiming));
	std::vector<double> t0(warm + total), t1(warm + total);

	struct Row {
		const char *name;
		double mbps, lat50, lat99, cpu;
		bool ok;
	};
	std::vector<Row> rows;

	auto check_gpu = [&]() {
		std::vector<uint8_t> back(chunk);
		bool ok = true;
		for (int k = 0; k < R; k++) {
			CK(cudaMemcpy(back.data(), gpu + k * chunk, chunk,
				cudaMemcpyDeviceToHost));
			ok &= !memcmp(back.data(), pat.data(), chunk);
		}
		return ok;
	};
	auto run = [&](const char *name, int kind) {
		CK(cudaMemset(gpu, 0, R * chunk));
		memset(host, 0, R * chunk);
		CK(cudaDeviceSynchronize());
		double start = 0, c0 = 0;
		for (int i = 0; i < warm + total; i++) {
			if (i == warm) {
				CK(cudaStreamSynchronize(s));
				start = now_s();
				c0 = cpu_s();
			}
			int k = i % R;
			switch (kind) {
			case 0:		/* FPGA -> host RAM only */
				t0[i] = now_s();
				fpga_c2h_host(f, host + k * chunk);
				t1[i] = now_s();
				break;
			case 1:		/* GPUDirect RDMA */
				t0[i] = now_s();
				fpga_c2h_cuda(f, handles[k]);
				t1[i] = now_s();
				break;
			case 2:		/* staged, serial */
				t0[i] = now_s();
				fpga_c2h_host(f, host + k * chunk);
				CK(cudaMemcpyAsync(gpu + k * chunk, host + k * chunk,
					chunk, cudaMemcpyHostToDevice, s));
				CK(cudaStreamSynchronize(s));
				t1[i] = now_s();
				break;
			case 3:		/* staged, pipelined */
				if (i >= R)
					CK(cudaEventSynchronize(slot_free[k]));
				t0[i] = now_s();
				fpga_c2h_host(f, host + k * chunk);
				CK(cudaMemcpyAsync(gpu + k * chunk, host + k * chunk,
					chunk, cudaMemcpyHostToDevice, s));
				CK(cudaLaunchHostFunc(s, stamp_now, &t1[i]));
				CK(cudaEventRecord(slot_free[k], s));
				break;
			}
		}
		CK(cudaStreamSynchronize(s));
		double el = now_s() - start, cpu = cpu_s() - c0;
		std::vector<double> lat;
		for (int i = warm; i < warm + total; i++)
			lat.push_back((t1[i] - t0[i]) * 1e6);
		bool ok;
		if (kind == 0) {
			ok = true;
			for (int k = 0; k < R; k++)
				ok &= !memcmp(host + k * chunk, pat.data(), chunk);
		} else {
			ok = check_gpu();
		}
		rows.push_back({ name, (double)total * chunk / el / 1e6,
			percentile(lat, 0.5), percentile(lat, 0.99), cpu / el, ok });
	};

	run("FPGA -> host RAM (no GPU)", 0);
	run("GPUDirect RDMA: FPGA -> GPU", 1);
	run("Staged, serial: FPGA -> host -> GPU", 2);
	run("Staged, pipelined: FPGA -> host -> GPU", 3);

	printf("ingest: %d x %zu KiB chunks per path, host buffers on %s\n",
		total, chunk / 1024,
		hb.huge ? "2 MB huge pages" : "4 KiB pages (THP requested)");
	printf("  %-40s %9s %8s %12s %12s %7s  %s\n", "path", "MB/s", "MS/s",
		"lat p50 us", "lat p99 us", "CPU %", "data");
	for (const Row &r : rows)
		printf("  %-40s %9.1f %8.1f %12.1f %12.1f %7.1f  %s\n", r.name,
			r.mbps, r.mbps / 4, r.lat50, r.lat99, 100 * r.cpu,
			r.ok ? "ok" : "MISMATCH");
	printf("  (latency = DMA start until the chunk is usable in GPU memory;\n"
		"   MS/s = complex 16-bit IQ samples per second)\n");

	bool all_ok = true;
	for (const Row &r : rows)
		all_ok &= r.ok;
	unpin_chunks(f, handles);
	host_free(hb);
	cudaFree(gpu);
	close(f.fd);
	return all_ok ? 0 : 1;
}

/* ------------------------------------------------------------ fpga mode */

/*
 * End-to-end: the FPGA streams CPIs into a ring of buffers while the GPU
 * processes each completed CPI. --path selects how samples reach the GPU:
 *   rdma      FPGA writes GPU memory directly (GPUDirect RDMA)
 *   staged    FPGA writes pinned host memory; cudaMemcpyAsync to the GPU
 *   zerocopy  FPGA writes pinned host memory; the GPU reads its input
 *             directly from host memory, without a copy
 */
static int run_fpga(const Config &c)
{
	Fpga f;
	if (!fpga_open(f))
		return 1;
	const size_t chunk = f.chunk;
	const size_t n = (size_t)c.N * c.M;
	const size_t cpi_bytes = n * sizeof(short2);
	if (cpi_bytes % chunk) {
		fprintf(stderr, "CPI size must be a multiple of %zu bytes\n", chunk);
		return 1;
	}
	const int nchunks = cpi_bytes / chunk;
	const bool rdma = c.path == "rdma";
	const bool staged = c.path == "staged";
	const bool zerocopy = c.path == "zerocopy";
	if (!rdma && !staged && !zerocopy) {
		fprintf(stderr, "--path must be rdma, staged or zerocopy\n");
		return 1;
	}

	Gpu g;
	Config c1 = c;
	c1.streams = std::min(c.streams, c.ring);
	gpu_init(g, 0, c1);

	/* Synthetic IQ into the FPGA RAM (the "ADC" for now) */
	std::vector<short2> h;
	make_cpi(c, default_targets(c), 300.0, 7, h);
	fpga_load(f, h.data());

	std::vector<short2 *> gbuf(c.ring, nullptr);	/* GPU CPI buffers */
	std::vector<std::vector<__u32>> handle(c.ring);
	std::vector<HostBuf> hbuf(c.ring);		/* host CPI buffers */
	std::vector<short2 *> zdev(c.ring, nullptr);
	for (int b = 0; b < c.ring; b++) {
		if (!zerocopy)
			CK(cudaMalloc(&gbuf[b], cpi_bytes));
		if (rdma)
			handle[b] = pin_chunks(f, gbuf[b], cpi_bytes);
		if (staged)
			hbuf[b] = host_alloc(cpi_bytes, cudaHostRegisterDefault);
		if (zerocopy) {
			hbuf[b] = host_alloc(cpi_bytes, cudaHostRegisterMapped);
			CK(cudaHostGetDevicePointer((void **)&zdev[b], hbuf[b].p, 0));
		}
	}
	std::vector<cudaEvent_t> done(c.ring);
	for (auto &e : done)
		CK(cudaEventCreateWithFlags(&e, cudaEventDisableTiming));

	int total = c.warmup + c.cpis;
	std::vector<double> t_arrive(total), t_detect(total);
	int stalls = 0;
	double stall_s = 0, dma_s = 0, start = 0, c0 = 0;
	for (int i = 0; i < total; i++) {
		if (i == c.warmup) {
			CK(cudaDeviceSynchronize());
			stalls = 0;
			stall_s = dma_s = 0;
			start = now_s();
			c0 = cpu_s();
		}
		int b = i % c.ring;
		if (i >= c.ring && cudaEventQuery(done[b]) == cudaErrorNotReady) {
			/* GPU still using the CPI that last used this buffer */
			double t = now_s();
			CK(cudaEventSynchronize(done[b]));
			stall_s += now_s() - t;
			stalls++;
		}
		Lane &l = g.lanes[b % g.lanes.size()];
		double t = now_s();
		for (int k = 0; k < nchunks; k++) {
			if (rdma) {
				fpga_c2h_cuda(f, handle[b][k]);
			} else {
				char *src = (char *)hbuf[b].p + k * chunk;
				fpga_c2h_host(f, src);
				/* Copy each chunk as it arrives, overlapping the DMA */
				if (staged)
					CK(cudaMemcpyAsync((char *)gbuf[b] + k * chunk,
						src, chunk, cudaMemcpyHostToDevice,
						l.s));
			}
		}
		t_arrive[i] = now_s();
		dma_s += t_arrive[i] - t;

		const short2 *raw = zerocopy ? zdev[b] : gbuf[b];
		process_cpi(g, l, raw, false, nullptr);
		CK(cudaLaunchHostFunc(l.s, stamp_now, &t_detect[i]));
		CK(cudaEventRecord(done[b], l.s));
	}
	CK(cudaDeviceSynchronize());
	double elapsed = now_s() - start, cpu = cpu_s() - c0;

	/* Check that what the GPU processed matches the FPGA RAM */
	std::vector<short2> back(chunk / sizeof(short2));
	if (zerocopy)
		memcpy(back.data(), hbuf[0].p, chunk);
	else
		CK(cudaMemcpy(back.data(), gbuf[0], chunk, cudaMemcpyDeviceToHost));
	bool match = !memcmp(back.data(), h.data(), chunk);

	std::vector<double> lat;
	for (int i = c.warmup; i < total; i++)
		lat.push_back((t_detect[i] - t_arrive[i]) * 1e3);
	double samples = (double)c.cpis * n;
	if (c.csv) {
		printf("%s,%d,%d,%.1f,%.1f,%d,%.3f,%.3f,%.1f,%s\n", c.path.c_str(),
			c.N, c.M, samples / elapsed / 1e6, samples / dma_s / 1e6,
			stalls, percentile(lat, 0.5), percentile(lat, 0.99),
			100 * cpu / elapsed, match ? "ok" : "MISMATCH");
	} else {
		printf("fpga mode, path %s: N=%d M=%d L=%d, ring %d CPIs, %d x %zu KiB DMAs per CPI%s\n",
			c.path.c_str(), c.N, c.M, c.L, c.ring, nchunks, chunk / 1024,
			rdma ? "" : (hbuf[0].huge ? ", host buffers on 2 MB huge pages" :
				", host buffers on 4 KiB pages"));
		printf("  FPGA DMA rate: %.1f MS/s (%.1f MB/s) while DMA active\n",
			samples / dma_s / 1e6, samples * 4 / dma_s / 1e6);
		printf("  end-to-end sustained: %.1f MS/s (%.1f MB/s), %d CPIs in %.3f s\n",
			samples / elapsed / 1e6, samples * 4 / elapsed / 1e6, c.cpis,
			elapsed);
		printf("  GPU kept up: %s (%d stalls, %.3f s total)\n",
			stalls ? "NO" : "yes", stalls, stall_s);
		printf("  CPI arrival -> detections: median %.3f ms, p99 %.3f ms\n",
			percentile(lat, 0.5), percentile(lat, 0.99));
		printf("  host CPU: %.1f%% of one core\n", 100 * cpu / elapsed);
		printf("  data check: %s\n", match ? "matches FPGA RAM" :
			"DOES NOT match FPGA RAM");
	}

	for (int b = 0; b < c.ring; b++) {
		if (rdma)
			unpin_chunks(f, handle[b]);
		if (gbuf[b])
			cudaFree(gbuf[b]);
		if (hbuf[b].p)
			host_free(hbuf[b]);
	}
	gpu_free(g);
	close(f.fd);
	return match ? 0 : 1;
}

/* ---------------------------------------------------------- emulate mode */

/*
 * Emulates a sample source faster than the Acorn's link, to measure GPUDirect
 * RDMA versus staging through host memory at higher ingest rates. A paced
 * "device" delivers CPIs chunk by chunk at --rate GB/s:
 *   staged  device threads write each chunk into pinned (huge page) host
 *           memory with non-temporal stores, which like DMA bypass the CPU
 *           caches; the control thread copies each chunk to the GPU as it
 *           arrives (cudaMemcpyAsync), then the GPU processes the CPI.
 *   direct  each chunk is written straight into GPU memory, with no host
 *           involvement (paced GPU memory writes, i.e. the same memory
 *           traffic as a device's RDMA writes), then the GPU processes it.
 * Reports the achieved rate, overruns (data arriving for a ring slot that is
 * still in use, i.e. sample loss in a real system), latency from a CPI's last
 * chunk to its detections, and the host time spent submitting each chunk.
 */

__attribute__((target("avx2")))
static void nt_copy(void *dst, const void *src, size_t bytes)
{
	__m256i *d = (__m256i *)dst;
	const __m256i *s = (const __m256i *)src;
	for (size_t i = 0; i < bytes / 32; i++)
		_mm256_stream_si256(d + i, _mm256_loadu_si256(s + i));
	_mm_sfence();
}

static void sleep_until(double t)
{
	for (;;) {
		double d = t - now_s();
		if (d <= 0)
			return;
		if (d > 200e-6)
			std::this_thread::sleep_for(
				std::chrono::microseconds((long)((d - 100e-6) * 1e6)));
	}
}

static int run_emulate(const Config &c)
{
	const bool staged = c.path == "staged";
	if (!staged && c.path != "direct") {
		fprintf(stderr, "emulate: --path must be staged or direct\n");
		return 1;
	}
	const size_t chunk = (size_t)c.chunk_kb << 10;
	const size_t n = (size_t)c.N * c.M;
	const size_t cpi_bytes = n * sizeof(short2);
	if (cpi_bytes % chunk || chunk % 32) {
		fprintf(stderr, "CPI size must be a multiple of the chunk size\n");
		return 1;
	}
	const int nchunks = cpi_bytes / chunk;
	const int ring = c.ring;
	const int total = c.warmup + c.cpis;
	const double rate = c.rate_gbs * 1e9;	/* bytes/s */

	Gpu g;
	Config c1 = c;
	c1.streams = ring;
	gpu_init(g, 0, c1);

	std::vector<short2> h;
	make_cpi(c, default_targets(c), 300.0, 7, h);

	std::vector<short2 *> gbuf(ring);
	std::vector<HostBuf> hbuf(ring);
	for (int b = 0; b < ring; b++) {
		CK(cudaMalloc(&gbuf[b], cpi_bytes));
		if (staged)
			hbuf[b] = host_alloc(cpi_bytes, cudaHostRegisterDefault);
	}
	cudaStream_t xs;	/* copies (staged) or device writes (direct) */
	CK(cudaStreamCreateWithFlags(&xs, cudaStreamNonBlocking));
	std::vector<cudaEvent_t> in_done(ring), proc_done(ring);
	for (int b = 0; b < ring; b++) {
		CK(cudaEventCreateWithFlags(&in_done[b], cudaEventDisableTiming));
		CK(cudaEventCreateWithFlags(&proc_done[b], cudaEventDisableTiming));
		CK(cudaEventRecord(proc_done[b], xs));
	}

	/*
	 * Host slot generations (staged): incremented when a CPI's copies out of
	 * the slot complete. CPI i may be written into slot i % ring once the
	 * slot's generation reaches i / ring.
	 */
	std::vector<std::atomic<long>> slot_gen(ring);
	for (auto &x : slot_gen)
		x = 0;
	auto on_copied = [](void *p) {
		((std::atomic<long> *)p)->fetch_add(1);
	};

	/* Chunk publication from the device threads: seq number per chunk */
	const long nall = (long)total * nchunks;
	std::vector<std::atomic<long>> ready(ring * nchunks);
	for (auto &x : ready)
		x = -1;
	std::vector<double> t_last(total), t_detect(total);
	std::atomic<long> overruns(0);
	std::atomic<bool> stop(false);
	const int nwriters = staged ? c.writers : 1;
	const double t0 = now_s() + 0.2;

	/*
	 * Device threads (staged): chunk k is written by thread k % nwriters at
	 * t0 + k * chunk / rate, into host slot (k / nchunks) % ring.
	 */
	auto writer = [&](int w) {
		for (long k = w; k < nall && !stop; k += nwriters) {
			int cpi = k / nchunks, ck = k % nchunks, b = cpi % ring;
			sleep_until(t0 + k * chunk / rate);
			if (slot_gen[b].load() < cpi / ring) {
				/* slot still being copied out: data would be lost */
				if (ck == 0)
					overruns++;
				while (slot_gen[b].load() < cpi / ring && !stop)
					;
			}
			nt_copy((char *)hbuf[b].p + ck * chunk,
				(const char *)h.data() + ck * chunk, chunk);
			ready[b * nchunks + ck].store(k);
		}
	};
	std::vector<std::thread> wt;
	if (staged)
		for (int w = 0; w < nwriters; w++)
			wt.emplace_back(writer, w);

	/* Control thread: route each chunk to the GPU, process each CPI */
	double start = 0, submit_s = 0;
	for (int i = 0; i < total; i++) {
		int b = i % ring;
		Lane &l = g.lanes[b];
		if (i == c.warmup) {
			start = now_s();
			submit_s = 0;
		}
		/* GPU buffer b must not be refilled until its last CPI is done */
		CK(cudaStreamWaitEvent(xs, proc_done[b], 0));
		for (int ck = 0; ck < nchunks; ck++) {
			long k = (long)i * nchunks + ck;
			char *dst = (char *)gbuf[b] + ck * chunk;
			if (staged) {
				while (ready[b * nchunks + ck].load() != k)
					;
				double ts = now_s();
				CK(cudaMemcpyAsync(dst, (char *)hbuf[b].p + ck * chunk,
					chunk, cudaMemcpyHostToDevice, xs));
				submit_s += now_s() - ts;
			} else {
				double due = t0 + k * chunk / rate;
				sleep_until(due);
				if (ck == 0 && i >= ring &&
						cudaEventQuery(proc_done[b]) ==
						cudaErrorNotReady)
					overruns++;
				/* device write: chunk-sized write into GPU memory */
				double ts = now_s();
				CK(cudaMemsetAsync(dst, k & 0xff, chunk, xs));
				submit_s += now_s() - ts;
			}
		}
		t_last[i] = now_s();
		if (staged)
			CK(cudaLaunchHostFunc(xs, on_copied, &slot_gen[b]));
		CK(cudaEventRecord(in_done[b], xs));
		CK(cudaStreamWaitEvent(l.s, in_done[b], 0));
		process_cpi(g, l, gbuf[b], false, nullptr);
		CK(cudaLaunchHostFunc(l.s, stamp_now, &t_detect[i]));
		CK(cudaEventRecord(proc_done[b], l.s));
	}
	CK(cudaDeviceSynchronize());
	double elapsed = now_s() - start;
	stop = true;
	for (auto &t : wt)
		t.join();

	std::vector<double> lat;
	double last_detect = 0;
	for (int i = c.warmup; i < total; i++) {
		lat.push_back((t_detect[i] - t_last[i]) * 1e3);
		last_detect = std::max(last_detect, t_detect[i]);
	}
	double bytes = (double)c.cpis * cpi_bytes;
	double achieved = bytes / (last_detect - start);
	(void)elapsed;
	printf("%s,%.1f,%.2f,%ld,%.3f,%.3f,%.1f,%s\n", c.path.c_str(),
		c.rate_gbs, achieved / 1e9, overruns.load(),
		percentile(lat, 0.5), percentile(lat, 0.99),
		1e6 * submit_s / ((double)c.cpis * nchunks),
		staged ? (hbuf[0].huge ? "hugepages" : "4k-pages") : "-");

	for (int b = 0; b < ring; b++) {
		cudaFree(gbuf[b]);
		if (staged)
			host_free(hbuf[b]);
	}
	gpu_free(g);
	return 0;
}

/* ----------------------------------------------------------- stream mode */

/* FPGA RAM region -> part of a pinned GPU buffer (GPUDirect RDMA) */
static void fpga_c2h_cuda_at(const Fpga &f, __u32 handle, size_t src,
	size_t len)
{
	struct picoevb_rdma_c2h_dma c2h = {};
	c2h.dst = handle;
	c2h.src = src;
	c2h.len = len;
	c2h.flags = PICOEVB_C2H_DMA_FLAG_DST_IS_CUDA;
	if (ioctl(f.fd, PICOEVB_IOC_C2H_DMA, &c2h)) {
		perror("ioctl(C2H_DMA to GPU)");
		exit(1);
	}
}

/* IQ generator registers (fpga-acorn-cle215/iq_gen.v), at BAR0 + 0x1000 */
enum {
	G_ID = 0x00, G_CONTROL = 0x04, G_RATE_INC = 0x08, G_LOG2N = 0x0C,
	G_NOISE = 0x10, G_T0_DELAY = 0x14, G_T0_DINC = 0x18, G_T0_AMP = 0x1C,
	G_T1_DELAY = 0x20, G_T1_DINC = 0x24, G_T1_AMP = 0x28, G_WRITE = 0x2C,
	G_READ = 0x30, G_OVERFLOWS = 0x34, G_STATUS = 0x38, G_CHIRP_LEN = 0x3C,
	G_LINK_RESETS = 0x40,
};
static const uint32_t GEN_ID = 0x49514731;
static const size_t GEN_BASE = 0x1000, BAR0_SIZE = 0x10000;
static const double GEN_CLOCK = 125e6;	/* AXI clock, 4 samples per word */

struct GenRegs {
	volatile uint32_t *p = nullptr;
	uint32_t rd(int off) { return p[off / 4]; }
	void wr(int off, uint32_t v) { p[off / 4] = v; }
};

static bool gen_map(const Fpga &f, GenRegs &g)
{
	void *m = mmap(nullptr, BAR0_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
		f.fd, 0);
	if (m == MAP_FAILED) {
		perror("mmap(BAR0)");
		return false;
	}
	g.p = (volatile uint32_t *)((char *)m + GEN_BASE);
	if (g.rd(G_ID) != GEN_ID) {
		fprintf(stderr, "no IQ generator (ID 0x%08x); flash the subsystem 0x0005 design\n",
			g.rd(G_ID));
		return false;
	}
	return true;
}

struct GenTarget {
	int range;	/* delay in samples, multiple of 4 */
	int doppler;	/* Doppler bin */
	int amp;	/* counts */
};

static std::vector<GenTarget> gen_targets(const Config &c)
{
	int nv = c.N - c.L + 1;
	return { { (nv / 5) & ~3, c.M / 8 + 1, 150 },
		 { (nv * 3 / 5) & ~3, c.M - 7, 60 } };
}

static uint32_t gen_dinc(const Config &c, int bin)
{
	return (uint32_t)(((uint64_t)bin << 32) / c.M);
}

/* Program the generator; returns the actual sample rate */
static double gen_setup(GenRegs &g, const Config &c,
	const std::vector<GenTarget> &t, double noise_sigma)
{
	g.wr(G_CONTROL, 0);
	g.wr(G_READ, 0);
	int log2n = 0;
	while ((1 << log2n) < c.N)
		log2n++;
	g.wr(G_LOG2N, log2n);
	g.wr(G_NOISE, (uint32_t)std::min(65535.0, noise_sigma / 0.57735 + 0.5));
	g.wr(G_T0_DELAY, t[0].range);
	g.wr(G_T0_DINC, gen_dinc(c, t[0].doppler));
	g.wr(G_T0_AMP, t[0].amp);
	g.wr(G_T1_DELAY, t[1].range);
	g.wr(G_T1_DINC, gen_dinc(c, t[1].doppler));
	g.wr(G_T1_AMP, t[1].amp);
	double words = c.gen_msps * 1e6 / 4 / GEN_CLOCK;	/* per clock */
	if (words >= 1.0) {
		g.wr(G_RATE_INC, 0);
		return GEN_CLOCK * 4;
	}
	uint32_t inc = (uint32_t)(words * 4294967296.0);
	g.wr(G_RATE_INC, inc);
	return inc / 4294967296.0 * GEN_CLOCK * 4;
}

/* paced: the DMA engine streams the ring by itself, paced by the generator */
static void gen_start(GenRegs &g, const Config &c, bool paced)
{
	bool full = c.gen_msps * 1e6 / 4 >= GEN_CLOCK;
	g.wr(G_CONTROL, 1 | (full ? 2 : 0) | (paced ? 4 : 0));
}

/* Does the FPGA design support DMA pacing (CONTROL[2])? */
static bool gen_has_pacing(GenRegs &g)
{
	g.wr(G_CONTROL, 4);
	bool ok = g.rd(G_CONTROL) & 4;
	g.wr(G_CONTROL, 0);
	return ok;
}

/*
 * Continuous DMA (PICOEVB_IOC_C2H_STREAM_*): a circular descriptor list
 * copies the FPGA ring into a ring of GPU buffers with no host involvement.
 */
struct DmaStream {
	std::vector<picoevb_rdma_c2h_stream_buf> bufs;
	uint32_t n_descs = 0;
	/* completed-descriptor count at which CPI i is in GPU memory */
	uint32_t end(int64_t i) const
	{
		int ring = bufs.size();
		return (uint32_t)((uint64_t)(i / ring) * n_descs +
			bufs[i % ring].last_desc + 1);
	}
};

static DmaStream stream_start(const Fpga &f,
	const std::vector<std::vector<__u32>> &handle)
{
	DmaStream ds;
	for (const auto &h : handle) {
		picoevb_rdma_c2h_stream_buf b = {};
		b.handle = h[0];
		ds.bufs.push_back(b);
	}
	picoevb_rdma_c2h_stream_start st = {};
	st.bufs = (__u64)ds.bufs.data();
	st.n_bufs = ds.bufs.size();
	st.ring_size = f.chunk;
	if (ioctl(f.fd, PICOEVB_IOC_C2H_STREAM_START, &st)) {
		perror("ioctl(C2H_STREAM_START)");
		exit(1);
	}
	ds.n_descs = st.n_descs;
	return ds;
}

static uint32_t stream_completed(const Fpga &f, uint32_t *status = nullptr)
{
	picoevb_rdma_c2h_stream_status st;
	if (ioctl(f.fd, PICOEVB_IOC_C2H_STREAM_STATUS, &st)) {
		perror("ioctl(C2H_STREAM_STATUS)");
		exit(1);
	}
	if (status)
		*status = st.status;
	return st.completed_descs;
}

/*
 * Wait until the DMA has completed `target` descriptors; false on timeout.
 * Poll every ~20 us rather than spinning: a real-time thread that spins is
 * throttled by the kernel (sched_rt_runtime_us, by default 95% of each
 * second), which here would freeze the loop for ~50 ms every second.
 */
static bool stream_wait(const Fpga &f, uint32_t target, double timeout_s)
{
	double t0 = now_s();
	for (;;) {
		uint32_t done = stream_completed(f);
		if ((int32_t)(done - target) >= 0)
			return true;
		std::this_thread::sleep_for(std::chrono::microseconds(20));
		if (now_s() - t0 > timeout_s) {
			uint32_t status;
			done = stream_completed(f, &status);
			fprintf(stderr, "DMA stream stalled: %u of %u descriptors done, engine status 0x%08x\n",
				done, target, status);
			return false;
		}
	}
}

static void stream_stop(const Fpga &f)
{
	if (ioctl(f.fd, PICOEVB_IOC_C2H_STREAM_STOP))
		perror("ioctl(C2H_STREAM_STOP)");
}

/* ------------------------------------------------ live dashboard telemetry */

/*
 * Max-pool the power of a CPI's range-Doppler map (rd: [range][Doppler]) into
 * W range columns: out[x * M + p].
 */
__global__ void k_thumb(const cufftComplex *rd, float *out, int nvalid, int M,
	int W)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx >= W * M)
		return;
	int x = idx / M, p = idx % M;
	int r0 = (int)((long long)x * nvalid / W);
	int r1 = (int)((long long)(x + 1) * nvalid / W);
	float m = 0;
	for (int r = r0; r < r1; r++) {
		cufftComplex v = rd[(size_t)r * M + p];
		m = fmaxf(m, v.x * v.x + v.y * v.y);
	}
	out[idx] = m;
}

static const int TELE_W = 512;		/* range columns in the map */
static const int TELE_IQ = 1024;	/* raw samples per frame */
static const int TELE_DETS = 256;	/* detections per frame, at most */

struct TeleStats {
	double t;			/* s since the stream started */
	uint64_t words;			/* generator words written */
	long cpis_checked, cpis_ok, hits[2], false_alarms;
	int overruns, stalls;
	uint32_t overflows;
	double lat_p50, lat_p99;	/* ms, recent CPIs */
};

/*
 * Sends a snapshot of the pipeline a few times a second, as one JSON line
 * per frame over TCP, to the dashboard server (dashboard/server.py). The
 * streaming loop only enqueues a frame's GPU work when the sender thread is
 * idle, and never waits for it.
 */
struct Telemetry {
	std::string ip;
	int port = 0;
	int sock = -1;
	double next_connect = 0;
	std::atomic<bool> busy{false};
	std::mutex m;
	std::condition_variable cv;
	bool ready = false, quit = false;
	std::thread th;

	/* the frame being sent; written by the loop while !busy */
	float *d_thumb = nullptr, *h_thumb = nullptr;
	short2 *h_iq = nullptr;
	int iq_start = 0;
	Lane *lane = nullptr;
	Det dets[TELE_DETS];
	unsigned ndets = 0, ndets_total = 0;
	long cpi = 0;
	bool truth_valid = false;
	std::vector<GenTarget> truth;
	TeleStats st = {};

	int N = 0, M = 0, L = 0, nvalid = 0, r_begin = 0, r_end = 0;
	double rate = 0, noise = 0, move = 0;
};

/* CUDA host callback: the frame's GPU copies are done */
static void CUDART_CB tele_frame_ready(void *p)
{
	Telemetry *T = (Telemetry *)p;
	T->ndets_total = std::min<unsigned>(*T->lane->h_ndets, MAX_DETS);
	T->ndets = std::min<unsigned>(T->ndets_total, TELE_DETS);
	memcpy(T->dets, T->lane->h_dets, T->ndets * sizeof(Det));
	std::lock_guard<std::mutex> lk(T->m);
	T->ready = true;
	T->cv.notify_one();
}

static std::string base64(const uint8_t *p, size_t n)
{
	static const char *tab =
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	std::string o;
	o.reserve((n + 2) / 3 * 4);
	for (size_t i = 0; i < n; i += 3) {
		uint32_t v = p[i] << 16;
		if (i + 1 < n)
			v |= p[i + 1] << 8;
		if (i + 2 < n)
			v |= p[i + 2];
		o += tab[v >> 18];
		o += tab[(v >> 12) & 63];
		o += i + 1 < n ? tab[(v >> 6) & 63] : '=';
		o += i + 2 < n ? tab[v & 63] : '=';
	}
	return o;
}

/* Send one frame, (re)connecting at most once a second; drops on failure */
static void tele_send(Telemetry &T, const std::string &msg)
{
	double now = now_s();
	if (T.sock < 0) {
		if (now < T.next_connect)
			return;
		T.next_connect = now + 1.0;
		int fd = socket(AF_INET, SOCK_STREAM, 0);
		sockaddr_in a = {};
		a.sin_family = AF_INET;
		a.sin_port = htons(T.port);
		if (fd < 0 || inet_pton(AF_INET, T.ip.c_str(), &a.sin_addr) != 1 ||
				connect(fd, (sockaddr *)&a, sizeof(a))) {
			if (fd >= 0)
				close(fd);
			return;
		}
		T.sock = fd;
	}
	size_t off = 0;
	while (off < msg.size()) {
		ssize_t w = send(T.sock, msg.data() + off, msg.size() - off,
			MSG_NOSIGNAL);
		if (w <= 0) {
			close(T.sock);
			T.sock = -1;
			return;
		}
		off += w;
	}
}

static void tele_thread(Telemetry *T)
{
	const int n = TELE_W * T->M;
	std::vector<float> db(n), tmp(n);
	std::vector<uint8_t> q(n);
	char b[512];
	for (;;) {
		{
			std::unique_lock<std::mutex> lk(T->m);
			T->cv.wait(lk, [&] { return T->ready || T->quit; });
			if (T->quit)
				return;
			T->ready = false;
		}
		/* Map in dB, from just below the noise floor (median) up */
		for (int i = 0; i < n; i++)
			db[i] = 10 * log10f(T->h_thumb[i] + 1e-6f);
		tmp = db;
		std::nth_element(tmp.begin(), tmp.begin() + n / 2, tmp.end());
		float lo = tmp[n / 2] - 3;
		float hi = std::max(*std::max_element(db.begin(), db.end()),
			lo + 30);
		for (int i = 0; i < n; i++)
			q[i] = (uint8_t)std::min(255.0f, std::max(0.0f,
				(db[i] - lo) / (hi - lo) * 255 + 0.5f));

		const TeleStats &st = T->st;
		std::string o;
		o.reserve(120000);
		snprintf(b, sizeof(b),
			"{\"cpi\":%ld,\"N\":%d,\"M\":%d,\"L\":%d,\"nvalid\":%d,\"r_begin\":%d,\"r_end\":%d,"
			"\"rate\":%.0f,\"noise\":%.1f,\"move\":%.1f,",
			T->cpi, T->N, T->M, T->L, T->nvalid, T->r_begin, T->r_end,
			T->rate, T->noise, T->move);
		o += b;
		snprintf(b, sizeof(b),
			"\"stats\":{\"t\":%.3f,\"words\":%llu,\"cpis_checked\":%ld,\"cpis_ok\":%ld,"
			"\"hits\":[%ld,%ld],\"false_alarms\":%ld,\"overruns\":%d,\"stalls\":%d,"
			"\"overflows\":%u,\"lat_p50\":%.3f,\"lat_p99\":%.3f},",
			st.t, (unsigned long long)st.words, st.cpis_checked,
			st.cpis_ok, st.hits[0], st.hits[1], st.false_alarms,
			st.overruns, st.stalls, st.overflows, st.lat_p50,
			st.lat_p99);
		o += b;
		o += "\"truth_valid\":";
		o += T->truth_valid ? "true" : "false";
		o += ",\"truth\":[";
		for (size_t k = 0; k < T->truth.size(); k++) {
			snprintf(b, sizeof(b), "%s[%d,%d,%d]", k ? "," : "",
				T->truth[k].range, T->truth[k].doppler,
				T->truth[k].amp);
			o += b;
		}
		snprintf(b, sizeof(b), "],\"ndets_total\":%u,\"dets\":[",
			T->ndets_total);
		o += b;
		for (unsigned k = 0; k < T->ndets; k++) {
			const Det &d = T->dets[k];
			snprintf(b, sizeof(b), "%s[%d,%d,%.1f,%.1f]", k ? "," : "",
				d.range, d.doppler, 10 * log10f(d.power + 1e-30f),
				10 * log10f(d.power / (d.noise + 1e-30f)));
			o += b;
		}
		snprintf(b, sizeof(b), "],\"iq_start\":%d,\"iq\":[", T->iq_start);
		o += b;
		for (int k = 0; k < TELE_IQ; k++) {
			snprintf(b, sizeof(b), "%s%d,%d", k ? "," : "",
				T->h_iq[k].x, T->h_iq[k].y);
			o += b;
		}
		snprintf(b, sizeof(b),
			"],\"map\":{\"w\":%d,\"h\":%d,\"lo\":%.1f,\"hi\":%.1f,\"data\":\"",
			TELE_W, T->M, lo, hi);
		o += b;
		o += base64(q.data(), n);
		o += "\"}}\n";
		tele_send(*T, o);
		T->busy = false;
	}
}

/* Ctrl-C ends a stream run cleanly (the run summary is still printed) */
static std::atomic<bool> g_stop{false};

static void on_stop_signal(int)
{
	g_stop = true;
}

/* Tracks the generator's 32-bit word counter as a 64-bit count */
struct WordCounter {
	uint32_t last = 0;
	uint64_t total = 0;
	uint64_t update(GenRegs &g)
	{
		uint32_t w = g.rd(G_WRITE);
		total += (uint32_t)(w - last);
		last = w;
		return total;
	}
};

/* Bit-exact software model of iq_gen.v with no noise */
static void gen_model(const Config &c, const std::vector<GenTarget> &t,
	int pulses, std::vector<short2> &out)
{
	auto rnd = [](double x) { return (int)floor(x + 0.5); };
	std::vector<int> ci(c.L), cq(c.L), cs(1024), sn(1024);
	for (int n = 0; n < c.L; n++) {
		double tt = n - c.L / 2.0;
		double ph = M_PI * 0.8 * tt * tt / c.L;
		ci[n] = rnd(32000 * cos(ph));
		cq[n] = rnd(32000 * sin(ph));
	}
	for (int a = 0; a < 1024; a++) {
		cs[a] = rnd(32767 * cos(2 * M_PI * a / 1024));
		sn[a] = rnd(32767 * sin(2 * M_PI * a / 1024));
	}
	out.assign((size_t)pulses * c.N, make_short2(0, 0));
	for (int p = 0; p < pulses; p++) {
		for (const GenTarget &x : t) {
			uint32_t ph = (uint32_t)(p * (uint64_t)gen_dinc(c, x.doppler));
			int idx = ph >> 22;
			int64_t rr = ((int64_t)x.amp * cs[idx]) >> 15;
			int64_t ri = ((int64_t)x.amp * sn[idx]) >> 15;
			for (int n = 0; n < c.L && x.range + n < c.N; n++) {
				int64_t er = (ci[n] * rr - cq[n] * ri) >> 15;
				int64_t ei = (ci[n] * ri + cq[n] * rr) >> 15;
				short2 &s = out[(size_t)p * c.N + x.range + n];
				s.x = (short)std::max<int64_t>(-32768,
					std::min<int64_t>(32767, s.x + er));
				s.y = (short)std::max<int64_t>(-32768,
					std::min<int64_t>(32767, s.y + ei));
			}
		}
	}
}

static int run_stream(Config c)
{
	Fpga f;
	if (!fpga_open(f))
		return 1;
	GenRegs gen;
	if (!gen_map(f, gen))
		return 1;
	/* resets the FPGA's PCIe link watchdog needed to bring the link up */
	printf("FPGA PCIe link watchdog resets since power-on: %u\n",
		gen.rd(G_LINK_RESETS));
	int chirp_len = gen.rd(G_CHIRP_LEN);
	if (c.L != chirp_len) {
		printf("using L=%d, the generator's chirp length\n", chirp_len);
		c.L = chirp_len;
	}
	/* The FPGA RAM is a ring of nreg regions, DMA'd out one at a time */
	const size_t region = c.region_kb ? (size_t)c.region_kb << 10 :
		f.chunk / 2;
	if (region < 65536 || f.chunk % region) {
		fprintf(stderr, "--region-kb must divide %zu KiB, >= 64\n",
			f.chunk / 1024);
		return 1;
	}
	const int nreg = f.chunk / region;
	const uint64_t region_words = region / 16;
	const size_t cpi_bytes = (size_t)c.N * c.M * sizeof(short2);
	if (cpi_bytes % region) {
		fprintf(stderr, "CPI size must be a multiple of %zu KiB\n",
			region / 1024);
		return 1;
	}
	const int rpc = cpi_bytes / region;		/* regions per CPI */
	auto targets = gen_targets(c);
	const bool paced = c.dma == "stream";
	if (paced && !gen_has_pacing(gen)) {
		fprintf(stderr, "this FPGA design can't pace a DMA stream; use --dma ioctl or flash the current design\n");
		return 1;
	}
	if (paced && cpi_bytes % f.chunk) {
		fprintf(stderr, "--dma stream needs the CPI size to be a multiple of %zu KiB\n",
			f.chunk / 1024);
		return 1;
	}

	Gpu g;
	Config c1 = c;
	c1.streams = c.ring;
	gpu_init(g, 0, c1);
	std::vector<short2 *> gbuf(c.ring);
	std::vector<std::vector<__u32>> handle(c.ring);
	for (int b = 0; b < c.ring; b++) {
		CK(cudaMalloc(&gbuf[b], cpi_bytes));
		/* A stream maps each whole buffer; ioctl DMAs go by region */
		handle[b] = pin_chunks(f, gbuf[b], cpi_bytes,
			paced ? cpi_bytes : region);
	}
	std::vector<cudaEvent_t> done(c.ring);
	for (auto &e : done)
		CK(cudaEventCreateWithFlags(&e, cudaEventDisableTiming));
	/* stream: the GPU has finished reading the buffer (no host callback) */
	std::vector<cudaEvent_t> consumed(c.ring);
	for (auto &e : consumed)
		CK(cudaEventCreateWithFlags(&e, cudaEventDisableTiming));

	if (c.gen_check) {
		/* One CPI with no noise, compared with the software model */
		double rate = gen_setup(gen, c, targets, 0.0);
		if (paced) {
			gen_start(gen, c, true);
			DmaStream ds = stream_start(f, handle);
			bool ok = stream_wait(f, ds.end(0), 5.0);
			/* Stop the engine while the generator still feeds it */
			stream_stop(f);
			gen.wr(G_CONTROL, 0);
			if (!ok)
				return 1;
		} else {
			gen_start(gen, c, false);
			WordCounter wc;
			for (int k = 0; k < rpc; k++) {
				while (wc.update(gen) < (k + 1) * region_words)
					;
				fpga_c2h_cuda_at(f, handle[0][k], (k % nreg) * region,
					region);
				gen.wr(G_READ, (uint32_t)((k + 1) * region_words));
			}
			gen.wr(G_CONTROL, 0);
		}
		std::vector<short2> hw((size_t)c.N * c.M), model;
		CK(cudaMemcpy(hw.data(), gbuf[0], cpi_bytes, cudaMemcpyDeviceToHost));
		gen_model(c, targets, c.M, model);
		size_t bad = 0, nonzero = 0;
		for (size_t i = 0; i < hw.size(); i++) {
			if (hw[i].x != model[i].x || hw[i].y != model[i].y) {
				if (bad < 5)
					printf("  sample %zu (pulse %zu, n %zu): hw (%d, %d) model (%d, %d)\n",
						i, i / c.N, i % c.N, hw[i].x, hw[i].y,
						model[i].x, model[i].y);
				bad++;
			}
			nonzero += model[i].x || model[i].y;
		}
		printf("gen-check: N=%d M=%d at %.1f MS/s, overflows %u: %zu of %zu samples differ from the model (%zu nonzero)\n",
			c.N, c.M, rate / 1e6, gen.rd(G_OVERFLOWS), bad, hw.size(),
			nonzero);
		return bad ? 1 : 0;
	}

	double rate = gen_setup(gen, c, targets, c.noise);
	int total = c.warmup + c.cpis;
	std::vector<double> t_arrive(total), t_detect(total);
	int stalls = 0, cpis_ok = 0, cpis_checked = 0;
	/* stream: CPIs whose buffer the DMA reached before the GPU was done */
	int overruns = 0;
	bool stalled = false;
	long false_alarms = 0, hits[2] = {0, 0};
	double stall_s = 0;
	WordCounter wc;

	/*
	 * With --move, the targets' ranges change during the run (one closing,
	 * one opening). A change written to the generator when CPI i arrives
	 * lands in CPI i + 1 (the generator is at most half a CPI ahead of the
	 * DMA), so CPIs i + 1 and i + 2 aren't scored.
	 */
	struct Truth {
		std::vector<GenTarget> t;
		bool valid;
	};
	const int TRUTH_HIST = 64;
	if (c.ring >= TRUTH_HIST) {
		fprintf(stderr, "--ring must be < %d\n", TRUTH_HIST);
		return 1;
	}
	std::vector<Truth> truth(TRUTH_HIST);
	std::vector<GenTarget> cur = targets;
	long last_move = -100;
	const double cpi_rate = rate / ((double)c.N * c.M);
	const int move_every = c.move > 0 ?
		std::max(1, (int)lround(4 / c.move * cpi_rate)) : 0;
	const int range_lo = (g.r_begin + 7) & ~3;
	const int range_hi = (g.r_end - 8) & ~3;

	std::vector<double> recent_lat(256, 0.0);
	long n_lat = 0;

	auto check = [&](int cpi, Lane &l) {
		if (cpi < c.warmup)
			return;
		recent_lat[n_lat++ % recent_lat.size()] =
			(t_detect[cpi] - t_arrive[cpi]) * 1e3;
		const Truth &tr = truth[cpi % TRUTH_HIST];
		if (!tr.valid)
			return;
		unsigned nd = std::min<unsigned>(*l.h_ndets, MAX_DETS);
		int found = 0;
		for (size_t k = 0; k < tr.t.size(); k++)
			for (unsigned i = 0; i < nd; i++)
				if (abs(l.h_dets[i].range - tr.t[k].range) <= 1 &&
						l.h_dets[i].doppler == tr.t[k].doppler) {
					found++;
					if (k < 2)
						hits[k]++;
					break;
				}
		cpis_checked++;
		cpis_ok += found == (int)tr.t.size();
		false_alarms += nd - found;
	};

	/* Record CPI i's truth, then maybe move the targets (see above) */
	auto on_arrival = [&](int i) {
		truth[i % TRUTH_HIST] = { cur, i - last_move > 2 };
		if (!move_every || i == 0 || i % move_every)
			return;
		cur[0].range -= 4;
		if (cur[0].range < range_lo)
			cur[0].range = range_hi;
		cur[1].range += 4;
		if (cur[1].range > range_hi)
			cur[1].range = range_lo;
		gen.wr(G_T0_DELAY, cur[0].range);
		gen.wr(G_T1_DELAY, cur[1].range);
		last_move = i;
	};

	Telemetry T;
	int tele_every = 0;
	if (!c.telemetry.empty()) {
		size_t colon = c.telemetry.rfind(':');
		if (colon == std::string::npos) {
			fprintf(stderr, "--telemetry needs ip:port\n");
			return 1;
		}
		T.ip = c.telemetry.substr(0, colon);
		T.port = atoi(c.telemetry.c_str() + colon + 1);
		T.N = c.N;
		T.M = c.M;
		T.L = c.L;
		T.nvalid = c.N - c.L + 1;
		T.r_begin = g.r_begin;
		T.r_end = g.r_end;
		T.rate = rate;
		T.noise = c.noise;
		T.move = c.move;
		CK(cudaMalloc(&T.d_thumb, TELE_W * c.M * sizeof(float)));
		CK(cudaMallocHost(&T.h_thumb, TELE_W * c.M * sizeof(float)));
		CK(cudaMallocHost(&T.h_iq, TELE_IQ * sizeof(short2)));
		tele_every = std::max(1, (int)lround(cpi_rate / c.tele_hz));
		/* before this thread goes real-time: threads inherit that */
		T.th = std::thread(tele_thread, &T);
	}
	/* Enqueue a dashboard frame for CPI i, if the sender is free */
	auto tele_frame = [&](int i, Lane &l, const short2 *raw) {
		if (!tele_every || i % tele_every || T.busy)
			return;
		T.busy = true;
		T.lane = &l;
		T.cpi = i;
		T.truth = truth[i % TRUTH_HIST].t;
		T.truth_valid = truth[i % TRUTH_HIST].valid;
		TeleStats &st = T.st;
		st.t = now_s() - t_arrive[0];
		st.words = wc.total;
		st.cpis_checked = cpis_checked;
		st.cpis_ok = cpis_ok;
		st.hits[0] = hits[0];
		st.hits[1] = hits[1];
		st.false_alarms = false_alarms;
		st.overruns = overruns;
		st.stalls = stalls;
		st.overflows = gen.rd(G_OVERFLOWS);
		std::vector<double> lat(recent_lat.begin(), recent_lat.begin() +
			std::min<long>(n_lat, recent_lat.size()));
		st.lat_p50 = lat.empty() ? 0 : percentile(lat, 0.5);
		st.lat_p99 = lat.empty() ? 0 : percentile(lat, 0.99);
		/* raw IQ from the first pulse, starting a little before target 0 */
		T.iq_start = std::min(std::max(0, T.truth[0].range - 256),
			c.N - TELE_IQ);
		k_thumb<<<(TELE_W * c.M + 255) / 256, 256, 0, l.s>>>(l.b,
			T.d_thumb, c.N - c.L + 1, c.M, TELE_W);
		CK(cudaMemcpyAsync(T.h_thumb, T.d_thumb,
			TELE_W * c.M * sizeof(float), cudaMemcpyDeviceToHost, l.s));
		CK(cudaMemcpyAsync(T.h_iq, raw + T.iq_start,
			TELE_IQ * sizeof(short2), cudaMemcpyDeviceToHost, l.s));
		CK(cudaLaunchHostFunc(l.s, tele_frame_ready, &T));
	};
	signal(SIGINT, on_stop_signal);
	signal(SIGTERM, on_stop_signal);

	/*
	 * The FPGA ring holds only ~1 ms of samples, so keep the streaming loop
	 * from being preempted: real-time priority, pinned to one CPU.
	 */
	bool rt = false;
	/*
	 * Threads inherit their creator's scheduling policy and affinity, so
	 * make CUDA create its host callback thread now, before this thread
	 * becomes real-time; otherwise that thread competes with this busy loop
	 * on the same CPU at the same priority, and starves.
	 */
	CK(cudaLaunchHostFunc(g.lanes[0].s, stamp_now, &t_detect[0]));
	CK(cudaDeviceSynchronize());
	if (c.rt_cpu >= 0) {
		cpu_set_t set;
		CPU_ZERO(&set);
		CPU_SET(c.rt_cpu, &set);
		struct sched_param sp = {};
		sp.sched_priority = 50;
		rt = !sched_setaffinity(0, sizeof(set), &set) &&
			!sched_setscheduler(0, SCHED_FIFO, &sp);
		if (!rt)
			perror("real-time scheduling (continuing without)");
	}
	std::vector<double> dma_us, lag_us, lag0_us, pre_us, post_us;
	dma_us.reserve((size_t)total * rpc);
	lag_us.reserve((size_t)total * rpc);
	gen_start(gen, c, paced);
	DmaStream ds;
	if (paced)
		ds = stream_start(f, handle);
	double start = now_s();
	for (int i = 0; i < total; i++) {
		if (g_stop) {
			total = i;
			break;
		}
		int b = i % c.ring;
		Lane &l = g.lanes[b];
		double tp = now_s();
		/*
		 * The DMA starts overwriting buffer b once CPI i - 1 is in; if
		 * the GPU is still processing CPI i - ring from it by then, that
		 * CPI may have been corrupted.
		 */
		if (paced && i >= c.ring &&
				cudaEventQuery(consumed[b]) == cudaErrorNotReady &&
				(int32_t)(stream_completed(f) - ds.end(i - 1)) >= 0)
			overruns++;
		if (i >= c.ring) {
			if (cudaEventQuery(done[b]) == cudaErrorNotReady) {
				double t = now_s();
				CK(cudaEventSynchronize(done[b]));
				stall_s += now_s() - t;
				stalls++;
			}
			check(i - c.ring, l);
		}
		pre_us.push_back((now_s() - tp) * 1e6);
		if (paced) {
			if (!stream_wait(f, ds.end(i), 2.0)) {
				stalled = true;
				break;
			}
			t_arrive[i] = now_s();
			wc.update(gen);		/* often enough not to miss a wrap */
			on_arrival(i);
			/* overwritten already, before processing even starts */
			if ((int32_t)(stream_completed(f) - ds.end(i + c.ring - 1)) >= 0)
				overruns++;
			process_cpi(g, l, gbuf[b], true, nullptr);
			CK(cudaLaunchHostFunc(l.s, stamp_now, &t_detect[i]));
			tele_frame(i, l, gbuf[b]);
			CK(cudaEventRecord(consumed[b], l.s));
			CK(cudaEventRecord(done[b], l.s));
			post_us.push_back((now_s() - t_arrive[i]) * 1e6);
			continue;
		}
		for (int k = 0; k < rpc; k++) {
			uint64_t r = (uint64_t)i * rpc + k;
			while (wc.update(gen) < (r + 1) * region_words)
				;
			/* how far the generator is ahead of this DMA */
			double lead = (wc.total - (r + 1) * region_words) * 4 /
				rate * 1e6;
			lag_us.push_back(lead);
			if (k == 0)
				lag0_us.push_back(lead);
			double t0 = now_s();
			fpga_c2h_cuda_at(f, handle[b][k], (r % nreg) * region, region);
			dma_us.push_back((now_s() - t0) * 1e6);
			gen.wr(G_READ, (uint32_t)((r + 1) * region_words));
		}
		t_arrive[i] = now_s();
		on_arrival(i);
		process_cpi(g, l, gbuf[b], true, nullptr);
		CK(cudaLaunchHostFunc(l.s, stamp_now, &t_detect[i]));
		tele_frame(i, l, gbuf[b]);
		CK(cudaEventRecord(done[b], l.s));
		post_us.push_back((now_s() - t_arrive[i]) * 1e6);
	}
	CK(cudaDeviceSynchronize());
	double elapsed = now_s() - start;
	uint64_t words = wc.update(gen);
	uint32_t overflows = gen.rd(G_OVERFLOWS);
	/* Stop the engine while the generator still feeds it */
	if (paced)
		stream_stop(f);
	gen.wr(G_CONTROL, 0);
	if (T.th.joinable()) {
		{
			std::lock_guard<std::mutex> lk(T.m);
			T.quit = true;
		}
		T.cv.notify_one();
		T.th.join();
		if (T.sock >= 0)
			close(T.sock);
	}
	if (stalled)
		return 1;
	for (int i = std::max(0, total - c.ring); i < total; i++)
		check(i, g.lanes[i % c.ring]);

	std::vector<double> lat;
	for (int i = c.warmup; i < total; i++)
		lat.push_back((t_detect[i] - t_arrive[i]) * 1e3);
	if (lat.empty())
		lat.push_back(0);
	if (dma_us.empty())
		dma_us.push_back(0), lag_us.push_back(0), lag0_us.push_back(0);
	if (pre_us.empty())
		pre_us.push_back(0), post_us.push_back(0);
	printf("stream: FPGA IQ generator -> GPUDirect RDMA -> GPU radar pipeline\n");
	if (paced)
		printf("  N=%d M=%d L=%d, CPI %.2f ms, continuous DMA: %u descriptors over a ring of %d CPI buffers\n",
			c.N, c.M, c.L, 1e3 * c.N * c.M / rate, ds.n_descs, c.ring);
	else
		printf("  N=%d M=%d L=%d, CPI %.2f ms, %d x %zu KiB DMAs per CPI, ring %d\n",
			c.N, c.M, c.L, 1e3 * c.N * c.M / rate, rpc, region / 1024,
			c.ring);
	printf("  generator: set %.1f MS/s, measured %.1f MS/s (%.1f MB/s) over %.2f s\n",
		rate / 1e6, words * 4 / elapsed / 1e6, words * 16 / elapsed / 1e6,
		elapsed);
	printf("  samples lost (FPGA ring overflows): %llu words\n",
		(unsigned long long)overflows);
	printf("  GPU stalls: %d (%.3f s)\n", stalls, stall_s);
	if (paced) {
		printf("  GPU buffers overwritten before processed: %d; real-time scheduling %s\n",
			overruns, rt ? "on" : "off");
		printf("  per-CPI host work: GPU enqueue p99 %.0f us max %.0f us\n",
			percentile(post_us, 0.99), percentile(post_us, 1.0));
	} else {
		printf("  ring: %d x %zu KiB regions; slack before overflow %.0f us; real-time scheduling %s\n",
			nreg, region / 1024,
			(nreg - 1) * region_words * 4 / rate * 1e6,
			rt ? "on" : "off");
		printf("  per-region DMA: p50 %.0f us, p99 %.0f us, max %.0f us; generator lead at DMA start: p50 %.0f us, p99 %.0f us, max %.0f us\n",
			percentile(dma_us, 0.5), percentile(dma_us, 0.99),
			percentile(dma_us, 1.0), percentile(lag_us, 0.5),
			percentile(lag_us, 0.99), percentile(lag_us, 1.0));
		printf("  per-CPI host work: before DMAs p99 %.0f us max %.0f us; GPU enqueue p99 %.0f us max %.0f us; lead at a CPI's first DMA: p99 %.0f us max %.0f us\n",
			percentile(pre_us, 0.99), percentile(pre_us, 1.0),
			percentile(post_us, 0.99), percentile(post_us, 1.0),
			percentile(lag0_us, 0.99), percentile(lag0_us, 1.0));
	}
	printf("  CPIs with both targets detected: %d / %d; other detections %.1f per CPI\n",
		cpis_ok, cpis_checked, cpis_checked ?
			(double)false_alarms / cpis_checked : 0.0);
	printf("  targets: (range %d, Doppler %d, amp %d), (range %d, Doppler %d, amp %d), noise sigma %.0f\n",
		targets[0].range, targets[0].doppler, targets[0].amp,
		targets[1].range, targets[1].doppler, targets[1].amp, c.noise);
	printf("  CPI complete -> detections: median %.3f ms, p99 %.3f ms\n",
		percentile(lat, 0.5), percentile(lat, 0.99));
	bool pass = overflows == 0 && overruns == 0 && cpis_ok == cpis_checked;
	printf("  REAL-TIME: %s\n", pass ?
		"PASS (no samples lost, every CPI's targets detected)" : "FAIL");

	for (int b = 0; b < c.ring; b++) {
		unpin_chunks(f, handle[b]);
		cudaFree(gbuf[b]);
	}
	gpu_free(g);
	close(f.fd);
	return pass ? 0 : 1;
}

/* ----------------------------------------------------------------- main */

static void usage()
{
	fprintf(stderr,
		"usage: radar-bench [gpu|fpga|stream|ingest|emulate|verify] [options]\n"
		"  --N n        range samples per pulse (power of 2, default 4096)\n"
		"  --M m        pulses per CPI (default 128)\n"
		"  --L l        chirp length (default 512)\n"
		"  --gpus g     GPUs to use, gpu mode (default 1)\n"
		"  --streams s  CUDA streams per GPU (default 3)\n"
		"  --cpis k     CPIs to time (default 200)\n"
		"  --ring r     fpga mode: ring size in CPIs (default 3)\n"
		"  --path p     fpga mode: rdma, staged or zerocopy (default rdma)\n"
		"  --ingest-mb m  ingest mode: MiB moved per path (default 512)\n"
		"  --rate r     emulate mode: source rate in GB/s (default 1.4)\n"
		"  --chunk-kb k emulate mode: chunk size (default 1024)\n"
		"  --writers w  emulate mode: source threads, staged (default 4)\n"
		"  (emulate mode uses --path staged or direct)\n"
		"  --rate-msps r  stream mode: FPGA generator rate, MS/s (default 250)\n"
		"  --noise s    stream mode: noise sigma in counts (default 300)\n"
		"  --gen-check  stream mode: compare one noiseless CPI with a model\n"
		"  --region-kb k  stream mode: DMA region size (default half the RAM)\n"
		"  --rt-cpu c   stream mode: real-time CPU for the loop (-1 = off, default 2)\n"
		"  --dma d      stream mode: stream (continuous, FPGA-paced; default) or ioctl\n"
		"  --telemetry ip:port  stream mode: send frames to the dashboard server\n"
		"  --move v     stream mode: move the targets at v range bins/s\n"
		"  --pfa p      CFAR false alarm probability (default 1e-6)\n"
		"  --csv        gpu/fpga mode: one CSV line\n"
		"  --classic-cfar  separate power and CFAR kernels\n");
	exit(1);
}

int main(int argc, char **argv)
{
	Config c;
	int i = 1;
	if (i < argc && argv[i][0] != '-')
		c.mode = argv[i++];
	for (; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() {
			if (i + 1 >= argc)
				usage();
			return argv[++i];
		};
		if (a == "--N") c.N = atoi(next());
		else if (a == "--M") c.M = atoi(next());
		else if (a == "--L") c.L = atoi(next());
		else if (a == "--gpus") c.gpus = atoi(next());
		else if (a == "--streams") c.streams = atoi(next());
		else if (a == "--cpis") c.cpis = atoi(next());
		else if (a == "--ring") c.ring = atoi(next());
		else if (a == "--pfa") c.pfa = atof(next());
		else if (a == "--csv") c.csv = true;
		else if (a == "--classic-cfar") c.fused_cfar = false;
		else if (a == "--path") c.path = next();
		else if (a == "--ingest-mb") c.ingest_mb = atoi(next());
		else if (a == "--rate") c.rate_gbs = atof(next());
		else if (a == "--chunk-kb") c.chunk_kb = atoi(next());
		else if (a == "--writers") c.writers = atoi(next());
		else if (a == "--rate-msps") c.gen_msps = atof(next());
		else if (a == "--noise") c.noise = atof(next());
		else if (a == "--gen-check") c.gen_check = true;
		else if (a == "--region-kb") c.region_kb = atoi(next());
		else if (a == "--rt-cpu") c.rt_cpu = atoi(next());
		else if (a == "--dma") c.dma = next();
		else if (a == "--telemetry") c.telemetry = next();
		else if (a == "--move") c.move = atof(next());
		else usage();
	}
	if (c.L > c.N / 2 || c.M < 8 || (c.N & (c.N - 1)))
		usage();
	if (c.mode == "verify")
		return run_verify(c);
	if (c.mode == "gpu")
		return run_gpu(c);
	if (c.mode == "fpga")
		return run_fpga(c);
	if (c.mode == "ingest")
		return run_ingest(c);
	if (c.mode == "emulate")
		return run_emulate(c);
	if (c.mode == "stream")
		return run_stream(c);
	usage();
}
