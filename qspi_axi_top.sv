module qspi_axi_top #(
  parameter int unsigned TIMEOUT_CYCLES = 20'hFFFFF
)(
  input  logic        ACLK,
  input  logic        ARESETn,   // active-low, AXI-side reset

  input  logic        qclk,
  input  logic        qclk_rst,  // active-high, QSPI-side reset

  //AXI4-Lite slave interface (external - to the real bus master)
  input  logic [31:0] AXI_AWADDR,
  input  logic        AXI_AWVALID,
  output logic        AXI_AWREADY,

  input  logic [31:0] AXI_WDATA,
  input  logic [3:0]  AXI_WSTRB,
  input  logic        AXI_WVALID,
  output logic        AXI_WREADY,

  output logic [1:0]  AXI_BRESP,
  output logic        AXI_BVALID,
  input  logic        AXI_BREADY,

  input  logic [31:0] AXI_ARADDR,
  input  logic        AXI_ARVALID,
  output logic        AXI_ARREADY,

  output logic [31:0] AXI_RDATA,
  output logic [1:0]  AXI_RRESP,
  output logic        AXI_RVALID,
  input  logic        AXI_RREADY,

  //QSPI physical pins (external - to the real flash chip)
  output logic        cs_n,

  output logic        io0_out, output logic io0_oe, input logic io0_in,
  output logic        io1_out, output logic io1_oe, input logic io1_in,
  output logic        io2_out, output logic io2_oe, input logic io2_in,
  output logic        io3_out, output logic io3_oe, input logic io3_in
);

  //Internal wiring: axi4L_slave <-> cdc_bridge (ACLK domain)
  logic        int_a_start;
  logic        int_a_abort;
  logic [31:0] int_a_ctrl_cmd;
  logic [31:0] int_a_addr;
  logic [31:0] int_a_num_bytes;
  logic        int_a_busy;
  logic        int_a_done;
  logic        int_a_error;
  logic [7:0]  int_a_tx_data;
  logic        int_a_tx_req;
  logic [7:0]  int_a_rx_data;
  logic        int_a_rx_valid;

  //Internal wiring: cdc_bridge <-> qspi_engine (qclk domain)
  logic        int_q_start;
  logic        int_q_abort;
  logic [31:0] int_q_ctrl_cmd;
  logic [31:0] int_q_addr;
  logic [31:0] int_q_num_bytes;
  logic        int_q_busy;
  logic        int_q_done;
  logic        int_q_error;
  logic [7:0]  int_q_tx_data;
  logic        int_q_tx_req;
  logic [7:0]  int_q_rx_data;
  logic        int_q_rx_valid;

  axi4L_slave u_axi_slave (
    .ACLK        (ACLK),
    .ARESETn     (ARESETn),

    .AXI_AWADDR  (AXI_AWADDR),
    .AXI_AWVALID (AXI_AWVALID),
    .AXI_AWREADY (AXI_AWREADY),

    .AXI_WDATA   (AXI_WDATA),
    .AXI_WSTRB   (AXI_WSTRB),
    .AXI_WVALID  (AXI_WVALID),
    .AXI_WREADY  (AXI_WREADY),

    .AXI_BRESP   (AXI_BRESP),
    .AXI_BVALID  (AXI_BVALID),
    .AXI_BREADY  (AXI_BREADY),

    .AXI_ARADDR  (AXI_ARADDR),
    .AXI_ARVALID (AXI_ARVALID),
    .AXI_ARREADY (AXI_ARREADY),

    .AXI_RDATA   (AXI_RDATA),
    .AXI_RRESP   (AXI_RRESP),
    .AXI_RVALID  (AXI_RVALID),
    .AXI_RREADY  (AXI_RREADY),

    .qspi_start     (int_a_start),
    .qspi_abort     (int_a_abort),
    .qspi_ctrl_cmd  (int_a_ctrl_cmd),
    .qspi_addr      (int_a_addr),
    .qspi_num_bytes (int_a_num_bytes),
    .qspi_busy      (int_a_busy),
    .qspi_done      (int_a_done),
    .qspi_error     (int_a_error),
    .qspi_tx_data   (int_a_tx_data),
    .qspi_tx_req    (int_a_tx_req),
    .qspi_rx_data   (int_a_rx_data),
    .qspi_rx_valid  (int_a_rx_valid)
  );

  cdc_bridge u_cdc (
    .aclk      (ACLK),
    .aclk_rstn (ARESETn),
    .qclk      (qclk),
    .qclk_rst  (qclk_rst),

    .axi_start      (int_a_start),
    .axi_abort      (int_a_abort),
    .axi_ctrl_cmd   (int_a_ctrl_cmd),
    .axi_addr       (int_a_addr),
    .axi_num_bytes  (int_a_num_bytes),
    .axi_busy       (int_a_busy),
    .axi_done       (int_a_done),
    .axi_error      (int_a_error),
    .axi_tx_data    (int_a_tx_data),
    .axi_tx_req     (int_a_tx_req),
    .axi_rx_data    (int_a_rx_data),
    .axi_rx_valid   (int_a_rx_valid),

    .qspi_start     (int_q_start),
    .qspi_abort     (int_q_abort),
    .qspi_ctrl_cmd  (int_q_ctrl_cmd),
    .qspi_addr      (int_q_addr),
    .qspi_num_bytes (int_q_num_bytes),
    .qspi_busy      (int_q_busy),
    .qspi_done      (int_q_done),
    .qspi_error     (int_q_error),
    .qspi_tx_data   (int_q_tx_data),
    .qspi_tx_req    (int_q_tx_req),
    .qspi_rx_data   (int_q_rx_data),
    .qspi_rx_valid  (int_q_rx_valid)
  );

  qspi_engine #(
    .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
  ) u_qspi_engine (
    .sclk     (qclk),
    .sclk_rst (qclk_rst),

    .cs_n (cs_n),

    .io0_out(io0_out), .io0_oe(io0_oe), .io0_in(io0_in),
    .io1_out(io1_out), .io1_oe(io1_oe), .io1_in(io1_in),
    .io2_out(io2_out), .io2_oe(io2_oe), .io2_in(io2_in),
    .io3_out(io3_out), .io3_oe(io3_oe), .io3_in(io3_in),

    .qspi_start     (int_q_start),
    .qspi_abort     (int_q_abort),
    .qspi_ctrl_cmd  (int_q_ctrl_cmd),
    .qspi_addr      (int_q_addr),
    .qspi_num_bytes (int_q_num_bytes),
    .qspi_busy      (int_q_busy),
    .qspi_done      (int_q_done),
    .qspi_error     (int_q_error),
    .qspi_tx_data   (int_q_tx_data),
    .qspi_tx_req    (int_q_tx_req),
    .qspi_rx_data   (int_q_rx_data),
    .qspi_rx_valid  (int_q_rx_valid)
  );

endmodule