# Implementation Walkthrough: A Transaction Traced Through the Code

**Project:** QSPI Controller with AXI4-Lite Wrapper
**Scope:** This document traces a single transaction end-to-end through
the actual RTL and testbench, identifying every relevant signal, its
governing file, and its approximate line number. It assumes familiarity
with the concepts in [docs/THEORY.md](./THEORY.md); this document covers
implementation, not protocol theory.

**Line numbers** reflect the project files as of this document's
creation and will drift if the files are subsequently edited.

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
| `reg_ctrl_cmd`, `reg_addr`, `reg_num_bytes`, `reg_tx_data` | `axi4L_slave.sv` : ~90 | The stored register values |
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
| `tx_data_write` / `rx_data_read` | `axi4L_slave.sv` : 234-236 | Auto-clear detection for TX_READY/RX_READY |

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
