# LBTiny Flash ROM — Read, Write, and Emulation Reference

## Part 1: How the SST39VF010A NOR Flash Works

### Memory Map

The ROM occupies the address range `0x000–0xBFF` (3 KB). It is backed by a
4096-entry BRAM (the next power of two above 3072, required for clean BRAM
inference in Vivado). Entries above `0xBFF` within that BRAM are allocated
but are never decoded by the address logic.

At bitstream load time the BRAM is initialized from `rom_init.mem` using
`$readmemh`. Any address not covered by that file defaults to `0xFF` — the
erased state of a blank NOR flash cell.

---

### Reading

Reading is straightforward. The bus master drives a standard 8085-style
read transaction:

1. Assert `ALE` high and place the 12-bit address on `A[11:8]` and
   `AD[7:0]`. The memory subsystem latches `AD[7:0]` on each rising clock
   edge while `ALE` is high.
2. Drop `ALE` low (data phase). The address is now held in the internal
   latch and the full 12-bit address is decoded combinationally.
3. Assert `RD_n` low. After one clock cycle (BRAM read latency plus one
   registered chip-select pipeline stage), the memory drives the read data
   onto `AD[7:0]`.
4. The bus master samples `AD` on the sixth clock cycle of `RD_n` low.
5. De-assert `RD_n`. The memory releases `AD` to high-Z one cycle later.

A complete read transaction takes **15 bus clock cycles** (~3.9 µs at
3.846 MHz). The memory drives the bus only when `RD_n` is low **and** the
registered chip-select for the ROM, RAM, or MMIO range is asserted —
all other cycles the `AD` bus is floating.

---

### Writing — Why a Bare Write Does Nothing

The SST39VF010A uses a hardware protection mechanism: a bare write to any
ROM address is silently ignored. This prevents accidental corruption from
bus glitches, power-on noise, or unintended bus masters. The only way to
change ROM contents is to send the correct multi-step unlock command
sequence first.

The emulation faithfully replicates this behaviour. Any write that arrives
outside a recognized sequence is dropped without error.

---

### Byte Program Sequence

To write a single byte `D` to ROM address `A` (where `A ∈ 0x000–0xBFF`),
four bus write cycles must be issued in strict order:

| Step | Address | Data | Purpose |
|------|---------|------|---------|
| 1 | `0x555` | `0xAA` | First unlock |
| 2 | `0x2AA` | `0x55` | Second unlock |
| 3 | `0x555` | `0xA0` | Program command |
| 4 | `A` | `D` | Actual data byte |

If the address or data in steps 1–3 is wrong, the internal command FSM
resets to `IDLE` and the sequence must start over. Step 4 to an address
outside `0x000–0xBFF` is also silently dropped.

Each "bus write cycle" follows the same 8085-style protocol: address
phase with `ALE` high, data phase with `WR_n` pulsed low. The write is
committed on the **rising edge of `WR_n`** (de-assertion), at which point
the bus master is still holding valid data on `AD`.

---

### Chip Erase Sequence

To erase the entire ROM back to `0xFF`, six bus write cycles must be
issued:

| Step | Address | Data | Purpose |
|------|---------|------|---------|
| 1 | `0x555` | `0xAA` | First unlock |
| 2 | `0x2AA` | `0x55` | Second unlock |
| 3 | `0x555` | `0x80` | Erase command prefix |
| 4 | `0x555` | `0xAA` | Third unlock |
| 5 | `0x2AA` | `0x55` | Fourth unlock |
| 6 | any ROM addr | `0x30` | Trigger erase |

After step 6, the memory begins an internal **erase walker** that writes
`0xFF` to every address from `0x000` to `0xBFF`, one byte per clock cycle.
This takes **3072 bus clock cycles** (~800 µs at 3.846 MHz). The real
SST39VF010A takes tens of milliseconds for the same operation; the
emulation is much faster but the supervisor's fixed delay is set
conservatively enough to cover either.

> **Note:** The real SST39VF010A supports sector-granularity erase in
> addition to chip erase. The emulation treats any erase command as a
> full `0x000–0xBFF` chip erase regardless of the address used in step 6,
> because the entire 3 KB ROM is always reprogrammed as a unit.

---

### Flash Command FSM

The memory subsystem tracks the unlock sequence using a seven-state FSM
clocked on every write pulse. `RESET_n` forces the FSM back to `S_IDLE`
asynchronously, so a half-completed sequence cannot survive a CPU reset
or a supervisor handoff.

```
S_IDLE    ──(0xAA @ 0x555)──► S_UNLOCK1
S_UNLOCK1 ──(0x55 @ 0x2AA)──► S_UNLOCK2
           ──(anything else)──► S_IDLE

S_UNLOCK2 ──(0xA0 @ 0x555)──► S_PROGRAM   (byte program path)
           ──(0x80 @ 0x555)──► S_ERASE1    (chip erase path)
           ──(anything else)──► S_IDLE

S_PROGRAM ──(data @ addr)───► S_IDLE       (commits write if addr in ROM range)

S_ERASE1  ──(0xAA @ 0x555)──► S_ERASE2
           ──(anything else)──► S_IDLE
S_ERASE2  ──(0x55 @ 0x2AA)──► S_ERASE3
           ──(anything else)──► S_IDLE
S_ERASE3  ──(0x30 @ any)───► S_IDLE        (triggers erase walker)
```

---

## Part 2: How the Viewer Emulates Flash Programming

### Overview

`lbtiny_viewer` contains a controller FSM that acts as an internal bus
master. When SW15 is up (CPU halted), pressing **BTNC** triggers a full
memory fill: every address from `0x000` to `0xEFF` is written with
`addr[7:0]` as the data value. Because the ROM requires the unlock sequence
before each byte, the viewer issues **four bus write transactions per ROM
byte** and **one bus write transaction per RAM byte**.

The viewer never bypasses the flash FSM — it drives the real bus signals and
lets the memory's own command decoder validate each step. This means the
viewer exercises exactly the same code path the STM32 supervisor will use in
production.

---

### Power-On Initialization

Before entering normal operation, the viewer always runs a two-phase
initialization sequence:

**Phase 1 — ROM Erase**

The viewer issues the six-write chip erase sequence through the bus master:

```
Write 0xAA → 0x555    (step 0)
Write 0x55 → 0x2AA    (step 1)
Write 0x80 → 0x555    (step 2)
Write 0xAA → 0x555    (step 3)
Write 0x55 → 0x2AA    (step 4)
Write 0x30 → 0x000    (step 5, triggers erase walker)
```

After the sixth write, the viewer waits **3300 bus clock cycles** in
`S_INIT_ERASE_WAIT` before proceeding, giving the erase walker time to
finish its 3072-cycle sweep with margin to spare.

**Phase 2 — RAM Fill**

The viewer then writes `0xFF` to every RAM address from `0xC00` to `0xEFF`
(768 bytes, one direct write each). RAM requires no unlock sequence.

**BTNU** re-enters phase 1 at any time, re-erasing the ROM and refilling
RAM with `0xFF`.

---

### BTNC Fill Sequence (ROM + RAM)

Pressing **BTNC** while the CPU is halted enters `S_FILL_NEXT` with
`fill_addr = 0x000` and `step = 0`. The FSM walks through every address:

**ROM addresses (0x000–0xBFF):** four bus writes per byte.

For each `fill_addr` in the ROM range, the step counter cycles through
0–3:

| Step | Write issued |
|------|-------------|
| 0 | `0xAA → 0x555` — first unlock |
| 1 | `0x55 → 0x2AA` — second unlock |
| 2 | `0xA0 → 0x555` — program command |
| 3 | `fill_addr[7:0] → fill_addr` — data byte |

When step 3 completes, `step` resets to 0 and `fill_addr` advances by 1.

**RAM addresses (0xC00–0xEFF):** one bus write per byte.

The same `fill_addr` variable continues past `0xBFF`. For each RAM address
the FSM issues a single direct write of `fill_addr[7:0]` with no unlock
preamble.

The fill ends when `fill_addr` exceeds `0xEFF` and the FSM returns to
`S_IDLE`.

**Total transaction count:**

| Region | Bytes | Writes/byte | Transactions |
|--------|-------|-------------|--------------|
| ROM (0x000–0xBFF) | 3072 | 4 | 12,288 |
| RAM (0xC00–0xEFF) | 768 | 1 | 768 |
| **Total** | **3840** | — | **13,056** |

At ~3.4 µs per write transaction, the complete fill takes approximately
**44 ms**.

---

### Shared Issue/Wait States

All bus transactions — whether from the erase sequence, the RAM fill, or
the BTNC fill — funnel through two shared states:

- **`S_ISSUE`**: waits until the bus master (`lbtiny_bus_master`) is not
  busy, then asserts `txn_start` for one cycle and advances to `S_WAIT`.
- **`S_WAIT`**: holds until `txn_done` pulses, then returns to whatever
  state `return_state` was set to before the transaction was issued.

This pattern keeps the FSM simple: any state that needs a bus transaction
sets `op_write`, `op_addr`, `op_data`, and `return_state`, then jumps to
`S_ISSUE`. The bus master handles all the cycle-level timing.

---

### Status Indicators During Fill

| LED | Signal | Meaning during fill |
|-----|--------|---------------------|
| `LED[14]` | `fill_busy` | Lit for the entire BTNC fill (~44 ms) |
| `LED[15]` | `viewer_busy` | Also lit; cleared only when back in `S_IDLE` |
| `LED[11:0]` | `viewed_addr` | Follows SW[11:0] live via the peek port |

The 7-segment display continues to show the address selected by SW[11:0]
and the data at that address throughout the fill, because observation goes
through the memory's independent **peek port** and never touches the bus.