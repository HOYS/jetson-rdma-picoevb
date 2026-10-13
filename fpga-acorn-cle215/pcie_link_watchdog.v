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
 * Resets the PCIe core again if its link does not come up.
 *
 * When the FPGA configures from flash at power-on, the PCIe core can come out
 * of reset in a state from which it never trains (the host's root port then
 * sits in Training forever), while a later reset of the core trains normally.
 * This holds the core in reset while PERST# is asserted, as before, and also
 * pulses its reset whenever PERST# is deasserted but the link has stayed down
 * for 2^WAIT_LOG2 cycles of the FPGA's internal configuration oscillator
 * (CFGMCLK, 65 MHz +/-50%: ~260 ms by default). It runs from CFGMCLK because
 * the PCIe clocks may be the thing that's missing.
 */
module pcie_link_watchdog #(
    parameter WAIT_LOG2 = 24,   /* link-down time before a reset */
    parameter PULSE_LOG2 = 16   /* reset pulse length (~1 ms) */
) (
    input perst_n,
    input user_lnk_up,
    output reg sys_rst_n,
    output reg [7:0] resets,    /* watchdog resets so far (CFGMCLK domain) */
    output heartbeat,           /* CFGMCLK / 2^26: blinks at ~1 Hz */
    output link_up              /* user_lnk_up, synchronized */
);
    wire cfgmclk;
    STARTUPE2 #(
        .PROG_USR("FALSE"),
        .SIM_CCLK_FREQ(0.0)
    ) startup (
        .CFGCLK(),
        .CFGMCLK(cfgmclk),
        .EOS(),
        .PREQ(),
        .CLK(1'b0),
        .GSR(1'b0),
        .GTS(1'b0),
        .KEYCLEARB(1'b1),
        .PACK(1'b0),
        .USRCCLKO(1'b0),
        .USRCCLKTS(1'b1),
        .USRDONEO(1'b1),
        .USRDONETS(1'b1)
    );

    (* ASYNC_REG = "TRUE" *) reg [1:0] perst_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] lnk_sync = 2'b00;
    always @(posedge cfgmclk) begin
        perst_sync <= {perst_sync[0], perst_n};
        lnk_sync <= {lnk_sync[0], user_lnk_up};
    end

    reg [25:0] beat = 0;
    always @(posedge cfgmclk)
        beat <= beat + 1'b1;
    assign heartbeat = beat[25];
    assign link_up = lnk_sync[1];

    reg [WAIT_LOG2-1:0] down_count = 0;
    reg [PULSE_LOG2-1:0] pulse_count = 0;
    reg pulsing = 1'b0;
    initial sys_rst_n = 1'b0;
    initial resets = 8'd0;

    always @(posedge cfgmclk) begin
        if (!perst_sync[1]) begin
            down_count <= 0;
            pulsing <= 1'b0;
            sys_rst_n <= 1'b0;
        end else if (pulsing) begin
            sys_rst_n <= 1'b0;
            pulse_count <= pulse_count + 1'b1;
            if (&pulse_count)
                pulsing <= 1'b0;
        end else begin
            sys_rst_n <= 1'b1;
            if (lnk_sync[1]) begin
                down_count <= 0;
            end else begin
                down_count <= down_count + 1'b1;
                if (&down_count) begin
                    pulsing <= 1'b1;
                    pulse_count <= 0;
                    if (~&resets)
                        resets <= resets + 1'b1;
                end
            end
        end
    end
endmodule
