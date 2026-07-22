# Protocol Theory: AXI4-Lite, SPI/QSPI, and Clock Domain Crossing

**Project:** QSPI Controller with AXI4-Lite Wrapper
**Scope:** This document explains the protocol and digital-design theory
underlying this implementation, with each concept tied directly to the
corresponding signal, register, or file in the RTL. It is not a general
protocol tutorial; it assumes the reader is looking at this specific
codebase alongside it.

**Related documents:** [README.md](../README.md) (architecture, register
map, build instructions, waveform evidence) ·
[docs/WALKTHROUGH.md](./WALKTHROUGH.md) (signal-level trace of a
transaction executing through the code)

---

## 1. Purpose

A flash memory chip and a CPU/interconnect do not share memory, wires, or
a common notion of time. A protocol is an agreed-upon set of rules for
converting an intent ("read this address") into ordered voltage changes
on a defined set of wires, interpretable identically by both sides. This
project implements two such protocols and bridges them:

- **AXI4-Lite** between the CPU/interconnect and this IP block
- **QSPI** (an extension of SPI) between this IP block and the flash chip

## 2. AXI4-Lite: the register interface

### 2.1 Address/data decoupling

AXI4-Lite transmits an address and its associated data as separate
signal groups that are not required to arrive on the same clock cycle.
This allows a slave to accept an address while still preparing to accept
the corresponding data, without stalling unrelated bus activity. In this
implementation, `axi4L_slave.sv`'s `write_state_t` FSM (`IDLE`,
`ADDR_OK`, `DATA_OK`, `RESP`) explicitly accommodates address and data
arriving on different cycles.

### 2.2 Channel structure

AXI4-Lite defines five independent channels:

| Channel | Direction | Purpose |
|---|---|---|
| AW (write address) | Master → Slave | Specifies the target write address |
| W (write data) | Master → Slave | Carries write data and `WSTRB`, a per-byte valid mask |
| B (write response) | Slave → Master | Reports write completion status (OKAY/SLVERR/DECERR) |
| AR (read address) | Master → Slave | Specifies the target read address |
| R (read data) | Slave → Master | Carries read data and its response status |

Separating these five channels allows AW/W to be in flight independently
and prevents reads from blocking writes. Full AXI4 additionally supports
burst transfers and out-of-order completion via ID tags; AXI4-Lite omits
both, restricting every transfer to a single 32-bit word. This
restriction is what keeps `axi4L_slave.sv` a few hundred lines rather
than an order of magnitude larger.

### 2.3 VALID/READY handshaking

Every AXI4-Lite channel follows one handshake convention: the sender
asserts VALID and holds its data stable; the receiver asserts READY
when able to accept; the transfer completes on the clock edge where both
signals are simultaneously high. This convention allows a master and
slave running at different effective rates to interoperate without
either side needing advance knowledge of the other's timing.
`axi4L_slave.sv` computes this condition directly:
`aw_hs = AXI_AWVALID & AXI_AWREADY` (and equivalently for each of the
other four channels).

### 2.4 Address decoding

AXI4-Lite does not itself assign meaning to an address; that is entirely
the responsibility of the slave. This project's register map (defined in
`qspi_axi_pkg.sv`, decoded via the `case (eff_addr)` block in
`axi4L_slave.sv`) is the resulting contract: offset `0x00` is CTRL_CMD,
`0x0C` is STATUS, and so on. Once published, this mapping is what any
software driver must target.

## 3. SPI: baseline protocol

### 3.1 Rationale

Serial interfaces trade wire count for time: a parallel bus moves many
bits per clock over many wires, while a serial interface moves few bits
per clock over few wires. Flash memory packages are pin-constrained
parts, which is why SPI - "as few pins as possible" - is the dominant
interface for this class of device.

### 3.2 Signal set

| Signal | Role |
|---|---|
| SCLK | Clock, generated exclusively by the master |
| MOSI | Master Out / Slave In - unidirectional |
| MISO | Master In / Slave Out - unidirectional |
| CS# | Active-low chip select; distinguishes addressed communication from bus noise |

Because MOSI and MISO are separate, physically distinct wires, standard
SPI is full-duplex: a bit can be transmitted and received on the same
clock edge. This is a capability QSPI deliberately forfeits, discussed in
Section 4.

### 3.3 Shift-register mechanism

Both communicating parties maintain an N-bit shift register. On each
clock edge, both registers shift by one position, simultaneously
outputting their top bit and admitting a new bit at the bottom. After N
edges, the two parties have fully exchanged register contents. This
mechanism is implemented directly in `qspi_engine.sv` as `out_shift`,
`tx_shift_byte`, and `in_byte` - functionally identical shift registers,
generalized to shift by up to 4 bits per edge and to change drive
direction per protocol phase rather than per transfer.

## 4. QSPI: extension to four data lines

### 4.1 Rationale and tradeoff

Standard SPI is limited to one bit per clock edge by construction - one
data wire per direction. QSPI's extension is to provide four data lines
(`io0`-`io3`) and, during appropriate phases, use all four as one
4-bit-wide channel.

This throughput gain has a direct cost: the four lines are bidirectional,
not fixed-direction like MOSI/MISO, so only one side may drive them at a
given time. QSPI is therefore half-duplex during quad-width operation,
in contrast to standard SPI's full duplex. Direction is fixed for the
duration of a protocol phase, not renegotiated per bit.

### 4.2 Transaction phases

A QSPI transaction proceeds through four phases, each with a defined
purpose:

1. **CMD** - 8 bits, always single-line, always master-driven. Carries
   the opcode identifying the requested operation. Restricting this
   phase to single-line width, unconditionally, preserves backward
   compatibility: a quad-capable device still recognizes the same
   opcode a legacy single-line-only device would.
2. **ADDR** - the target address, width configurable per opcode
   (single/dual/quad), master-driven.
3. **DUMMY** - a span of cycles during which neither party drives the
   bus. This phase exists because ADDR is master-driven while the DATA
   phase of a read is slave-driven; a zero-cycle transition between the
   two risks both parties driving the bus simultaneously, an electrical
   hazard rather than a timing inconvenience. Real flash datasheets
   specify a fixed dummy-cycle count per opcode for exactly this reason.
4. **DATA** - the payload, direction dependent on read/write, width
   again configurable.

This sequence is implemented as the `phase_t` enum (`CMD, ADDR, DUMMY,
DATA`) in `qspi_engine.sv` and reflects standard QSPI flash command
structure rather than a scheme specific to this project.

### 4.3 Bit/nibble accounting

At quad width, four bits transfer per clock edge - one nibble. This is
why the DATA-phase shift logic in `qspi_engine.sv` operates in
nibble-sized increments for quad mode (e.g. `tx_shift_byte << 4`,
sampling `io0`-`io3` simultaneously) and single-bit increments for
single-line mode.

## 5. Clock Domain Crossing

### 5.1 Motivation for two clock domains

The AXI-facing and QSPI-facing logic have no inherent requirement to
share a clock frequency - the system bus may run at one rate while the
flash interface, constrained by the flash device's maximum SCLK
frequency, runs at another. Decoupling the two domains permits each to
be clocked appropriately for its own function.

### 5.2 The metastability problem

A flip-flop requires its input to remain stable through a defined
setup/hold window around the clock edge. A signal originating from an
unrelated clock domain may change within that window, driving the
flip-flop into a metastable state: an output that hovers at an
indeterminate voltage for an unbounded duration before resolving to 0 or
1, with the resolved value effectively unpredictable. This is a physical
property of real flip-flops, not a simulation artifact, and it is the
reason a signal cannot be connected directly between two independently
clocked domains.

### 5.3 Synchronization strategies

Two distinct techniques are used in this design, selected by signal
type:

- **Level signals** (e.g. `qspi_busy`): synchronized with a two-stage
  flip-flop chain (`busy_ff1`, `busy_ff2` in `cdc_bridge.sv`). The first
  stage may go metastable; the second stage provides one additional
  clock period for resolution. This is sufficient because a level signal
  requires no edge information - the destination domain only needs an
  eventually-correct sample of the current value.
- **Pulse signals** (e.g. `qspi_start`, `qspi_done`): a single-cycle
  pulse on a faster clock can be entirely missed by a slower clock if it
  occurs between two of the slower clock's sampling edges. `pulse_sync.sv`
  addresses this with a toggle-based scheme: the source domain toggles a
  flip-flop on every input pulse; that toggle (a level, and therefore
  immune to the pulse-loss problem) is synchronized into the destination
  domain via a multi-stage flip-flop chain; an edge-detector on the
  destination side (XOR of two consecutive synchronized samples)
  regenerates a clean single-cycle pulse.

This distinction, and `cdc_bridge.sv`'s consistent application of it, is
the central design principle of that file.

## 6. Summary

Software issues AXI4-Lite register writes describing a desired QSPI
transaction. `axi4L_slave.sv` implements the AXI4-Lite-facing interface.
`cdc_bridge.sv` transports the resulting control, status, and data
signals across the ACLK/qclk boundary using the synchronization
strategies described in Section 5. `qspi_engine.sv` implements the
QSPI-facing protocol engine, executing the phase sequence described in
Section 4. `qspi_flash_model.sv` is a behavioral stand-in for a physical
flash device, used exclusively for simulation.

The design applies established AXI4-Lite, QSPI, and CDC theory; it does
not introduce novel protocol mechanisms.

## 7. References

Each entry below is tied to the specific section of this document - and,
by extension, the specific file(s) in the RTL - it informed.

| Source | Informs |
|---|---|
| ARM. ["AXI Protocol Overview"](https://developer.arm.com/documentation/102202/0300/AXI-protocol-overview) - ARM Developer Documentation | **Section 2** (AXI4-Lite channel structure, VALID/READY handshaking). Directly underlies the AW/W/B/AR/R channel split and handshake logic implemented in `axi4L_slave.sv`. |
| Winbond Electronics. ["W25Q128JV Datasheet"](https://www.winbond.com/resource-files/W25Q128JV%20RevH%2003102021%20Plus.pdf) - Winbond, Rev. H, 2021 | **Section 4** (QSPI phase structure, opcode/dummy-cycle values). The specific opcode `0x6B` (Fast Read Quad Output) and 8-cycle dummy count used throughout the testbench's opcode table (`qspi_flash_model.sv`) come directly from this part's command set, which is the flash device this design targets. |
| Gisselquist, D. ["Formally Verifying a QSPI Flash Controller"](https://zipcpu.com/blog/2019/03/27/qflexpress.html) - ZipCPU | **Section 4** (QSPI protocol phases and their rationale, particularly the DUMMY-phase bus-turnaround discussion). A practical design writeup covering the same CMD/ADDR/DUMMY/DATA structure implemented in `qspi_engine.sv`, including edge cases (mode bits, continuous-read mode) this project's phase FSM does not implement - see the note in `qspi_flash_model.sv`'s header regarding the `0xEB` opcode. |
| Cummings, C. E. ["Clock Domain Crossing (CDC) Design & Verification Techniques Using SystemVerilog"](http://www.sunburst-design.com/papers/CummingsSNUG2008Boston_CDC.pdf) - SNUG Boston 2008 (1st place paper) | **Section 5** (metastability, synchronizer design). The industry-standard reference for the toggle-based pulse synchronizer technique implemented in `pulse_sync.sv`, and for the 2-flop level-synchronizer technique used for `qspi_busy`/`qspi_error` in `cdc_bridge.sv`. |
