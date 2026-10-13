/*
 * Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
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

module top(
    input perst_n,
    output clkreq_n,
    input refclk_p,
    input refclk_n,
    input [3:0] per_p,
    input [3:0] per_n,
    output [3:0] pet_p,
    output [3:0] pet_n,
    output [3:0] leds,
    inout [3:0] iocon
);
    assign clkreq_n = 1'b0;

    wire sys_clk;
    IBUFDS_GTE2 pcie_clk_ibuf(
        .I(refclk_p),
        .IB(refclk_n),
        .CEB(1'b0),
        .O(sys_clk),
        .ODIV2()
    );

    wire user_lnk_up;
    wire sys_rst_n;
    wire [7:0] link_resets;
    wire cfgmclk_beat;
    wire link_up_sync;
    pcie_link_watchdog link_watchdog(
        .perst_n(perst_n),
        .user_lnk_up(user_lnk_up),
        .sys_rst_n(sys_rst_n),
        .resets(link_resets),
        .heartbeat(cfgmclk_beat),
        .link_up(link_up_sync)
    );

    wire axi_aclk;

    /*
     * The (active-low) LEDs follow the GPIO while the link is up. While it's
     * down they show: 0 = PCIe core clock heartbeat (so the reference clock
     * is present and the transceiver PLL locked), 1 = configuration
     * oscillator heartbeat, 2 = PERST# deasserted, 3 = toggles on each
     * link watchdog reset.
     */
    reg [26:0] aclk_beat = 0;
    always @(posedge axi_aclk)
        aclk_beat <= aclk_beat + 1'b1;
    wire [3:0] gpio_leds;
    assign leds = link_up_sync ? gpio_leds :
        ~{link_resets[0], perst_n, cfgmclk_beat, aclk_beat[26]};

    wire axi_aresetn;
    wire usr_irq_req;
    wire usr_irq_ack;
    wire msi_enable;
    wire [2:0] msi_vector_width;
    wire m_axi_awready;
    wire m_axi_wready;
    wire [1:0] m_axi_bid;
    wire [1:0] m_axi_bresp;
    wire m_axi_bvalid;
    wire m_axi_arready;
    wire [1:0] m_axi_rid;
    wire [127:0] m_axi_rdata;
    wire [1:0] m_axi_rresp;
    wire m_axi_rlast;
    wire m_axi_rvalid;
    wire [1:0] m_axi_awid;
    wire [63:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire [2:0] m_axi_awprot;
    wire m_axi_awvalid;
    wire m_axi_awlock;
    wire [3:0] m_axi_awcache;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    wire m_axi_wlast;
    wire m_axi_wvalid;
    wire m_axi_bready;
    wire [1:0] m_axi_arid;
    wire [63:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire [2:0] m_axi_arprot;
    wire m_axi_arvalid;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire m_axi_rready;
    /* The IQ generator paces the DMA engine's reads of its ring */
    wire dma_ar_allow;
    wire bram_arready;
    assign m_axi_arready = bram_arready && dma_ar_allow;
    wire [31:0] m_axil_awaddr;
    wire [2:0] m_axil_awprot;
    wire m_axil_awvalid;
    wire m_axil_awready;
    wire [31:0] m_axil_wdata;
    wire [3:0] m_axil_wstrb;
    wire m_axil_wvalid;
    wire m_axil_wready;
    wire m_axil_bvalid;
    wire [1:0] m_axil_bresp;
    wire m_axil_bready;
    wire [31:0] m_axil_araddr;
    wire [2:0] m_axil_arprot;
    wire m_axil_arvalid;
    wire m_axil_arready;
    wire [31:0] m_axil_rdata;
    wire [1:0] m_axil_rresp;
    wire m_axil_rvalid;
    wire m_axil_rready;
    xdma_0 xdma(
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .user_lnk_up(user_lnk_up),
        .pci_exp_rxp(per_p),
        .pci_exp_rxn(per_n),
        .pci_exp_txp(pet_p),
        .pci_exp_txn(pet_n),
        .axi_aclk(axi_aclk),
        .axi_aresetn(axi_aresetn),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack),
        .msi_enable(msi_enable),
        .msi_vector_width(msi_vector_width),
        .m_axi_awready(m_axi_awready),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_rready(m_axi_rready),
        .m_axil_awaddr(m_axil_awaddr),
        .m_axil_awprot(m_axil_awprot),
        .m_axil_awvalid(m_axil_awvalid),
        .m_axil_awready(m_axil_awready),
        .m_axil_wdata(m_axil_wdata),
        .m_axil_wstrb(m_axil_wstrb),
        .m_axil_wvalid(m_axil_wvalid),
        .m_axil_wready(m_axil_wready),
        .m_axil_bvalid(m_axil_bvalid),
        .m_axil_bresp(m_axil_bresp),
        .m_axil_bready(m_axil_bready),
        .m_axil_araddr(m_axil_araddr),
        .m_axil_arprot(m_axil_arprot),
        .m_axil_arvalid(m_axil_arvalid),
        .m_axil_arready(m_axil_arready),
        .m_axil_rdata(m_axil_rdata),
        .m_axil_rresp(m_axil_rresp),
        .m_axil_rvalid(m_axil_rvalid),
        .m_axil_rready(m_axil_rready)
    );

    wire bram_rst_a;
    wire bram_clk_a;
    wire bram_en_a;
    wire [15:0] bram_we_a;
    wire [19:0] bram_addr_a;
    wire [127:0] bram_wrdata_a;
    wire [127:0] bram_rddata_a;
    axi_bram_ctrl_0 axi_bram_ctrl(
        .s_axi_aclk(axi_aclk),
        .s_axi_aresetn(axi_aresetn),
        .s_axi_awid(m_axi_awid),
        .s_axi_awaddr(m_axi_awaddr[19:0]),
        .s_axi_awlen(m_axi_awlen),
        .s_axi_awsize(m_axi_awsize),
        .s_axi_awburst(m_axi_awburst),
        .s_axi_awlock(m_axi_awlock),
        .s_axi_awcache(m_axi_awcache),
        .s_axi_awprot(m_axi_awprot),
        .s_axi_awvalid(m_axi_awvalid),
        .s_axi_awready(m_axi_awready),
        .s_axi_wdata(m_axi_wdata),
        .s_axi_wstrb(m_axi_wstrb),
        .s_axi_wlast(m_axi_wlast),
        .s_axi_wvalid(m_axi_wvalid),
        .s_axi_wready(m_axi_wready),
        .s_axi_bid(m_axi_bid),
        .s_axi_bresp(m_axi_bresp),
        .s_axi_bvalid(m_axi_bvalid),
        .s_axi_bready(m_axi_bready),
        .s_axi_arid(m_axi_arid),
        .s_axi_araddr(m_axi_araddr[19:0]),
        .s_axi_arlen(m_axi_arlen),
        .s_axi_arsize(m_axi_arsize),
        .s_axi_arburst(m_axi_arburst),
        .s_axi_arlock(m_axi_arlock),
        .s_axi_arcache(m_axi_arcache),
        .s_axi_arprot(m_axi_arprot),
        .s_axi_arvalid(m_axi_arvalid && dma_ar_allow),
        .s_axi_arready(bram_arready),
        .s_axi_rid(m_axi_rid),
        .s_axi_rdata(m_axi_rdata),
        .s_axi_rresp(m_axi_rresp),
        .s_axi_rlast(m_axi_rlast),
        .s_axi_rvalid(m_axi_rvalid),
        .s_axi_rready(m_axi_rready),
        .bram_rst_a(bram_rst_a),
        .bram_clk_a(bram_clk_a),
        .bram_en_a(bram_en_a),
        .bram_we_a(bram_we_a),
        .bram_addr_a(bram_addr_a),
        .bram_wrdata_a(bram_wrdata_a),
        .bram_rddata_a(bram_rddata_a)
    );

    wire gen_bram_en;
    wire [15:0] gen_bram_we;
    wire [15:0] gen_bram_addr;
    wire [127:0] gen_bram_din;
    blk_mem_gen_0 axi_bram(
        .clka(bram_clk_a),
        .rsta(bram_rst_a),
        .ena(bram_en_a),
        .wea(bram_we_a),
        .addra(bram_addr_a[19:4]),
        .dina(bram_wrdata_a),
        .douta(bram_rddata_a),
        .rsta_busy(),
        /* Port B: IQ generator writes */
        .clkb(axi_aclk),
        .rstb(bram_rst_a),
        .enb(gen_bram_en),
        .web(gen_bram_we),
        .addrb(gen_bram_addr),
        .dinb(gen_bram_din),
        .doutb(),
        .rstb_busy()
    );

    wire [3:0] iocon_buf_i;
    wire [3:0] iocon_buf_o;
    wire [3:0] iocon_buf_t;
    genvar i;
    generate
        for (i = 0; i < 4 ; i = i + 1) begin
            IOBUF iocon_buf(
                .I(iocon_buf_i[i]),
                .IO(iocon[i]),
                .O(iocon_buf_o[i]),
                .T(iocon_buf_t[i])
            );
        end
    endgenerate

    /* BAR0 (AXI-Lite): 0x0000 GPIO, 0x1000 IQ generator */
    wire gpio_awvalid, gpio_awready, gpio_wvalid, gpio_wready;
    wire [1:0] gpio_bresp;
    wire gpio_bvalid, gpio_bready, gpio_arvalid, gpio_arready;
    wire [31:0] gpio_rdata;
    wire [1:0] gpio_rresp;
    wire gpio_rvalid, gpio_rready;
    wire gen_awvalid, gen_awready, gen_wvalid, gen_wready;
    wire gen_bvalid, gen_bready, gen_arvalid, gen_arready;
    wire [31:0] gen_rdata;
    wire gen_rvalid, gen_rready;
    axil_split2 #(.SEL_BIT(12)) axil_split(
        .clk(axi_aclk),
        .rst_n(axi_aresetn),
        .m_awaddr(m_axil_awaddr), .m_awvalid(m_axil_awvalid),
        .m_awready(m_axil_awready),
        .m_wdata(m_axil_wdata), .m_wstrb(m_axil_wstrb),
        .m_wvalid(m_axil_wvalid), .m_wready(m_axil_wready),
        .m_bresp(m_axil_bresp), .m_bvalid(m_axil_bvalid),
        .m_bready(m_axil_bready),
        .m_araddr(m_axil_araddr), .m_arvalid(m_axil_arvalid),
        .m_arready(m_axil_arready),
        .m_rdata(m_axil_rdata), .m_rresp(m_axil_rresp),
        .m_rvalid(m_axil_rvalid), .m_rready(m_axil_rready),
        .a_awvalid(gpio_awvalid), .a_awready(gpio_awready),
        .a_wvalid(gpio_wvalid), .a_wready(gpio_wready),
        .a_bresp(gpio_bresp), .a_bvalid(gpio_bvalid), .a_bready(gpio_bready),
        .a_arvalid(gpio_arvalid), .a_arready(gpio_arready),
        .a_rdata(gpio_rdata), .a_rresp(gpio_rresp),
        .a_rvalid(gpio_rvalid), .a_rready(gpio_rready),
        .b_awvalid(gen_awvalid), .b_awready(gen_awready),
        .b_wvalid(gen_wvalid), .b_wready(gen_wready),
        .b_bresp(2'b00), .b_bvalid(gen_bvalid), .b_bready(gen_bready),
        .b_arvalid(gen_arvalid), .b_arready(gen_arready),
        .b_rdata(gen_rdata), .b_rresp(2'b00),
        .b_rvalid(gen_rvalid), .b_rready(gen_rready)
    );

    iq_gen #(.CHIRP_LEN(512)) iq_generator(
        .clk(axi_aclk),
        .rst_n(axi_aresetn),
        .s_awaddr(m_axil_awaddr[7:0]),
        .s_awvalid(gen_awvalid),
        .s_awready(gen_awready),
        .s_wdata(m_axil_wdata),
        .s_wvalid(gen_wvalid),
        .s_wready(gen_wready),
        .s_bvalid(gen_bvalid),
        .s_bready(gen_bready),
        .s_araddr(m_axil_araddr[7:0]),
        .s_arvalid(gen_arvalid),
        .s_arready(gen_arready),
        .s_rdata(gen_rdata),
        .s_rvalid(gen_rvalid),
        .s_rready(gen_rready),
        .bram_en(gen_bram_en),
        .bram_we(gen_bram_we),
        .bram_addr(gen_bram_addr),
        .bram_din(gen_bram_din),
        .link_resets(link_resets),
        .dma_arlen(m_axi_arlen),
        .dma_ar_handshake(m_axi_arvalid && m_axi_arready),
        .dma_ar_allow(dma_ar_allow),
        .dma_rbeat(m_axi_rvalid && m_axi_rready)
    );

    axi_gpio_0 axil_gpios(
        .s_axi_aclk(axi_aclk),
        .s_axi_aresetn(axi_aresetn),
        .s_axi_awaddr(m_axil_awaddr[8:0]),
        .s_axi_awvalid(gpio_awvalid),
        .s_axi_awready(gpio_awready),
        .s_axi_wdata(m_axil_wdata),
        .s_axi_wstrb(m_axil_wstrb),
        .s_axi_wvalid(gpio_wvalid),
        .s_axi_wready(gpio_wready),
        .s_axi_bresp(gpio_bresp),
        .s_axi_bvalid(gpio_bvalid),
        .s_axi_bready(gpio_bready),
        .s_axi_araddr(m_axil_araddr[8:0]),
        .s_axi_arvalid(gpio_arvalid),
        .s_axi_arready(gpio_arready),
        .s_axi_rdata(gpio_rdata),
        .s_axi_rresp(gpio_rresp),
        .s_axi_rvalid(gpio_rvalid),
        .s_axi_rready(gpio_rready),
        .ip2intc_irpt(usr_irq_req),
        .gpio_io_o(gpio_leds),
        .gpio2_io_i(iocon_buf_o),
        .gpio2_io_o(iocon_buf_i),
        .gpio2_io_t(iocon_buf_t)
    );
endmodule
