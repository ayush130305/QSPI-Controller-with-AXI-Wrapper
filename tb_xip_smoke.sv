// tb_xip_smoke.sv
//
// Minimal, directed smoke test for the new XIP path (qspi_xip_slave.sv +
// qspi_arbiter.sv). Not a replacement for a full test suite - just
// enough to confirm the basic flow actually works before handing this
// off, given it's genuinely new, never-before-run logic.

import qspi_axi_pkg::*;

module tb_xip_smoke;

  localparam real ACLK_PERIOD = 10.0;
  localparam real QCLK_PERIOD = 20.0;

  logic ACLK, qclk, ARESETn, qclk_rst;
  initial begin ACLK = 0; forever #(ACLK_PERIOD/2) ACLK = ~ACLK; end
  initial begin qclk = 0; forever #(QCLK_PERIOD/2) qclk = ~qclk; end
  initial begin
    ARESETn = 0; qclk_rst = 1;
    repeat (5) @(posedge ACLK);
    ARESETn = 1;
    repeat (5) @(posedge qclk);
    qclk_rst = 0;
  end

  // Register-path AXI signals
  logic [31:0] AXI_AWADDR; logic AXI_AWVALID, AXI_AWREADY;
  logic [31:0] AXI_WDATA;  logic [3:0] AXI_WSTRB; logic AXI_WVALID, AXI_WREADY;
  logic [1:0]  AXI_BRESP;  logic AXI_BVALID, AXI_BREADY;
  logic [31:0] AXI_ARADDR; logic AXI_ARVALID, AXI_ARREADY;
  logic [31:0] AXI_RDATA;  logic [1:0] AXI_RRESP; logic AXI_RVALID, AXI_RREADY;

  // XIP-path AXI signals
  logic [31:0] XIP_ARADDR; logic XIP_ARVALID, XIP_ARREADY;
  logic [31:0] XIP_RDATA;  logic [1:0] XIP_RRESP; logic XIP_RVALID, XIP_RREADY;

  logic dut_cs_n;
  logic dut_io0_out, dut_io0_oe, dut_io0_in;
  logic dut_io1_out, dut_io1_oe, dut_io1_in;
  logic dut_io2_out, dut_io2_oe, dut_io2_in;
  logic dut_io3_out, dut_io3_oe, dut_io3_in;
  logic fm_io0_out, fm_io0_oe, fm_io1_out, fm_io1_oe;
  logic fm_io2_out, fm_io2_oe, fm_io3_out, fm_io3_oe;

  wire io0_line = dut_io0_oe ? dut_io0_out : (fm_io0_oe ? fm_io0_out : 1'bz);
  wire io1_line = dut_io1_oe ? dut_io1_out : (fm_io1_oe ? fm_io1_out : 1'bz);
  wire io2_line = dut_io2_oe ? dut_io2_out : (fm_io2_oe ? fm_io2_out : 1'bz);
  wire io3_line = dut_io3_oe ? dut_io3_out : (fm_io3_oe ? fm_io3_out : 1'bz);
  assign dut_io0_in = io0_line; assign dut_io1_in = io1_line;
  assign dut_io2_in = io2_line; assign dut_io3_in = io3_line;

  qspi_axi_top #(
    .XIP_BASE(32'h0100_0000),
    .XIP_SIZE(32'h0000_1000) // small window for this test
  ) u_dut (
    .ACLK(ACLK), .ARESETn(ARESETn), .qclk(qclk), .qclk_rst(qclk_rst),
    .AXI_AWADDR(AXI_AWADDR), .AXI_AWVALID(AXI_AWVALID), .AXI_AWREADY(AXI_AWREADY),
    .AXI_WDATA(AXI_WDATA), .AXI_WSTRB(AXI_WSTRB), .AXI_WVALID(AXI_WVALID), .AXI_WREADY(AXI_WREADY),
    .AXI_BRESP(AXI_BRESP), .AXI_BVALID(AXI_BVALID), .AXI_BREADY(AXI_BREADY),
    .AXI_ARADDR(AXI_ARADDR), .AXI_ARVALID(AXI_ARVALID), .AXI_ARREADY(AXI_ARREADY),
    .AXI_RDATA(AXI_RDATA), .AXI_RRESP(AXI_RRESP), .AXI_RVALID(AXI_RVALID), .AXI_RREADY(AXI_RREADY),
    .XIP_ARADDR(XIP_ARADDR), .XIP_ARVALID(XIP_ARVALID), .XIP_ARREADY(XIP_ARREADY),
    .XIP_RDATA(XIP_RDATA), .XIP_RRESP(XIP_RRESP), .XIP_RVALID(XIP_RVALID), .XIP_RREADY(XIP_RREADY),
    .cs_n(dut_cs_n),
    .io0_out(dut_io0_out), .io0_oe(dut_io0_oe), .io0_in(dut_io0_in),
    .io1_out(dut_io1_out), .io1_oe(dut_io1_oe), .io1_in(dut_io1_in),
    .io2_out(dut_io2_out), .io2_oe(dut_io2_oe), .io2_in(dut_io2_in),
    .io3_out(dut_io3_out), .io3_oe(dut_io3_oe), .io3_in(dut_io3_in)
  );

  qspi_flash_model u_model (
    .qclk(qclk), .cs_n(dut_cs_n),
    .io0_in(io0_line), .io1_in(io1_line), .io2_in(io2_line), .io3_in(io3_line),
    .io0_out(fm_io0_out), .io0_oe(fm_io0_oe),
    .io1_out(fm_io1_out), .io1_oe(fm_io1_oe),
    .io2_out(fm_io2_out), .io2_oe(fm_io2_oe),
    .io3_out(fm_io3_out), .io3_oe(fm_io3_oe),
    .written_valid(), .written_byte()
  );

  int pass_count = 0, fail_count = 0;
  task automatic report(input string name, input bit ok, input string detail = "");
    if (ok) begin pass_count++; $display("[PASS] %s %s", name, detail); end
    else begin fail_count++; $display("[FAIL] %s %s", name, detail); end
  endtask

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    logic aw_done, w_done;
    aw_done = 0; w_done = 0;
    @(posedge ACLK); #2;
    AXI_AWADDR = addr; AXI_AWVALID = 1; AXI_WDATA = data; AXI_WSTRB = 4'hF; AXI_WVALID = 1;
    while (!(aw_done && w_done)) begin
      @(posedge ACLK);
      if (AXI_AWVALID && AXI_AWREADY) aw_done = 1;
      if (AXI_WVALID && AXI_WREADY) w_done = 1;
    end
    @(posedge ACLK); AXI_AWVALID <= 0; AXI_WVALID <= 0;
    @(posedge ACLK); AXI_BREADY <= 1;
    while (!AXI_BVALID) @(posedge ACLK);
    @(posedge ACLK); AXI_BREADY <= 0;
  endtask

  task automatic xip_read(input logic [31:0] addr, output logic [31:0] data, output logic [1:0] resp);
    logic ar_done, r_done;
    ar_done = 1'b0;
    r_done  = 1'b0;
    @(posedge ACLK); #2;
    XIP_ARADDR = addr;
    XIP_ARVALID = 1;
    // RREADY asserted immediately, alongside ARVALID - NOT delayed a cycle
    // (or two) after the AR handshake the way the register-path pattern
    // does. That delay is fine for axi4L_slave.sv, which always takes a
    // real clock edge to produce a response - but qspi_xip_slave can
    // resolve to XIP_RESP as fast as the very next cycle for its
    // immediate-error paths (disabled/out-of-range), and a master that
    // isn't ready yet would miss that window entirely. Asserting RREADY
    // up front is a legal, standard AXI master pattern - nothing in the
    // protocol requires artificially delaying readiness.
    XIP_RREADY = 1;
    while (!ar_done) begin
      @(posedge ACLK);
      if (XIP_ARVALID && XIP_ARREADY) begin
        ar_done     = 1'b1;
        XIP_ARVALID <= 0; // clear the SAME edge it's accepted, not one cycle later -
                          // qspi_xip_slave can resolve fast enough (immediate-error
                          // paths) that an extra lingering cycle of ARVALID=1 risks
                          // the FSM cycling back to IDLE and re-accepting the same
                          // address as a brand-new request
      end
    end
    while (!r_done) begin
      @(posedge ACLK);
      if (XIP_RVALID && XIP_RREADY) r_done = 1'b1;
    end
    data = XIP_RDATA; resp = XIP_RRESP;
    @(posedge ACLK); XIP_RREADY <= 0;
  endtask

  logic [31:0] xip_cfg_word, rdata;
  logic [1:0]  rresp;

  initial begin
    fork
      begin #200000; $display("GLOBAL TIMEOUT"); $finish; end
    join_none

    @(posedge ARESETn); repeat (5) @(posedge ACLK);
    AXI_AWVALID=0; AXI_WVALID=0; AXI_BREADY=0; AXI_ARVALID=0; AXI_RREADY=0;
    XIP_ARVALID=0; XIP_RREADY=0;

    // ---- 1. XIP disabled by default ----
    xip_read(32'h0100_0000, rdata, rresp);
    report("xip_disabled_by_default", rresp == 2'b10,
           $sformatf("(resp=%b, expected DECERR since XIP_ENABLE defaults to 0)", rresp));

    // ---- 2. Configure XIP_CFG (quad read, opcode 0x6B, dummy=8, single addr) and enable ----
    xip_cfg_word = {1'b0/*enable, set below*/, 10'b0/*reserved*/, 8'd8/*dummy*/, 1'b0/*addr_width*/, LW_QUAD, LW_SINGLE, 8'h6B};
    xip_cfg_word[XIP_CFG_BIT_ENABLE] = 1'b1;
    axi_write(REG_XIP_CFG, xip_cfg_word);

    // ---- 3. Basic XIP read - address 0x0100_0032 -> flash offset 0x32..0x35 ----
    // Bytes shift in MSB-first, so the assembled word is {mem[0x32],
    // mem[0x33], mem[0x34], mem[0x35]} = 0x32333435 - the LOW byte is the
    // LAST byte fetched (0x35), not the first.
    xip_read(32'h0100_0032, rdata, rresp);
    report("xip_basic_read", rresp == 2'b00 && rdata == 32'h32333435,
           $sformatf("(resp=%b rdata=%08h, expected OKAY and 0x32333435)", rresp, rdata));

    // ---- 4. Out-of-range XIP address -> DECERR, no engine access at all ----
    xip_read(32'h0200_0000, rdata, rresp);
    report("xip_out_of_range", rresp == 2'b10,
           $sformatf("(resp=%b, expected DECERR)", rresp));

    // ---- 5. Register path still works correctly after XIP activity ----
    axi_write(REG_ADDR, 32'd80);
    axi_write(REG_NUM_BYTES, 32'd1);
    axi_write(REG_CTRL_CMD, {9'b0, 1'b0, 1'b1, 8'd8, 1'b0, LW_QUAD, 2'b00, 8'h6B});
    begin
      logic [31:0] status_val;
      int poll_count; poll_count = 0;
      do begin
        repeat(2) @(posedge ACLK);
        // quick inline read of STATUS
        AXI_ARADDR = REG_STATUS; AXI_ARVALID = 1;
        while (!(AXI_ARVALID && AXI_ARREADY)) @(posedge ACLK);
        @(posedge ACLK); AXI_ARVALID <= 0;
        @(posedge ACLK); AXI_RREADY <= 1;
        while (!AXI_RVALID) @(posedge ACLK);
        status_val = AXI_RDATA;
        @(posedge ACLK); AXI_RREADY <= 0;
        poll_count++;
      end while (status_val[STATUS_BIT_BUSY] && poll_count < 2000);
      AXI_ARADDR = REG_RX_DATA; AXI_ARVALID = 1;
      while (!(AXI_ARVALID && AXI_ARREADY)) @(posedge ACLK);
      @(posedge ACLK); AXI_ARVALID <= 0;
      @(posedge ACLK); AXI_RREADY <= 1;
      while (!AXI_RVALID) @(posedge ACLK);
      rdata = AXI_RDATA;
      @(posedge ACLK); AXI_RREADY <= 0;
      report("register_path_after_xip", rdata[7:0] == 8'h50,
             $sformatf("(got %02h expected 50)", rdata[7:0]));
    end

    $display("=====================================");
    $display("SUMMARY: %0d pass, %0d fail", pass_count, fail_count);
    $finish;
  end

endmodule