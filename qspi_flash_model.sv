// qspi_flash_model.sv
//
// Generalized behavioral QSPI peripheral for verification use.
// Handles both read and write direction, any data-line width, both
// 24-bit/32-bit addressing, and now single/dual/quad-line ADDRESS phase
// too - all decoded from the OPCODE byte received during the CMD phase,
// the way a real flash chip would, rather than being told directly by
// the testbench what to expect.
//
// Opcode table (borrows real Winbond/Macronix-style codes where they
// exist; 0xF0/0xEB/0xBD are fictional test-only codes - see notes below):
//   0x03  Read Data                    1-1-1  addr=3B  dummy=0
//   0x0B  Fast Read                    1-1-1  addr=3B  dummy=8
//   0x3B  Dual Output Fast Read        1-1-2  addr=3B  dummy=8
//   0x6B  Quad Output Fast Read        1-1-4  addr=3B  dummy=8
//   0x02  Page Program                 1-1-1  addr=3B  dummy=0  (write)
//   0x32  Quad Page Program            1-1-4  addr=3B  dummy=0  (write)
//   0x13  Read Data, 4-byte addr       1-1-1  addr=4B  dummy=0
//   0x0C  Fast Read, 4-byte addr       1-1-1  addr=4B  dummy=8
//   0x6C  Quad Output Fast Read, 4B    1-1-4  addr=4B  dummy=8
//   0xF0  ** non-standard, test-fixture only ** quad output read, addr=3B,
//         dummy=0 - no real flash chip has a zero-dummy quad read; this
//         exists purely so the testbench can exercise dummy_cycles==0
//         without inventing a whole separate addressing mode for it.
//   0xBD  ** non-standard, test-fixture only ** dual address + dual data,
//         addr=3B, dummy=8 - exercises the DUT's dual-line ADDRESS phase,
//         which nothing else in this table touches (everything above
//         sends the address single-line regardless of data width, same
//         as real 1-1-x opcodes).
//   0xEB  ** simplified, test-fixture only ** quad address + quad data,
//         addr=3B, dummy=8 - real Fast Read Quad I/O (also 0xEB on most
//         parts) additionally uses mode bits after the address; this
//         model skips that nuance and just goes straight to dummy cycles.
//         Exercises the DUT's quad-line ADDRESS phase.
//   anything else -> defaults to the 0x0B behavior (single/3B/dummy8)

module qspi_flash_model #(
  parameter int MEM_SIZE = 256
)(
  input  logic       qclk, // same clock the DUT's qspi_engine runs on - this model isn't a
                           // separate clock domain, it's a peer on the same wire
  input  logic       cs_n, // driven BY the DUT (this model never drives it) - phase resets
                           // to FM_CMD whenever this goes high, mirroring how a real chip
                           // forgets everything about the previous transaction once
                           // deselected

  // io0_in..io3_in: what this model reads off the shared bus - during
  // phases the DUT drives (CMD, ADDR, and DATA-on-a-write), these reflect
  // the DUT's io*_out. During phases THIS model drives (DATA-on-a-read),
  // reading them back would just be self-loopback, so they're unused there.
  input  logic       io0_in,
  input  logic       io1_in,
  input  logic       io2_in,
  input  logic       io3_in,
  // io0_out/io0_oe..: this model's own drive outputs, only actually
  // asserted (io*_oe=1) during a read's DATA phase - see the pin-driving
  // always_comb at the bottom of this file.
  output logic       io0_out, output logic io0_oe,
  output logic       io1_out, output logic io1_oe,
  output logic       io2_out, output logic io2_oe,
  output logic       io3_out, output logic io3_oe,

  output logic       written_valid, // pulses one qclk cycle whenever a full byte has
                                     // been captured on a write - the testbench watches
                                     // this to build up a list of "what did the model see"
  output logic [7:0] written_byte
);

  localparam logic [1:0] LW_S = 2'd0, LW_D = 2'd1, LW_Q = 2'd2; // same S/D/Q width
                                                                  // encoding as qspi_engine.sv

  localparam logic [7:0] OP_READ          = 8'h03;
  localparam logic [7:0] OP_FAST_READ     = 8'h0B;
  localparam logic [7:0] OP_DUAL_READ     = 8'h3B;
  localparam logic [7:0] OP_QUAD_READ     = 8'h6B;
  localparam logic [7:0] OP_PAGE_PROGRAM  = 8'h02;
  localparam logic [7:0] OP_QUAD_PROGRAM  = 8'h32;
  localparam logic [7:0] OP_READ_4B       = 8'h13;
  localparam logic [7:0] OP_FAST_READ_4B  = 8'h0C;
  localparam logic [7:0] OP_QUAD_READ_4B  = 8'h6C;
  localparam logic [7:0] OP_TEST_QUAD_ND  = 8'hF0; // test-fixture only, see header
  localparam logic [7:0] OP_TEST_DUAL_ADDR = 8'hBD; // test-fixture only, see header
  localparam logic [7:0] OP_TEST_QUAD_ADDR = 8'hEB; // simplified, see header

  // Same purpose as qspi_engine.sv's lines_per_clock function - converts a
  // line-width encoding into bits transferred per qclk cycle. Kept as a
  // separately-named function (lpc, not lines_per_clock) purely because
  // this is a different module with its own local scope - there's no
  // dependency between the two, they just happen to compute the same thing.
  function automatic int unsigned lpc(logic [1:0] w);
    case (w)
      LW_S: lpc = 1;
      LW_D: lpc = 2;
      LW_Q: lpc = 4;
      default: lpc = 1;
    endcase
  endfunction

  // mem[i] = i is a deliberate choice, not a placeholder - it means any
  // address directly tells you what byte to expect back (address 0x50
  // should read back 0x50), which is what makes it easy to spot exactly
  // which nibble/bit got corrupted just by comparing expected vs actual
  // in a test failure message, without needing a lookup table.
  logic [7:0] mem [0:MEM_SIZE-1];
  initial for (int i = 0; i < MEM_SIZE; i++) mem[i] = i[7:0];

  typedef enum logic [1:0] {FM_CMD, FM_ADDR, FM_DUMMY_PH, FM_DATA} phase_t;
  phase_t      phase;         // this model's own phase tracking - mirrors qspi_engine.sv's
                              // phase_t, but is a completely separate state machine; nothing
                              // enforces the two staying in lockstep except both sides
                              // following the same protocol rules
  logic [10:0] bitcnt;         // position within the CURRENT phase (mirrors qspi_engine's bit_cnt)
  logic [7:0]  opcode;         // shift register filling in with the CMD-phase opcode byte
  logic [31:0] addr_shift;     // shift register filling in with the ADDR-phase address bits
  logic [7:0]  out_byte, next_addr_byte; // out_byte: the byte currently being shifted out on
                                        // a read; next_addr_byte: where to refill from once
                                        // out_byte is exhausted (for multi-byte reads)
  logic [3:0]  nibblecnt;      // position within the CURRENT byte of the DATA phase (mirrors
                              // qspi_engine's byte_bit_cnt)
  logic [3:0]  clocks_per_byte;
  logic [7:0]  in_byte_acc;    // accumulator for a byte being captured on a write

  // ---- opcode decode: real flash chips do exactly this off the same
  // 8 CMD-phase bits everyone always sends first ----
  logic       dec_dir;
  logic [1:0] dec_data_lines;
  logic [1:0] dec_addr_lines;
  logic [7:0] dec_dummy_cycles;
  logic [7:0] dec_addr_bytes;

  always_comb begin
    case (opcode)
      OP_READ:          begin dec_dir=1'b0; dec_data_lines=LW_S; dec_addr_lines=LW_S; dec_dummy_cycles=8'd0; dec_addr_bytes=8'd3; end
      OP_FAST_READ:     begin dec_dir=1'b0; dec_data_lines=LW_S; dec_addr_lines=LW_S; dec_dummy_cycles=8'd8; dec_addr_bytes=8'd3; end
      OP_DUAL_READ:     begin dec_dir=1'b0; dec_data_lines=LW_D; dec_addr_lines=LW_S; dec_dummy_cycles=8'd8; dec_addr_bytes=8'd3; end
      OP_QUAD_READ:     begin dec_dir=1'b0; dec_data_lines=LW_Q; dec_addr_lines=LW_S; dec_dummy_cycles=8'd8; dec_addr_bytes=8'd3; end
      OP_PAGE_PROGRAM:  begin dec_dir=1'b1; dec_data_lines=LW_S; dec_addr_lines=LW_S; dec_dummy_cycles=8'd0; dec_addr_bytes=8'd3; end
      OP_QUAD_PROGRAM:  begin dec_dir=1'b1; dec_data_lines=LW_Q; dec_addr_lines=LW_S; dec_dummy_cycles=8'd0; dec_addr_bytes=8'd3; end
      OP_READ_4B:       begin dec_dir=1'b0; dec_data_lines=LW_S; dec_addr_lines=LW_S; dec_dummy_cycles=8'd0; dec_addr_bytes=8'd4; end
      OP_FAST_READ_4B:  begin dec_dir=1'b0; dec_data_lines=LW_S; dec_addr_lines=LW_S; dec_dummy_cycles=8'd8; dec_addr_bytes=8'd4; end
      OP_QUAD_READ_4B:  begin dec_dir=1'b0; dec_data_lines=LW_Q; dec_addr_lines=LW_S; dec_dummy_cycles=8'd8; dec_addr_bytes=8'd4; end
      OP_TEST_QUAD_ND:  begin dec_dir=1'b0; dec_data_lines=LW_Q; dec_addr_lines=LW_S; dec_dummy_cycles=8'd0; dec_addr_bytes=8'd3; end
      OP_TEST_DUAL_ADDR: begin dec_dir=1'b0; dec_data_lines=LW_D; dec_addr_lines=LW_D; dec_dummy_cycles=8'd8; dec_addr_bytes=8'd3; end
      OP_TEST_QUAD_ADDR: begin dec_dir=1'b0; dec_data_lines=LW_Q; dec_addr_lines=LW_Q; dec_dummy_cycles=8'd8; dec_addr_bytes=8'd3; end
      default:          begin dec_dir=1'b0; dec_data_lines=LW_S; dec_addr_lines=LW_S; dec_dummy_cycles=8'd8; dec_addr_bytes=8'd3; end
    endcase
  end

  assign clocks_per_byte = 4'(8 / lpc(dec_data_lines));

  // Main state machine - walks the same CMD->ADDR->DUMMY->DATA sequence as
  // qspi_engine.sv, but from the opposite side of the wire: this model
  // SAMPLES what the DUT sends during CMD/ADDR (and during DATA on a
  // write), and DRIVES a response during DATA on a read.
  always_ff @(posedge qclk) begin
    written_valid <= 1'b0; // default every cycle; only pulses high on the specific
                           // cycle a write byte completes, set explicitly below
    if (cs_n) begin
      // Deselected - forget everything and be ready for a fresh CMD phase
      // the moment cs_n goes low again, exactly like a real flash chip.
      phase <= FM_CMD; bitcnt <= '0; nibblecnt <= '0;
    end else begin
      case (phase)
        FM_CMD: begin
          // Shift in the opcode 1 bit/cycle (CMD phase is always single-line
          // on real hardware - see qspi_engine.sv's qspi_ctrl_t comments for
          // why). Once all 8 bits have arrived, the opcode decode table
          // above already has a valid answer for this transaction's
          // dir/data_lines/addr_lines/dummy_cycles/addr_bytes.
          opcode <= {opcode[6:0], io0_in};
          if (bitcnt == 7) begin phase <= FM_ADDR; bitcnt <= '0; end
          else bitcnt <= bitcnt + 1'b1;
        end

        FM_ADDR: begin
          // Shift in the address at whatever width this opcode specifies
          // (dec_addr_lines) - unlike the original inline model this is
          // based on, this one supports dual/quad address capture, not
          // just single-line.
          case (dec_addr_lines)
            LW_S: addr_shift <= {addr_shift[30:0], io0_in};
            LW_D: addr_shift <= {addr_shift[29:0], io1_in, io0_in};
            LW_Q: addr_shift <= {addr_shift[27:0], io3_in, io2_in, io1_in, io0_in};
            default: addr_shift <= {addr_shift[30:0], io0_in};
          endcase
          if (bitcnt == (11'(dec_addr_bytes) * 8 / lpc(dec_addr_lines) - 1)) begin
            // Last address cycle - either skip straight to DATA (if this
            // opcode has dec_dummy_cycles==0) or go through FM_DUMMY_PH
            // first. Either way, out_byte/next_addr_byte get primed here
            // from whichever address bits just arrived, "+io0_in" style
            // trick because the very last address bit is still landing on
            // THIS edge and addr_shift's own update above hasn't taken
            // effect yet.
            if (dec_dummy_cycles == 0) begin
              phase <= FM_DATA; bitcnt <= '0; nibblecnt <= '0;
              case (dec_addr_lines)
                LW_S: begin
                  out_byte       <= mem[{addr_shift[6:0], io0_in}];
                  next_addr_byte <= {addr_shift[6:0], io0_in} + 8'd1;
                end
                LW_D: begin
                  out_byte       <= mem[{addr_shift[5:0], io1_in, io0_in}];
                  next_addr_byte <= {addr_shift[5:0], io1_in, io0_in} + 8'd1;
                end
                LW_Q: begin
                  out_byte       <= mem[{addr_shift[3:0], io3_in, io2_in, io1_in, io0_in}];
                  next_addr_byte <= {addr_shift[3:0], io3_in, io2_in, io1_in, io0_in} + 8'd1;
                end
                default: begin
                  out_byte       <= mem[{addr_shift[6:0], io0_in}];
                  next_addr_byte <= {addr_shift[6:0], io0_in} + 8'd1;
                end
              endcase
            end else begin
              phase <= FM_DUMMY_PH; bitcnt <= '0;
            end
          end else bitcnt <= bitcnt + 1'b1;
        end

        FM_DUMMY_PH: begin
          // Nobody drives the bus here (see the pin-driving always_comb -
          // it explicitly gates output on phase==FM_DATA, so DUMMY is
          // silent by omission) - this is purely a cycle-counter waiting
          // out the bus-turnaround gap before priming out_byte/next_addr_byte
          // for the DATA phase that follows. 
          if (bitcnt == dec_dummy_cycles - 1) begin
            phase          <= FM_DATA; bitcnt <= '0; nibblecnt <= '0;
            out_byte       <= mem[addr_shift[7:0]];
            next_addr_byte <= addr_shift[7:0] + 8'd1;
          end else bitcnt <= bitcnt + 1'b1;
        end

        FM_DATA: begin
          if (!dec_dir) begin
            // READ: shift out_byte left by lpc bits/cycle, refill at byte boundary
            if (nibblecnt == clocks_per_byte - 1) begin
              out_byte       <= mem[next_addr_byte];
              next_addr_byte <= next_addr_byte + 8'd1;
              nibblecnt      <= '0;
            end else begin
              out_byte  <= out_byte << lpc(dec_data_lines);
              nibblecnt <= nibblecnt + 4'd1;
            end
          end else begin
            // WRITE: capture lpc bits/cycle from whichever lines are active
            case (dec_data_lines)
              LW_S: in_byte_acc <= {in_byte_acc[6:0], io0_in};
              LW_D: in_byte_acc <= {in_byte_acc[5:0], io1_in, io0_in};
              LW_Q: in_byte_acc <= {in_byte_acc[3:0], io3_in, io2_in, io1_in, io0_in};
              default: in_byte_acc <= {in_byte_acc[6:0], io0_in};
            endcase

            if (nibblecnt == clocks_per_byte - 1) begin

              written_valid <= 1'b1;
              case (dec_data_lines)
                LW_S: written_byte <= {in_byte_acc[6:0], io0_in};
                LW_D: written_byte <= {in_byte_acc[5:0], io1_in, io0_in};
                LW_Q: written_byte <= {in_byte_acc[3:0], io3_in, io2_in, io1_in, io0_in};
                default: written_byte <= {in_byte_acc[6:0], io0_in};
              endcase
              nibblecnt <= '0;
            end else begin
              nibblecnt <= nibblecnt + 4'd1;
            end
          end
        end
        default: ;
      endcase
    end
  end


  always_comb begin
    io0_oe = 0; io1_oe = 0; io2_oe = 0; io3_oe = 0;
    io0_out = 0; io1_out = 0; io2_out = 0; io3_out = 0;
    if (!cs_n && phase == FM_DATA && !dec_dir) begin
      case (dec_data_lines)
        LW_S: begin io0_oe = 1; io0_out = out_byte[7]; end
        LW_D: begin io0_oe = 1; io1_oe = 1; io1_out = out_byte[7]; io0_out = out_byte[6]; end
        LW_Q: begin
          io0_oe = 1; io1_oe = 1; io2_oe = 1; io3_oe = 1;
          io3_out = out_byte[7]; io2_out = out_byte[6];
          io1_out = out_byte[5]; io0_out = out_byte[4];
        end
        default: ;
      endcase
    end
  end

endmodule