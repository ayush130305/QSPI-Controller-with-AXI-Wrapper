# QSPI Controller with AXI4-Lite Wrapper

A Quad-SPI flash controller with an AXI4-Lite register interface.

## Background

For the underlying protocol theory (AXI4-Lite, SPI/QSPI, clock domain
crossing), see [THEORY.md](./THEORY.md).

For a signal-level trace of a transaction executing through the actual
code, see [WALKTHROUGH.md](./WALKTHROUGH.md).

## Architecture

```
AXI4-Lite bus                                          QSPI flash chip
     |                                                        ^
     v                                                        |
+-----------+     +------------+     +--------------+   cs_n, io0-3
| axi4L_    | --> | cdc_bridge | --> | qspi_engine  | --------------->
| slave     |     | (ACLK <->  |     | (CMD/ADDR/   |
| (ACLK     |     |  qclk CDC) |     |  DUMMY/DATA  |
|  domain)  | <-- |            | <-- |  phase FSM)  |
+-----------+     +------------+     +--------------+
```

- **axi4L_slave.sv** — AXI4-Lite target: register bank, AW/W/B and AR/R
  channel FSMs.
- **cdc_bridge.sv** — crosses every control/status/data signal between the
  ACLK and qclk domains, since the AXI bus and the QSPI serial engine can
  run on independent, asynchronous clocks. Uses toggle-based pulse
  synchronizers (`pulse_sync.sv`) for control pulses and 2-flop
  synchronizers for level signals.
- **qspi_engine.sv** — the actual QSPI shift engine. Walks CMD → ADDR →
  DUMMY → DATA phases, driving/sampling `io0`–`io3` at 1/2/4 bits per
  clock depending on configured line width.
- **qspi_axi_pkg.sv** — shared register offsets, bit-position constants,
  and FSM enums.
- **qspi_axi_top.sv** — top-level wiring of the three modules above.

## Register Map

| Offset | Name         | Access | Notes |
|--------|--------------|--------|-------|
| 0x00   | CTRL_CMD     | R/W    | see bit layout below |
| 0x04   | ADDR         | R/W    | flash address, 24 or 32-bit depending on CTRL_CMD |
| 0x08   | NUM_BYTES    | R/W    | byte count, 12-bit effective range (0-4095) |
| 0x0C   | STATUS       | R/W*   | see bit layout below (*STATUS is written only for W1C bits) |
| 0x10   | TX_DATA      | W      | next byte to transmit (write direction) |
| 0x14   | RX_DATA      | R      | last byte received (read direction) |

**CTRL_CMD bits:**

| Bits | Field | Notes |
|------|-------|-------|
| 31:24 | reserved | |
| 23 | ABORT | write 1 to immediately cancel any in-progress transaction, any phase |
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

## Building and running the testbench

Requires Verilator 5.x.

**Verilator:**
```bash
verilator --binary --timing --trace -Wno-fatal --top-module tb_qspi_axi_top \
  qspi_axi_pkg.sv pulse_sync.sv cdc_bridge.sv axi4L_slave.sv \
  qspi_engine.sv qspi_axi_top.sv qspi_flash_model.sv tb_qspi_axi_top.sv
./obj_dir/Vtb_qspi_axi_top
```

Expected output: `SUMMARY: 17 pass, 0 fail`.

The simulator dumps `tb_qspi_axi_top.vcd` in the working directory
(`--trace` is required for this - without it, Verilator silently skips
the dump). Open it with:
```bash
gtkwave tb_qspi_axi_top.vcd
```

Note the simulation's time unit is **picoseconds**, not nanoseconds — the
GTKWave time axis and the `From:`/`To:` zoom fields will show `ps`.


## Verification status

All 17 testbench cases pass on Verilator 5.032.

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
- Abort/cancel support (CTRL_CMD bit 23)
- Timeout safety net with a dedicated ERROR status bit
- TX_READY/RX_READY visibility bits (see flow-control caveat above)
- Dual/quad-line ADDRESS phase verified for the first time (previously
  only single-line addressing had ever been exercised, regardless of
  data width)

## Waveform Evidence

Every capture below is from the actual `tb_qspi_axi_top.sv` simulation
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
