# LBTiny Bus & Memory Subsystem — Technical Reference

**Files:** `lbtiny_mem.v`, `lbtiny_viewer.v`, `lbtiny_top.v`, `lbtiny_cpu.v`  
**Target:** Xilinx Artix-7, Nexys A7-100T (also -50T)  
**Bus clock:** ~3.846 MHz (100 MHz ÷ 26)  
**Status:** Verified working on hardware with BRAM confirmed in synthesis.

---

## 1. Purpose & Context

`lbtiny_mem` is an FPGA model of the external memory hardware on the LBTiny
reference board. It emulates:

- An **SST39VF010A NOR flash** (ROM, 3 KB) — must be written using the real
  AMD/SST unlock+program or unlock+erase command sequences.
- An **AS6C6264 SRAM** (RAM, 768 B) — written directly, no command sequence.
- A **stub MMIO region** (256 B) — reads return 0x00, writes are ignored.

`lbtiny_viewer` is the debug subsystem. It provides:

- **Observation** — a live peek port into BRAM, always active regardless of
  bus ownership. No bus transaction required.
- **Mutation** — an internal bus master that can erase and fill ROM/RAM via
  the real bus protocol, gated behind SW15 (CPU halt switch).

`lbtiny_top` is the production top, integrating `lbtiny_cpu`, `lbtiny_mem`,
and `lbtiny_viewer` together. Three agents can own the bus:

- **CPU** — runs when SW15 is down and STM32 is not asserting reset.
- **STM32 Nucleo supervisor** — takes the bus by pulling RESET_n low via Pmod JA.
- **Viewer mutation FSM** — takes the bus when SW15 is up.

Bus ownership is mutually exclusive by convention. The STM32 and viewer FSM
must not be active simultaneously.

---

## 2. Bus Protocol

The bus is an **8085/8051-style multiplexed address/data bus**. All signals are
synchronous to the rising edge of CLK (the bus clock, ~3.846 MHz).

### 2.1 Signal Definitions — `lbtiny_mem` Bus Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `CLK` | in | 1 | Bus clock. All internal state clocks on the rising edge. |
| `RESET_n` | in | 1 | Active-low power-on reset. Clears control state (address latch, flash FSM, write strobe register). Does **not** reset BRAM contents. Independent of CPU reset — memory stays out of reset while CPU is halted. |
| `A[3:0]` | in | 4 | Upper address nibble A[11:8]. Held stable by the bus master throughout the transaction. |
| `AD[7:0]` | inout | 8 | Multiplexed address/data bus. During address phase (ALE high) carries A[7:0]. During data phase (ALE low) carries write data (master drives) or read data (slave drives when RD_n low). |
| `ALE` | in | 1 | Address latch enable. High = address phase. Low = data phase. |
| `RD_n` | in | 1 | Active-low read strobe. While low and address is in a valid region, slave drives AD[7:0] with read data. |
| `WR_n` | in | 1 | Active-low write strobe. Slave commits a write on the **rising edge** of WR_n (de-assertion), provided ALE is low. |

### 2.2 Peek Port — `lbtiny_mem` Additional Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `peek_addr[11:0]` | in | 12 | Address to observe. Driven continuously by the viewer from the synchronized switch value. |
| `peek_data[7:0]` | out | 8 | Data at `peek_addr`, registered one cycle later. Always live regardless of bus activity or reset state. |

The peek port is a second read port on each BRAM (true dual-port inference).
It never conflicts with the bus port and requires no arbitration.

### 2.3 Transaction Timing

All timings are in bus clock cycles. The viewer's internal bus master generates
these timings; the CPU and STM32 must meet the same requirements.

#### Write transaction (13 cycles total)

```
Cycle:  1   2   3   4   5   6   7   8   9  10  11  12  13
ALE:    1   1   1   0   0   0   0   0   0   0   0   0   0
A[3:0]: <-- addr[11:8] held throughout ----------------->
AD:    [A7:0]   [A7:0] [D]  [D]  [D] [D]  [D] [D]  [D]  Z   Z   Z
WR_n:   1   1   1   1   1   1   0   0   0   1   1   1   1
        |<-T_ADDR->| TH |<TW>|<--T_WLOW->|<-T_WHIGH->| DONE
```

- **T_ADDR** (3 cycles): ALE=1, address on A and AD[7:0].
- **T_HOLD** (2 cycles): ALE drops. AD transitions to write data.
- **T_WDATA** (2 cycles): AD = write data, WR_n still high.
- **T_WLOW** (3 cycles): WR_n=0. AD = write data.
- **T_WHIGH** (3 cycles): WR_n returns to 1. **Write commits on the first cycle of T_WHIGH.**
- **T_DONE** (1 cycle): AD released.

#### Read transaction (15 cycles total)

```
Cycle:  1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
ALE:    1   1   1   0   0   0   0   0   0   0   0   0   0   0   0
AD:    [A7:0]       Z   Z  [rdata driven by slave -------]  Z
RD_n:   1   1   1   1   1   1   0   0   0   0   0   0   1   1   1
        |<-T_ADDR->| TH |TR |<----T_RLOW (6 cy)---->|TRH| DONE
```

- **T_RTURN** (2 cycles): master releases AD, RD_n still high.
- **T_RLOW** (6 cycles): RD_n=0. Slave drives AD. Master samples on cycle 6.
- **T_RHIGH** (2 cycles): RD_n returns to 1. Slave releases AD.

### 2.4 Address Latching Detail

```verilog
always @(posedge CLK or negedge RESET_n) begin
    if (!RESET_n) ad_low_latched <= 8'h00;
    else if (ALE) ad_low_latched <= AD;
end
wire [11:0] addr = {A, ad_low_latched};
```

Synchronous approximation of the external 74HC573 transparent latch. `A[3:0]`
is held by the bus master for the entire transaction and never needs latching.

### 2.5 Write Commit Detail

```verilog
reg wr_n_q;
always @(posedge CLK or negedge RESET_n) begin
    if (!RESET_n) wr_n_q <= 1'b1;
    else          wr_n_q <= WR_n;
end

wire wr_rising   = (wr_n_q == 1'b0) && (WR_n == 1'b1);
wire data_phase  = ~ALE;
wire write_pulse = wr_rising & data_phase;
wire [7:0] write_data = AD;
```

`write_pulse` is a single-cycle combinational pulse on the cycle after WR_n
transitions low-to-high. At that moment ALE is 0, the master is still driving
valid data on AD, and `addr` reflects the latched address from T_ADDR.

### 2.6 Read Drive Detail

```verilog
reg cs_rom_q, cs_ram_q, cs_mmio_q;
always @(posedge CLK) begin
    cs_rom_q  <= cs_rom;
    cs_ram_q  <= cs_ram;
    cs_mmio_q <= cs_mmio;
end

wire drive_en = (RD_n == 1'b0) && (cs_rom_q || cs_ram_q || cs_mmio_q);
assign AD = drive_en ? rdata : 8'bz;
```

Chip selects are registered one cycle to align with the BRAM synchronous read
output register. The slave drives AD whenever RD_n is low and the address is
in a valid region.

---

## 3. Memory Map

| Range | Size | Type | Notes |
|-------|------|------|-------|
| `0x000–0xBFF` | 3072 B | ROM (NOR flash emulation) | Write requires unlock+program sequence. Erase writes all 0xFF. |
| `0xC00–0xEFF` | 768 B | RAM (SRAM emulation) | Direct write, no command sequence. |
| `0xF00–0xFFF` | 256 B | MMIO stub | Reads 0x00, writes ignored. |

ROM is allocated as a 4096-entry BRAM (4 KB). RAM is allocated as a 1024-entry
BRAM (1 KB). Both sized at powers of two for clean BRAM inference. Each BRAM
has two read ports (bus port + peek port), inferred as true dual-port by Vivado.

ROM is initialized from `rom_init.mem` via `$readmemh`. Unspecified entries
default to `0xFF`. RAM initializes to `0x00`.

---

## 4. ROM Flash Command Protocol (SST39VF010A Emulation)

ROM **cannot** be written with a bare write cycle. Any write that doesn't follow
the unlock sequence is silently dropped.

### 4.1 Byte Program (4 bus writes)

| Step | Address | Data | Notes |
|------|---------|------|-------|
| 1 | `0x555` | `0xAA` | Unlock 1 |
| 2 | `0x2AA` | `0x55` | Unlock 2 |
| 3 | `0x555` | `0xA0` | Program command |
| 4 | target | data byte | Must be in `0x000–0xBFF` |

### 4.2 Chip Erase (6 bus writes)

| Step | Address | Data |
|------|---------|------|
| 1 | `0x555` | `0xAA` |
| 2 | `0x2AA` | `0x55` |
| 3 | `0x555` | `0x80` |
| 4 | `0x555` | `0xAA` |
| 5 | `0x2AA` | `0x55` |
| 6 | any ROM addr | `0x30` |

After step 6 an internal erase walker writes `0xFF` to `0x000–0xBFF` at one
byte per CLK (~800 µs at 3.846 MHz). Wait at least 3300 bus clocks before
issuing any new ROM access after an erase command.

### 4.3 Flash FSM States

```
S_IDLE    → (AA@555)  → S_UNLOCK1
S_UNLOCK1 → (55@2AA)  → S_UNLOCK2
S_UNLOCK2 → (A0@555)  → S_PROGRAM   -- program path
          → (80@555)  → S_ERASE1    -- erase path
S_PROGRAM → (data@addr) → S_IDLE    -- commits write
S_ERASE1  → (AA@555)  → S_ERASE2
S_ERASE2  → (55@2AA)  → S_ERASE3
S_ERASE3  → (30@any)  → S_IDLE      -- triggers erase walker
Any unexpected write in any state → S_IDLE (abort)
```

---

## 5. BRAM Inference Details

Both memories use the Xilinx true dual-port BRAM inference pattern:

- Single `always @(posedge CLK)` block, **no reset on the array**.
- One write port, two independent read ports (bus + peek) in the same block.
- Synchronous output register on both read ports, also reset-free.
- `(* ram_style = "block" *)` forces BRAM — Vivado errors rather than
  silently falling back to LUTs if inference fails.

The ROM write port is driven by a combinational mux external to the BRAM block:

```verilog
wire        rom_we    = erasing | rom_program_we;
wire [11:0] rom_waddr = erasing ? erase_idx       : rom_program_addr;
wire [7:0]  rom_wdata = erasing ? 8'hFF           : rom_program_data;
```

This allows the erase walker and byte-program path to share one write port
without either touching the BRAM inference template.

**Critical rule:** any reset on the BRAM array block dissolves it into flip-flops.
All control state (flash FSM, address latch, write strobe register) lives in
separate always blocks that can have resets. The BRAM arrays never do.

---

## 6. System Architecture — `lbtiny_top`

```
CLK100MHZ ──► clk_div (÷26) ──► clk_bus (~3.846 MHz)
                                      │
                    ┌─────────────────┼──────────────────┐
                    │                 │                   │
              lbtiny_cpu         lbtiny_mem          lbtiny_viewer
              (u_cpu)            (u_mem)             (u_viewer)
                    │                 │                   │
                    └──── bus mux ────┘         peek_addr/peek_data
                          (A, AD, ALE,
                           RD_n, WR_n)
```

### 6.1 Reset Architecture

```verilog
wire cpu_reset_n = stm32_reset_n & ~sw15_synced;
wire cpu_halted  = ~cpu_reset_n;
```

`cpu_reset_n` is the AND of all reset sources. Any source can hold the CPU
in reset; the CPU only runs when all release it.

`lbtiny_mem` has its own independent power-on reset (`mem_reset_n`) that
releases after 40 bus clocks and stays released forever. It is never driven
by `cpu_reset_n` — the memory must remain active while the CPU is halted so
the viewer and STM32 can write to it.

### 6.2 Bus Ownership

| Condition | Bus master |
|-----------|-----------|
| SW15 down, STM32 not asserting | CPU (`lbtiny_cpu`) |
| SW15 up | Viewer mutation FSM (BTNC/BTNU) |
| STM32 asserting RESET_n (Pmod JA pin 10 low) | STM32 via Pmod JB |

The viewer FSM and STM32 must not be active simultaneously — this is a
procedural constraint, not enforced in hardware.

### 6.3 AD Bus Wiring

```verilog
wire mem_ad_oe = cpu_halted & viewer_ad_oe;
assign ad_bus  = mem_ad_oe ? viewer_ad_out : 8'hzz;
```

The CPU's `inout AD` port connects directly to `ad_bus`. When the CPU is
running it drives `ad_bus` through its port. When the CPU is halted the
viewer drives `ad_bus` through the output enable mux above. The two paths
are mutually exclusive by `cpu_halted`.

### 6.4 Clock Domain

`clk_bus` is a divide-by-26 counter on `CLK100MHZ`. Vivado auto-inserts a
BUFG. All memory and viewer sequential logic clocks on `clk_bus`. The 7-seg
scan counter uses `CLK100MHZ` directly for smooth display.

---

## 7. Viewer Subsystem — `lbtiny_viewer`

### 7.1 Observation (always active)

`peek_addr` is driven continuously from the synchronized `SW[11:0]` value.
`peek_data` returns from `lbtiny_mem`'s peek port one cycle later and is
displayed on the 7-seg and LEDs in real time. No bus transaction is issued.
The CPU can be running and observation still works.

### 7.2 Mutation FSM States

```
S_INIT_ERASE_NEXT  Issue one of the 6 erase command bytes (step 0–5).
S_INIT_ERASE_ADV   Increment step counter, return to S_INIT_ERASE_NEXT.
S_INIT_ERASE_WAIT  Wait 3300 bus clocks for erase walker to finish.
S_INIT_RAM_NEXT    Write 0xFF to RAM fill_addr (0xC00–0xEFF).
S_INIT_RAM_ADV     Increment fill_addr, return to S_INIT_RAM_NEXT.
S_IDLE             Wait for BTNC/BTNU requests. Observation via peek — no bus reads.
S_FILL_NEXT        Issue one transaction of the BTNC fill sequence (ROM or RAM).
S_FILL_ADV         Advance step/fill_addr, return to S_FILL_NEXT.
S_ISSUE            Wait for !txn_busy, assert txn_start, go to S_WAIT.
S_WAIT             Wait for txn_done, return to return_state.
```

**Power-on sequence:**
1. `S_INIT_ERASE_NEXT/ADV` × 6 — issues 6-write chip erase to ROM.
2. `S_INIT_ERASE_WAIT` — waits 3300 cycles for the erase walker.
3. `S_INIT_RAM_NEXT/ADV` × 768 — fills RAM with 0xFF.
4. `S_IDLE` — normal operation.

Note: power-on reset for the memory is handled separately in `lbtiny_top`
(40-cycle `mem_reset_n`). The viewer FSM starts from `S_INIT_ERASE_NEXT`
directly — there is no `S_RESET_HOLD` state in the viewer itself.

**BTNU** — restarts from `S_INIT_ERASE_NEXT` (re-erases ROM + re-fills RAM).
Requires SW15 up.

**BTNC** — fills ROM+RAM with `addr[7:0]`:
- ROM (`0x000–0xBFF`): 4 bus writes per byte (unlock+program). 3072 × 4 = 12,288 writes.
- RAM (`0xC00–0xEFF`): 1 bus write per byte. 768 writes.
- Total: ~44 ms at 3.846 MHz.
Requires SW15 up.

### 7.3 Button Handling

Three-stage pipeline:

1. **2-FF metastability synchronizer** — clocked on `clk_bus`.
2. **Counter debouncer** — `DEBOUNCE_TICKS = 16000` bus clocks (~4.2 ms) of
   stable input required before `btnX_stable` updates.
3. **Sticky request flag** (`btnc_req`/`btnu_req`) — set on debounced rising
   edge, cleared by FSM in `S_IDLE`. Requests are only latched when
   `cpu_halted` is high.

**Cross-masking:** `btnc_edge` is gated with `~btnu_stable` and vice versa.

### 7.4 LED Assignments

| LED | Signal | Meaning |
|-----|--------|---------|
| `LED[11:0]` | `viewed_addr` | Currently viewed address (tracks SW[11:0] live) |
| `LED[12]` | `viewed_addr <= 0xBFF` | Viewed address is in ROM |
| `LED[13]` | `viewed_addr in 0xC00–0xEFF` | Viewed address is in RAM |
| `LED[14]` | `fill_busy` | BTNC fill in progress |
| `LED[15]` | `cpu_halted` | CPU is in reset (SW15 up or STM32 holding RESET_n) |

Note: `LED[15]` is driven by `cpu_halted` in `lbtiny_top`, overriding the
`viewer_busy` signal that `lbtiny_viewer` provides on that pin.

### 7.5 7-Segment Display

8-digit multiplexed display, scanned at ~763 Hz per digit (100 MHz / 2¹⁷).

```
Digit:  7   6   5   4   3   2   1   0
        _  [  address  ]  _   _ [data ]
```

Digits 6–4: 12-bit `viewed_addr`. Digits 1–0: 8-bit `viewed_data`.
Digit 7, 3, 2: blanked. Updates live from peek port.

---

## 8. XDC Pin Assignments (Nexys A7-100T)

| Signal | Package Pin | Notes |
|--------|-------------|-------|
| `CLK100MHZ` | E3 | 100 MHz MRCC |
| `BTNC` | N17 | Center button — fill (SW15 must be up) |
| `BTNU` | M18 | Up button — reinit (SW15 must be up) |
| `SW[0:11]` | J15–T13 | Address select |
| `SW[15]` | V10 | CPU halt / mutation enable |
| `LED[0:15]` | H17–V11 | See §7.4 |
| `CA–CG`, `DP` | T10, R10, K16, K13, P15, T11, L18, H15 | Segments, active-low |
| `AN[0:7]` | J17–U13 | Anodes, active-low |
| `JA pins 1–4` | C17, D18, E18, G17 | A[8:11] — STM32 upper address |
| `JA pins 7–10` | D17, E17, F18, G18 | ALE, RD_n, WR_n, RESET_n |
| `JB pins 1–4` | D14, F16, G16, H14 | AD[0:3] — bidirectional |
| `JB pins 7–10` | E16, F13, G13, H16 | AD[4:7] — bidirectional |

---

## 9. Known Limitations / Design Notes

1. **ROM erase is chip-wide.** The SST39VF010A supports sector erase, but
   the current implementation treats any erase command as a full 0x000–0xBFF
   erase regardless of the address in step 6. Sufficient for full-image
   programming; extend if sector granularity is needed.

2. **MMIO is a stub.** `0xF00–0xFFF` returns 0x00 and drops writes. Production
   use needs real registers here (GPIO, UART status, timer, etc.).

3. **clk_bus is a logic-generated clock.** Vivado auto-inserts a BUFG. Add
   `create_generated_clock` to the XDC if timing reports are needed, or replace
   the div-by-26 counter with an MMCM output if the clock budget tightens.

4. **STM32 and viewer must not be used simultaneously.** There is no hardware
   arbitration between the two. SW15 and the STM32 RESET_n both contribute to
   `cpu_reset_n` but the system cannot detect if both are active at once.

5. **Pmod JB is not connected to the internal AD bus in firmware.** The STM32
   drives Pmod JB externally; the internal `ad_bus` is a separate net. Connecting
   them for a true shared bus requires a physical wire harness. This is left as
   a stub until the reference board is ready.
