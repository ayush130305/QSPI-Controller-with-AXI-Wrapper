import qspi_axi_pkg::*;

/*  this module is the AXI4-Lite slave interface to the QSPI engine. It handles the AXI4-Lite protocol, including the write and read channels, 
    and provides a simple register interface to control the QSPI engine. The module also includes status registers to monitor the state of the
    QSPI engine and flags for busy, done, tx_ready, rx_ready, and error conditions.
*/

module axi4L_slave (
    input logic ACLK, // axi clock signal
    input logic ARESETn, /*active low reset signal */

    //AW (address write) channel signals
    /*address write is used to specify the address of the register to be written, it consists of signals awaddr (address), awvalid (valid signal), 
    and awready (ready signal). The master asserts awvalid when it has a valid address to write, and the slave asserts awready when it is ready to 
    accept the address. The address is latched on the rising edge of ACLK when both awvalid and awready are high. 
    */
    input logic [31:0] AXI_AWADDR,
    input logic AXI_AWVALID, // master asserts awvalid when it has a valid address to write
    output logic AXI_AWREADY, // ready signals always flow backwards from slave to master, slave asserts awready when it is ready to accept the address

    //W (write) channel signals
    /*
    The write channel is used to transfer the data to be written to the specified address. It consists of signals wdata (data), wstrb (write strobe),
    wvalid (valid signal), and wready (ready signal). The master asserts wvalid when it has valid data to write, and the slave asserts wready when 
    it is ready to accept the data. The data is latched on the rising edge of ACLK when both wvalid and wready are high.
    */
    input logic [31:0] AXI_WDATA, // data to be written to the specified address
    input logic [3:0] AXI_WSTRB, // write strobe signals to indicate which bytes of the data are valid (1 = valid, 0 = invalid)
    input logic AXI_WVALID, // master asserts wvalid when it has valid data to write
    output logic AXI_WREADY, // slave asserts wready when it is ready to accept the data
    //strobe signals are used to indicate which bytes of the data are valid. Each bit in the wstrb signal corresponds to a byte in the wdata signal.

    //B (write response) channel signals
    /*
    The write response channel is used to indicate the status of the write transaction. It consists of signals bresp (response), bvalid (valid signal),
    and bready (ready signal). The slave asserts bvalid when it has a valid response to the write transaction, and the master asserts bready when
    it is ready to accept the response. The response is latched on the rising edge of ACLK when both bvalid and bready are high. The bresp signal
    indicates the status of the write transaction, with 2'b00 indicating an OKAY response, 2'b01 indicating a SLVERR (slave error) response, and 
    2'b10 indicating a DECERR (decode error) response.
    */
    output logic [1:0] AXI_BRESP, // response signals to indicate the status of the write transaction (2'b00 = OKAY, 2'b01 = SLVERR, 2'b10 = DECERR)
    /* 
    SLVERR response indicates that the slave was unable to process the write transaction due to an internal error, while DECERR response indicates 
    that the address specified in the write transaction is not valid for this slave. 
    */
    output logic AXI_BVALID, // slave asserts bvalid when it has a valid response to the write transaction
    input logic AXI_BREADY, // master asserts bready when it is ready to accept the response

    //AR (address read) channel signals
    /*
    Address read is used to specify the address of the register to be read, it consists of signals araddr (address), arvalid (valid signal), and 
    arready (ready signal). The master asserts arvalid when it has a valid address to read, and the slave asserts arready when it is ready to accept 
    the address. The address is latched on the rising edge of ACLK when both arvalid and arready are high.
    */
    input logic [31:0] AXI_ARADDR, // address of the register to be read
    input logic AXI_ARVALID, // master asserts arvalid when it has a valid address to read
    output logic AXI_ARREADY, // slave asserts arready when it is ready to accept the address

    //R (read) channel signals
    /*
    The read channel is used to transfer data from the slave to the master. It consists of signals rdata (data), rresp (response), rvalid (valid signal),
    and rready (ready signal). The slave asserts rvalid when it has valid data to transfer, and the master asserts rready when it is ready to accept the data.
    The data is latched on the rising edge of ACLK when both rvalid and rready are high. The rresp signal indicates the status of the read transaction,
    with 2'b00 indicating an OKAY response, 2'b01 indicating a SLVERR (slave error) response, and 2'b10 indicating a DECERR (decode error) response.
    */
    output logic [31:0] AXI_RDATA, // data to be transferred from slave to master
    output logic [1:0] AXI_RRESP, // response signals to indicate the status of the read transaction (2'b00 = OKAY, 2'b01 = SLVERR, 2'b10 = DECERR)
    output logic AXI_RVALID, // slave asserts rvalid when it has valid data to transfer
    input logic AXI_RREADY, // master asserts rready when it is ready to accept the data

    //Internal interface to qspi_engine.sv
    // pins of the qspi_engine.sv module are connected to the physical pins of the QSPI flash chip, while the internal interface signals
    // are used to communicate
    output logic        qspi_start, //  pulses to start a transaction
    output logic        qspi_abort, // synced strobe: cancel whatever's in progress
    output logic [31:0] qspi_ctrl_cmd, // ctrl cmd register is used to control the QSPI engine, it contains various fields such as direction, start, dummy cycles, address width, data lines, address lines, and opcode.
    output logic [31:0] qspi_addr, // address register is used to specify the address of the data to be transferred over QSPI
    output logic [31:0] qspi_num_bytes, // num bytes register is used to specify the number of bytes to be transferred over QSPI
    input  logic        qspi_busy, // level signal to indicate the QSPI engine is busy
    input  logic        qspi_done,// pulse to indicate the QSPI engine has completed the transaction
    input  logic        qspi_error, // level signal: timeout safety net fired

    output logic [7:0]  qspi_tx_data, // tx data register is used to write data to be transmitted over QSPI
    input  logic        qspi_tx_req,   // engine asking for the next byte
    input  logic [7:0]  qspi_rx_data, // rx data register is used to read data received over QSPI
    input  logic        qspi_rx_valid,  // engine says: this byte is ready to capture

    output logic [31:0] xip_cfg // XIP_CFG register value, exposed for qspi_xip_slave.sv to consume
);

    // internal register storage for the control and status registers
    logic [31:0] reg_ctrl_cmd; // control register contains various fields such as direction, start, dummy cycles, address width, data lines, address lines, and opcode.
    logic [31:0] reg_addr; // address register is used to specify the address of the data to be transferred over QSPI
    logic [31:0] reg_num_bytes; // num bytes register is used to specify the number of bytes to be transferred over QSPI
    logic [31:0] reg_tx_data; // tx data register is used to write data to be transmitted over QSPI
    logic [31:0] reg_xip_cfg; // XIP configuration register - see qspi_axi_pkg.sv for bit layout
    assign xip_cfg = reg_xip_cfg;

    // write channel FSM
    write_state_t state; // state variable to keep track of the current state of the write channel FSM

    //transfer detection signals
    logic aw_hs, w_hs, b_hs, ar_hs, r_hs;
    assign aw_hs = AXI_AWVALID & AXI_AWREADY; // handshake signal for the address write channel, high when both awvalid and awready are high
    assign w_hs  = AXI_WVALID  & AXI_WREADY; // handshake signal for the write channel, high when both wvalid and wready are high
    assign b_hs  = AXI_BVALID  & AXI_BREADY; // handshake signal for the write response channel, high when both bvalid and bready are high
    assign ar_hs = AXI_ARVALID & AXI_ARREADY; // handshake signal for the address read channel, high when both arvalid and arready are high
    assign r_hs  = AXI_RVALID  & AXI_RREADY; // handshake signal for the read channel, high when both rvalid and rready are high

    //fsm for the write channel, which handles the address and data phases of the write transaction. 
    //The FSM has four states: IDLE, ADDR_OK, DATA_OK, and RESP.

    always_ff @(posedge ACLK or negedge ARESETn) begin
  if (!ARESETn) begin
    state <= IDLE;
  end else begin
    case (state)
      IDLE:     if (aw_hs && w_hs) state <= RESP;
                else if (aw_hs)    state <= ADDR_OK;
                else if (w_hs)     state <= DATA_OK;
      ADDR_OK:  if (w_hs)  state <= RESP;
      DATA_OK:  if (aw_hs) state <= RESP;
      RESP:     if (b_hs)  state <= IDLE;
    endcase // FSM is easy to understand only, just go thorugh states
  end
end
    
    // latched signals
    logic [31:0] aw_addr_latched; // used to hold the address of the register to be written when both awvalid and awready are high
    logic [31:0] w_data_latched;  // used to hold the data to be written when both wvalid and wready are high
    logic [3:0]  w_strb_latched;  // used to hold the write strobe signals when both wvalid and wready are high
    logic [31:0] ar_addr_latched; // used to hold the address of the register to be read when both arvalid and arready are high

    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            aw_addr_latched <= '0;
            w_data_latched  <= '0;
            w_strb_latched  <= '0;
            ar_addr_latched <= '0;
        end else begin 
            if (aw_hs) aw_addr_latched <= AXI_AWADDR; 
            if (w_hs)  w_data_latched  <= AXI_WDATA;
            if (w_hs)  w_strb_latched  <= AXI_WSTRB;
            if (ar_hs) ar_addr_latched <= AXI_ARADDR;
        end //if (handshake) then latch the address/data/strb signals, AXI_(...) holds the live values, which get latched onto the latch signals one by one
    end

    // output logic
    always_comb begin
        // default values
        AXI_AWREADY = (state == IDLE) || (state == DATA_OK);
        AXI_WREADY  = (state == IDLE) || (state == ADDR_OK);
        AXI_BVALID  = (state == RESP);
        AXI_BRESP   = 2'b00; // OKAY response

    end

    logic do_write; //fires exactly the cycle a register write actually completes
    logic [31:0] eff_addr, eff_data; //live-or-latched address/data at that exact moment
    logic [3:0]  eff_strb; //live-or-latched write strobe at that exact moment

    //eff_(...) is there because the write channel FSM can be in a state where either the address or data phase has completed, but not both.
    //In that case, the latched value of the completed phase is used, while the live value of the incomplete phase is used. 
    //This ensures that the correct address and data are used for the write transaction, regardless of the state of the FSM.

    assign eff_addr = aw_hs ? AXI_AWADDR : aw_addr_latched;// if aw_hs is high, use the live address from AXI_AWADDR, otherwise use the latched address from aw_addr_latched
    assign eff_data = w_hs  ? AXI_WDATA  : w_data_latched; // if w_hs is high, use the live data from AXI_WDATA, otherwise use the latched data from w_data_latched
    assign eff_strb = w_hs  ? AXI_WSTRB  : w_strb_latched; // if w_hs is high, use the live write strobe from AXI_WSTRB, otherwise use the latched write strobe from w_strb_latched

    assign do_write = (state == IDLE   && aw_hs && w_hs) ||
                    (state == ADDR_OK && w_hs)        ||
                    (state == DATA_OK && aw_hs);

    /* do write fires exactly the cycle a register write actually completes, which is when both the address and data phases have completed.
     it fires every time a write transaction completes, regardless of the state of the FSM. 
     The eff_(...) signals are used to determine the address and data of the register to be written, based on the state of the FSM. The eff_(...) signals are used to ensure that the correct address and data are used for the write transaction,
     regardless of the state of the FSM. The eff_(...) signals are used to determine the address and data of the register to be written, based on the state of the FSM. 
     The eff_(...) signals are used to ensure that the correct address and data are used for the write transaction 
    */

    //read channel FSM
    read_state_t read_state;

    /*
    Read channel FSM is simpler than the write channel FSM, as it only handles the address and data phases of the read transaction.
    The FSM has two states: READ_IDLE and READ_RESP. In the READ_IDLE state, the FSM waits for a valid address to be presented on the AR channel. When a valid address is presented, the FSM transitions to the READ_RESP state, where it waits for the master to assert RREADY. 
    When RREADY is asserted, the FSM transitions back to the READ_IDLE state, and the read transaction is complete. The FSM also handles the RRESP signal, which indicates the status of the read transaction.
    */

    // sequential logic for read channel fsm - follows the same pattern as the write channel fsm, but simpler since it only has two states
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            read_state <= READ_IDLE;
        end else begin
            case (read_state)
                READ_IDLE: if (ar_hs) read_state <= READ_RESP;
                READ_RESP: if (r_hs) read_state <= READ_IDLE;
                default:   read_state <= READ_IDLE;
            endcase
        end
    end

    /*
    The combinational block for the read channel FSM handles the RVALID, RRESP, and RDATA signals.
    RVALID is asserted when the FSM is in the READ_RESP state, indicating that valid data is available on the RDATA signal. 
    RRESP is always set to 2'b00 (OKAY) for this implementation, as there are no error conditions to report. 
    RDATA is set based on the address latched during the AR handshake, returning the appropriate register value. 
    */

    always_comb begin
        AXI_ARREADY = (read_state == READ_IDLE);
        AXI_RVALID  = (read_state == READ_RESP);
        AXI_RRESP   = 2'b00;
        case (ar_addr_latched)
            REG_CTRL_CMD:  AXI_RDATA = reg_ctrl_cmd;
            REG_ADDR:      AXI_RDATA = reg_addr;
            REG_NUM_BYTES: AXI_RDATA = reg_num_bytes;
            REG_STATUS:    AXI_RDATA = {27'd0, error_latched, rx_ready_latched, tx_ready_latched, done_latched, qspi_busy};
            REG_TX_DATA:   AXI_RDATA = '0;  // write-only, reads return 0
            REG_XIP_CFG:   AXI_RDATA = reg_xip_cfg;
            REG_RX_DATA:   AXI_RDATA = {24'd0, qspi_rx_data};
            default:       AXI_RDATA = '0; // unknown address - return 0
        endcase
    end

// Sticky STATUS bits. DONE and ERROR are write-1-to-clear (software can clear them by writing 1 to the corresponding bit in the STATUS register). 
// TX_READY and RX_READY are cleared by the software reading the corresponding data register (REG_TX_DATA or REG_RX_DATA).

logic done_latched, tx_ready_latched, rx_ready_latched, error_latched;
logic qspi_error_d1; // previous sample of qspi_error, for edge detection

logic status_w1c_done, status_w1c_error;
// status (done/error) tracks the moment the engine asserts its pulse, and stays high until software clears it. This is a "sticky" status bit, so we can always see it even if the engine's pulse was very brief.
// the ' w1c ' in the name means "write 1 to clear" - software can clear it by writing a 1 to the corresponding bit in the STATUS register. Writing a 0 has no effect.
assign status_w1c_done  = do_write && (eff_addr == REG_STATUS) && eff_strb[0] && eff_data[STATUS_BIT_DONE];
assign status_w1c_error = do_write && (eff_addr == REG_STATUS) && eff_strb[0] && eff_data[STATUS_BIT_ERROR];

// tx_data_write and rx_data_read are used to detect when the software writes to the TX_DATA register or reads from the RX_DATA register, respectively.
logic tx_data_write, rx_data_read;
assign tx_data_write = do_write && (eff_addr == REG_TX_DATA); // tx_data_write fires exactly the cycle a write to REG_TX_DATA completes, which is when both the address and data phases have completed. It is used to clear the TX_READY status bit
assign rx_data_read  = r_hs && (ar_addr_latched == REG_RX_DATA); // rx_data_read fires exactly the cycle a read from REG_RX_DATA completes, which is when both the address and data phases have completed. It is used to clear the RX_READY status bit

always_ff @(posedge ACLK or negedge ARESETn) begin
  if (!ARESETn) begin
    done_latched     <= 1'b0;
    tx_ready_latched <= 1'b0;
    rx_ready_latched <= 1'b0;
    error_latched    <= 1'b0;
    qspi_error_d1    <= 1'b0;
  end else begin
    qspi_error_d1 <= qspi_error; // shows us the previous sample of qspi_error, for edge detection

    // DONE: pulse always wins (never miss a completion that happens to
    // land on the same cycle as a clear), then start clears, then W1C.
    if (qspi_done)             done_latched <= 1'b1;
    else if (qspi_start)       done_latched <= 1'b0;
    else if (status_w1c_done)  done_latched <= 1'b0;

    // TX_READY: set on request, clear on the write that services it.
    if (qspi_tx_req)        tx_ready_latched <= 1'b1;
    else if (tx_data_write) tx_ready_latched <= 1'b0;

    // RX_READY: set on valid, clear on the read that services it.
    if (qspi_rx_valid)     rx_ready_latched <= 1'b1;
    else if (rx_data_read) rx_ready_latched <= 1'b0;

    // ERROR: edge-detect the synced level from cdc_bridge, since qspi_error
    // itself stays high until the engine's next start - we only want to
    // latch the moment it *becomes* true, not re-latch every cycle it's held.
    if (qspi_error && !qspi_error_d1) error_latched <= 1'b1;
    else if (qspi_start)              error_latched <= 1'b0;
    else if (status_w1c_error)        error_latched <= 1'b0;
  end
end

/* qspi_start: pulses exactly one ACLK cycle when we write CTRL_CMD
 with the start bit (bit 21) set. do_write already fires precisely on the
 cycle a write completes, using eff_data (live-or-latched, whichever is
 correct for that cycle) - no separate edge-detection needed.
*/
assign qspi_start = do_write && (eff_addr == REG_CTRL_CMD) && eff_data[21];

// qspi_abort: same strobe pattern as start, using the dedicated abort bit.
// Not stored in reg_ctrl_cmd - it's a one-shot action, not a mode setting.
assign qspi_abort = do_write && (eff_addr == REG_CTRL_CMD) && eff_data[CTRL_BIT_ABORT];

always_ff @(posedge ACLK or negedge ARESETn) begin
if (!ARESETn) begin
    reg_ctrl_cmd  <= '0;
    reg_addr      <= '0;
    reg_num_bytes <= '0;
    reg_tx_data   <= '0;
    reg_xip_cfg   <= '0; // XIP_ENABLE defaults to 0 - XIP is off until software explicitly configures and enables it
end else if (do_write) begin
    case (eff_addr)
    REG_CTRL_CMD:  for (int i = 0; i < 4; i++)
                        if (eff_strb[i]) reg_ctrl_cmd[i*8 +: 8] <= eff_data[i*8 +: 8];
    REG_ADDR:      for (int i = 0; i < 4; i++)
                        if (eff_strb[i]) reg_addr[i*8 +: 8] <= eff_data[i*8 +: 8];
    REG_NUM_BYTES: for (int i = 0; i < 4; i++)
                        if (eff_strb[i]) reg_num_bytes[i*8 +: 8] <= eff_data[i*8 +: 8];
    REG_TX_DATA:   for (int i = 0; i < 4; i++)
                        if (eff_strb[i]) reg_tx_data[i*8 +: 8] <= eff_data[i*8 +: 8];
    REG_XIP_CFG:   for (int i = 0; i < 4; i++)
                        if (eff_strb[i]) reg_xip_cfg[i*8 +: 8] <= eff_data[i*8 +: 8];
    default: ;
    endcase
    end
end

// the for loops above are used to handle the write strobe signals, which indicate which bytes of the data are valid. 
// for int i = 0; i < 4; i++ iterates over the 4 bytes of the data, and if the corresponding bit in eff_strb is high, the corresponding byte in reg_ctrl_cmd, reg_addr, reg_num_bytes, or reg_tx_data is updated with the corresponding byte from eff_data.

assign qspi_tx_data = reg_tx_data[7:0];
assign qspi_ctrl_cmd  = reg_ctrl_cmd;
assign qspi_addr      = reg_addr;
assign qspi_num_bytes = reg_num_bytes;

endmodule