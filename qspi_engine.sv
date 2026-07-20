// qspi_engine.sv
//
// This is the actual QSPI shift engine - the module that walks through a
// transaction's CMD -> ADDR -> DUMMY -> DATA phases and drives/samples the
// physical io0-io3 pins. 
//It has no AXI awareness at all;
// sclk/sclk_rst here are the SAME qclk/qclk_rst used everywhere else in
// this design - "sclk" is just this module's own name for its clock input,
// not a separate clock domain. sclk_rst is active-HIGH (opposite polarity
// from ARESETn in the AXI-side file), which is why every always_ff below
// uses "posedge sclk_rst" instead of "negedge".
module qspi_engine #(
  /* Safety-net timeout: if a transaction stays busy for longer than this
   many sclk cycles, force an abort and flag qspi_error. */
  parameter int unsigned TIMEOUT_CYCLES = 20'hFFFFF
)(
  input  logic sclk,
  input  logic sclk_rst,

  output logic cs_n, // active-low chip select to the flash chip - low exactly while busy_r is 1

  /* 
   io0-io3 are the 4 physical, bidirectional QSPI data lines. Each has an
   output value, an output-enable (drive vs tri-state), and an input
   value (what's actually on the wire, whether we're driving it or not).
   */
  output logic io0_out, output logic io0_oe, input logic io0_in,
  output logic io1_out, output logic io1_oe, input logic io1_in,
  output logic io2_out, output logic io2_oe, input logic io2_in,
  output logic io3_out, output logic io3_oe, input logic io3_in,

  input  logic        qspi_start, // pulse to start a transaction
  input  logic        qspi_abort,   // already-synced pulse: cancel now, whatever phase we're in
  input  logic [31:0] qspi_ctrl_cmd, // multibit data to control the QSPI engine
  input  logic [31:0] qspi_addr, // multibit data to control the QSPI engine
  input  logic [31:0] qspi_num_bytes, // multibit data to control the QSPI engine
  output logic        qspi_busy, // set if the engine is currently processing a transaction
  output logic        qspi_done, // pulse to indicate the engine has completed the transaction
  output logic        qspi_error,   // set if the timeout safety net fired
  input  logic [7:0]  qspi_tx_data, // multibit data to be transmitted over QSPI
  output logic        qspi_tx_req, // pulse request to transmit data over QSPI
  output logic [7:0]  qspi_rx_data, // multibit data received over QSPI
  output logic        qspi_rx_valid 
);

  // bit 22 "dir" is a project addition to the register map: 0=read, 1=write
  //
  // This struct is packed directly from qspi_ctrl_cmd[22:0] (see the
  // latching always_ff below) 
  typedef struct packed {
    logic        dir;           // 0 = read (flash drives DATA phase), 1 = write (we drive it)
    logic        start;         // present here because it's part of the same CTRL_CMD word, but
                                 // qspi_start (already a clean synced pulse) is what actually
                                 // triggers a transaction - this bit isn't read back out of ctrl
    logic [7:0]  dummy_cycles;  // how many DATA-direction-turnaround cycles to insert (see phase FSM)
    logic        addr_width;    // 0 = 24-bit address, 1 = 32-bit address
    logic [1:0]  data_lines;    // DATA phase width: LW_S/LW_D/LW_Q
    logic [1:0]  addr_lines;    // ADDR phase width: LW_S/LW_D/LW_Q (CMD phase is always single-line)
    logic [7:0]  opcode;        // the flash command byte, sent single-line during CMD phase
  } qspi_ctrl_t;

  // Line-width encoding shared by addr_lines and data_lines - S/D/Q for
  // single/dual/quad, i.e. 1/2/4 bits transferred per sclk cycle.
  localparam logic [1:0] LW_S = 2'd0, LW_D = 2'd1, LW_Q = 2'd2;

  // The four phases of one QSPI transaction, walked in this order:
  //   CMD   - always 1 line, always master-driven: the opcode byte
  //   ADDR  - master-driven, width from ctrl.addr_lines
  //   DUMMY - nobody drives (bus turnaround time before a read's DATA
  //           phase flips direction to slave-driven) - skipped entirely
  //           if ctrl.dummy_cycles == 0
  //   DATA  - direction depends on ctrl.dir; width from ctrl.data_lines
  typedef enum logic [1:0] { CMD, ADDR, DUMMY, DATA } phase_t;
  phase_t phase;
  // Widened from 11 to 16 bits (was previously derived from num_bytes[7:0],
  // which silently wrapped at 256 bytes - see phase_limit computation below).
  logic [15:0] bit_cnt;      // cycles elapsed within the CURRENT phase (resets every phase change)
  logic        busy_r;       // 1 while a transaction is in flight, 0 when idle - drives cs_n directly

  qspi_ctrl_t  ctrl;         // latched copy of qspi_ctrl_cmd, stable for the whole transaction
  logic [31:0] addr_lat;     // latched copy of qspi_addr
  logic [31:0] num_bytes_lat;// latched copy of qspi_num_bytes

  
  always_ff @(posedge sclk or posedge sclk_rst) begin
    if (sclk_rst) begin
      ctrl <= '0; addr_lat <= '0; num_bytes_lat <= '0;
    end else if (!busy_r && qspi_start) begin
      ctrl          <= qspi_ctrl_t'(qspi_ctrl_cmd[22:0]);
      addr_lat      <= qspi_addr;
      num_bytes_lat <= qspi_num_bytes;
    end
  end

  /* Converts a line-width encoding into how many bits move per sclk cycle -
   used everywhere a cycle count or shift amount depends on width (address
   clock count, data clock count, and the per-cycle shift amount itself). */
  function automatic int unsigned lines_per_clock(logic [1:0] lw);
    case (lw)
      LW_S: lines_per_clock = 1; 
      LW_D: lines_per_clock = 2;
      LW_Q: lines_per_clock = 4;
      default: lines_per_clock = 1;
    endcase
  endfunction

  
  
  logic [15:0] phase_limit, addr_clocks, data_clocks;

  always_comb begin
    // addr_clocks/data_clocks: total bits needed (address width or
    // num_bytes*8) divided by how many bits move per cycle at the
    // configured line width - e.g. a 24-bit address at quad width takes
    // 24/4 = 6 cycles, not 24.
    addr_clocks = (ctrl.addr_width ? 16'd32 : 16'd24) / lines_per_clock(ctrl.addr_lines);
    data_clocks = (16'(num_bytes_lat[11:0]) * 16'd8) / lines_per_clock(ctrl.data_lines);
    case (phase)
      CMD:   phase_limit = 16'd7; // opcode is always exactly 8 bits, single-line -> 8 cycles, limit=7
      ADDR:  phase_limit = addr_clocks - 1'b1;
      DUMMY: phase_limit = (ctrl.dummy_cycles == 0) ? 16'd0 : {8'b0, ctrl.dummy_cycles} - 16'd1;
      DATA:  phase_limit = (data_clocks == 0) ? 16'd0 : data_clocks - 1'b1;
      default: phase_limit = 16'd0;
    endcase
  end

  // Timeout safety net - counts sclk cycles while busy; if a transaction
  // never completes (stuck flash, misconfiguration, etc.) this forces an
  // abort rather than leaving busy asserted forever with no way out.
  logic [31:0] timeout_cnt; // deliberately much wider than bit_cnt needs to be -
                            // TIMEOUT_CYCLES is meant to catch pathological cases
                            // (e.g. a misconfigured DUMMY that never ends), not just
                            // count up to the largest legitimate phase_limit
  logic        timeout_hit;
  assign timeout_hit = busy_r && (timeout_cnt >= TIMEOUT_CYCLES);

  always_ff @(posedge sclk or posedge sclk_rst) begin
    if (sclk_rst) timeout_cnt <= '0;
    else if (!busy_r) timeout_cnt <= '0; // reset every time we go idle, not just on sclk_rst
    else timeout_cnt <= timeout_cnt + 1'b1;
  end

  logic error_r; // latched until the next accepted start (see phase-transition FSM below) -
                 // axi4L_slave.sv is what actually gives software a sticky, W1C view of this
  assign qspi_error = error_r;

  // Phase transition - busy_r prevents free-running after reset/completion.
  // qspi_abort and timeout_hit both take priority over everything else -
  // an abort or timeout ends the transaction immediately regardless of
  // what phase/bit_cnt it was in.
  always_ff @(posedge sclk or posedge sclk_rst) begin
    if (sclk_rst) begin
      phase <= CMD; bit_cnt <= '0; busy_r <= 1'b0; error_r <= 1'b0;
    end else if (qspi_abort || timeout_hit) begin
      // Highest priority, unconditionally - whatever phase/bit_cnt we were
      // at is simply abandoned. cs_n deasserts on the very next cycle
      // since it's just "!busy_r" (see assign below), and phase resets to
      // CMD so the engine is immediately ready to accept a fresh start.
      busy_r <= 1'b0; phase <= CMD; bit_cnt <= '0;
      if (timeout_hit) error_r <= 1'b1; // an explicit abort is NOT an error - only timeout is
    end else if (!busy_r) begin
      // Idle: the only thing that can happen is accepting a new start.
      // Ignoring qspi_start entirely while busy_r is already 1 is what
      // makes "start while busy" a documented no-op rather than a
      // mid-transaction reset (see the start_while_busy_ignored test).
      if (qspi_start) begin
        busy_r <= 1'b1; phase <= CMD; bit_cnt <= '0; error_r <= 1'b0;
      end
    end else if (bit_cnt == phase_limit) begin
      // This phase just finished (this cycle was its last).
      if (phase == DATA) begin
        // DATA is the last phase of every transaction - finishing it
        // means the whole transfer is done, not just moving to another
        // phase. qspi_done (below) fires combinationally off this exact
        // condition on this exact cycle.
        busy_r <= 1'b0; phase <= CMD; bit_cnt <= '0;
      end else begin
        // Any other phase finishing just advances to the next one.
        bit_cnt <= '0;
        case (phase)
          CMD:   phase <= ADDR;
          ADDR:  phase <= (ctrl.dummy_cycles > 0) ? DUMMY : DATA; // skip DUMMY entirely if 0 cycles configured
          DUMMY: phase <= DATA;
          default: phase <= CMD;
        endcase
      end
    end else begin
      // Still mid-phase - just keep counting.
      bit_cnt <= bit_cnt + 1'b1;
    end
  end

  assign qspi_busy = busy_r;
  // qspi_done: a single-cycle pulse on the exact same cycle busy_r is
  // about to drop (i.e. the last cycle of the DATA phase). This is a raw,
  // unlatched pulse at this module's boundary - cdc_bridge.sv carries it
  // across to the AXI clock domain, and axi4L_slave.sv is what actually
  // latches it into something software can reliably poll (see STATUS.DONE
  // in that file's comments).
  assign qspi_done = busy_r && phase == DATA && bit_cnt == phase_limit;
  assign cs_n      = !busy_r; // chip select is simply "are we in a transaction" - asserted
                              // (driven low) for the CMD/ADDR/DUMMY/DATA phases as a block,
                              // deasserted the instant busy_r drops for any reason (normal
                              // completion, abort, or timeout)

 
  // out_shift carries the opcode AND the address together as one 40-bit
  // shift register: 8 bits of opcode + up to 32 bits of address, loaded
  // once at start and shifted left through both the CMD and ADDR phases
  // back to back. Combining them into one register (rather than two
  // separate ones) is what makes the CMD->ADDR phase transition seamless -
  // there's no re-load event between them, the same register just keeps
  // shifting, picking up in ADDR exactly where CMD left off.
  //
  // Loading: for a 32-bit address (qspi_ctrl_cmd[12]=1) the low 32 bits are
  // qspi_addr directly. For a 24-bit address, only qspi_addr[23:0] is used
  // and the register is padded with 8'h00 underneath - since only 24 of
  // those low 32 bits ever actually get shifted out (ADDR phase's own
  // cycle count is sized for 24 bits in that case), the padding is never
  // observed on the wire, it's just there to keep the concatenation a
  // fixed 40 bits either way.
  logic [39:0] out_shift;
  always_ff @(posedge sclk or posedge sclk_rst) begin
    if (sclk_rst) out_shift <= '0;
    else if (!busy_r && qspi_start)
      out_shift <= qspi_ctrl_cmd[12] ? {qspi_ctrl_cmd[7:0], qspi_addr}
                                      : {qspi_ctrl_cmd[7:0], qspi_addr[23:0], 8'h00};
    else if (busy_r && phase == CMD)
      out_shift <= out_shift << 1; // CMD is always single-line: exactly 1 bit/cycle
    else if (busy_r && phase == ADDR)
      out_shift <= out_shift << lines_per_clock(ctrl.addr_lines); // ADDR width is configurable
  end

  
  // tx_shift_byte/in_byte are the DATA-phase equivalent of out_shift above,
  // but scoped to a single byte at a time rather than the whole CMD+ADDR
  // run - because DATA can be many bytes long (up to 4095), and each byte
  // needs its own fresh load (write) or gets fully reassembled from
  // scratch (read) rather than one giant shift register sized for the
  // whole transfer.
  logic [7:0] tx_shift_byte, in_byte;
  logic [3:0] clocks_per_byte;   // 8 / lines_per_clock: 8 (single), 4 (dual), 2 (quad)
  logic [3:0] byte_bit_cnt;      // position within the current byte, 0..clocks_per_byte-1
  logic       byte_boundary;     // true on the last clock of each byte

  assign clocks_per_byte = 4'(8 / lines_per_clock(ctrl.data_lines));
  assign byte_boundary   = busy_r && phase == DATA &&
                           (byte_bit_cnt == clocks_per_byte - 4'd1);

  // Separate from bit_cnt above - bit_cnt tracks position within the whole
  // DATA phase (all bytes combined), byte_bit_cnt tracks position within
  // just the CURRENT byte, wrapping back to 0 every clocks_per_byte cycles
  // regardless of how many total bytes remain. Both counters run
  // simultaneously throughout DATA; bit_cnt is what phase_limit compares
  // against to end the whole phase, byte_bit_cnt is what drives per-byte
  // events (byte_boundary, and the tx/rx logic below).
  always_ff @(posedge sclk or posedge sclk_rst) begin
    if (sclk_rst) begin
      byte_bit_cnt <= '0;
    end else if (busy_r && phase == DATA) begin
      if (byte_bit_cnt == clocks_per_byte - 4'd1) byte_bit_cnt <= '0;
      else byte_bit_cnt <= byte_bit_cnt + 4'd1;
    end else begin
      byte_bit_cnt <= '0; // reset whenever we're not actively in DATA, so a fresh
                          // transaction (or a fresh DATA phase after ADDR/DUMMY)
                          // always starts a byte cleanly at position 0
    end
  end

  // The DATA-phase tx/rx logic is a bit more complicated than CMD/ADDR
  // because DATA can be many bytes long, and each byte needs its own
  // load (write) or reassembly (read). The tx_shift_byte register is loaded
  // with a fresh byte from qspi_tx_data on the first cycle of DATA (after
  // ADDR/DUMMY) and on every subsequent byte_boundary. The in_byte register
  // is reassembled from the io*_in lines every cycle of DATA, and is
  // presented to qspi_rx_data on the cycle after each byte_boundary (see
  // the delayed rx_valid below).
  logic entering_data_from_addr, entering_data_from_dummy;
  assign entering_data_from_addr  = busy_r && phase == ADDR  && bit_cnt == phase_limit && ctrl.dummy_cycles == 0;
  assign entering_data_from_dummy = busy_r && phase == DUMMY && bit_cnt == phase_limit;

  always_ff @(posedge sclk or posedge sclk_rst) begin
    if (sclk_rst) begin
      tx_shift_byte <= '0; in_byte <= '0;
    end else if (ctrl.dir && (entering_data_from_addr || entering_data_from_dummy ||
                               byte_boundary)) begin
      tx_shift_byte <= qspi_tx_data; // ctrl.dir gate means this whole branch only exists for writes -
                                     // on a read, this condition is always false regardless of phase
    end else if (busy_r && phase == DATA) begin
      if (ctrl.dir) begin
        // The load branch above already claims the specific edges where a
        // fresh byte needs to land (entry into DATA, and each
        // byte_boundary) - every other DATA-phase cycle just shifts.
        tx_shift_byte <= tx_shift_byte << lines_per_clock(ctrl.data_lines);
      end else begin
        // Only sample the IO lines actually active for the current
        // data_lines width - previously this unconditionally OR'd in all
        // 4 lines regardless of width, so single/dual-line reads picked up
        // whatever io1_in/io2_in/io3_in happened to be floating at (they're
        // legitimately unused/undriven in those modes on real hardware).
        case (ctrl.data_lines)
          LW_S: in_byte <= (in_byte << 1) | {7'b0, io0_in};
          LW_D: in_byte <= (in_byte << 2) | {6'b0, io1_in, io0_in};
          LW_Q: in_byte <= (in_byte << 4) | {4'b0, io3_in, io2_in, io1_in, io0_in};
          default: in_byte <= (in_byte << 1) | {7'b0, io0_in};
        endcase
      end
    end
  end

  /* qspi_tx_req and qspi_rx_valid are the two signals that cross the clock domain to the AXI side. 
  tx_req is a pulse that fires one cycle early (on the last cycle of the current byte) to give the AXI side time to prepare the next byte, 
  while rx_valid fires one cycle late (on the first cycle of the next byte) to indicate that the current byte has been fully received. 
  This is why rx_valid is delayed by one cycle using byte_boundary_d1, while tx_req is not delayed. 
  The comments above explain the reasoning behind this design */
  logic byte_boundary_d1;
  always_ff @(posedge sclk or posedge sclk_rst) begin
    if (sclk_rst) byte_boundary_d1 <= 1'b0;
    else byte_boundary_d1 <= byte_boundary;
  end

  assign qspi_tx_req   = byte_boundary && ctrl.dir;
  // Deliberately NOT delayed by one cycle the way qspi_rx_valid is below -
  // tx_req means "get the NEXT byte ready soon", fired one cycle early on
  // purpose to give cdc_bridge's round trip to the AXI domain and back
  // some lead time before the engine actually needs that byte (at the
  // following byte's byte_bit_cnt==0). rx_valid means the opposite - "this
  // byte is done NOW" - so it needs the settled, not the early, timing.
  assign qspi_rx_valid = byte_boundary_d1 && !ctrl.dir;
  assign qspi_rx_data  = in_byte;

  // Pin driving: for every phase/direction/width combination, decide which
  // io*_oe lines this engine drives and what value goes on them. Whatever
  // isn't explicitly set here defaults to 0/tri-stated from the top of the
  // block - this is what makes DUMMY phase and read-direction DATA both
  // correctly drive nothing (no case branch needed for either).
  always_comb begin
    io0_oe=0; io1_oe=0; io2_oe=0; io3_oe=0;
    io0_out=0; io1_out=0; io2_out=0; io3_out=0;

    if (busy_r) begin
      case (phase)
        CMD: begin
          // Always single-line regardless of any width setting - see the
          // qspi_ctrl_t field comments above for why (backward compatibility
          // with chips that don't support wider CMD phases at all).
          io0_oe = 1; io0_out = out_shift[39];
        end
        ADDR: case (ctrl.addr_lines)
          // out_shift's top bits are read directly here since CMD already
          // shifted the register left by 8 (or by whatever CMD consumed) -
          // ADDR just continues reading from wherever CMD left off, no
          // separate re-indexing needed.
          LW_S: begin io0_oe=1; io0_out=out_shift[39]; end
          LW_D: begin io0_oe=1; io1_oe=1; io1_out=out_shift[39]; io0_out=out_shift[38]; end
          LW_Q: begin io0_oe=1; io1_oe=1; io2_oe=1; io3_oe=1;
                io3_out=out_shift[39]; io2_out=out_shift[38];
                io1_out=out_shift[37]; io0_out=out_shift[36]; end
          default: ;
        endcase
        DATA: if (ctrl.dir) case (ctrl.data_lines)
          // Only reached on writes (ctrl.dir==1) - on a read, this whole
          // case is skipped, leaving the io*_oe defaults (all 0) in place
          // so the flash chip can drive the lines instead.
          LW_S: begin io0_oe=1; io0_out=tx_shift_byte[7]; end
          LW_D: begin io0_oe=1; io1_oe=1; io1_out=tx_shift_byte[7]; io0_out=tx_shift_byte[6]; end
          LW_Q: begin io0_oe=1; io1_oe=1; io2_oe=1; io3_oe=1;
                io3_out=tx_shift_byte[7]; io2_out=tx_shift_byte[6];
                io1_out=tx_shift_byte[5]; io0_out=tx_shift_byte[4]; end
          default: ;
        endcase
        // DUMMY: defaults already correct (nobody drives)
        default: ;
      endcase
    end
  end

endmodule