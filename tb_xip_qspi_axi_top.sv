// tb_xip_qspi_axi_top.sv
// Dedicated verification suite for the XIP memory-mapped interface and Arbiter.

import qspi_axi_pkg::*;

module tb_xip_qspi_axi_top;

  // ---------------- Clocks / reset ----------------
  localparam real ACLK_PERIOD = 10.0;
  real qclk_period = 20.0; // aligned 2:1 default

  logic ACLK, qclk;
  logic ARESETn, qclk_rst;

  initial begin ACLK = 0; forever #(ACLK_PERIOD/2) ACLK = ~ACLK; end
  initial begin qclk = 0; forever #(qclk_period/2) qclk = ~qclk; end

  initial begin
    ARESETn  = 1'b0;
    qclk_rst = 1'b1;
    repeat (5) @(posedge ACLK);
    ARESETn = 1'b1;
    repeat (5) @(posedge qclk);
    qclk_rst = 1'b0;
  end

  // ---------------- AXI-Lite Signals (Register Path) ----------------
  logic [31:0] AXI_AWADDR;
  logic        AXI_AWVALID, AXI_AWREADY;
  logic [31:0] AXI_WDATA;
  logic [3:0]  AXI_WSTRB;
  logic        AXI_WVALID, AXI_WREADY;
  logic [1:0]  AXI_BRESP;
  logic        AXI_BVALID, AXI_BREADY;
  logic [31:0] AXI_ARADDR;
  logic        AXI_ARVALID, AXI_ARREADY;
  logic [31:0] AXI_RDATA;
  logic [1:0]  AXI_RRESP;
  logic        AXI_RVALID, AXI_RREADY;

  // ---------------- AXI-Lite Signals (XIP Path) ----------------
  logic [31:0] XIP_ARADDR;
  logic        XIP_ARVALID, XIP_ARREADY;
  logic [31:0] XIP_RDATA;
  logic [1:0]  XIP_RRESP;
  logic        XIP_RVALID, XIP_RREADY;

  // ---------------- QSPI Pins ----------------
  logic dut_cs_n;
  logic dut_io0_out, dut_io0_oe, dut_io0_in;
  logic dut_io1_out, dut_io1_oe, dut_io1_in;
  logic dut_io2_out, dut_io2_oe, dut_io2_in;
  logic dut_io3_out, dut_io3_oe, dut_io3_in;

  logic fm_io0_out, fm_io0_oe;
  logic fm_io1_out, fm_io1_oe;
  logic fm_io2_out, fm_io2_oe;
  logic fm_io3_out, fm_io3_oe;

  wire io0_line = dut_io0_oe ? dut_io0_out : (fm_io0_oe ? fm_io0_out : 1'bz);
  wire io1_line = dut_io1_oe ? dut_io1_out : (fm_io1_oe ? fm_io1_out : 1'bz);
  wire io2_line = dut_io2_oe ? dut_io2_out : (fm_io2_oe ? fm_io2_out : 1'bz);
  wire io3_line = dut_io3_oe ? dut_io3_out : (fm_io3_oe ? fm_io3_out : 1'bz);

  assign dut_io0_in = io0_line;
  assign dut_io1_in = io1_line;
  assign dut_io2_in = io2_line;
  assign dut_io3_in = io3_line;

  // ---------------- DUT ----------------
  qspi_axi_top #(
    .TIMEOUT_CYCLES(150),
    .XIP_BASE(32'h0100_0000),
    .XIP_SIZE(32'h0100_0000)
  ) u_dut (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .qclk(qclk), .qclk_rst(qclk_rst),

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

  // ---------------- Peripheral Model ----------------
  logic       fm_written_valid;
  logic [7:0] fm_written_byte;

  qspi_flash_model u_model (
    .qclk(qclk), .cs_n(dut_cs_n),
    .io0_in(io0_line), .io1_in(io1_line), .io2_in(io2_line), .io3_in(io3_line),
    .io0_out(fm_io0_out), .io0_oe(fm_io0_oe),
    .io1_out(fm_io1_out), .io1_oe(fm_io1_oe),
    .io2_out(fm_io2_out), .io2_oe(fm_io2_oe),
    .io3_out(fm_io3_out), .io3_oe(fm_io3_oe),
    .written_valid(fm_written_valid), .written_byte(fm_written_byte)
  );

  // ---------------- AXI Tasks ----------------
  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    logic aw_done = 0, w_done = 0;
    @(posedge ACLK); #2;
    AXI_AWADDR = addr; AXI_AWVALID = 1'b1;
    AXI_WDATA  = data; AXI_WSTRB = 4'hF; AXI_WVALID = 1'b1;
    while (!(aw_done && w_done)) begin
      @(posedge ACLK);
      if (AXI_AWVALID && AXI_AWREADY) aw_done = 1'b1;
      if (AXI_WVALID  && AXI_WREADY)  w_done  = 1'b1;
    end
    @(posedge ACLK);
    AXI_AWVALID <= 1'b0; AXI_WVALID <= 1'b0;
    @(posedge ACLK);
    AXI_BREADY <= 1'b1;
    while (!AXI_BVALID) @(posedge ACLK);
    @(posedge ACLK);
    AXI_BREADY <= 1'b0;
  endtask

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] data, output logic [1:0] resp);
    logic ar_done = 0;
    @(posedge ACLK); #2;
    AXI_ARADDR = addr; AXI_ARVALID = 1'b1;
    while (!ar_done) begin
      @(posedge ACLK);
      if (AXI_ARVALID && AXI_ARREADY) ar_done = 1'b1;
    end
    @(posedge ACLK);
    AXI_ARVALID <= 1'b0;
    @(posedge ACLK);
    AXI_RREADY <= 1'b1;
    while (!AXI_RVALID) @(posedge ACLK);
    data = AXI_RDATA;
    resp = AXI_RRESP;
    @(posedge ACLK);
    AXI_RREADY <= 1'b0;
  endtask

  task automatic xip_read(input logic [31:0] addr, output logic [31:0] data, output logic [1:0] resp);
    logic ar_done = 0;
    @(posedge ACLK); #2;
    XIP_ARADDR = addr; XIP_ARVALID = 1'b1;
    while (!ar_done) begin
      @(posedge ACLK);
      if (XIP_ARVALID && XIP_ARREADY) ar_done = 1'b1;
    end
    @(posedge ACLK);
    XIP_ARVALID <= 1'b0;
    @(posedge ACLK);
    XIP_RREADY <= 1'b1;
    while (!XIP_RVALID) @(posedge ACLK);
    data = XIP_RDATA;
    resp = XIP_RRESP;
    @(posedge ACLK);
    XIP_RREADY <= 1'b0;
  endtask

  // ---------------- Pass/Fail Bookkeeping ----------------
  int pass_count = 0, fail_count = 0;
  task automatic report(input string name, input bit ok, input string detail = "");
    if (ok) begin
      pass_count++; $display("[PASS] %s %s", name, detail);
    end else begin
      fail_count++; $display("[FAIL] %s %s", name, detail);
    end
  endtask

  // ---------------- Test Sequence ----------------
  initial begin
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic [31:0] xip_cfg_val;

    fork
      begin #500000; $display("GLOBAL TIMEOUT"); $finish; end
    join_none

    @(posedge ARESETn);
    repeat (5) @(posedge ACLK);

    // ---- 1. XIP Disabled / Out of Range Rejection ----
    xip_read(32'h0100_0004, rdata, rresp);
    report("xip_disabled_reject", rresp === 2'b10, "(Expected DECERR 2'b10 when disabled)");

    // ---- 2. Baseline XIP Fetch ----
    xip_cfg_val = (1 << XIP_CFG_BIT_ENABLE) | (8 << 13) | 32'h0B;
    axi_write(REG_XIP_CFG, xip_cfg_val);

    xip_read(32'h0100_0010, rdata, rresp);
    report("xip_baseline_fetch", (rresp === 2'b00) && (rdata === 32'h13121110), 
           $sformatf("(Got %08h, Expected 13121110, Resp %b)", rdata, rresp));

    // ---- 3. Out of bounds range check ----
    xip_read(32'h0200_0000, rdata, rresp);
    report("xip_out_of_range", rresp === 2'b10, "(Expected DECERR 2'b10 for out-of-bounds address)");

    // ---- 4. Arbiter Priority (Register vs XIP collision) ----
    begin
      logic [31:0] ax_data, xp_data;
      logic [1:0]  ax_resp, xp_resp;
      
      @(posedge ACLK);
      AXI_ARADDR = REG_STATUS; AXI_ARVALID = 1'b1;
      XIP_ARADDR = 32'h0100_0020; XIP_ARVALID = 1'b1;

      fork
        begin
          while (!(AXI_ARVALID && AXI_ARREADY)) @(posedge ACLK);
          @(posedge ACLK); AXI_ARVALID <= 1'b0;
          AXI_RREADY <= 1'b1;
          while (!AXI_RVALID) @(posedge ACLK);
          ax_data = AXI_RDATA; ax_resp = AXI_RRESP;
          @(posedge ACLK); AXI_RREADY <= 1'b0;
        end
        begin
          while (!(XIP_ARVALID && XIP_ARREADY)) @(posedge ACLK);
          @(posedge ACLK); XIP_ARVALID <= 1'b0;
          XIP_RREADY <= 1'b1;
          while (!XIP_RVALID) @(posedge ACLK);
          xp_data = XIP_RDATA; xp_resp = XIP_RRESP;
          @(posedge ACLK); XIP_RREADY <= 1'b0;
        end
      join

      report("arbiter_collision_resolution", 
             (ax_resp === 2'b00) && (xp_resp === 2'b00) && (xp_data === 32'h23222120),
             "(Both transactions completed successfully after collision)");
    end

    // ---- 5. Abort is global - cuts short a transaction even while XIP holds the grant ----
    // qspi_arbiter.sv now forwards a_abort unconditionally, regardless of
    // which side holds the grant (see arbiter comments) - abort is a
    // safety/override mechanism, not a normal arbitrated request. This
    // verifies a register-path ABORT write genuinely cuts short an
    // in-flight XIP fetch, reported back to the XIP requester as an
    // error rather than completing with real data.
    begin
      logic [31:0] xip_data;
      logic [1:0]  xip_resp;
      logic [31:0] abort_ctrl_cmd;

      @(posedge ACLK);
      XIP_ARADDR = 32'h0100_0040; XIP_ARVALID = 1'b1;

      fork
        begin
          while (!(XIP_ARVALID && XIP_ARREADY)) @(posedge ACLK);
          @(posedge ACLK); XIP_ARVALID <= 1'b0;
          XIP_RREADY <= 1'b1;
          while (!XIP_RVALID) @(posedge ACLK);
          xip_data = XIP_RDATA; xip_resp = XIP_RRESP;
          @(posedge ACLK); XIP_RREADY <= 1'b0;
        end
        begin
          // Wait until the XIP transaction is genuinely mid-flight
          // (past CMD, into ADDR for this single-line config) before
          // attempting the abort.
          repeat (20) @(posedge ACLK);
          abort_ctrl_cmd = 32'h0;
          abort_ctrl_cmd[CTRL_BIT_ABORT] = 1'b1;
          axi_write(REG_CTRL_CMD, abort_ctrl_cmd);
        end
      join

      report("abort_cuts_short_xip_transaction",
             xip_resp === 2'b10,
             $sformatf("(Register-path ABORT should cut short the in-flight XIP fetch, reported as DECERR - got resp=%b data=%08h)",
                       xip_resp, xip_data));
    end

    // ---- 6. Timeout while XIP holds the grant ----
    // Reconfigure XIP_CFG with near-maximum dummy cycles so a single XIP
    // fetch exceeds this DUT instance's TIMEOUT_CYCLES(150) override.
    // Checks: (a) the XIP request correctly sees the resulting error
    // response rather than hanging, and (b) the grant releases cleanly
    // afterward so a subsequent, ordinary register-path transaction still
    // works - i.e. a timeout on the XIP side doesn't leave the arbiter
    // stuck.
    begin
      logic [31:0] slow_xip_cfg;
      logic [31:0] xip_data;
      logic [1:0]  xip_resp;
      logic [31:0] status_val;
      logic [1:0]  status_resp;

      slow_xip_cfg = (1 << XIP_CFG_BIT_ENABLE) | (255 << 13) | 32'h0B;
      axi_write(REG_XIP_CFG, slow_xip_cfg);

      xip_read(32'h0100_0050, xip_data, xip_resp);
      report("xip_timeout_reports_error", xip_resp === 2'b10,
             $sformatf("(Expected DECERR from timeout-triggered engine error, got resp=%b)", xip_resp));

      // Grant-recovery check: restore normal XIP_CFG and confirm a
      // completely ordinary register-path transaction still works -
      // i.e. the arbiter didn't get stuck holding GNT_XIP forever.
      axi_write(REG_XIP_CFG, (1 << XIP_CFG_BIT_ENABLE) | (8 << 13) | 32'h0B);
      axi_read(REG_STATUS, status_val, status_resp);
      report("register_path_recovers_after_xip_timeout", status_resp === 2'b00,
             $sformatf("(Register-path STATUS read after XIP timeout: resp=%b, expected 00)", status_resp));
    end

    // ---- 7. XIP_CFG written mid-flight does not corrupt an in-progress fetch ----
    // The already-latched configuration inside qspi_engine should govern
    // an in-progress transaction regardless of what XIP_CFG is
    // overwritten to while that transaction is still running.
    begin
      logic [31:0] xip_data;
      logic [1:0]  xip_resp;

      @(posedge ACLK);
      XIP_ARADDR = 32'h0100_0060; XIP_ARVALID = 1'b1;

      fork
        begin
          while (!(XIP_ARVALID && XIP_ARREADY)) @(posedge ACLK);
          @(posedge ACLK); XIP_ARVALID <= 1'b0;
          XIP_RREADY <= 1'b1;
          while (!XIP_RVALID) @(posedge ACLK);
          xip_data = XIP_RDATA; xip_resp = XIP_RRESP;
          @(posedge ACLK); XIP_RREADY <= 1'b0;
        end
        begin
          repeat (15) @(posedge ACLK);
          // Overwrite XIP_CFG with a deliberately different (bogus)
          // config while the above transaction is still in flight.
          axi_write(REG_XIP_CFG, (1 << XIP_CFG_BIT_ENABLE) | (2 << 13) | 32'hFF);
        end
      join

      report("xip_cfg_write_mid_flight_does_not_corrupt", 
             (xip_resp === 2'b00) && (xip_data === 32'h63626160),
             $sformatf("(In-flight fetch should use its ORIGINALLY latched config - got resp=%b data=%08h, expected resp=00 data=63626160)",
                       xip_resp, xip_data));
    end

    // ---- 8. Dual-line XIP fetch ----
    // Tests: only single-line XIP data had ever been exercised before this.
    // Expected: address 0x0100_0080 -> flash offset 0x80..0x83 ->
    // little-endian word 0x83828180.
    begin
      logic [31:0] dual_xip_cfg;
      logic [31:0] xip_data;
      logic [1:0]  xip_resp;

      dual_xip_cfg = (1 << XIP_CFG_BIT_ENABLE) | (8 << 13) | (LW_DUAL << 10) | (LW_SINGLE << 8) | 32'h3B;
      axi_write(REG_XIP_CFG, dual_xip_cfg);

      xip_read(32'h0100_0080, xip_data, xip_resp);
      report("xip_dual_line_data_fetch", (xip_resp === 2'b00) && (xip_data === 32'h83828180),
             $sformatf("(Got resp=%b data=%08h, expected resp=00 data=83828180)", xip_resp, xip_data));
    end

    // ---- 9. Quad-line XIP fetch ----
    // Expected: address 0x0100_0090 -> flash offset 0x90..0x93 ->
    // little-endian word 0x93929190.
    begin
      logic [31:0] quad_xip_cfg;
      logic [31:0] xip_data;
      logic [1:0]  xip_resp;

      quad_xip_cfg = (1 << XIP_CFG_BIT_ENABLE) | (8 << 13) | (LW_QUAD << 10) | (LW_SINGLE << 8) | 32'h6B;
      axi_write(REG_XIP_CFG, quad_xip_cfg);

      xip_read(32'h0100_0090, xip_data, xip_resp);
      report("xip_quad_line_data_fetch", (xip_resp === 2'b00) && (xip_data === 32'h93929190),
             $sformatf("(Got resp=%b data=%08h, expected resp=00 data=93929190)", xip_resp, xip_data));
    end

    // ---- 10. Back-to-back XIP fetches ----
    // Tests: repeated, rapid-succession XIP reads with no artificial delay
    // between them - closer to how a real CPU's fetch unit would actually
    // drive this interface than a single one-shot request ever exercises.
    // Reverts to the normal single-line config first.
    begin
      logic [31:0] normal_xip_cfg;
      logic [31:0] xip_data;
      logic [1:0]  xip_resp;
      logic        all_ok;
      logic [31:0] base_addr;
      logic [31:0] expected;

      normal_xip_cfg = (1 << XIP_CFG_BIT_ENABLE) | (8 << 13) | 32'h0B;
      axi_write(REG_XIP_CFG, normal_xip_cfg);

      all_ok = 1'b1;
      base_addr = 32'h0100_00A0;
      for (int i = 0; i < 6; i++) begin
        xip_read(base_addr + (i * 4), xip_data, xip_resp);
        // single-line reads a byte at a time, still little-endian assembled:
        // bytes (base+4i)..(base+4i+3), low byte first.
        expected = {8'((base_addr[7:0] + i*4 + 3)), 8'((base_addr[7:0] + i*4 + 2)),
                    8'((base_addr[7:0] + i*4 + 1)), 8'((base_addr[7:0] + i*4))};
        if (xip_resp !== 2'b00 || xip_data !== expected) begin
          all_ok = 1'b0;
          $display("[BACK2BACK] fetch %0d MISMATCH: got resp=%b data=%08h, expected resp=00 data=%08h",
                    i, xip_resp, xip_data, expected);
        end
      end
      report("xip_back_to_back_fetches", all_ok,
             "(6 consecutive XIP fetches, no delay between them, each independently checked)");
    end

    $display("=====================================");
    $display("SUMMARY: %0d pass, %0d fail", pass_count, fail_count);
    $finish;
  end

  initial begin
    $dumpfile("tb_xip_qspi_axi_top.vcd");
    $dumpvars(0, tb_xip_qspi_axi_top);
  end

endmodule