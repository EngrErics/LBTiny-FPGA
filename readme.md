# LBTiny-MemBus

FPGA-based memory subsystem emulator for the LBTiny 8-bit CPU, running on a Digilent Nexys A7. Emulates the external ROM, RAM, and MMIO hardware that will eventually live on the LBTiny reference board, allowing CPU firmware development and supervisor integration to proceed before the physical board is available.

---

## What this does

The FPGA emulates three memory-mapped devices on an 8085/8051-style multiplexed address/data bus:

| Region | Size | Device emulated | Notes |
|--------|------|-----------------|-------|
| `0x000–0xBFF` | 3 KB | SST39VF010A NOR flash | Requires unlock+program sequence to write |
| `0xC00–0xEFF` | 768 B | AS6C6264 SRAM | Direct write, no command sequence |
| `0xF00–0xFFF` | 256 B | MMIO stub | Reads `0x00`, writes ignored |

Three agents can own the bus:

- **LBTiny CPU** — runs when SW15 is down and STM32 is not asserting reset
- **STM32 Nucleo supervisor** — takes the bus by pulling `RESET_n` low via Pmod JA
- **Memory viewer FSM** — takes the bus when SW15 is up (CPU halted by switch)

Bus ownership is mutually exclusive by convention. The STM32 and the viewer FSM must not be used simultaneously.

---

## Repository structure

```
src/
  lbtiny_top.v          Production top: CPU + memory + viewer
  lbtiny_mem.v          Memory subsystem (ROM, RAM, MMIO, peek ports)
  lbtiny_viewer.v       Viewer: live observation + mutation FSM + bus master + 7-seg
  lbtiny_cpu.v          CPU placeholder (real CPU replaces this file only)
  lbtiny.xdc            Vivado pin constraints for lbtiny_top
  rom_init.mem          ROM initialization (blank flash template, all 0xFF)

build_bitstream.bat     Build the bitstream (Windows)
build_bitstream.tcl     Vivado batch build script
program_bitstream.bat   Program the Nexys A7 over JTAG (Windows)
program_bitstream.tcl   Vivado hardware programming script
```

---

## User interface (Nexys A7)

### Switches

| Switch | Function |
|--------|----------|
| `SW[11:0]` | Address to observe (live, via peek port — no bus transaction) |
| `SW[15]` | **UP** = halt CPU, enable BTNC/BTNU mutation. **DOWN** = CPU runs, mutation blocked |

### Buttons

| Button | Function | Requires SW15 up |
|--------|----------|-----------------|
| `BTNC` | Fill ROM (`0x000–0xBFF`) and RAM (`0xC00–0xEFF`) with `addr[7:0]` | Yes |
| `BTNU` | Reinitialize: ROM chip-erase + RAM fill `0xFF` | Yes |

BTNC uses the real flash unlock+program sequence for ROM (4 bus writes per byte) and direct writes for RAM. Total fill time is ~44 ms.

### LEDs

| LED | Meaning |
|-----|---------|
| `LED[11:0]` | Currently viewed address (tracks SW[11:0] live) |
| `LED[12]` | Viewed address is in ROM range (`0x000–0xBFF`) |
| `LED[13]` | Viewed address is in RAM range (`0xC00–0xEFF`) |
| `LED[14]` | BTNC fill in progress |
| `LED[15]` | CPU is halted (SW15 up or STM32 holding reset) |

### 7-segment display

```
Digit:  7   6   5   4   3   2   1   0
        _  [  address  ]  _   _ [data ]
```

Digits 6–4 show the 12-bit viewed address in hex. Digits 1–0 show the 8-bit data at that address in hex. Updates live from the peek port — no bus transaction required.

---

## Reset architecture

```
cpu_reset_n = stm32_reset_n & ~sw15_synced
```

Any source can hold the CPU in reset; the CPU only runs when all sources release it. The memory subsystem has its own independent power-on reset and is never held in reset by SW15 or the STM32 — it must remain active so the viewer and supervisor can write to it while the CPU is halted.

---

## Build and program

### Requirements

- Vivado 2024.2 (or compatible). Either on PATH or installed under `C:\Xilinx\Vivado\` or `C:\AMD\Vivado\`.
- Nexys A7-100T or -50T connected via USB-JTAG (PROG port).

### Build

```bat
build_bitstream.bat        # Nexys A7-100T (default)
build_bitstream.bat 50T    # Nexys A7-50T
```

Output: `build\LBTiny\LBTiny.runs\impl_1\lbtiny_top.bit`

### Program

```bat
program_bitstream.bat                  # programs default bitstream
program_bitstream.bat path\to\file.bit # programs a specific bitstream
```

---

## STM32 supervisor wiring (Pmod)

All signals are 3.3 V LVCMOS33. The STM32 drives the bus when it pulls `RESET_n` low; the CPU is held in reset during this time.

### Pmod JA — bus control + upper address

| Signal | Pmod JA pin | FPGA ball | Nucleo MCU pin |
|--------|-------------|-----------|----------------|
| `A[8]` | 1 | C17 | PC8 |
| `A[9]` | 2 | D18 | PC9 |
| `A[10]` | 3 | E18 | PC10 |
| `A[11]` | 4 | G17 | PC11 |
| `ALE` | 7 | D17 | PC12 |
| `RD_n` | 8 | E17 | PB0 |
| `WR_n` | 9 | F18 | PB1 |
| `RESET_n` | 10 | G18 | PB2 |

### Pmod JB — multiplexed address/data bus (bidirectional)

| Signal | Pmod JB pin | FPGA ball | Nucleo MCU pin |
|--------|-------------|-----------|----------------|
| `AD[0]` | 1 | D14 | PC0 |
| `AD[1]` | 2 | F16 | PC1 |
| `AD[2]` | 3 | G16 | PC2 |
| `AD[3]` | 4 | H14 | PC3 |
| `AD[4]` | 7 | E16 | PC4 |
| `AD[5]` | 8 | F13 | PC5 |
| `AD[6]` | 9 | G13 | PC6 |
| `AD[7]` | 10 | H16 | PC7 |

> **⚠️ Verify Nucleo Morpho header pin numbers against the official ST UM1724 user manual before wiring.** The MCU pin assignments above are what the firmware programs and are authoritative.

### Pull resistors

| Signal | Pull | Reason |
|--------|------|--------|
| `ALE` | 10 kΩ to GND | Safe low when bus is idle |
| `RD_n` | 10 kΩ to 3.3 V | Safe high (deasserted) when bus is idle |
| `WR_n` | 10 kΩ to 3.3 V | Safe high (deasserted) when bus is idle |
| `RESET_n` | 10 kΩ to 3.3 V | CPU runs when STM32 releases |

### Ground

Run at least one GND wire between the Nucleo (CN7 pin 8 or 22) and the Nexys (any Pmod pin 5 or 11). Without a common ground, bus levels will be ambiguous.

---

## Memory viewer — observation vs mutation

The viewer provides two independent capabilities:

**Observation** is always live regardless of bus ownership. `SW[11:0]` selects an address; the data at that address is read directly from the BRAM peek port and displayed on the 7-seg and LEDs in real time. The CPU can be running and the display still updates — no bus transaction is needed.

**Mutation** (BTNC/BTNU) requires SW15 up. The viewer's internal bus master drives the 8085-style bus to issue real flash command sequences for ROM writes and direct writes for RAM. This is the same protocol the STM32 supervisor uses.

---

## Flash command protocol (SST39VF010A emulation)

ROM cannot be written with a bare bus write. The full unlock sequence must precede every byte program.

### Byte program (4 bus writes)

| Step | Address | Data |
|------|---------|------|
| 1 | `0x555` | `0xAA` |
| 2 | `0x2AA` | `0x55` |
| 3 | `0x555` | `0xA0` |
| 4 | target | data byte |

### Chip erase (6 bus writes)

| Step | Address | Data |
|------|---------|------|
| 1 | `0x555` | `0xAA` |
| 2 | `0x2AA` | `0x55` |
| 3 | `0x555` | `0x80` |
| 4 | `0x555` | `0xAA` |
| 5 | `0x2AA` | `0x55` |
| 6 | any ROM addr | `0x30` |

After step 6 an internal erase walker writes `0xFF` to `0x000–0xBFF` at one byte per bus clock (~800 µs at 3.846 MHz). Any new ROM access should wait at least 3300 bus clocks after issuing the erase command.

### Flash FSM states

| State | Meaning |
|-------|---------|
| `S_IDLE` | Waiting for `0xAA @ 0x555` |
| `S_UNLOCK1` | Got unlock 1, waiting for `0x55 @ 0x2AA` |
| `S_UNLOCK2` | Got unlock 2, waiting for command at `0x555` |
| `S_PROGRAM` | Got `0xA0`, next write programs one byte |
| `S_ERASE1–3` | Second unlock pair for chip erase |

Any unexpected write in any state returns the FSM to `S_IDLE`.

---

## STM32 supervisor protocol (v4)

### Frame format

```
PC → Nucleo:   0xA5  [cmd: 1B]  [len: 4B LE]  [payload...]
Nucleo → PC:   0x5A  [cmd: 1B]  [status: 1B]  [data_len: 4B LE]  [data...]
```

### Commands

| Code | Name | Request payload | Response data |
|------|------|-----------------|---------------|
| `0x01` | `TRANSFER_CRC` | bytes | declared_len (4B) + crc (4B) |
| `0x02` | `PING` | — | — |
| `0x10` | `MEM_WRITE` | addr (2B) + bytes | — |
| `0x11` | `MEM_READ` | addr (2B) + len (2B) | bytes |
| `0x12` | `FLASH_ERASE` | — | — |

### Status codes

| Code | Name |
|------|------|
| `0x00` | `OK` |
| `0x01` | `OVERFLOW` |
| `0x02` | `OUT_OF_RANGE` |
| `0x03` | `PAYLOAD_INVALID` |
| `0xFF` | `UNKNOWN_CMD` |

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| All reads return `0xFF` | `RD_n` pull-up missing; supervisor not asserting `RD_n`; check `LED[12:13]` to confirm address is decoding to a valid region |
| All reads return `0x00` | AD lines stuck low — check GND continuity; confirm STM32 switches PC0–PC7 to input during read data phase |
| Reads return garbage | Pull resistors missing or wrong polarity; ground bounce; two masters driving simultaneously |
| ROM unchanged after BTNC/BTNU | SW15 must be up before pressing buttons; confirm `LED[14]` lights on press |
| ROM unchanged after supervisor program | Flash unlock sequence not reaching memory intact — scope `WR_n` and check address lines during program sequence |
| `LED[15]` always lit | SW15 is up or STM32 is holding `RESET_n` low |
| `STATUS_OUT_OF_RANGE` | Host requesting address past `0xFFF` |
| `STATUS_PAYLOAD_INVAL` | Frame integrity error — disconnect/reconnect IDE worker |

---

## Reference board notes

The current wiring uses bare GPIO between the STM32 and the Nexys Pmod. On the eventual reference board:

- The supervisor outputs will be buffered through a **74LVC245 octal bus transceiver** so the STM32 can truly tristate the bus when releasing it
- `OE` on the 74LVC245 ties to a supervisor `BUS_OE_n` GPIO
- `RESET_n` and `INT` do not need buffering (unidirectional)
- Pull resistors on `RD_n`, `WR_n`, and `ALE` move from the breadboard onto the reference board near the buffer

When the reference board is ready, `lbtiny_mem.v` and the bus protocol are retired — the CPU talks directly to the real SST39VF010A and AS6C6264 devices.
