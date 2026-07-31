// qspi_arbiter.sv
//
// Sits between the two ACLK-domain requesters of the QSPI engine - the
// existing register-based interface (axi4L_slave.sv) and the new
// memory-mapped XIP interface (qspi_xip_slave.sv) - and cdc_bridge.sv,
// which only has one set of request/response ports. Only one requester
// can actually be talking to the engine at a time; this module decides
// who, and makes sure each requester only ever sees ITS OWN completion,
// not the other's.
//
// Priority: if both request in the same cycle, the register interface
// wins - explicit software control takes priority over an opportunistic
// instruction/data prefetch. This is a simple, non-preemptive arbiter:
// once granted, a requester holds the engine until its own transaction
// finishes, the other requester just waits.
//
// Grant-release timing: releasing on "busy has dropped" is NOT enough by
// itself - axi_busy takes several ACLK cycles to actually assert after
// axi_start fires, due to the ACLK<->qclk CDC round trip (same class of
// race documented in the cocotb testbench's wait_for_done task). If the
// arbiter released the grant the moment it saw axi_busy==0 without first
// confirming busy had genuinely gone high, it would release the grant
// before the transaction even started. busy_seen tracks that the engine
// has actually gone busy at least once before treating it dropping again
// as real completion. Also note: qspi_done only pulses on NORMAL
// completion, not on abort or timeout - so release is gated on busy
// dropping, not on done pulsing, or an aborted/timed-out transaction
// would leave the grant stuck forever.

module qspi_arbiter (
  input  logic        ACLK,
  input  logic        ARESETn,

  // Register-path requester (axi4L_slave.sv)
  input  logic        a_start,
  input  logic        a_abort,
  input  logic [31:0] a_ctrl_cmd,
  input  logic [31:0] a_addr,
  input  logic [31:0] a_num_bytes,
  input  logic [7:0]  a_tx_data,
  output logic        a_busy,
  output logic        a_done,
  output logic        a_error,
  output logic        a_tx_req,
  output logic [7:0]  a_rx_data,
  output logic        a_rx_valid,

  // XIP-path requester (qspi_xip_slave.sv) - read-only, no abort/tx_data
  input  logic        x_start,
  input  logic [31:0] x_ctrl_cmd,
  input  logic [31:0] x_addr,
  input  logic [31:0] x_num_bytes,
  output logic        x_busy,
  output logic        x_done,
  output logic        x_error,
  output logic [7:0]  x_rx_data,
  output logic        x_rx_valid,

  // Merged path to cdc_bridge.sv - same ports axi4L_slave.sv used to
  // connect to directly before the arbiter existed
  output logic        axi_start,
  output logic        axi_abort,
  output logic [31:0] axi_ctrl_cmd,
  output logic [31:0] axi_addr,
  output logic [31:0] axi_num_bytes,
  output logic [7:0]  axi_tx_data,
  input  logic        axi_busy,
  input  logic        axi_done,
  input  logic        axi_error,
  input  logic        axi_tx_req,
  input  logic [7:0]  axi_rx_data,
  input  logic        axi_rx_valid
);

  typedef enum logic [1:0] {GNT_NONE, GNT_REG, GNT_XIP} grant_t;
  grant_t      grant;
  logic        busy_seen;
  logic [3:0]  drain_cnt;

  // DRAIN_CYCLES: after busy drops, hold the grant a few more cycles
  // before actually releasing it. This exists because axi_busy (a plain
  // 2-flop level sync) and axi_rx_valid/axi_tx_req/axi_done (toggle-based
  // pulse syncs, with more synchronizer stages - see pulse_sync.sv) don't
  // necessarily resolve on the same ACLK cycle even for the same
  // underlying qclk-domain event. Without this margin, busy can read 0
  // one or two cycles before the LAST rx_valid/tx_req pulse for that same
  // transaction arrives - releasing the grant right then would silently
  // drop that final pulse instead of routing it to the requester it
  // belongs to.
  localparam int DRAIN_CYCLES = 4;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      grant     <= GNT_NONE;
      busy_seen <= 1'b0;
      drain_cnt <= '0;
    end else begin
      case (grant)
        GNT_NONE: begin
          busy_seen <= 1'b0;
          drain_cnt <= '0;
          // Register-path priority: if both a_start and x_start happen to
          // fire the same cycle, explicit software control wins over an
          // opportunistic prefetch.
          if (a_start) grant <= GNT_REG;
          else if (x_start) grant <= GNT_XIP;
        end
        GNT_REG, GNT_XIP: begin
          if (axi_busy) begin
            busy_seen <= 1'b1;
            drain_cnt <= '0;
          end else if (busy_seen) begin
            if (drain_cnt == DRAIN_CYCLES - 1) begin
              grant     <= GNT_NONE;
              busy_seen <= 1'b0;
              drain_cnt <= '0;
            end else begin
              drain_cnt <= drain_cnt + 1'b1;
            end
          end
        end
        default: begin grant <= GNT_NONE; busy_seen <= 1'b0; drain_cnt <= '0; end
      endcase
    end
  end

  // Forward whichever requester currently holds (or is about to be
  // granted) the engine. a_start/x_start are used directly here (not the
  // registered grant) for the actual START pulse, since grant only
  // updates on the NEXT edge - the qspi_start pulse itself needs to reach
  // cdc_bridge the SAME cycle the request fires, not one cycle later.
  always_comb begin
    axi_start     = 1'b0;
    axi_abort     = 1'b0;
    axi_ctrl_cmd  = '0;
    axi_addr      = '0;
    axi_num_bytes = '0;
    axi_tx_data   = '0;

    unique case (grant)
      GNT_NONE: begin
        if (a_start) begin
          axi_start     = a_start;
          axi_abort     = a_abort;
          axi_ctrl_cmd  = a_ctrl_cmd;
          axi_addr      = a_addr;
          axi_num_bytes = a_num_bytes;
          axi_tx_data   = a_tx_data;
        end else if (x_start) begin
          axi_start     = x_start;
          axi_ctrl_cmd  = x_ctrl_cmd;
          axi_addr      = x_addr;
          axi_num_bytes = x_num_bytes;
        end
      end
      GNT_REG: begin
        axi_start     = a_start;
        axi_abort     = a_abort;
        axi_ctrl_cmd  = a_ctrl_cmd;
        axi_addr      = a_addr;
        axi_num_bytes = a_num_bytes;
        axi_tx_data   = a_tx_data;
      end
      GNT_XIP: begin
        axi_start     = x_start;
        axi_ctrl_cmd  = x_ctrl_cmd;
        axi_addr      = x_addr;
        axi_num_bytes = x_num_bytes;
      end
      default: ;
    endcase
  end

  // Response routing: each requester only ever sees busy/done/error/
  // tx_req/rx_data/rx_valid while IT holds the grant (or is about to,
  // same-cycle as GNT_NONE above) - the other requester's transaction
  // completing never looks like "my transaction finished" to the wrong side.
  logic route_to_reg, route_to_xip;
  assign route_to_reg = (grant == GNT_REG) || (grant == GNT_NONE && a_start);
  assign route_to_xip = (grant == GNT_XIP) || (grant == GNT_NONE && !a_start && x_start);

  // rx_data is NOT gated by grant - it's a held value with no meaning of
  // its own; it's only ever acted on by whichever side also sees its OWN
  // gated rx_valid pulse below. Gating the data itself (as an earlier
  // version of this file did) breaks the register path specifically:
  // software reads REG_RX_DATA only AFTER busy has dropped and grant has
  // already released back to GNT_NONE, and zeroing rx_data at that point
  // clobbers the very value it's trying to read.
  assign a_rx_data  = axi_rx_data;
  assign x_rx_data  = axi_rx_data;

  assign a_busy     = route_to_reg ? axi_busy     : 1'b0;
  assign a_done     = route_to_reg ? axi_done     : 1'b0;
  assign a_error    = route_to_reg ? axi_error    : 1'b0;
  assign a_tx_req   = route_to_reg ? axi_tx_req   : 1'b0;
  assign a_rx_valid = route_to_reg ? axi_rx_valid : 1'b0;

  assign x_busy     = route_to_xip ? axi_busy     : 1'b0;
  assign x_done     = route_to_xip ? axi_done     : 1'b0;
  assign x_error    = route_to_xip ? axi_error    : 1'b0;
  assign x_rx_valid = route_to_xip ? axi_rx_valid : 1'b0;

endmodule