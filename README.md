# QSPI Controller with AXI4-Lite Wrapper

A QSPI flash controller with an AXI4-Lite register interface. It lets a CPU or AXI master control a QSPI flash transaction by writing and reading registers, while a separate QSPI engine generates the actual serial protocol on cs_n and io0-io3. A second, memory-mapped XIP interface is also available, letting a CPU treat the flash as ordinary memory-mapped address space for reads.

## Background

For the underlying protocol theory (AXI4-Lite, SPI/QSPI, clock domain
crossing, XIP), see [THEORY.md](./THEORY.md).

For a signal-level trace of a transaction executing through the actual
code, see [WALKTHROUGH.md](./WALKTHROUGH.md).

## Architecture

```
                    AXI4-Lite bus (register path)
                         |            ^
                         v            |
                  +-----------+       |
                  | axi4L_    |       |
                  | slave     |       |
                  +-----+-----+       |
                        |             |
XIP AXI4-Lite bus       v             |
(memory-mapped,   +-----------+       |
 read-only)  ---->| qspi_     |       |
                   | arbiter  |       |
                   +-----+-----+       |
                        |             |
                        v             |
                  +------------+     +--------------+   cs_n, io0-3
                  | cdc_bridge | --> | qspi_engine  | --------------->
                  | (ACLK <->  |     | (CMD/ADDR/   |
                  |  qclk CDC) |     |  DUMMY/DATA  |
                  |            | <-- |  phase FSM)  |
                  +------------+     +--------------+
```

- **axi4L_slave.sv** — AXI4-Lite target: register bank, AW/W/B and AR/R
  channel FSMs. Also holds the `XIP_CFG` register that configures the
  fixed opcode/width/dummy-count used by every XIP-triggered access.
- **qspi_xip_slave.sv** — a second, memory-mapped, read-only AXI4-Lite
  slave. A read landing in the configured address window transparently
  triggers a QSPI read through the shared engine, translating the AXI
  address into a flash address and assembling the returned bytes into a
  little-endian word.
- **qspi_arbiter.sv** — arbitrates access to the shared engine between
  the register path and the XIP path. The register path wins a same-
  cycle start collision; each requester only ever sees its own
  completion, never the other's. **ABORT is global** - forwarded to the
  engine regardless of which side currently holds the grant, since it's
  a safety/override mechanism, not a normal arbitrated request.
- **cdc_bridge.sv** — crosses every control/status/data signal between the
  ACLK and qclk domains, since the AXI bus and the QSPI serial engine can
  run on independent, asynchronous clocks. Uses toggle-based pulse
  synchronizers (`pulse_sync.sv`) for control pulses and 2-flop
  synchronizers for level signals.
- **qspi_engine.sv** — the actual QSPI shift engine. Walks CMD → ADDR →
  DUMMY → DATA phases, driving/sampling `io0`–`io3` at 1/2/4 bits per
  clock depending on configured line width. Shared, unmodified, by both
  the register path and the XIP path.
- **qspi_axi_pkg.sv** — shared register offsets, bit-position constants,
  and FSM enums.
- **qspi_axi_top.sv** — top-level wiring of all modules above.

## Register Map

| Offset | Name         | Access | Notes |
|--------|--------------|--------|-------|
| 0x00   | CTRL_CMD     | R/W    | see bit layout below |
| 0x04   | ADDR         | R/W    | flash address, 24 or 32-bit depending on CTRL_CMD |
| 0x08   | NUM_BYTES    | R/W    | byte count, 12-bit effective range (0-4095) |
| 0x0C   | STATUS       | R/W*   | see bit layout below (*STATUS is written only for W1C bits) |
| 0x10   | TX_DATA      | W      | next byte to transmit (write direction) |
| 0x14   | RX_DATA      | R      | last byte received (read direction) |
| 0x18   | XIP_CFG      | R/W    | see bit layout below; configures every XIP-triggered access |

**CTRL_CMD bits:**

| Bits | Field | Notes |
|------|-------|-------|
| 31:24 | reserved | |
| 23 | ABORT | write 1 to immediately cancel any in-progress transaction, any phase, **regardless of whether it was started via the register path or via XIP** |
| 22 | DIR | 0=read, 1=write |
| 21 | START | write 1 to begin a transaction |
| 20:13 | DUMMY_CYCLES | 0-255 |
| 12 | ADDR_WIDTH | 0=24-bit, 1=32-bit |
| 11:10 | DATA_LINES | 0=single, 1=dual, 2=quad |
| 9:8 | ADDR_LINES | 0=single, 1=dual, 2=quad |
| 7:0 | OPCODE | flash command byte |

**STATUS bits:**

| Bit | Field | Type | Notes |
|-----|-------|------|-------|
| 0 | BUSY | RO, level | transaction in progress |
| 1 | DONE | sticky, W1C | latched on completion; write 1 to clear (also auto-clears on next START) |
| 2 | TX_READY | sticky, auto-clear | set when the engine wants the next TX byte; clears on TX_DATA write. **Informational only - see caveat below.** |
| 3 | RX_READY | sticky, auto-clear | set when a byte has landed in RX_DATA; clears on RX_DATA read. **Informational only - see caveat below.** |
| 4 | ERROR | sticky, W1C | set if the timeout safety net fires (busy stuck far longer than any legitimate transfer should take) |
| 31:5 | reserved | | |

**XIP_CFG bits:** (set once at boot, before enabling XIP - not re-specified per access, since a CPU fetch has no way to program a register before each read)

| Bits | Field | Notes |
|------|-------|-------|
| 31 | XIP_ENABLE | gates whether the XIP interface accepts requests at all |
| 20:13 | DUMMY_CYCLES | |
| 12 | ADDR_WIDTH | 0=24-bit, 1=32-bit |
| 11:10 | DATA_LINES | same encoding as CTRL_CMD |
| 9:8 | ADDR_LINES | same encoding |
| 7:0 | OPCODE | fixed read opcode used for every XIP access |

## ⚠️ Known limitations

**No real multi-byte flow control.** `TX_READY`/`RX_READY` tell software
when a byte needs servicing, but the engine does **not stall** waiting
for that to happen — the byte stream keeps running at full `qclk` speed
regardless. Real backpressure requires pausing the engine's internal
counters mid-transfer, which is only safe if `qclk` is gated/enabled
before it reaches the physical SCLK pin. That's a board/top-level detail
outside these RTL files, and it was never confirmed.

**No continuous/burst-read mode for XIP.** Every XIP access pays the full
CMD+ADDR+DUMMY overhead of a fresh QSPI transaction — there is no
mode-bits phase to enable continuous read mode. This makes XIP correct
for occasional memory-mapped access but likely too slow to actually
execute code from, without further work.

## Building and running the testbenches

Requires Verilator 5.x or Icarus Verilog.

**Core register-path suite (18 tests):**
```bash
verilator --binary --timing --trace -Wno-fatal --top-module tb_qspi_axi_top \
  qspi_axi_pkg.sv pulse_sync.sv cdc_bridge.sv axi4L_slave.sv \
  qspi_engine.sv qspi_arbiter.sv qspi_xip_slave.sv qspi_axi_top.sv \
  qspi_flash_model.sv tb_qspi_axi_top.sv
./obj_dir/Vtb_qspi_axi_top
```
Expected: `SUMMARY: 18 pass, 0 fail`.

**XIP suite (11 tests):**
```bash
verilator --binary --timing -Wno-fatal --top-module tb_xip_qspi_axi_top \
  qspi_axi_pkg.sv pulse_sync.sv cdc_bridge.sv axi4L_slave.sv qspi_engine.sv \
  qspi_arbiter.sv qspi_xip_slave.sv qspi_axi_top.sv qspi_flash_model.sv \
  tb_xip_qspi_axi_top.sv
./obj_dir/Vtb_xip_qspi_axi_top
```
Expected: `SUMMARY: 11 pass, 0 fail`.

Note the simulation's time unit is **picoseconds**, not nanoseconds — the
GTKWave time axis and the `From:`/`To:` zoom fields will show `ps`.

## Verification status

All 18 core testbench cases and all 11 XIP testbench cases pass on both
Icarus Verilog and Verilator 5.032.

**RTL bugs found and fixed (qspi_engine.sv, cdc_bridge.sv):**
- RX capture losing the first nibble/bit of every byte (timing race
  between `rx_valid` and the final shift-register update)
- Single/dual-line reads corrupted by unconditionally sampling all 4 IO
  lines regardless of configured data width
- Write direction losing byte 0 (TX data never primed before the engine's
  first byte-load point)
- TX shift register loading one cycle too late, corrupting every write
  (same NBA-timing bug class as the RX issue, on the drive side)
- NUM_BYTES silently wrapping at 256 due to only using `num_bytes[7:0]`

**Register-map / architecture additions:**
- STATUS.DONE changed from a raw single-cycle pulse (effectively
  unobservable by polling) to a sticky, write-1-to-clear bit
- Abort/cancel support (CTRL_CMD bit 23) - **global**, works regardless
  of which side (register path or XIP) currently holds the engine
- Timeout safety net with a dedicated ERROR status bit
- TX_READY/RX_READY visibility bits (see flow-control caveat above)
- Dual/quad-line ADDRESS phase verified for the first time (previously
  only single-line addressing had ever been exercised, regardless of
  data width)
- Mixed line-width combination verified (quad address + single data,
  the previously-untested opposite direction from the already-covered
  single-address-plus-quad-data case)
- Memory-mapped XIP read path, with arbitration against the existing
  register interface

**Bugs found and fixed in the XIP additions specifically (qspi_arbiter.sv, qspi_xip_slave.sv):**
- `rx_data` incorrectly gated by grant state, breaking the register
  path's own reads once a transaction had ended
- Grant released before the slower-latency `rx_valid`/`tx_req`
  synchronizer had time to arrive - fixed with a drain margin
- A real AXI protocol violation: `ARREADY` gated on the XIP-enable bit,
  meaning a disabled XIP interface could hang a master forever
- `XIP_CFG` bit-layout collision - the enable bit originally overlapped
  the opcode field
- An NBA-timing race identical in class to the RX-timing bug above:
  `x_rx_data` sampled one cycle too early relative to when `cdc_bridge`
  actually settles it
- Byte assembly was originally big-endian; corrected to little-endian,
  matching how a real CPU (ARM/RISC-V/x86) expects a memory-mapped word
  read to be laid out
- A stale error condition from a *previous* transaction could still be
  visible to a *new* transaction for a few cycles (CDC round-trip lag) -
  fixed by gating error detection on having observed `busy` go high
  first for the current transaction
- After making abort global, a genuine new race appeared: `busy`
  (fast level-sync) can drop before the slower, pulse-synced `rx_valid`
  for the final byte has arrived, even during a completely normal
  completion - `qspi_xip_slave.sv` was initially misreporting some
  successful fetches as aborted. Fixed with a drain-margin counter,
  the same pattern already used in the arbiter itself.

## Waveform Evidence

Every capture below is from the core `tb_qspi_axi_top.sv` simulation
(Verilator 5.032), GTKWave, signals added via their full hierarchical
path (e.g. `tb_qspi_axi_top.u_dut.u_qspi_engine.phase`).

### 1. Basic read transaction, phase-by-phase

<img width="2278" height="468" alt="waveform_1_basic_read_phases" src="https://github.com/user-attachments/assets/694ceb63-2e90-418a-b5e2-ee922d5a9ab1" />

**Window:** ~90ps–1210ps (`read_quad_1byte`)
**Signals:** `ACLK`, `qclk`, `qspi_start`, `phase`, `bit_cnt`, `cs_n`, `io0_out`, `io0_oe`, `busy_r`

**Proves:** `phase` walks `CMD(00) → ADDR(01) → DUMMY(10) → DATA(11) → CMD(00)`
in order, with durations matching the expected cycle counts for each
phase. `cs_n` and `busy_r` step together, `io0_oe` is only asserted while
the transaction is active, and `io0_out` shows the opcode bits shifting
out one at a time during CMD. The most basic "does this correctly
implement the QSPI phase protocol" claim.

### 2. RX-timing fix (the nibble-loss bug)

<img width="2246" height="344" alt="waveform_2_rx_timing_fix" src="https://github.com/user-attachments/assets/ede2ce41-8b55-4555-876e-1be2bf23d0aa" />

**Window:** same as above, zoomed into the DATA-phase tail (`read_quad_1byte`, address 0x50 — chosen specifically because its high nibble is non-zero)
**Signals:** `byte_boundary`, `byte_boundary_d1`, `in_byte`, `qspi_rx_valid`

**Proves:** at the moment `byte_boundary` pulses, `in_byte` still reads
`05` — incomplete, missing the high nibble. One `qclk` cycle later, when
`byte_boundary_d1` pulses, `in_byte` has become the correct `50`.
`qspi_rx_valid` is built from `byte_boundary_d1`, so it only ever fires
once the byte is genuinely complete — this is the actual mechanism of
the fix, not just a claim that a fix exists.

### 3. TX priming fix (byte-0-loss bug)

<img width="2238" height="566" alt="waveform_3_tx_priming_fix" src="https://github.com/user-attachments/assets/738e7507-73ad-45d6-b166-797d1f671c3a" />

**Window:** ~3630ps–4750ps (`write_single_1byte`)
**Signals:** `axi_start`, `tx_data_hold`, `qspi_tx_data`, `tx_shift_byte`, `io0_out`

**Proves:** `tx_data_hold` updates to `AA` immediately after `axi_start`,
not waiting for a `tx_req` that hasn't happened yet. `tx_shift_byte`
correctly walks `AA → 54 → A8 → 50 → A0 → 40 → 80 → 00`, the exact
bit-by-bit left-shift of `0xAA`, and `io0_out` reproduces the
`1,0,1,0,1,0,1,0` pattern that byte should produce — correct from the
very first bit, not a stale value that only becomes right one cycle in.

### 4. CDC pulse crossing (start signal, ACLK → qclk)

<img width="2256" height="436" alt="waveform_4_cdc_pulse_sync" src="https://github.com/user-attachments/assets/695df688-797f-4cb8-b454-a07621dbc2fe" />

**Window:** ~90ps–250ps
**Signals:** `axi_start`, `u_start_sync.toggle_src`, `u_start_sync.sync_ff1/2/3`, `qspi_start`

**Proves:** the actual toggle-synchronizer mechanism. `axi_start` pulses,
`toggle_src` flips the same cycle, and `sync_ff1`, `sync_ff2`, `sync_ff3`
each pick up that flip exactly one `qclk` cycle behind the previous one —
a clean three-step staircase. `qspi_start` (the regenerated pulse)
appears in the exact one-cycle window where `sync_ff2` and `sync_ff3`
disagree, which is the XOR edge-detect working as designed.

### 5. Abort mid-transaction

<img width="2252" height="436" alt="waveform_5_abort_midtransaction" src="https://github.com/user-attachments/assets/7854b2d7-2e42-42cd-9345-82f24bdb6cb5" />

**Window:** ~22140ps–22570ps (`abort_midtransaction`)
**Signals:** `phase`, `bit_cnt`, `qspi_abort`, `busy_r`, `cs_n`, `qspi_done`

**Proves:** `qspi_abort` fires while `bit_cnt` is genuinely mid-count
(here, still inside the CMD phase) — a real interruption, not a
coincidental completion. `busy_r` and `cs_n` both flip the same cycle
`qspi_abort` pulses, and `qspi_done` stays low for the entire window,
confirming this was a cut-short abort, not a disguised normal completion.
(This capture is from the register-path abort test; abort's behavior
while XIP holds the grant is covered separately by the XIP suite's
`abort_cuts_short_xip_transaction` test.)

### 6. Timeout safety net

<img width="2270" height="362" alt="waveform_6_timeout_safety_net" src="https://github.com/user-attachments/assets/53412420-3de5-4ea1-a961-74f55debd85f" />

**Window:** ~22560ps–26945ps, the full `timeout_safety_net` test (this DUT
instance's `TIMEOUT_CYCLES` overridden to 200 for testability)
**Signals:** `timeout_cnt`, `timeout_hit`, `error_r`, `busy_r`

**Proves:** `busy_r` stays high for the entire ~4.3μs stretch (roughly
215 `qclk` cycles at 20ns each — right around the 200-cycle threshold),
and `timeout_cnt` is visibly active and counting the whole time, not
stuck. This is the "big picture" view - it shows the safety net actually
running for a realistic duration rather than firing suspiciously early or
late. At this zoom level the exact trigger cycle isn't individually
readable, which is what the zoomed capture below is for.

**Zoomed on the trigger:**

<img width="2270" height="362" alt="waveform_6b_timeout_safety_net_zoomed" src="https://github.com/user-attachments/assets/7cc0ffdb-6137-4793-ad17-a0094862546d" />

**Window:** tight zoom around ~26900ps, same test
**Signals:** `timeout_cnt`, `timeout_hit`, `error_r`, `busy_r`

**Proves:** the exact causal chain, cycle-by-cycle: `timeout_hit` pulses
for exactly one cycle the instant `timeout_cnt` reaches its threshold,
`error_r` sets on the very next edge, and `busy_r` drops on that same
edge. Together with the wide capture above, this shows both that the
timeout ran for a realistic, non-trivial duration *and* that the actual
trigger is provably instantaneous and correctly sequenced - not just
"these all happen somewhere in the same general area."

### 7. STATUS sticky-bit behavior (DONE)

<img width="2238" height="350" alt="waveform_7_sticky_done_bit" src="https://github.com/user-attachments/assets/77df8918-5183-490c-8856-a81e59eb1bb7" />

**Window:** ~16800ps–18020ps (`sticky_done_bit`)
**Signals:** `qspi_done`, `done_latched`, `AXI_RDATA`, `status_w1c_done`

**Proves:** `qspi_done` is a brief pulse; `done_latched` sets on it and
stays set well after `qspi_done` has gone low again. `AXI_RDATA` reads
`0x0E` on one STATUS poll, then `0x0C` on a later one — only bit 1
(DONE) cleared between them, confirming the write-1-to-clear is
bit-specific and doesn't disturb TX_READY/RX_READY sitting in the same
register. This is the direct, visual fix for the original "STATUS.done
is a raw pulse and essentially unpollable" finding.

## XIP Waveform Evidence

Every capture below is from the `tb_xip_qspi_axi_top.sv` simulation.
These document mechanisms specific to the XIP path that the core suite's
7 captures above don't touch at all: arbitration between the two
requesters, abort's global reach, and multi-byte word assembly.

### 8. Arbiter routing during a register-path / XIP collision

<img width="2253" height="324" alt="waveform_8_xip_status_concurrent" src="https://github.com/user-attachments/assets/1b6b36f8-d07d-44bd-a647-2944f4b22c0a" />


**Window:** ~1855ps–3465ps
**Signals:** `u_arbiter.grant`, `u_arbiter.a_start`, `u_arbiter.x_start`, `u_arbiter.axi_start`, `u_axi_slave.qspi_busy` (this is `a_busy` as seen by the register path), `u_xip_slave.x_busy` (**Note:** `x_busy` is internal to `qspi_arbiter.sv`'s port connections - add it via `u_arbiter.x_busy` instead if `u_xip_slave`'s own view isn't in your signal tree)

**Proves:** with both `a_start` and `x_start` high the same cycle, `grant`
resolves to `GNT_REG` (register path wins the tie), and only the
register path's own busy signal goes high for that first transaction -
the XIP path's busy stays low until its turn comes, confirming neither
side sees the other's transaction as its own.

### 9. Global abort cutting short an XIP transaction

<img width="2259" height="396" alt="waveform_9_global_abort_xip" src="https://github.com/user-attachments/assets/70b64055-8f8c-4e4c-a6f6-54216de4313f" />


**Window:** ~3465ps–3845ps
**Signals:** `u_arbiter.grant`, `u_axi_slave.qspi_abort` (this is `a_abort`), `u_arbiter.axi_abort`, `u_xip_slave.state`, `u_xip_slave.fetch_error`, `XIP_RRESP`

**Proves:** `grant` reads `GNT_XIP` (the transaction in flight belongs to
XIP, not the register path) at the exact moment `a_abort` pulses, yet
`axi_abort` still asserts that same cycle - the unconditional forwarding
working as designed. `u_xip_slave.state` should be seen leaving
`XIP_COLLECT` for `XIP_RESP` shortly after (via the drain-margin delay,
not instantly), `fetch_error` sets, and `XIP_RRESP` reads `2'b10`
(DECERR) - a register-path abort genuinely reaching and cutting short a
transaction it didn't start.

### 10. Little-endian byte assembly

<img width="2249" height="301" alt="waveform_10_little_endian_assembly" src="https://github.com/user-attachments/assets/61124e30-006a-4f8b-9273-ca7e696e1178" />

**Window:** ~145ps–1805ps
**Signals:** `u_xip_slave.x_rx_valid_d1`, `u_xip_slave.byte_count`, `u_xip_slave.assemble_reg`, `XIP_RDATA`

**Proves:** each `x_rx_valid_d1` pulse lands a new byte at a *specific*
position in `assemble_reg` (bits `[7:0]` on the first pulse, `[31:24]`
on the fourth) rather than a uniform shift-in - watch `assemble_reg`
build up `10`, `1110`, `121110`, then finally `13121110` across the four
pulses, confirming the first-arriving byte (lowest address) ends up in
the low byte of the word, not the high byte.

