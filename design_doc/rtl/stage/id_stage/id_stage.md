# ID Stage 设计描述

## 概述

ID（Instruction Decode）Stage 是 5 级流水线的第二级，负责将 IF Stage 传来的 32 位指令字一次性译码为：字段提取、立即数生成、以及全部 EX/MEM/WB 阶段所需的控制信号。

与先前解耦设计不同，本阶段**仅包含一个组合逻辑模块**：

- `decode.v` — 执行全部译码工作：字段提取 + 立即数生成 + 控制信号生成（包括 ALU 操作码）

`decode.v` 是整个流水线的**控制信号唯一来源（Single Source of Truth）**。所有控制信号（含扁平化 `alu_opcode`）在 ID 阶段一次性生成，通过 `id_ex.v` 透传至 EX/MEM/WB，后续阶段不再进行任何控制信号的二次解码。

数据经 `id_ex.v` 流水线寄存器锁存后传递给 EX Stage。

## 模块组成

```
              IF/ID (if_id.v)
                   │
        ┌──────────┤
        │          │
        ▼          ▼
    decode.v    RegFile (resources)
   (全部译码)       │
        │     rs1_data, rs2_data
        │          │
        ▼          ▼
      ╔══════════════════════════════╗
      ║        id_ex.v              ║────► EX Stage
      ║  (寄存器值 + 立即数 + 控制)    ║
      ╚══════════════════════════════╝
```

数据流向：`if_id.v` → `decode.v` → `id_ex.v` → EX Stage
寄存器值：`decode.v`（地址）→ `regfile.v`（读出数据）→ `id_ex.v`

## 模块详解

### 1. decode.v

**职责**：纯组合逻辑。接收 32 位指令字和当前 PC，一次性输出三样东西：
1. 寄存器地址（`rs1_addr`, `rs2_addr`, `rd_addr`）
2. 32 位立即数（`imm`）
3. 完整的控制信号束（`alu_opcode`, `branch`, `reg_write` 等）

内部按子功能划分为三个 `always_comb` 块，但对外是统一模块。

**控制通路设计原则**：

```
  decode.v (ID, 一次性生成全部控制 + 立即数)
       │
       ▼
  id_ex.v  (锁存完整控制总线)
       │
       ▼
  executor.v (纯数据通路，直接消费控制信号)
```

**输入**：

| 信号 | 宽度 | 来源 | 说明 |
|------|------|------|------|
| `i_instruction` | 32 | if_id.v (o_instruction) | 32 位指令字 |

**输出——寄存器地址**：

| 信号 | 宽度 | 去向 | 说明 |
|------|------|------|------|
| `o_rs1_addr` | 5 | regfile.v (i_rs1_addr) | inst[19:15]，读口 1 |
| `o_rs2_addr` | 5 | regfile.v (i_rs2_addr) | inst[24:20]，读口 2 |
| `o_rd_addr` | 5 | id_ex.v → … → WB Stage | inst[11:7]，目标寄存器 |

**输出——立即数**：

| 信号 | 宽度 | 去向 | 说明 |
|------|------|------|------|
| `o_imm` | 32 | id_ex.v → EX Stage | 32 位符号扩展立即数 |

**输出——控制信号束**：

| 信号 | 宽度 | 去向 | 说明 |
|------|------|------|------|
| `o_alu_opcode` | 4 | id_ex.v → executor.v | ALU 运算类型（扁平编码，含分支比较） |
| `o_alu_src_a` | 1 | id_ex.v → executor.v | ALU A 口选择：0=rs1_data, 1=pc（AUIPC / JAL / JALR） |
| `o_alu_src` | 1 | id_ex.v → executor.v | ALU B 口选择：0=rs2_data, 1=imm（I / U / J / S / B 型） |
| `o_branch` | 1 | id_ex.v → flow_control.v | 是否为分支指令（opcode == BRANCH 时置 1） |
| `o_mem_read` | 1 | id_ex.v → MEM Stage | 读数据存储器使能 |
| `o_mem_write` | 1 | id_ex.v → MEM Stage | 写数据存储器使能 |
| `o_mem_width` | 2 | id_ex.v → MEM Stage | 访存宽度：00=Byte, 01=Half, 10=Word |
| `o_mem_sext` | 1 | id_ex.v → MEM Stage | Load 符号扩展：0=零扩展, 1=符号扩展 |
| `o_mem_to_reg` | 1 | id_ex.v → WB Stage | 写回源选择：0=ALU, 1=内存（JAL/JALR 的 PC+4 写回路径 TBD） |
| `o_reg_write` | 1 | id_ex.v → WB Stage | 寄存器写使能 |

> `o_rd_addr` 同时进入 `id_ex.v` 锁存，经 `ex_mem.v` → `mem_wb.v` 透传至 WB Stage，用于 regfile 写回。

**内部组织（代码结构）**：

```verilog
module decode (
    input  wire [31:0] i_instruction,
    // 寄存器地址
    output wire [ 4:0] o_rs1_addr,
    output wire [ 4:0] o_rs2_addr,
    output wire [ 4:0] o_rd_addr,

    // 立即数
    output wire [31:0] o_imm,

    // 控制信号束
    output wire [ 3:0] o_alu_opcode,
    output wire        o_alu_src_a,
    output wire        o_alu_src,
    output wire        o_branch,
    output wire        o_mem_read,
    output wire        o_mem_write,
    output wire [ 1:0] o_mem_width,
    output wire        o_mem_sext,
    output wire        o_mem_to_reg,
    output wire        o_reg_write
);

    // ---- 内部信号：字段提取 ----
    wire [6:0] opcode;
    wire [2:0] funct3;
    wire [6:0] funct7;
    wire       inst_30;

    // ---- 第 1 块：字段提取 ----
    assign opcode  = i_instruction[6:0];
    assign funct3  = i_instruction[14:12];
    assign funct7  = i_instruction[31:25];
    assign inst_30 = i_instruction[30];
    assign o_rs1_addr = i_instruction[19:15];
    assign o_rs2_addr = i_instruction[24:20];
    assign o_rd_addr  = i_instruction[11:7];

    // ---- 第 2 块：立即数生成 ----
    // ...（见下文立即数生成逻辑）

    // ---- 第 3 块：控制信号生成 ----
    // ...（见下文控制信号生成逻辑）

endmodule
```

三个块各自为 `always_comb`（或 `assign`），不存在跨块依赖导致的组合环。

---

#### 1.1 字段提取

纯 `assign`，从 `i_instruction` 直接截取 6 个字段：

| 字段 | 位范围 | 说明 |
|------|--------|------|
| `opcode` | [6:0] | 全格式统一 |
| `rd_addr` | [11:7] | R/I/U/J 型有意义，S/B 型不使用 |
| `funct3` | [14:12] | 全格式统一 |
| `rs1_addr` | [19:15] | 全格式统一 |
| `rs2_addr` | [24:20] | R/S/B 型使用，I/U/J 型不使用 |
| `funct7` | [31:25] | 仅 R 型有意义 |
| `inst_30` | [30] | SRLI/SRAI 和 SUB/ADD 的额外区分位 |

不区分指令格式——格式判断由立即数生成和控制信号生成各自的 `case (opcode)` 完成。

---

#### 1.2 立即数生成

纯组合逻辑，根据 `opcode`（必要时配合 `funct3`）按 RISC-V 规范拼接 32 位立即数。

**格式判断与拼接规则**：

| 格式 | 判断条件 (opcode) | 重组方式 |
|------|-------------------|----------|
| I-type | LOAD / OP-IMM / JALR | `{{20{inst[31]}}, inst[31:20]}` |
| S-type | STORE | `{{20{inst[31]}}, inst[31:25], inst[11:7]}` |
| B-type | BRANCH | `{{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0}` |
| U-type | LUI / AUIPC | `{inst[31:12], 12'b0}` |
| J-type | JAL | `{{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0}` |
| shift-amt | OP-IMM 且 funct3∈{001,101} | `{27'b0, inst[24:20]}`（零扩展 5-bit shamt） |

**默认行为**：未匹配时 `o_imm = 32'h0`。

---

#### 1.3 控制信号生成

纯组合逻辑，根据 `opcode` / `funct3` / `funct7` / `inst_30` 生成 14 条控制信号。这是**全部控制信号的唯一产生点**。

**alu_opcode 编码**（4-bit 扁平编码，含分支比较）：

| 码值 | 名称 | 运算 | 触发条件 |
|------|------|------|----------|
| 0 | ALU_ADD | A + B | ADDI, ADD, LUI（imm=0）, AUIPC, JAL, JALR, LOAD, STORE |
| 1 | ALU_SUB | A - B | SUB |
| 2 | ALU_SLL | A << B[4:0] | SLLI, SLL |
| 3 | ALU_SLT | signed(A) < signed(B) | SLTI, SLT, BLT |
| 4 | ALU_SLTU | unsigned(A) < unsigned(B) | SLTIU, SLTU, BLTU |
| 5 | ALU_XOR | A ^ B | XORI, XOR |
| 6 | ALU_SRL | A >> B[4:0] (logical) | SRLI, SRL |
| 7 | ALU_SRA | A >> B[4:0] (arithmetic) | SRAI, SRA |
| 8 | ALU_OR | A | B | ORI, OR |
| 9 | ALU_AND | A & B | ANDI, AND |
| 10 | ALU_EQ | A == B | BEQ |
| 11 | ALU_NE | A != B | BNE |
| 12 | ALU_GE | signed(A) >= signed(B) | BGE |
| 13 | ALU_GEU | unsigned(A) >= unsigned(B) | BGEU |
| 14 | — | （保留） | — |
| 15 | ALU_NOP | result = 0 | 未实现/非法指令 / NOP bubble |

**分支处理**：`o_branch` 仅标记是否为分支指令（用于 flow_control），比较类型由 `o_alu_opcode` 携带。executor 内部的 Branch Unit 根据 `alu_opcode` 判断条件并输出 `branch_taken`。

**mem_width + mem_sext（LOAD 时）**：

| funct3 | mem_width | mem_sext | 指令 |
|--------|-----------|----------|------|
| 000 | 00 (Byte) | 1 | LB |
| 001 | 01 (Half) | 1 | LH |
| 010 | 10 (Word) | 1 | LW |
| 100 | 00 (Byte) | 0 | LBU |
| 101 | 01 (Half) | 0 | LHU |

**reg_write**：LUI, AUIPC, JAL, JALR, OP-IMM, OP, LOAD 使能；SYSTEM, STORE, BRANCH, MISC-MEM 不使能。

**译码伪代码**：

```verilog
// 控制信号块
always_comb begin
    // 安全默认值（NOP / 非法指令）
    o_alu_opcode  = ALU_NOP;    // 4'hF
    o_alu_src_a   = 1'b0;
    o_alu_src     = 1'b0;
    o_branch      = 1'b0;
    o_mem_read    = 1'b0;
    o_mem_write   = 1'b0;
    o_mem_width   = 2'b00;
    o_mem_sext    = 1'b0;
    o_mem_to_reg  = 1'b0;
    o_reg_write   = 1'b0;

    case (opcode)
        `OPCODE_OP: begin  // R-type
            o_reg_write = 1'b1;
            o_alu_src   = 1'b0;
            case (funct3)
                3'b000: o_alu_opcode = (funct7[5] && inst_30) ? ALU_SUB : ALU_ADD;
                3'b001: o_alu_opcode = ALU_SLL;
                3'b010: o_alu_opcode = ALU_SLT;
                3'b011: o_alu_opcode = ALU_SLTU;
                3'b100: o_alu_opcode = ALU_XOR;
                3'b101: o_alu_opcode = (funct7[5] && inst_30) ? ALU_SRA : ALU_SRL;
                3'b110: o_alu_opcode = ALU_OR;
                3'b111: o_alu_opcode = ALU_AND;
            endcase
        end

        `OPCODE_OPIMM: begin  // I-type
            o_reg_write = 1'b1;
            o_alu_src   = 1'b1;
            case (funct3)
                3'b000: o_alu_opcode = ALU_ADD;
                3'b010: o_alu_opcode = ALU_SLT;
                3'b011: o_alu_opcode = ALU_SLTU;
                3'b100: o_alu_opcode = ALU_XOR;
                3'b110: o_alu_opcode = ALU_OR;
                3'b111: o_alu_opcode = ALU_AND;
                3'b001: o_alu_opcode = ALU_SLL;  // SLLI: funct7[5]==0
                3'b101: o_alu_opcode = (funct7[5] && inst_30) ? ALU_SRA : ALU_SRL;
            endcase
        end

        `OPCODE_BRANCH: begin
            o_branch    = 1'b1;
            o_alu_src   = 1'b0;
            case (funct3)
                3'b000: o_alu_opcode = ALU_EQ;
                3'b001: o_alu_opcode = ALU_NE;
                3'b100: o_alu_opcode = ALU_SLT;
                3'b101: o_alu_opcode = ALU_GE;
                3'b110: o_alu_opcode = ALU_SLTU;
                3'b111: o_alu_opcode = ALU_GEU;
            endcase
        end

        `OPCODE_LOAD: begin
            o_reg_write  = 1'b1;
            o_mem_read   = 1'b1;
            o_alu_src    = 1'b1;
            o_alu_opcode = ALU_ADD;
            o_mem_to_reg = 1'b1;  // 写回来自内存
            case (funct3)
                3'b000: {o_mem_sext, o_mem_width} = {1'b1, 2'b00}; // LB
                3'b001: {o_mem_sext, o_mem_width} = {1'b1, 2'b01}; // LH
                3'b010: {o_mem_sext, o_mem_width} = {1'b1, 2'b10}; // LW
                3'b100: {o_mem_sext, o_mem_width} = {1'b0, 2'b00}; // LBU
                3'b101: {o_mem_sext, o_mem_width} = {1'b0, 2'b01}; // LHU
            endcase
        end

        `OPCODE_STORE: begin
            o_mem_write  = 1'b1;
            o_alu_src    = 1'b1;
            o_alu_opcode = ALU_ADD;
            case (funct3)
                3'b000: o_mem_width = 2'b00; // SB
                3'b001: o_mem_width = 2'b01; // SH
                3'b010: o_mem_width = 2'b10; // SW
            endcase
        end

        `OPCODE_LUI: begin
            o_reg_write  = 1'b1;
            o_alu_src    = 1'b1;
            o_alu_opcode = ALU_ADD;
            // ALU A = 0 (rs1_addr 指向 x0 时数据即为 0，或由 executor 判断)
        end

        `OPCODE_AUIPC: begin
            o_reg_write  = 1'b1;
            o_alu_src_a  = 1'b1;  // PC
            o_alu_src    = 1'b1;  // imm
            o_alu_opcode = ALU_ADD;
        end

        `OPCODE_JAL: begin
            o_reg_write  = 1'b1;
            o_alu_src_a  = 1'b1;  // PC
            o_alu_src    = 1'b1;  // imm (跳转目标)
            o_alu_opcode = ALU_ADD;
            // PC+4 写回路径 TBD（见"未来扩展"）
        end

        `OPCODE_JALR: begin
            o_reg_write  = 1'b1;
            o_alu_src    = 1'b1;
            o_alu_opcode = ALU_ADD;
            // rs1_data + imm = 跳转目标，PC+4 写回路径 TBD
        end

        // SYSTEM: ECALL/EBREAK — 保持默认值（均为 0，即 NOP）
        // MISC-MEM: FENCE/FENCE.I/PAUSE — 保持默认值
    endcase
end
```

**默认/安全行为**：
- 未匹配任何指令时全输出安全默认值（均为 0），等价于 NOP bubble，不产生副作用。

### 2. id_ex.v

**职责**：ID/EX 流水线寄存器。锁存 `decode.v` 产出的**完整控制总线**和数据通路值，传递给 EX Stage。不存储原始 funct3/funct7（decode 已完成全部解码）。响应 stall/flush。

**输入**：

| 信号 | 宽度 | 来源 | 说明 |
|------|------|------|------|
| `i_clk` | 1 | 全局时钟 | 系统时钟 |
| `i_rst_n` | 1 | 全局复位 | 异步复位，低有效 |
| `i_flush` | 1 | flow_control.v | 流水线冲刷 |
| `i_stall` | 1 | hazard_control.v | 流水线暂停 |
| `i_pc` | 32 | if_id.v (o_pc) | 当前指令 PC |
| `i_rs1_data` | 32 | regfile.v (o_rs1_data) | rs1 读出值 |
| `i_rs2_data` | 32 | regfile.v (o_rs2_data) | rs2 读出值 |
| `i_imm` | 32 | decode.v (o_imm) | 32 位立即数 |
| `i_rd_addr` | 5 | decode.v (o_rd_addr) | 目标寄存器地址 |
| `i_alu_opcode` | 4 | decode.v (o_alu_opcode) | ALU 运算类型 |
| `i_alu_src_a` | 1 | decode.v (o_alu_src_a) | ALU A 口选择 |
| `i_alu_src` | 1 | decode.v (o_alu_src) | ALU B 口选择 |
| `i_branch` | 1 | decode.v (o_branch) | 是否为分支指令 |
| `i_mem_read` | 1 | decode.v (o_mem_read) | 读 Memory |
| `i_mem_write` | 1 | decode.v (o_mem_write) | 写 Memory |
| `i_mem_width` | 2 | decode.v (o_mem_width) | 访存宽度 |
| `i_mem_sext` | 1 | decode.v (o_mem_sext) | 符号扩展 |
| `i_mem_to_reg` | 1 | decode.v (o_mem_to_reg) | 写回数据选择 |
| `i_reg_write` | 1 | decode.v (o_reg_write) | 寄存器写使能 |

**输出**：与输入一一对应，前缀 `o_`。控制信号直接输出至 `executor.v`（EX Stage 不再有中间控制模块）。

| 输出 | 去向 |
|------|------|
| `o_pc[31:0]` | executor.v |
| `o_rs1_data[31:0]` | executor.v (ALU A 口) |
| `o_rs2_data[31:0]` | executor.v (ALU B 口 / Store 数据) |
| `o_imm[31:0]` | executor.v |
| `o_alu_opcode[3:0]` 等 | executor.v（ALU/Branch Unit 直接消费） |
| `o_rd_addr[4:0]` | ex_mem.v → mem_wb.v → regfile.v |
| `o_branch` | flow_control.v |

**行为**（与 `if_id.v` 一致）：

```
always_ff @(posedge i_clk or negedge i_rst_n):
  if (!i_rst_n):              全部输出 ← 安全默认值
  else if (i_flush):          控制总线清零（reg_write=0, mem_read=0, mem_write=0, branch=0），数据 ← `XLEN_ZERO
  else if (i_stall):          保持当前值
  else:                       锁存所有输入
```

## 设计原则

1. **单模块译码**：字段提取、立即数生成、控制信号生成集中在 `decode.v` 一个模块内，减少跨模块连线。
2. **纯组合 ID**：`decode.v` 为纯组合逻辑，无状态。延迟集中在一拍内，由 `id_ex.v` 在时钟沿锁存。
3. **RegFile 为共享资源**：ID Stage 仅提供读地址（`decode.v` → `regfile.v`），读出数据直达 `id_ex.v`，写回由 WB Stage 完成。
4. **控制信号唯一来源**：`decode.v` 是全部控制信号的唯一产生点（包括 ALU 操作码），经 `id_ex.v` 锁存后透传至 EX/MEM/WB。EX 阶段不存在独立的控制模块，`executor.v` 直接消费扁平化 `alu_opcode`。
5. **默认安全**：未匹配指令时所有控制信号退化为 NOP（不写、不读、无分支），保证非法指令不产生副作用。

## 与其他模块的交互

### 与 IF Stage 的接口

| 来源 | 信号 | 目标 | 说明 |
|------|------|------|------|
| if_id.v | `o_instruction[31:0]` | decode.v (i_instruction) | 指令字 |
| if_id.v | `o_pc[31:0]` | id_ex.v (i_pc) | 当前指令 PC |

### 与 Resources 的交互

| 来源 | 信号 | 目标 | 说明 |
|------|------|------|------|
| decode.v | `o_rs1_addr[4:0]`, `o_rs2_addr[4:0]` | regfile.v | 读口地址 |
| regfile.v | `o_rs1_data[31:0]`, `o_rs2_data[31:0]` | id_ex.v | 读出值（组合路径，直达 id_ex） |

### 与 Pipeline Control 的交互

| 来源 | 信号 | 目标 | 说明 |
|------|------|------|------|
| hazard_control.v | `stall` | id_ex.v | 暂停 ID/EX 更新 |
| flow_control.v | `flush` | id_ex.v | 冲刷流水线寄存器 |
| id_ex.v | `o_branch` | flow_control.v | 标记分支指令，参与冲刷判断 |
| id_ex.v | `o_rd_addr` | hazard_control.v | 用于 RAW 冲突检测（forwarding） |

### 与 EX Stage 的交互

`id_ex.v` 的控制总线和数据通路值直接输出至 `executor.v`（纯数据通路执行单元），无需中间控制模块：

```
executor.v 内部:
  ALU:  .a(alu_src_a ? pc : rs1_data)
        .b(alu_src   ? imm : rs2_data)
        .opcode(alu_opcode)   // 直接来自 id_ex，不再查表
        .result(alu_result)

  Branch Unit: 根据 alu_opcode 判断条件，输出 branch_taken → flow_control.v
```

## 未来扩展

- **非法指令检测**：在 `decode.v` 中增加 `illegal_instr` 输出信号。
- **CSR 支持**：`decode.v` 扩展 SYSTEM opcode 译码，增加 `csr_read/csr_write/csr_addr` 等输出。
- **M 扩展**：`decode.v` 内增加 MUL/DIV 的 `alu_opcode` 编码（4-bit 可容纳）。
- **JAL/JALR 链接地址**：当前 `mem_to_reg` 为 1-bit（ALU vs 内存），JAL/JALR 的 PC+4 写回路径待后续设计（IF 阶段计算 PC+4 随流水线透传，或在 EX 段专设）。
- **FENCE / FENCE.I / PAUSE**：当前 NOP 处理，未来在 MEM 阶段实现。
- **ECALL / EBREAK**：当前 `reg_write=0`，未来触发异常流。
