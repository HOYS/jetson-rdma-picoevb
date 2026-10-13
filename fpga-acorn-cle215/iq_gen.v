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

`timescale 1ns / 1ps

/*
 * Free-running radar IQ generator, emulating an ADC + DDC.
 *
 * Produces 4 complex samples ({Q[15:0], I[15:0]}, I in the low half) per
 * 128-bit word, at a programmable rate of up to one word per clock, and
 * writes them into a ring buffer (the FPGA RAM, through its second port) of
 * 65536 words (1 MiB). The stream is divided into pulses of 2^LOG2N samples;
 * each contains up to two targets' echoes of a CHIRP_LEN-sample LFM chirp
 * (iq_gen_roms.v) at a programmable delay, rotated each pulse by a
 * programmable Doppler phase step, plus approximately Gaussian noise.
 *
 * The host consumes the ring and reports how many words it has consumed in
 * READ_WORDS. If the generator has to overwrite a word the host has not yet
 * consumed, it counts an overflow (samples lost) and continues.
 *
 * In DMA-paced mode (CONTROL[2]), the XDMA engine streams the ring to the
 * host by itself, from a circular descriptor list that reads the ring in
 * order from word 0: this module holds each of the engine's AXI read bursts
 * until the generator has written all of its words, and counts the words the
 * engine has read in READ_WORDS, so the host has no per-transfer work. Bursts
 * pass freely while the generator is stopped, so that the engine can be
 * stopped.
 *
 * Registers (32-bit, byte offsets):
 *   0x00 ID          RO  0x49514731 ("IQG1")
 *   0x04 CONTROL     RW  [0] enable (rising edge restarts the stream at
 *                        sample 0 of pulse 0 and clears the counters),
 *                        [1] full rate (one word per clock),
 *                        [2] DMA-paced (see above)
 *   0x08 RATE_INC    RW  words per clock * 2^32 (if not full rate)
 *   0x0C LOG2N       RW  log2(samples per pulse), 4..16
 *   0x10 NOISE_SCALE RW  noise sigma ~= 0.577 * NOISE_SCALE counts
 *   0x14 T0_DELAY    RW  target 0 delay in samples (multiple of 4)
 *   0x18 T0_DINC     RW  target 0 Doppler phase step per pulse * 2^32 / 2pi
 *   0x1C T0_AMP      RW  target 0 amplitude, counts (0 = off)
 *   0x20 T1_DELAY    RW  target 1 delay
 *   0x24 T1_DINC     RW  target 1 Doppler phase step
 *   0x28 T1_AMP      RW  target 1 amplitude
 *   0x2C WRITE_WORDS RO  words written since enable (wraps at 2^32)
 *   0x30 READ_WORDS  RW  words consumed by the host (wraps at 2^32)
 *   0x34 OVERFLOWS   RO  words written over unconsumed data since enable
 *   0x38 STATUS      RO  [0] running
 *   0x3C CHIRP_LEN   RO  chirp length in samples
 *   0x40 LINK_RESETS RO  PCIe link watchdog resets since power-on
 */
module iq_gen #(
    parameter CHIRP_LEN = 512
)(
    input clk,
    input rst_n,

    /* AXI4-Lite register slave (responses are always OKAY) */
    input [7:0] s_awaddr,
    input s_awvalid,
    output reg s_awready,
    input [31:0] s_wdata,
    input s_wvalid,
    output reg s_wready,
    output reg s_bvalid,
    input s_bready,
    input [7:0] s_araddr,
    input s_arvalid,
    output reg s_arready,
    output reg [31:0] s_rdata,
    output reg s_rvalid,
    input s_rready,

    /* RAM write port, 128-bit words */
    output reg bram_en,
    output [15:0] bram_we,
    output reg [15:0] bram_addr,
    output reg [127:0] bram_din,

    /* from pcie_link_watchdog, asynchronous; changes only while link is down */
    input [7:0] link_resets,

    /*
     * DMA pacing: the XDMA's AXI read address channel to the RAM passes only
     * while dma_ar_allow is set; dma_rbeat is a completed read data beat.
     */
    input [7:0] dma_arlen,
    input dma_ar_handshake,
    output dma_ar_allow,
    input dma_rbeat
);
    localparam [31:0] ID = 32'h49514731;
    localparam RING_WORDS = 65536;

    (* ASYNC_REG = "TRUE" *) reg [7:0] link_resets_s0, link_resets_s1;
    always @(posedge clk) begin
        link_resets_s0 <= link_resets;
        link_resets_s1 <= link_resets_s0;
    end

    /* ------------------------------------------------------- registers */

    reg ctrl_enable, ctrl_full, ctrl_paced;
    reg enable_d;			/* ctrl_enable, delayed */
    reg [31:0] rate_inc;
    reg [4:0] log2n;
    reg [15:0] noise_scale;
    reg [15:0] t_delay0, t_delay1;
    reg [31:0] t_dinc0, t_dinc1;
    reg [15:0] t_amp0, t_amp1;
    reg [31:0] read_words;
    reg [31:0] write_words;
    reg [31:0] overflows;
    reg running;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_awready <= 1'b0;
            s_wready <= 1'b0;
            s_bvalid <= 1'b0;
            s_arready <= 1'b0;
            s_rvalid <= 1'b0;
            s_rdata <= 32'd0;
            ctrl_enable <= 1'b0;
            ctrl_full <= 1'b0;
            ctrl_paced <= 1'b0;
            rate_inc <= 32'd0;
            log2n <= 5'd12;
            noise_scale <= 16'd0;
            t_delay0 <= 16'd0;
            t_delay1 <= 16'd0;
            t_dinc0 <= 32'd0;
            t_dinc1 <= 32'd0;
            t_amp0 <= 16'd0;
            t_amp1 <= 16'd0;
            read_words <= 32'd0;
        end else begin
            /* Write: accept AW and W together, respond after the handshake */
            s_awready <= 1'b0;
            s_wready <= 1'b0;
            if (s_awvalid && s_wvalid && !s_awready && !s_bvalid) begin
                s_awready <= 1'b1;
                s_wready <= 1'b1;
                case (s_awaddr[7:2])
                6'h01: begin
                    ctrl_enable <= s_wdata[0];
                    ctrl_full <= s_wdata[1];
                    ctrl_paced <= s_wdata[2];
                end
                6'h02: rate_inc <= s_wdata;
                6'h03: log2n <= (s_wdata[4:0] < 5'd4) ? 5'd4 :
                                (s_wdata[4:0] > 5'd16) ? 5'd16 : s_wdata[4:0];
                6'h04: noise_scale <= s_wdata[15:0];
                6'h05: t_delay0 <= {s_wdata[15:2], 2'b00};
                6'h06: t_dinc0 <= s_wdata;
                6'h07: t_amp0 <= s_wdata[15:0];
                6'h08: t_delay1 <= {s_wdata[15:2], 2'b00};
                6'h09: t_dinc1 <= s_wdata;
                6'h0A: t_amp1 <= s_wdata[15:0];
                6'h0C: read_words <= s_wdata;
                default: ;
                endcase
            end
            /* In DMA-paced mode, the DMA engine's reads consume the ring */
            if (ctrl_enable && !enable_d)
                read_words <= 32'd0;
            else if (ctrl_paced && dma_rbeat)
                read_words <= read_words + 32'd1;

            if (s_awready)
                s_bvalid <= 1'b1;
            else if (s_bvalid && s_bready)
                s_bvalid <= 1'b0;

            /* Read */
            s_arready <= 1'b0;
            if (s_arvalid && !s_arready && !s_rvalid) begin
                s_arready <= 1'b1;
                case (s_araddr[7:2])
                6'h00: s_rdata <= ID;
                6'h01: s_rdata <= {29'd0, ctrl_paced, ctrl_full, ctrl_enable};
                6'h02: s_rdata <= rate_inc;
                6'h03: s_rdata <= {27'd0, log2n};
                6'h04: s_rdata <= {16'd0, noise_scale};
                6'h05: s_rdata <= {16'd0, t_delay0};
                6'h06: s_rdata <= t_dinc0;
                6'h07: s_rdata <= {16'd0, t_amp0};
                6'h08: s_rdata <= {16'd0, t_delay1};
                6'h09: s_rdata <= t_dinc1;
                6'h0A: s_rdata <= {16'd0, t_amp1};
                6'h0B: s_rdata <= write_words;
                6'h0C: s_rdata <= read_words;
                6'h0D: s_rdata <= overflows;
                6'h0E: s_rdata <= {31'd0, running};
                6'h0F: s_rdata <= CHIRP_LEN;
                6'h10: s_rdata <= {24'd0, link_resets_s1};
                default: s_rdata <= 32'd0;
                endcase
            end
            if (s_arready)
                s_rvalid <= 1'b1;
            else if (s_rvalid && s_rready)
                s_rvalid <= 1'b0;
        end
    end

    /* ----------------------------------------- stage 0: rate and framing */

    reg [31:0] acc;
    wire [32:0] acc_sum = {1'b0, acc} + {1'b0, rate_inc};
    wire emit = running && (ctrl_full || acc_sum[32]);
    reg [13:0] nw;			/* word index within the pulse */
    wire [13:0] nw_last = (14'd1 << (log2n - 5'd2)) - 14'd1;
    reg [31:0] ph0, ph1;		/* Doppler phase of the current pulse */
    wire [16:0] n = {1'b0, nw, 2'b00};	/* sample index of lane 0 */

    always @(posedge clk) begin
        if (!rst_n) begin
            enable_d <= 1'b0;
            running <= 1'b0;
            acc <= 32'd0;
            nw <= 14'd0;
            ph0 <= 32'd0;
            ph1 <= 32'd0;
        end else begin
            enable_d <= ctrl_enable;
            if (ctrl_enable && !enable_d) begin
                running <= 1'b1;
                acc <= 32'd0;
                nw <= 14'd0;
                ph0 <= 32'd0;
                ph1 <= 32'd0;
            end else begin
                if (!ctrl_enable)
                    running <= 1'b0;
                acc <= acc_sum[31:0];
                if (emit) begin
                    if (nw >= nw_last) begin
                        nw <= 14'd0;
                        ph0 <= ph0 + t_dinc0;
                        ph1 <= ph1 + t_dinc1;
                    end else begin
                        nw <= nw + 14'd1;
                    end
                end
            end
        end
    end

    /* --------------------------------- stage 1: target windows, ROM reads */

    reg v1;
    reg in1_0, in1_1;
    reg [6:0] idx1_0, idx1_1;
    reg [9:0] sc1_0, sc1_1;
    wire [16:0] d0 = n - {1'b0, t_delay0};
    wire [16:0] d1 = n - {1'b0, t_delay1};

    always @(posedge clk) begin
        v1 <= emit;
        in1_0 <= (t_amp0 != 16'd0) && (n >= {1'b0, t_delay0}) &&
            (n < {1'b0, t_delay0} + CHIRP_LEN);
        in1_1 <= (t_amp1 != 16'd0) && (n >= {1'b0, t_delay1}) &&
            (n < {1'b0, t_delay1} + CHIRP_LEN);
        idx1_0 <= d0[8:2];
        idx1_1 <= d1[8:2];
        sc1_0 <= ph0[31:22];
        sc1_1 <= ph1[31:22];
    end

    wire [127:0] chirp2_0, chirp2_1;
    wire [31:0] sc2_0, sc2_1;
    iq_chirp_rom chirp_rom0(.clk(clk), .addr(idx1_0), .data(chirp2_0));
    iq_chirp_rom chirp_rom1(.clk(clk), .addr(idx1_1), .data(chirp2_1));
    iq_sincos_rom sincos_rom0(.clk(clk), .addr(sc1_0), .data(sc2_0));
    iq_sincos_rom sincos_rom1(.clk(clk), .addr(sc1_1), .data(sc2_1));

    /* Noise: 8 xorshift64 generators, 512 random bits per clock */
    reg [63:0] rng [0:7];
    integer r;
    function [63:0] xorshift64(input [63:0] x);
        reg [63:0] y;
        begin
            y = x ^ (x << 13);
            y = y ^ (y >> 7);
            xorshift64 = y ^ (y << 17);
        end
    endfunction
    always @(posedge clk) begin
        if (!rst_n) begin
            for (r = 0; r < 8; r = r + 1)
                rng[r] <= 64'h9E3779B97F4A7C15 * (r + 1) + 64'hD1B54A32D192ED03;
        end else begin
            for (r = 0; r < 8; r = r + 1)
                rng[r] <= xorshift64(rng[r]);
        end
    end
    wire [511:0] rbits = {rng[7], rng[6], rng[5], rng[4],
                          rng[3], rng[2], rng[1], rng[0]};

    /* ---------------------- stage 2: target rotations, noise uniforms sum */

    reg v2, in2_0, in2_1;
    always @(posedge clk) begin
        v2 <= v1;
        in2_0 <= in1_0;
        in2_1 <= in1_1;
    end

    reg v3;
    reg [127:0] chirp3_0, chirp3_1;
    reg signed [15:0] rr3_0, ri3_0, rr3_1, ri3_1;	/* amp * e^(j phase) */
    reg signed [17:0] nsum3 [0:7];	/* per lane I/Q: sum of 4 uniforms */
    wire signed [31:0] rr2_0 = $signed({1'b0, t_amp0[14:0]}) * $signed(sc2_0[15:0]);
    wire signed [31:0] ri2_0 = $signed({1'b0, t_amp0[14:0]}) * $signed(sc2_0[31:16]);
    wire signed [31:0] rr2_1 = $signed({1'b0, t_amp1[14:0]}) * $signed(sc2_1[15:0]);
    wire signed [31:0] ri2_1 = $signed({1'b0, t_amp1[14:0]}) * $signed(sc2_1[31:16]);
    integer k;
    always @(posedge clk) begin
        v3 <= v2;
        chirp3_0 <= in2_0 ? chirp2_0 : 128'd0;
        chirp3_1 <= in2_1 ? chirp2_1 : 128'd0;
        rr3_0 <= rr2_0 >>> 15;
        ri3_0 <= ri2_0 >>> 15;
        rr3_1 <= rr2_1 >>> 15;
        ri3_1 <= ri2_1 >>> 15;
        for (k = 0; k < 8; k = k + 1)
            nsum3[k] <= $signed(rbits[k*64 +: 16]) + $signed(rbits[k*64+16 +: 16]) +
                $signed(rbits[k*64+32 +: 16]) + $signed(rbits[k*64+48 +: 16]);
    end

    /* --------------------- stage 3: complex multiplies, noise scaling */

    reg v4;
    reg signed [32:0] er4_0 [0:3], ei4_0 [0:3], er4_1 [0:3], ei4_1 [0:3];
    reg signed [34:0] ns4 [0:7];
    integer j;
    always @(posedge clk) begin
        v4 <= v3;
        for (j = 0; j < 4; j = j + 1) begin
            /* (a + jb)(c + jd) = (ac - bd) + j(ad + bc) */
            er4_0[j] <= $signed(chirp3_0[32*j +: 16]) * rr3_0 -
                $signed(chirp3_0[32*j+16 +: 16]) * ri3_0;
            ei4_0[j] <= $signed(chirp3_0[32*j +: 16]) * ri3_0 +
                $signed(chirp3_0[32*j+16 +: 16]) * rr3_0;
            er4_1[j] <= $signed(chirp3_1[32*j +: 16]) * rr3_1 -
                $signed(chirp3_1[32*j+16 +: 16]) * ri3_1;
            ei4_1[j] <= $signed(chirp3_1[32*j +: 16]) * ri3_1 +
                $signed(chirp3_1[32*j+16 +: 16]) * rr3_1;
        end
        for (k = 0; k < 8; k = k + 1)
            ns4[k] <= nsum3[k] * $signed({1'b0, noise_scale});
    end

    /* ------------------------------------ stage 4: sum and saturate */

    function [15:0] sat16(input signed [21:0] x);
        begin
            if (x > 22'sd32767)
                sat16 = 16'h7fff;
            else if (x < -22'sd32768)
                sat16 = 16'h8000;
            else
                sat16 = x[15:0];
        end
    endfunction

    reg v5;
    reg [127:0] word5;
    reg signed [21:0] si, sq;
    always @(posedge clk) begin
        v5 <= v4;
        for (j = 0; j < 4; j = j + 1) begin
            si = (er4_0[j] >>> 15) + (er4_1[j] >>> 15) + (ns4[2*j] >>> 16);
            sq = (ei4_0[j] >>> 15) + (ei4_1[j] >>> 15) + (ns4[2*j+1] >>> 16);
            word5[32*j +: 32] <= {sat16(sq), sat16(si)};
        end
    end

    /* ------------------------------ stage 5: write the ring, accounting */

    assign bram_we = {16{1'b1}};
    wire [31:0] unread = write_words - read_words;

    always @(posedge clk) begin
        if (!rst_n) begin
            bram_en <= 1'b0;
            bram_addr <= 16'd0;
            bram_din <= 128'd0;
            write_words <= 32'd0;
            overflows <= 32'd0;
        end else if (ctrl_enable && !enable_d) begin
            bram_en <= 1'b0;
            write_words <= 32'd0;
            overflows <= 32'd0;
        end else begin
            bram_en <= v5;
            if (v5) begin
                bram_addr <= write_words[15:0];
                bram_din <= word5;
                write_words <= write_words + 32'd1;
                /* The ring holds RING_WORDS; beyond that, unread data is lost */
                if (unread >= RING_WORDS)
                    overflows <= overflows + 32'd1;
            end
        end
    end

    /* ------------------------------------------------------- DMA pacing */

    /*
     * write_words counts a word as it is presented to the RAM, which writes
     * it on the next edge; compare against a delayed copy, so that a granted
     * burst's reads (which reach the RAM at least a cycle after the grant)
     * always see the new data.
     */
    reg [31:0] written_d1, written_d2, written_d3;
    reg [31:0] granted;		/* words in bursts granted since enable */
    wire [31:0] grantable = written_d3 - granted;
    assign dma_ar_allow = !ctrl_paced || !running ||
        (!grantable[31] && grantable >= {23'd0, dma_arlen} + 32'd1);

    always @(posedge clk) begin
        written_d1 <= write_words;
        written_d2 <= written_d1;
        written_d3 <= written_d2;
        if (!rst_n || (ctrl_enable && !enable_d))
            granted <= 32'd0;
        else if (dma_ar_handshake)
            granted <= granted + {23'd0, dma_arlen} + 32'd1;
    end
endmodule

/*
 * Splits one AXI4-Lite master between two slaves, by address bit SEL_BIT:
 * 0 selects slave A, 1 slave B. One transaction of each kind at a time; the
 * selection is latched for the whole transaction, so slaves may accept the
 * address and data in any order or cycle.
 */
module axil_split2 #(
    parameter SEL_BIT = 12
)(
    input clk,
    input rst_n,
    /* master */
    input [31:0] m_awaddr, input m_awvalid, output m_awready,
    input [31:0] m_wdata, input [3:0] m_wstrb, input m_wvalid, output m_wready,
    output [1:0] m_bresp, output m_bvalid, input m_bready,
    input [31:0] m_araddr, input m_arvalid, output m_arready,
    output [31:0] m_rdata, output [1:0] m_rresp, output m_rvalid, input m_rready,
    /* slave A */
    output a_awvalid, input a_awready, output a_wvalid, input a_wready,
    input [1:0] a_bresp, input a_bvalid, output a_bready,
    output a_arvalid, input a_arready,
    input [31:0] a_rdata, input [1:0] a_rresp, input a_rvalid, output a_rready,
    /* slave B */
    output b_awvalid, input b_awready, output b_wvalid, input b_wready,
    input [1:0] b_bresp, input b_bvalid, output b_bready,
    output b_arvalid, input b_arready,
    input [31:0] b_rdata, input [1:0] b_rresp, input b_rvalid, output b_rready
);
    /* Write path */
    reg w_busy, w_sel, aw_done, w_done;
    always @(posedge clk) begin
        if (!rst_n) begin
            w_busy <= 1'b0;
            w_sel <= 1'b0;
            aw_done <= 1'b0;
            w_done <= 1'b0;
        end else if (!w_busy) begin
            if (m_awvalid && m_wvalid) begin
                w_busy <= 1'b1;
                w_sel <= m_awaddr[SEL_BIT];
                aw_done <= 1'b0;
                w_done <= 1'b0;
            end
        end else begin
            if (m_awvalid && m_awready)
                aw_done <= 1'b1;
            if (m_wvalid && m_wready)
                w_done <= 1'b1;
            if (m_bvalid && m_bready)
                w_busy <= 1'b0;
        end
    end
    wire aw_go = w_busy && !aw_done && m_awvalid;
    wire w_go = w_busy && !w_done && m_wvalid;
    assign a_awvalid = aw_go && !w_sel;
    assign b_awvalid = aw_go && w_sel;
    assign a_wvalid = w_go && !w_sel;
    assign b_wvalid = w_go && w_sel;
    assign m_awready = w_busy && !aw_done && (w_sel ? b_awready : a_awready);
    assign m_wready = w_busy && !w_done && (w_sel ? b_wready : a_wready);
    assign m_bvalid = w_busy && (w_sel ? b_bvalid : a_bvalid);
    assign m_bresp = w_sel ? b_bresp : a_bresp;
    assign a_bready = w_busy && !w_sel && m_bready;
    assign b_bready = w_busy && w_sel && m_bready;

    /* Read path */
    reg r_busy, r_sel, ar_done;
    always @(posedge clk) begin
        if (!rst_n) begin
            r_busy <= 1'b0;
            r_sel <= 1'b0;
            ar_done <= 1'b0;
        end else if (!r_busy) begin
            if (m_arvalid) begin
                r_busy <= 1'b1;
                r_sel <= m_araddr[SEL_BIT];
                ar_done <= 1'b0;
            end
        end else begin
            if (m_arvalid && m_arready)
                ar_done <= 1'b1;
            if (m_rvalid && m_rready)
                r_busy <= 1'b0;
        end
    end
    wire ar_go = r_busy && !ar_done && m_arvalid;
    assign a_arvalid = ar_go && !r_sel;
    assign b_arvalid = ar_go && r_sel;
    assign m_arready = r_busy && !ar_done && (r_sel ? b_arready : a_arready);
    assign m_rvalid = r_busy && (r_sel ? b_rvalid : a_rvalid);
    assign m_rdata = r_sel ? b_rdata : a_rdata;
    assign m_rresp = r_sel ? b_rresp : a_rresp;
    assign a_rready = r_busy && !r_sel && m_rready;
    assign b_rready = r_busy && r_sel && m_rready;
endmodule
