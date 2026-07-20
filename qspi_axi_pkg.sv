//imported by axi4L_slave.sv and cdc_bridge.sv to define the register map and other constants used in the QSPI AXI4-Lite interface.

package qspi_axi_pkg;
  localparam int REG_CTRL_CMD  = 'h00; // multibit control register for the QSPI engine
  localparam int REG_ADDR      = 'h04; // multibit address register for the QSPI engine
  localparam int REG_NUM_BYTES = 'h08; // multibit register to specify the number of bytes to transfer
  localparam int REG_STATUS    = 'h0C; // read-only status register to monitor the QSPI engine's state and flags
  localparam int REG_TX_DATA   = 'h10; // multibit register to write data to be transmitted over QSPI
  localparam int REG_RX_DATA   = 'h14; // multibit register to read data received over QSPI

  localparam int STATUS_BIT_BUSY     = 0; // level, read-only
  localparam int STATUS_BIT_DONE     = 1; // once high stays high until software writes REG_STATUS with bit1 set to 1
  localparam int STATUS_BIT_TX_READY = 2; // once high stays high until software writes REG_TX_DATA
  localparam int STATUS_BIT_RX_READY = 3; // once high stays high until software reads REG_RX_DATA
  localparam int STATUS_BIT_ERROR    = 4; // goes high if the engine's safety-net timeout fires, stays high until software writes REG_STATUS with bit4 set to 1
  //   bits5-31 reserved, read as 0

  // CTRL_CMD register bit layout (existing bits unchanged):
  //   bit22 dir, bit21 start, bits20:13 dummy_cycles, bit12 addr_width,
  //   bits11:10 data_lines, bits9:8 addr_lines, bits7:0 opcode
  //   bit23 ABORT (new) - write 1 to immediately cancel any in-progress
  //   transaction, regardless of what phase it's in. Not a stored control
  //   bit - it's a strobe, same as start.
  localparam int CTRL_BIT_ABORT = 23; //used to stop any in process transaction, regardless of what phase it's in. Not a stored control bit - it's a strobe, same as start.

  localparam logic [1:0] LW_SINGLE = 2'd0; // single line (1-bit) data transfer
  localparam logic [1:0] LW_DUAL   = 2'd1; // dual line (2-bit) data transfer
  localparam logic [1:0] LW_QUAD   = 2'd2; // quad line (4-bit) data transfer

  /* AXI4-Lite transaction state machines,IDLE state is common to both, so we can use 2-bit state variables for each. ADDR_OK and DATA_OK are mutually exclusive, so we can use a single 2-bit state variable for both.
  RESP is the final state where the slave responds to the master. */
  typedef enum logic [1:0] {
    IDLE, ADDR_OK, DATA_OK, RESP
  } write_state_t;

  /*
    Read logic is simpler as it only handles the address phase and the data phase, so we can use a single 2-bit state variable for both.
  */
  typedef enum logic [1:0] {
    READ_IDLE, READ_RESP
  } read_state_t;
endpackage