# Implementation Walkthrough: A Transaction Traced Through the Code

**Project:** QSPI Controller with AXI4-Lite Wrapper
**Scope:** This document traces transactions end-to-end through
the actual RTL and testbench, identifying every relevant signal, its
governing file, and its approximate line number. It assumes familiarity
with the concepts in [docs/THEORY.md](./THEORY.md); this document covers
implementation, not protocol theory. Sections 1-11 cover the core
register-path transaction; Sections 12-15 cover the XIP-specific
additions built on top of it.

**Line numbers** reflect the project files as of this document's
creation and will drift if the files are subsequently edited.

---

## Quick Overview

Before the detailed, file-by-file trace below, here is the same
transaction flow at a glance, with no file/line references:

1. Software (or the testbench) writes registers over AXI4-Lite.
2. `axi4L_slave` stores the settings and issues `qspi_start` on a START
   write.
3. `cdc_bridge` synchronizes `qspi_start` into the QSPI clock domain.
4. `qspi_engine` latches the command/address configuration and asserts
   `busy`.
5. `qspi_engine` lowers `cs_n`, then emits, in order:
   - the CMD opcode on `io0`
   - the address on `io0`/`io1`/`io2`/`io3`, depending on configured width
   - dummy cycles, if configured
   - data bytes, for either direction
6. For a **read**: the QSPI flash drives `io0`-`io3`; `qspi_engine`
   assembles the received bytes and pulses `qspi_rx_valid`.
7. For a **write**: `qspi_engine` drives `io0`-`io3` itself, pulsing
   `qspi_tx_req` before each new byte is needed.
8. At the end of the DATA phase, `qspi_engine` deasserts `busy` and
   pulses `qspi_done`.
9. `cdc_bridge` carries `done`, `rx_valid`, `tx_req`, and `busy` back
   across to the AXI side.
10. `axi4L_slave` updates the STATUS registers and RX_DATA, making the
    result visible to the AXI master.

For a memory-mapped XIP read, steps 1-2 are replaced by a plain AXI read
landing in the XIP address window (Section 12), and the fixed
configuration comes from `XIP_CFG` rather than a fresh CTRL_CMD write.
Everything from step 3 onward is unchanged - the same engine, the same
CDC bridge.

The remaining sections of this document trace each of these steps
against the actual signals and line numbers that implement them.

---

## 1. Clock and reset initialization

The testbench (`tb_qspi_axi_top.sv`) drives two independent, free-running
clocks:

| Signal | File : Line | Description |
|---|---|---|
| `ACLK_PERIOD` | `tb_qspi_axi_top.sv` : 15 | Fixed 10 ns period |
| `qclk_period` | `tb_qspi_axi_top.sv` : 16 | Real-valued, overridable via `+qclk_period=` plusarg |
| clock-generation `initial` blocks | `tb_qspi_axi_top.sv` : 25-26 | Drive `ACLK`/`qclk` toggling |

`ARESETn` (active-low) and `qclk_rst` (active-high) hold for several
cycles on their respective clocks before release. The differing reset
polarities are a recurring detail throughout this design; see Section 5.

## 2. Register writes (AXI4-Lite side)

The testbench's `run_txn` task (`tb_qspi_axi_top.sv` : 228) issues, in
order: `axi_write(REG_ADDR, ...)`, `axi_write(REG_NUM_BYTES, ...)`, and -
for write-direction transactions - `axi_write(REG_TX_DATA, ...)`.

Each write is processed by `axi4L_slave.sv`'s write-channel FSM:

| Element | File : Line | Description |
|---|---|---|
| `write_state_t state` | `axi4L_slave.sv` : 96 | `IDLE`/`ADDR_OK`/`DATA_OK`/`RESP` |
| `aw_hs`, `w_hs`, `b_hs`, `ar_hs`, `r_hs` | `axi4L_slave.sv` : ~100 | The five AXI handshake conditions |
| write-FSM `always_ff` | `axi4L_slave.sv` : 109 | Advances `state` |
| address/data latch `always_ff` | `axi4L_slave.sv` : 130 | Latches whichever of AW/W arrives first |
| `reg_ctrl_cmd`, `reg_addr`, `reg_num_bytes`, `reg_tx_data`, `reg_xip_cfg` | `axi4L_slave.sv` : ~90 | The stored register values |
| `eff_addr` / `eff_data` / `eff_strb` | `axi4L_slave.sv` : 155 | Resolves live-vs-latched address/data for the current cycle |
| `do_write` | `axi4L_slave.sv` : 166 | Asserted on the exact cycle a write completes |
| register-write `for` loops | `axi4L_slave.sv` : 290-296 | Per-register, walks `WSTRB` byte lanes into the target register |

## 3. Transaction start

`run_txn` writes `REG_CTRL_CMD` with bit 21 (START) set. The instant this
write completes:

```
assign qspi_start = do_write && (eff_addr == REG_CTRL_CMD) && eff_data[21];
```
(`axi4L_slave.sv` : 276)

`qspi_start` is a single-ACLK-cycle pulse in the ACLK domain.

## 4. Crossing into the qclk domain

`qspi_start` cannot be sampled directly by qclk-domain logic (see
THEORY.md Section 5). `cdc_bridge.sv` synchronizes it via a `pulse_sync`
instance:

| Element | File : Line | Description |
|---|---|---|
| `pulse_sync u_start_sync` | `cdc_bridge.sv` : 44 | ACLK → qclk crossing for `axi_start` → `qspi_start` |
| `toggle_src` | `pulse_sync.sv` : 22-25 | Source-side toggle-on-pulse |
| `sync_ff1` / `sync_ff2` / `sync_ff3` | `pulse_sync.sv` : 28-37 | Three-stage destination synchronizer chain |
| `pulse_out = sync_ff2 ^ sync_ff3` | `pulse_sync.sv` : 41 | Edge-detect regenerates a clean one-cycle pulse |

Concurrently, `cdc_bridge.sv` wires `qspi_ctrl_cmd`, `qspi_addr`, and
`qspi_num_bytes` directly from their `axi_*` counterparts with no
synchronizer, since these values are written well in advance of `start`
and remain stable through the transaction (documented in
`cdc_bridge.sv` immediately above these assignments).

## 5. Engine activation

`qspi_engine.sv`'s phase-transition block (line 151) accepts the synced
`qspi_start` pulse:

| Element | File : Line | Description |
|---|---|---|
| `busy_r` | `qspi_engine.sv` : 78 | Set on accepted start; gates the entire phase FSM |
| `ctrl` / `addr_lat` / `num_bytes_lat` latch | `qspi_engine.sv` : 85 | Freezes the transaction's configuration for its duration |
| `qspi_ctrl_t` packed struct | `qspi_engine.sv` : 50 | `dir`, `start`, `dummy_cycles`, `addr_width`, `data_lines`, `addr_lines`, `opcode` |
| `cs_n` | `qspi_engine.sv` : 20 | `= !busy_r`; drops the instant the transaction begins |

## 6. Phase sequence

| Phase | File : Line (relevant logic) | Notes |
|---|---|---|
| `phase_t` enum | `qspi_engine.sv` : 73 | `CMD, ADDR, DUMMY, DATA` |
| `out_shift` (CMD+ADDR shift register) | `qspi_engine.sv` : 222-223 | 40-bit register: 8-bit opcode + up to 32-bit address |
| `bit_cnt` | `qspi_engine.sv` : 77 | Position within the current phase |
| `function lines_per_clock` | `qspi_engine.sv` : 98 | Line-width encoding → bits transferred per cycle |
| DATA-phase byte tracking: `tx_shift_byte`, `in_byte`, `byte_bit_cnt`, `byte_boundary` | `qspi_engine.sv` : 241-244 | Per-byte state within a (possibly multi-byte) DATA phase |
| pin-driving `always_comb` | `qspi_engine.sv` (bottom of file) | Selects which of `io0`-`io3` drive, by phase and configured width |

## 7. Known timing-critical points

Two specific timing relationships in `qspi_engine.sv` required correction
during development and are documented in detail at their point of
definition in the source:

- **RX completion timing** (`byte_boundary_d1`, `qspi_engine.sv` : 316-317):
  `qspi_rx_valid` is derived from a one-cycle-delayed version of
  `byte_boundary` rather than the signal itself, ensuring the final
  bit/nibble of a byte has settled into `in_byte` before downstream logic
  samples it as valid.
- **TX priming timing** (`entering_data_from_addr` /
  `entering_data_from_dummy`, `qspi_engine.sv` : ~248-257): `tx_shift_byte`
  is loaded on the transition *into* the first cycle of a byte, rather
  than *at* that cycle, ensuring the correct byte is already present when
  it must be driven onto the bus.

## 8. Return path (qclk → ACLK)

| Element | File : Line | Description |
|---|---|---|
| `pulse_sync u_done_sync` | `cdc_bridge.sv` : 62 | `qspi_done` → `axi_done` |
| `pulse_sync u_txreq_sync` | `cdc_bridge.sv` : 87 | `qspi_tx_req` → `axi_tx_req` |
| `pulse_sync u_rxvalid_sync` | `cdc_bridge.sv` : 96 | `qspi_rx_valid` → `axi_rx_valid` |
| `busy_ff1` / `busy_ff2` | `cdc_bridge.sv` : 106-107 | Level synchronizer for `qspi_busy` → `axi_busy` |
| `tx_data_hold` | `cdc_bridge.sv` : 140 | Primed on `axi_start` **or** `axi_tx_req` (the byte-0 fix; see file comments) |
| `rx_data_hold` | `cdc_bridge.sv` : 193 | Captures `qspi_rx_data` on each `qspi_rx_valid` |

## 9. Status observation (software side)

| Element | File : Line | Description |
|---|---|---|
| `done_latched`, `tx_ready_latched`, `rx_ready_latched`, `error_latched` | `axi4L_slave.sv` : 224 | The four sticky STATUS bits |
| `status_w1c_done` / `status_w1c_error` | `axi4L_slave.sv` : 227-230 | Write-1-to-clear detection |
| `tx_data_write` / `rx_data_read` | `axi4L_slave.sv` : 234-236 | Auto-clear detection for TX/RX_READY |

`run_txn`'s companion task, `wait_for_done` (`tb_qspi_axi_top.sv` : 196),
polls `REG_STATUS` until `STATUS_BIT_BUSY` clears, then the testbench
reads `REG_RX_DATA` (for a read transaction) to retrieve the result.

## 10. Peripheral-side behavior (simulation only)

`qspi_flash_model.sv` implements an independent state machine
(`FM_CMD, FM_ADDR, FM_DUMMY_PH, FM_DATA`, line 107) that decodes the same
opcode byte from the CMD phase and derives its own configuration
(`dec_dir`, `dec_data_lines`, `dec_addr_lines`, `dec_dummy_cycles`,
`dec_addr_bytes`; decode table at line 131). Nothing enforces this model
staying synchronized with the DUT beyond both sides following the same
protocol - which is precisely what the testbench is verifying.

- `mem[0:MEM_SIZE-1]` (line 104): populated as `mem[i] = i`, so any read
  failure is immediately identifiable by comparing the returned byte to
  its address.
- `written_bytes` (accumulated via `written_valid`/`written_byte`):
  captures bytes received during write-direction transactions, checked
  directly by the `write_single_1byte`/`write_quad_1byte` test cases.

## 11. Special-case control paths

| Path | Governing logic | File : Line |
|---|---|---|
| Abort | `qspi_abort \|\| timeout_hit` at the top of the phase-transition priority chain | `qspi_engine.sv` : 151 |
| Timeout | `timeout_cnt`, `timeout_hit` | `qspi_engine.sv` : 130, 137 |
| Start-while-busy | `qspi_start` is only evaluated inside the `!busy_r` branch | `qspi_engine.sv` : 151 |
| Back-to-back transactions | All per-transaction state (`phase`, `bit_cnt`, `byte_bit_cnt`) resets on every `!busy_r` cycle | `qspi_engine.sv` : 151, 257 |

---

## 12. XIP: request path (memory-mapped read → engine)

`qspi_xip_slave.sv` is a second, read-only AXI4-Lite slave sitting on its
own address window. A CPU issuing an ordinary read at an address inside
that window triggers this path:

| Element | File | Description |
|---|---|---|
| `AXI_ARREADY = (state == XIP_IDLE)` | `qspi_xip_slave.sv` | Always asserted when idle, **regardless** of enable state - disabled/out-of-range requests are still accepted, then answered with an error. Gating ARREADY on enable was an earlier, real AXI protocol violation (see README bug list) - a slave must always eventually respond. |
| `addr_in_range_live` | `qspi_xip_slave.sv` | Computed from the **live** `AXI_ARADDR`, not the latched version - checking the latched address on the same cycle it updates gives the previous transaction's range result, not this one's |
| `flash_addr = ar_addr_latched - XIP_BASE` | `qspi_xip_slave.sv` | Address translation, once past the same-cycle latch race |
| `xip_state_t` enum: `XIP_IDLE, XIP_REQ, XIP_COLLECT, XIP_RESP, XIP_SETTLE` | `qspi_xip_slave.sv` | The whole request lifecycle |
| `x_ctrl_cmd` built from `xip_cfg` | `qspi_xip_slave.sv` | dir hardcoded to read (0), start pulsed for one cycle in `XIP_REQ`, everything else copied from the fixed boot-time `XIP_CFG` register |

`XIP_SETTLE` is a deliberate one-cycle gap between completing a
transaction and being ready to accept the next one - without it, a very
fast-resolving transaction (the immediate-error paths) could let the FSM
cycle back to `XIP_IDLE` and re-accept a still-lingering `ARVALID` from a
master that hasn't cleared it yet. This was a real, simulator-observable
race (see README bug list).

## 13. Arbitration (shared access to the engine)

Both the register path and the XIP path can request the engine.
`qspi_arbiter.sv` sits between them and the single set of request/
response ports `cdc_bridge.sv` exposes:

| Element | File | Description |
|---|---|---|
| `grant_t` enum: `GNT_NONE, GNT_REG, GNT_XIP` | `qspi_arbiter.sv` | Register path wins if both request the same cycle |
| `busy_seen` | `qspi_arbiter.sv` | Grant release requires having first observed `axi_busy` actually go high - otherwise the CDC round-trip latency between `axi_start` and `axi_busy` asserting could cause the arbiter to release the grant before the transaction even started |
| response routing (`route_to_reg`/`route_to_xip`) | `qspi_arbiter.sv` | Each requester only ever sees `busy`/`done`/`error`/`tx_req`/`rx_valid` while it holds the grant. **Exception:** `rx_data` itself is passed through unconditionally, not gated - it's an inert value with no meaning of its own until a requester also sees its own `rx_valid`; gating the data too broke the register path's own post-transaction reads |
| `assign axi_abort = a_abort;` | `qspi_arbiter.sv` | **Abort is NOT gated by grant at all.** Unlike every other signal above, it's forwarded to the engine unconditionally regardless of which side holds the grant - a register-path ABORT write can cut short an XIP-triggered transaction that's currently in flight. This is deliberate: abort is a safety/override mechanism, not a normal arbitrated request, and gating it would leave no way to recover a hung XIP transaction short of a full reset. |

## 14. XIP byte assembly

`qspi_xip_slave.sv`'s `XIP_COLLECT` state assembles up to 4 individually-arriving
bytes into one 32-bit word for the requesting master:

| Element | File | Description |
|---|---|---|
| `x_rx_valid_d1` | `qspi_xip_slave.sv` | `x_rx_data` only settles to its correct new value the cycle *after* `x_rx_valid` pulses (same NBA-race class as Section 7's RX-timing fix) - sampling is delayed one cycle to match |
| byte-position `case` on `byte_count` | `qspi_xip_slave.sv` | Little-endian assembly: the first-arriving byte (lowest address) lands in the LOW byte of the word, matching how a real CPU (ARM/RISC-V/x86) expects a memory-mapped word read to be laid out |

## 15. XIP: distinguishing normal completion from abort

Once abort became global (Section 13), `qspi_xip_slave.sv` needed a way
to tell "the transaction finished normally" apart from "the transaction
was cut short by an abort while it held the grant" - `qspi_done` never
pulses on an abort, and no further `rx_valid` pulses are coming either,
so without an explicit check, `XIP_COLLECT` would simply wait forever
for events that would never arrive.

| Element | File | Description |
|---|---|---|
| `engine_busy_seen` | `qspi_xip_slave.sv` | Also reused to guard against a *different* stale-state hazard: an error latched by a previous transaction can still be visible for a few cycles into a new one, since the CDC-synced view of "error cleared" lags behind the real clearing. Gating on having observed `busy` high first for *this* transaction sidesteps both problems with one flag. |
| `drain_cnt` / `XIP_DRAIN_CYCLES` | `qspi_xip_slave.sv` | The check for "busy dropped without completing" cannot fire the instant `busy` drops - during a completely normal completion, the fast level-synced `busy` can drop before the slower, pulse-synced `rx_valid` for the *final* byte has actually arrived. Firing immediately misreported some genuinely successful fetches as aborted. The fix waits `XIP_DRAIN_CYCLES` (matching the same margin pattern as `qspi_arbiter.sv`'s own `DRAIN_CYCLES`) before concluding the transaction was actually cut short rather than just finishing slightly late. |
| ordering within `XIP_COLLECT` | `qspi_xip_slave.sv` | The `x_rx_valid_d1` check is placed *before* the drain-margin abort check in the `if`/`else if` chain - not because of a same-cycle priority conflict (that was ruled out empirically), but so a final byte arriving partway through the drain window is still correctly processed as a completion rather than the window being allowed to run out first. |