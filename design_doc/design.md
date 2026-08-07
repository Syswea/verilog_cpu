# Verilog CPU Design Document

## Project Overview

This project implements a **5-stage pipelined RISC-V CPU** in Verilog.

Current target:

- ISA: RV32I (initial implementation)
- Future ISA:
  - RV32IMA
  - Zicsr
  - Zifencei
- Privilege:
  - M / S / U
- MMU:
  - Sv32
- Final goal:
  - Boot Linux kernel
  - Run on Xilinx XC7A35T FPGA

This document describes the current hardware architecture.

---

# Overall Architecture

The CPU follows a classic **5-stage pipeline**.

```
           Resources
        ┌──────────────┐
        │ PC RegFile   │
        └──────┬───────┘

 IF  →  ID  →  EX  →  MEM  →  WB

        ↑
 Pipeline Control
```

The design intentionally separates

- datapath
- control path
- pipeline control

to simplify future extensions.

---

# Module Layout

The project is organized into several logical regions.

## 1. Resources

Shared hardware resources used by all stages.

Modules:

```
pc.v
regfile.v
```

### pc.v

Responsibilities

- store current PC
- update PC every cycle
- receive pc_next
- output current PC

Connections

```
pc_next
    │
    ▼
pc.v
    │
    ▼
instruction memory
```

---

### regfile.v

Responsibilities

- 32 integer registers
- dual read ports
- single write port

Read:

```
Decode
    │
    ▼
RegFile
```

Write:

```
WB
   │
   ▼
RegFile
```

---

# 2. IF Stage

Modules

```
pc_next.v
inst_mem.v
if_id.v
```

Pipeline

```
PC
 │
 ▼
Instruction Memory
 │
 ▼
IF/ID
```

---

## pc_next.v

Computes next PC.

Inputs include

- branch redirect
- stall

Output

```
pc_next
```

No PC register exists inside this module.

---

## inst_mem.v

Instruction ROM / instruction bus.

Input

```
pc
```

Output

```
instruction
```

---

## if_id.v

Pipeline register.

Currently stores

- instruction

Future versions are expected to additionally store

- pc
- pc+4

---

# 3. ID Stage

Modules

```
decode.v
id_ex.v
```

---

## decode.v

Unified instruction decoder. Performs all ID-stage work:
- field extraction (opcode, funct3, funct7, rs1, rs2, rd)
- immediate generation (I/S/B/U/J/shift-amount formats)
- control signal generation (including flat-encoded `alu_opcode`)

This is the single source of truth for all pipeline control signals.
No separate imm_gen or id_control modules exist.
## id_ex.v

Pipeline register.

Stores

Datapath

- register values
- immediate

Control

- decoded control bundle

---

# 4. EX Stage

Modules

```
executor.v
```
---

## executor.v

Pure datapath execution unit. Consumes complete control bus from `id_ex.v` — no local control decoding.

Contains

```
ALU

Branch Unit
```

Responsibilities

- arithmetic
- logic
- comparisons
- branch evaluation

Outputs

```
ALU result

Branch information
```

Branch result is forwarded to pipeline control.

---

---

# 5. MEM Stage

Modules

```
ex_mem.v
data_mem.v
```

---

## ex_mem.v

Pipeline register.

Stores

- ALU result
- destination register
- memory address
- control bundle

---

## data_mem.v

Data memory interface.

Responsibilities

- load
- store

Input

```
address
```

Output

```
memory data
```

---

# 6. WB Stage

Modules

```
mem_wb.v
wb.v
```

---

## mem_wb.v

Pipeline register.

Stores

- memory result
- ALU result
- destination register
- control

---

## wb.v

Final write-back stage.

Selects write-back source.

Writes result into

```
regfile
```

---

# Pipeline Registers

Pipeline registers separate every stage.

```
IF/ID

ID/EX

EX/MEM

MEM/WB
```

Responsibilities

- store stage outputs
- support stall
- support flush
- isolate combinational logic

Pipeline registers are controlled by Pipeline Control.

---

# Pipeline Control

Pipeline control is intentionally separated from datapath.

Modules

```
flow_control.v

hazard_control.v
```

---

## flow_control.v

Responsibilities

- branch redirect
- pipeline flush
- PC redirection

Inputs

```
branch result
```

Outputs

```
flush

branch target

branch valid
```

Targets

```
pc_next

IF/ID

ID/EX
```

---

## hazard_control.v

Responsible for pipeline hazards.

Outputs

```
stall
```

Controls

- PC
- IF/ID
- ID/EX
- EX/MEM
- MEM/WB

Future responsibilities include

- RAW detection
- forwarding
- load-use stall
- structural hazards

---

# Datapath

Overall datapath

```
PC

↓

Instruction Memory

↓

IF/ID

↓

Decode

├── RegFile
├── Immediate Generator
└── Control Generator

↓

ID/EX

↓

Executor

↓

EX/MEM

↓

Data Memory

↓

MEM/WB

↓

Write Back

↓

RegFile
```

---

# Control Path

Control signals flow independently from datapath.

```
Decode

↓

ID Control

↓

ID/EX

↓
↓

Executor

↓

Flow Control

↓

Flush / Branch Redirect
```

Hazard logic is also independent.

```
Hazard Detection

↓

Pipeline Stall

↓

Pipeline Registers
```

---

# Design Principles

This project intentionally follows several rules.

## 1. Separation of Datapath and Control

Datapath modules should only compute data.

Control modules should only generate control signals.

---

## 2. Stage-local Logic

Each stage owns its own combinational logic.

Pipeline registers only store signals.

---

## 3. Shared Resources

PC and Register File are global resources.

They are not owned by any pipeline stage.

---

## 4. Pipeline Control Independence

Hazard handling and flow control are independent modules.

Execution modules should never directly stall or flush pipeline registers.

---

## 5. Extensibility

The architecture is designed for future support of

- M Extension
- CSR
- Exceptions
- Interrupts
- MMU
- Cache
- Linux boot

without redesigning the overall pipeline.

---

# Current Status

The architecture diagram defines the intended hardware organization.

Individual Verilog modules are implemented incrementally.

Future code should strictly follow this architecture unless the design document is updated.