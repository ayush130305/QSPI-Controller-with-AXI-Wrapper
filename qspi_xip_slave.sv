// qspi_xip_slave.sv
//
// Memory-mapped, READ-ONLY AXI4-Lite slave. A normal AXI read landing
// anywhere in [XIP_BASE, XIP_BASE+XIP_SIZE) transparently triggers a QSPI
// read through the shared engine (via qspi_arbiter.sv) and returns the
// fetched word as the read response - no register writes, no polling,
// from the requesting master's point of view this looks like ordinary
// memory.
//
// Scope of this first version (see project docs for the full XIP
// discussion): no continuous/burst-read / mode-bits support - every
// single AXI read pays the full CMD+ADDR+DUMMY+DATA overhead of a fresh
// QSPI transaction. This is the correctness-first version; a
// mode-bits-aware continuous-read mode would be a follow-on once
// qspi_engine.sv actually has a mode-bits phase (it doesn't yet).
//
// Configuration (opcode/dummy/width) is fixed for every access, read from
// XIP_CFG (see qspi_axi_pkg.sv) - set once at boot via the existing
// register interface, not re-specified per transaction, since a CPU
// instruction fetch has no way to program a register before each access.

import qspi_axi_pkg::*;

module qspi_xip_slave #(
  parameter logic [31:0] XIP_BASE = 32'h0100_0000,
  parameter logic [31:0] XIP_SIZE = 32'h0100_0000  // 16MB default window
)(
  input  logic        ACLK,
  input  logic        ARESETn,

  input  logic [31:0] AXI_ARADDR,
  input  logic        AXI_ARVALID,
  output logic        AXI_ARREADY,
  output logic [31:0] AXI_RDATA,
  output logic [1:0]  AXI_RRESP,
  output logic        AXI_RVALID,
  input  logic        AXI_RREADY,

  input  logic [31:0] xip_cfg, // from axi4L_slave.sv's reg_xip_cfg

  // To qspi_arbiter.sv
  output logic        x_start,
  output logic [31:0] x_ctrl_cmd,
  output logic [31:0] x_addr,
  output logic [31:0] x_num_bytes,
  input  logic        x_busy,
  input  logic        x_done,
  input  logic        x_error,
  input  logic [7:0]  x_rx_data,
  input  logic        x_rx_valid
);

  localparam int XIP_BEAT_BYTES = 4; // one AXI word per QSPI transaction, this version

  // XIP_SETTLE: a mandatory one-cycle gap between completing a transaction
  // (XIP_RESP) and being ready to accept a new one (XIP_IDLE, where
  // ARREADY reasserts). Without this gap, a transaction that resolves
  // very fast (the immediate-error paths - disabled/out-of-range - can
  // complete in just a couple of cycles) risks the FSM cycling back to
  // IDLE and re-accepting a testbench master's still-lingering ARVALID as
  // a brand-new request, before that master has had a chance to clear it.
  // This is a real, simulator-observable race (it manifested differently
  // under Icarus vs Verilator's scheduling) - closing it here, at the
  // DUT, is more robust than relying on perfect single-cycle timing from
  // every possible master.
  typedef enum logic [2:0] {XIP_IDLE, XIP_REQ, XIP_COLLECT, XIP_RESP, XIP_SETTLE} xip_state_t;
  xip_state_t state;

  logic [31:0] ar_addr_latched;
  logic [31:0] flash_addr;
  logic        addr_in_range_live; // used for the accept/reject decision itself
  logic [31:0] assemble_reg;
  logic [2:0]  byte_count;
  logic        fetch_error;
  logic        engine_busy_seen; // guards against a STALE x_error left over from a
                                 // PREVIOUS transaction still being visible for a few
                                 // cycles into a NEW one - error_r inside qspi_engine.sv
                                 // only clears when a fresh qspi_start is accepted, and
                                 // the CDC-synced view of that clearing (axi_error, a
                                 // 2-flop level sync) lags a few cycles behind the real
                                 // clearing. Waiting for busy to be confirmed high first
                                 // sidesteps this: busy asserts on the same qclk edge
                                 // error_r clears, so by the time THIS new transaction's
                                 // busy is visible through its own CDC path, any leftover
                                 // stale error has had at least as long to clear too.
  logic [3:0]  drain_cnt; // after busy drops, wait a few more cycles before concluding
                          // the transaction was aborted rather than completed normally -
                          // busy (a fast level-sync) can drop before the pulse-synced
                          // rx_valid for the FINAL byte has actually arrived, since the
                          // two use different synchronizer latencies. Same fix pattern as
                          // qspi_arbiter.sv's own DRAIN_CYCLES margin.
  localparam int XIP_DRAIN_CYCLES = 6;
  logic        x_rx_valid_d1; // x_rx_data only settles to its correct new value the
                              // cycle AFTER x_rx_valid pulses (cdc_bridge.sv's
                              // axi_rx_data updates via a same-edge nonblocking
                              // assignment) - sampling on x_rx_valid directly grabs
                              // the stale, one-cycle-old value every time. This
                              // mirrors qspi_engine.sv's byte_boundary_d1 fix exactly.

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) x_rx_valid_d1 <= 1'b0;
    else x_rx_valid_d1 <= x_rx_valid;
  end

  assign flash_addr    = ar_addr_latched - XIP_BASE;
  // addr_in_range_live: must check AXI_ARADDR directly, not ar_addr_latched -
  // the latter is still being updated via NBA on the exact same cycle the
  // accept/reject decision below is made, so reading it here would give the
  // PREVIOUS transaction's range result, not this one's.
  assign addr_in_range_live = (AXI_ARADDR >= XIP_BASE) && (AXI_ARADDR < (XIP_BASE + XIP_SIZE));

  assign AXI_ARREADY = (state == XIP_IDLE); // always ready when idle - disabled/out-of-range
                                             // is handled by responding with an error below,
                                             // NOT by refusing the AR handshake (that would be
                                             // a real AXI protocol violation: a slave must always
                                             // eventually respond to a valid request)
  assign AXI_RVALID  = (state == XIP_RESP);
  assign AXI_RDATA   = assemble_reg;
  assign AXI_RRESP   = fetch_error ? 2'b10 /*DECERR: disabled, bad address, or engine error*/ : 2'b00;

  // x_ctrl_cmd is built fresh from xip_cfg every request - dir is always
  // 0 (read) and start is only actually asserted during XIP_REQ's one
  // cycle (see the always_ff below), everything else is the fixed
  // per-boot XIP configuration.
  assign x_ctrl_cmd  = {9'b0, 1'b0, 1'b1, xip_cfg[20:13], xip_cfg[12], xip_cfg[11:10], xip_cfg[9:8], xip_cfg[7:0]};
  assign x_addr      = flash_addr;
  assign x_num_bytes = 32'(XIP_BEAT_BYTES);

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      state            <= XIP_IDLE;
      ar_addr_latched  <= '0;
      assemble_reg     <= '0;
      byte_count       <= '0;
      fetch_error      <= 1'b0;
      x_start          <= 1'b0;
      engine_busy_seen <= 1'b0;
      drain_cnt        <= '0;
    end else begin
      x_start <= 1'b0; // default: only pulses explicitly below, one cycle

      case (state)
        XIP_IDLE: begin
          if (AXI_ARVALID && AXI_ARREADY) begin
            ar_addr_latched  <= AXI_ARADDR;
            byte_count       <= '0;
            assemble_reg     <= '0;
            engine_busy_seen <= 1'b0;
            drain_cnt        <= '0;
            if (xip_cfg[XIP_CFG_BIT_ENABLE] && addr_in_range_live) begin
              state       <= XIP_REQ;
              fetch_error <= 1'b0;
            end else begin
              // Either XIP isn't enabled, or the address is outside the
              // configured window - accept the handshake (see the
              // ARREADY comment above) but respond with an error rather
              // than ever touching the QSPI engine.
              state       <= XIP_RESP;
              fetch_error <= 1'b1;
            end
          end
        end

        XIP_REQ: begin
          x_start <= 1'b1; // one-cycle request pulse into the arbiter
          state   <= XIP_COLLECT;
        end

        XIP_COLLECT: begin
          if (x_busy) engine_busy_seen <= 1'b1;
          if (engine_busy_seen && x_error) begin
            fetch_error <= 1'b1;
            state       <= XIP_RESP;
          end else if (x_rx_valid_d1) begin
            // Little-endian assembly: the first-arriving byte (lowest
            // address) lands in the LOW byte of the word, matching how a
            // real CPU (ARM, RISC-V, x86) expects a memory-mapped word
            // read to be laid out. This is NOT the same convention as
            // the register path's single-byte RX_DATA (which has no
            // ordering question at all, being one byte) - it only
            // matters here because XIP assembles multiple bytes into one
            // word for a real fetch unit to consume.
            //
            // This check must come BEFORE the busy-dropped abort
            // detection below: busy legitimately drops on/around the
            // same cycle as the FINAL byte's valid pulse during a normal
            // completion, and checking abort-detection first would steal
            // that cycle, losing the last byte and misreporting a
            // successful fetch as an aborted one.
            case (byte_count)
              0: assemble_reg[7:0]   <= x_rx_data;
              1: assemble_reg[15:8]  <= x_rx_data;
              2: assemble_reg[23:16] <= x_rx_data;
              3: assemble_reg[31:24] <= x_rx_data;
            endcase
            if (byte_count == XIP_BEAT_BYTES - 1) begin
              state <= XIP_RESP;
            end else begin
              byte_count <= byte_count + 1'b1;
            end
          end else if (engine_busy_seen && !x_busy) begin
            // busy has dropped. This could mean either (a) the transaction
            // completed normally and the final byte's rx_valid_d1 pulse is
            // still in flight (it uses a slower, pulse-synced path than
            // busy's fast level-sync, so it can genuinely arrive a few
            // cycles after busy itself drops), or (b) a real abort cut the
            // transaction short and no more pulses are ever coming. Wait
            // XIP_DRAIN_CYCLES to distinguish the two - same fix pattern
            // as qspi_arbiter.sv's own DRAIN_CYCLES margin. Only declare
            // an abort/error if that whole window passes with nothing
            // arriving.
            if (drain_cnt == XIP_DRAIN_CYCLES - 1) begin
              fetch_error <= 1'b1;
              state       <= XIP_RESP;
            end else begin
              drain_cnt <= drain_cnt + 1'b1;
            end
          end
        end

        XIP_RESP: begin
          if (AXI_RVALID && AXI_RREADY) begin
            state <= XIP_SETTLE;
          end
        end

        XIP_SETTLE: begin
          state <= XIP_IDLE; // ARREADY only reasserts starting next cycle
        end

        default: state <= XIP_IDLE;
      endcase
    end
  end

endmodule