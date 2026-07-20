/*
This file connects the QSPI engine to the AXI4 interface,
and handles clock domain crossing
As AXI4 interface used ACLK and QSPI interface uses QCLK we need to use CDC (Clock Domain Crossing) techniques

Clock Domain Crossing - the traversal of a signal from one clock domain to another
*/

module cdc_bridge (
  input  logic        aclk,
  input  logic        aclk_rstn,
  input  logic        qclk,
  input  logic        qclk_rst,

  // AXI4 interface
  input  logic        axi_start,
  input  logic        axi_abort,     // strobe: cancel whatever's in progress
  input  logic [31:0] axi_ctrl_cmd,
  input  logic [31:0] axi_addr,
  input  logic [31:0] axi_num_bytes,
  output logic        axi_busy,
  output logic        axi_done,
  output logic        axi_error,     // level, synced from qspi_error
  input  logic [7:0]  axi_tx_data,
  output logic        axi_tx_req,
  output logic [7:0]  axi_rx_data,
  output logic        axi_rx_valid,

    // QSPI interface
    output logic        qspi_start, //pulse to start a transaction
    output logic        qspi_abort, //synced strobe: cancel whatever's in progress
    output logic [31:0] qspi_ctrl_cmd, // multibit data to control the QSPI engine
    output logic [31:0] qspi_addr, //multibit data to control the QSPI engine
    output logic [31:0] qspi_num_bytes, //multibit data to control the QSPI engine
    input  logic        qspi_busy, //level signal to indicate the QSPI engine is busy
    input  logic        qspi_done, //pulse to indicate the QSPI engine has completed the transaction
    input  logic        qspi_error, //level signal: timeout safety net fired
    output logic [7:0]  qspi_tx_data, //multibit data to be transmitted over QSPI
    input  logic        qspi_tx_req, //pulse request to transmit data over QSPI
    input  logic [7:0]  qspi_rx_data, //multibit data received over QSPI
    input  logic        qspi_rx_valid //pulse valid signal for received data
);

pulse_sync u_start_sync (
    .src_clk  (aclk),
    .src_rstn (aclk_rstn),      // already active-low, no inversion needed
    .pulse_in (axi_start),
    .dst_clk  (qclk),
    .dst_rstn (~qclk_rst),      // qclk_rst is active-high; pulse_sync expects active-low, so invert here
    .pulse_out(qspi_start)
  );

  pulse_sync u_abort_sync (
    .src_clk  (aclk),
    .src_rstn (aclk_rstn),
    .pulse_in (axi_abort),
    .dst_clk  (qclk),
    .dst_rstn (~qclk_rst),
    .pulse_out(qspi_abort)
  );

  pulse_sync u_done_sync (
    .src_clk  (qclk),
    .src_rstn (~qclk_rst),      // qclk_rst is active-high; pulse_sync expects active-low, so invert here
    .pulse_in (qspi_done),
    .dst_clk  (aclk),
    .dst_rstn (aclk_rstn),      // already active-low, no inversion needed
    .pulse_out(axi_done)
  );

  // qspi_error: LEVEL signal (held from when the timeout fires until the
  // next transaction starts), not a pulse - same 2-flop sync as busy.
  // axi4L_slave is responsible for edge-detecting this into its own
  // sticky, W1C ERROR status bit.
  logic error_ff1, error_ff2;
  always_ff @(posedge aclk or negedge aclk_rstn) begin
    if (!aclk_rstn) begin
      error_ff1 <= 1'b0;
      error_ff2 <= 1'b0;
    end else begin
      error_ff1 <= qspi_error;
      error_ff2 <= error_ff1;
    end
  end
  assign axi_error = error_ff2;

  pulse_sync u_txreq_sync (
    .src_clk  (qclk),
    .src_rstn (~qclk_rst),      // qclk_rst is active-high; pulse_sync expects active-low, so invert here
    .pulse_in (qspi_tx_req),
    .dst_clk  (aclk),
    .dst_rstn (aclk_rstn),      // already active-low, no inversion needed
    .pulse_out(axi_tx_req)
  );

  pulse_sync u_rxvalid_sync (
    .src_clk  (qclk),
    .src_rstn (~qclk_rst),      // qclk_rst is active-high; pulse_sync expects active-low, so invert here
    .pulse_in (qspi_rx_valid),
    .dst_clk  (aclk),
    .dst_rstn (aclk_rstn),      // already active-low, no inversion needed
    .pulse_out(axi_rx_valid)
  );

    // qspi_busy: LEVEL signal, not a pulse - plain 2-flop sync
    logic busy_ff1, busy_ff2;
    always_ff @(posedge aclk or negedge aclk_rstn) begin
    if (!aclk_rstn) begin
        busy_ff1 <= 1'b0;
        busy_ff2 <= 1'b0;
    end else begin
        busy_ff1 <= qspi_busy;
        busy_ff2 <= busy_ff1;
    end
    end
    assign axi_busy = busy_ff2;

    /*
    Quasi-static: written well before start, held stable through the whole
    transaction. qspi_engine only samples these at the synchronized qspi_start
    pulse, by which point they're already stable - no per-bit sync needed.
    */
    assign qspi_ctrl_cmd  = axi_ctrl_cmd;
    assign qspi_addr      = axi_addr;
    assign qspi_num_bytes = axi_num_bytes;

/*
TX path: axi_tx_data (ACLK domain) -> qspi_tx_data (qclk domain)

axi_tx_req is already the synchronized version of qspi_tx_req (u_txreq_sync
above) - it tells ACLK exactly when the engine wants a new byte.
The moment it fires, we latch whatever axi_tx_data holds right then into tx_data_hold.
That register only changes again on the NEXT axi_tx_req, so it sits stable
for many cycles - plenty of margin for the qclk side to safely sample it.

We only need to synchronize the PULSE marking "a new byte was just latched" -
not the 8 data bits themselves, since they're already guaranteed stable by
the time that pulse's synchronized version arrives on the other side.
*/
logic [7:0] tx_data_hold;
logic       tx_data_ready; // pulses one ACLK cycle, right when tx_data_hold updates

// Priming fix: this used to only update tx_data_hold in response to
// axi_tx_req (the synced version of the engine's "give me the next byte"
// pulse) - but axi_tx_req only ever fires *after* the engine has already
// needed a byte once (at byte_bit_cnt==0 of the first byte). That left
// byte 0 of every write permanently stuck at qspi_tx_data's reset value
// (0x00), regardless of what software wrote to REG_TX_DATA. Also priming
// on axi_start means byte 0 gets latched right when the transaction
// begins, the same way byte_bit_cnt==0 expects it to already be there.
always_ff @(posedge aclk or negedge aclk_rstn) begin
  if (!aclk_rstn) begin
    tx_data_hold  <= '0;
    tx_data_ready <= 1'b0;
  end else begin
    tx_data_ready <= 1'b0;           // default: only pulse for exactly one cycle
    if (axi_start || axi_tx_req) begin
      tx_data_hold  <= axi_tx_data;  // capture the byte AXI is supplying right now
      tx_data_ready <= 1'b1;         // flag: tx_data_hold just became valid+stable
    end
  end
end

logic tx_data_ready_q; // tx_data_ready, synchronized into the qclk domain
pulse_sync u_tx_ready_sync (
  .src_clk  (aclk),
  .src_rstn (aclk_rstn),      // already active-low, no inversion needed
  .pulse_in (tx_data_ready),
  .dst_clk  (qclk),
  .dst_rstn (~qclk_rst),      // qclk_rst is active-high; pulse_sync expects active-low, so invert here
  .pulse_out(tx_data_ready_q)
);

// Sample tx_data_hold directly - safe because it's been stable since the
// ACLK-side capture, and tx_data_ready_q only arrives well after that.
always_ff @(posedge qclk or posedge qclk_rst) begin
  if (qclk_rst) begin
    qspi_tx_data <= '0;
  end else if (tx_data_ready_q) begin
    qspi_tx_data <= tx_data_hold;
  end
end


/*
RX path: qspi_rx_data (qclk domain) -> axi_rx_data (ACLK domain)

Mirror image of the TX path. qspi_rx_valid marks a fresh byte from the
engine - latch it into rx_data_hold right then, which stays stable until
the next qspi_rx_valid. axi_rx_valid (already synced via u_rxvalid_sync
above) tells ACLK exactly when it's safe to sample that held byte.
*/
logic [7:0] rx_data_hold;

always_ff @(posedge qclk or posedge qclk_rst) begin
  if (qclk_rst) begin
    rx_data_hold <= '0;
  end else if (qspi_rx_valid) begin
    rx_data_hold <= qspi_rx_data;   // capture the byte the engine just produced
  end
end

// Sample rx_data_hold directly - safe because it's been stable since the
// qclk-side capture, and axi_rx_valid only arrives well after that.
always_ff @(posedge aclk or negedge aclk_rstn) begin
  if (!aclk_rstn) begin
    axi_rx_data <= '0;
  end else if (axi_rx_valid) begin
    axi_rx_data <= rx_data_hold;
  end
end

endmodule