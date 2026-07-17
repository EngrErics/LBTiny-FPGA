LBTiny 8-bit Instruction Set Reference
=========================================
 
Legend:
  Z: Zero Flag     C: Carry Flag
  N: Negative Flag V: Overflow Flag
  -: Not Affected  0: Cleared       1: Set
  *: Affected based on result
 
IMPLIED (1-Byte)
Mnemonic  | Opcode | Description                  | Z | C | N | V | Cycles
----------|--------|------------------------------|---|---|---|---|-------
NOP       | 0x00   | No Operation                 | - | - | - | - | 3
SHR       | 0x01   | Shift Right (Acc>>1)         | * | * | 0 | - | 3
SHL       | 0x02   | Shift Left  (Acc<<1)         | * | * | * | * | 3
EI        | 0x03   | Enable Interrupts            | - | - | - | - | 3
DI        | 0x04   | Disable Interrupts           | - | - | - | - | 3
RETI      | 0x05   | Return from Interrupt        | - | - | - | - | 3
HALT      | 0x06   | Stop CPU Execution           | - | - | - | - | 3
INV       | 0x07   | Bitwise NOT Accumulator      | * | * | * | 0 | 3
INC       | 0x08   | Increment Accumulator        | * | * | * | * | 3
DEC       | 0x09   | Decrement Accumulator        | * | * | * | * | 3
PUSH      | 0x0A   | Push accumulator to stack    | - | - | - | - | 3
POP       | 0x0B   | Pop item from stack to acc   | * | - | * | - | 3
LD   [pr] | 0x0C   | Load item from [pr] to acc   | * | - | * | - | 3
ST   [pr] | 0x0D   | Store acc to [pr]            | - | - | - | - | 3
RET       | 0x0E   | Return from subroutine       | - | - | - | - | 3
ADDP      | 0x0F   | Add acc to pointer register  | - | - | - | - | 3
 
IMMEDIATE (2-Bytes)
Mnemonic  | Opcode | Description                  | Z | C | N | V | Cycles
----------|--------|------------------------------|---|---|---|---|-------
LDI   imm | 0x10   | Load Acc with Immediate      | * | - | * | - | 5
ANDI  imm | 0x12   | AND Acc with Immediate       | * | * | * | 0 | 5
ORI   imm | 0x13   | OR Acc with Immediate        | * | * | * | 0 | 5
XORI  imm | 0x14   | XOR Acc with Immediate       | * | * | * | 0 | 5
ADDI  imm | 0x15   | Add Immediate to Acc         | * | * | * | * | 5
SUBI  imm | 0x16   | Subtract Immediate from Acc  | * | * | * | * | 5
ADCI  imm | 0x17   | Add Imm + Carry to Acc       | * | * | * | * | 5
SBCI  imm | 0x18   | Sub Imm + Carry to Acc       | * | * | * | * | 5
ADPI  imm | 0x19   | Add Immediate to PR          | - | - | - | - | 5
CMPI  imm | 0x1A   | Compare accumulator w/ imm   | * | * | * | * | 5
TEST  imm | 0x1B   | AND bitmask w/ accumulator   | * | * | * | 0 | 5
PUSHI imm | 0x1C   | Push imm value to stack      | - | - | - | - | 5

 
ADDRESS (2-Bytes)
Mnemonic  | Opcode | Description                  | Z | C | N | V | Cycles
----------|--------|------------------------------|---|---|---|---|-------
AND  addr | 0x2n   | AND Acc with Memory          | * | * | * | 0 | 7
OR   addr | 0x3n   | OR Acc with Memory           | * | * | * | 0 | 7
XOR  addr | 0x4n   | XOR Acc with Memory          | * | * | * | 0 | 7
ADD  addr | 0x5n   | Add Memory to Acc            | * | * | * | * | 7
SUB  addr | 0x6n   | Subtract Memory from Acc     | * | * | * | * | 7
ADDC addr | 0x7n   | Add Memory + Carry to Acc    | * | * | * | * | 7
SUBC addr | 0x8n   | Add Memory + Carry to Acc    | * | * | * | * | 7
LD   addr | 0x9n   | Load Acc from Memory         | * | - | * | - | 7
ST   addr | 0xAn   | Store Acc to Memory          | - | - | - | - | 7
JCC  ---- | 0xBn   | Conditional Jump (see below) | - | - | - | - | 7
JMP  addr | 0xCn   | Unconditional Jump           | - | - | - | - | 7
LDP  addr | 0xDn   | Load address to PR           | - | - | - | - | 7
CALL addr | 0xEn   | Call subroutine              | - | - | - | - | 7
 
Note: For Address Opcodes, 'n' represents the upper 4 bits
      of the 12-bit address.
 
CONDITIONAL BRANCH (2-Bytes, PC-relative signed offset)
Opcode  | Mnemonic | Alt Mnemonic | Flags           | C Condition        | Description
--------|----------|--------------|-----------------|--------------------|---------------------
0xB0    | JZ       | JEQ          | Z=1             | a == b             | Jump if Zero
0xB1    | JNZ      | JNE          | Z=0             | a != b             | Jump if Not Zero
0xB2    | JC       | JUGE         | C=1             | (uint)a >= (uint)b | Jump if Carry
0xB3    | JNC      | JULT         | C=0             | (uint)a < (uint)b  | Jump if No Carry
0xB4    | JA       | JUGT         | C=1 & Z=0       | (uint)a > (uint)b  | Jump if Above
0xB5    | JBE      | JULE         | C=0 | Z=1       | (uint)a <= (uint)b | Jump if Below/Equal
0xB6    | JGE      | JSGE         | N^V=0           | (int)a >= (int)b   | Jump if Greater/Equal
0xB7    | JLT      | JSLT         | N^V=1           | (int)a < (int)b    | Jump if Less Than
0xB8    | JGT      | JSGT         | N^V=0 & Z=0     | (int)a > (int)b    | Jump if Greater Than
0xB9    | JLE      | JSLE         | N^V=1 | Z=1     | (int)a <= (int)b   | Jump if Less/Equal
0xBA    | JN       | JNEG         | N=1             | a < 0              | Jump if Negative
0xBB    | JP       | JPOS         | N=0             | a >= 0             | Jump if Positive
0xBC    | JO       | JOVF         | V=1             | no C equivalent    | Jump if Overflow
0xBD    | JNO      | JNOV         | V=0             | no C equivalent    | Jump if No Overflow
0xBE    | --       | --           | --              | reserved           | --
0xBF    | --       | --           | --              | reserved           | --
 
Note: Conditional branch opcode byte = 0x1n where 'n' is the 4-bit condition
      code from the table above. The second byte is a signed 8-bit offset
      applied to PC after the instruction fetch (PC += 2 + offset).
      Range: -126 to +129 bytes from the branch instruction.
 
Note: N (Negative) reflects bit 7 of the result. V (Overflow) is set when
      the signed result exceeds the 8-bit signed range [-128, +127].
 
Note: SHR always clears N (MSB shifted in is 0, i.e. logical right shift).
      For logical operations (AND/OR/XOR/INV/ANDI/ORI/XORI), V is always
      cleared as overflow has no meaning for bitwise results.

Note: For SHL and SHR, C acts as the shift out of our shift operation. For SHL, V
      signals whether or not the accumulator is still a valid signed representation.

Note: For logical operations, carry acts as a parity bit where 1 = Odd
      parity and 0 = Even parity.
 
Note: For subtraction, carry acts as a no-borrow flag (C=1 means no borrow).
 
Note: CALL and RET push and pop return addresses for subroutine calls.
      The top 4 bits are stored first, then the low 8 bits. All calls
      take up 2 bytes in the stack.
 
Note: When comparing (CMPI) with an immediate, all flags are set as if a
      subtraction was performed without storing the result.
 
Note: ADDC/ADDCI add the carry flag into the result, enabling multi-byte
      addition across multiple instructions.