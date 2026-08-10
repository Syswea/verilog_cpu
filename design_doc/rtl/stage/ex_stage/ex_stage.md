# EX Stage 设计描述（修订版 v2）

## 概述

EX（Execute）Stage 是 5 级流水线的第三级，负责执行所有算术/逻辑/比较运算以及分支跳转判定。**本级是纯数据通路，不含任何控制信号生成逻辑**——所有控制信号已在 ID Stage 的 `decode.v` 中一次性生成，经 `id_ex.v` 透传至本级直接消费。

**v2 修订要点**（相对 v1）：

- 按运算类别平铺**并行运算单元**：一个指令的所有运算同一拍并行完成，由选择信号 `alu_src_a` / `alu_src` 选出操作数，各单元无状态、无串行复用。
- 明确**无条件并行计算、消费端门控**原则：所有运算单元恒算，结果是否生效由消费端（寄存器写使能 / PC 更新）决定，EX 内不做条件计算。
- **废弃 `op_pair_*.v`（3 个文件）**：操作数组合不再用固定配对模块，改为 executor 内由 `alu_src_a[1:0]` / `alu_src` 直接驱动 MUX 选出 `alu_a` / `alu_b`。
- 新增 **pc+4 链接地址单元**（JAL/JALR 写回）与 **JALR 目标单元**（`(rs1+imm) & ~1`，跳转目标在 EX 内自闭环）。
- 分支判定改用独立的 **`i_branch_sel[1:0]`**（区分无/条件分支/JAL/JALR），不再用 `alu_opcode` 推断，消除二次解码。
- `alu_arith` 接口统一为 `(i_a, i_b, i_opcode, o_result)`，分支目标加法器 `pc+imm` 独立为 executor 级恒算单元。

## 模块组成

```
                      id_ex.v (Pipeline Register)
                          │
           ┌──────────────┼──────────────────────────┐
           │ pc, rs1, rs2, imm, rd                   │
           │ alu_opcode, alu_src_a[1:0], alu_src     │ (控制总线)
           │ branch_sel[1:0], wb_src[1:0], mem_*     │
           ▼              ▼                          ▼
┌──────────────────────────────────────────────────────────────┐
│  executor.v                                                  │
│                                                              │
│  ┌────────────────────── 操作数选择 MUX ──────────────────┐  │
│  │  alu_a = rs1 | pc | 0   (alu_src_a[1:0])              │  │
│  │  alu_b = rs2 | imm      (alu_src)                     │  │
│  └──────────┬───────────────────────────────┬────────────┘  │
│             │ alu_a, alu_b                  │ 固定输入        │
│  ┌──────────┴───────────┐         ┌─────────┴──────────────┐ │
│  │  alu.v               │         │ pc+4 单元              │ │
│  │  ├─ alu_arith (加减) │         │ pc+imm 目标加法器       │ │
│  │  ├─ alu_bit   (位运算)│         │ JALR 单元 (rs1+imm&~1) │ │
│  │  └─ alu_cmp   (判断)  │         └─────────┬──────────────┘ │
│  └──────────┬───────────┘                   │                │
│             │ alu_result                    │                │
│  ┌──────────┴───────────┐                   │                │
│  │   Branch Unit        │◄──────────────────┘                │
│  │  (branch_sel 判定)    │                                    │
│  └──────────┬───────────┘                                    │
│             │ branch_taken / branch_target                   │
│  ┌──────────┴───────────┐                                    │
│  │ 控制透传（含 wb_src） │                                    │
│  └──────────────────────┘                                    │
└─────────────┬───────────────────────────────────────────────┘
              │
   ┌──────────┼─────────────────┬────────────────┐
   ▼          ▼                 ▼                ▼
flow_ctrl ex_mem.v       ex_mem.v         ex_mem.v
(branch_taken,(alu_result,   (o_rs2_data,     (o_pc_plus4,
 branch_target) o_rd_addr)    mem_* 透传)      wb_src, reg_write)
```

### 模块清单

| 文件 | 职责 |
|------|------|
| `executor.v` | EX 顶层：操作数选择 MUX、pc+4 单元、分支目标加法器、JALR 单元、Branch Unit、控制透传 |
| `alu.v` | ALU 顶层选择器：实例化 3 个子单元，按 `i_opcode` 选择结果 |
| `alu_arith.v` | 加减单元（ADD / SUB） |
| `alu_bit.v` | 位运算单元（SLL/SRL/SRA/XOR/OR/AND） |
| `alu_cmp.v` | 判断单元（SLT/SLTU/EQ/NE/GE/GEU，布尔输出） |

> 原 v1 的 `op_pair_rs1_rs2.v` / `op_pair_rs1_imm.v` / `op_pair_pc_imm.v` 三个文件**废弃**，操作数组合改由选择信号驱动 MUX 完成。

## 运算单元总览

一个指令所需的全部运算**并行平铺**，各单元独立、同时产出，由信号选通结果：

| 单元 | 实现位置 | 输入 | 输出 | 覆盖指令 | 说明 |
|------|---------|------|------|---------|------|
| pc+4 单元 | executor 内 | `i_pc` | `o_pc_plus4` | JAL, JALR | 链接地址，供 WB 写回 rd |
| 加减单元 | `alu_arith.v` | `alu_a`, `alu_b`, `opcode` | result | R-type ADD/SUB、ADDI、LOAD/STORE 地址、LUI、AUIPC | 结果由 opcode 门控 |
| 位运算单元 | `alu_bit.v` | `alu_a`, `alu_b`, `opcode` | result | SLL/SRL/SRA/XOR/OR/AND 及 I 型（shift 量取 `i_b[4:0]`） | |
| 判断单元 | `alu_cmp.v` | `alu_a`, `alu_b`, `opcode` | result（0/1） | SLT/SLTU/EQ/NE/GE/GEU 及 I 型、BRANCH | 布尔输出，供写回与分支判定 |
| JALR 目标单元 | executor 内 | `i_rs1_data`, `i_imm` | `jalr_target` | JALR | `(rs1 + imm) & ~1`，低位对齐 |
| 分支目标加法器 | executor 内 | `i_pc`, `i_imm` | `pc_plus_imm` | JAL, BRANCH | 恒算，不受 opcode 影响 |

**为什么需要独立的分支目标加法器**：BRANCH 指令时判断单元需要 `(rs1, rs2)` 做比较，而跳转目标需要 `(pc, imm)`——两组操作数同时需要，而 `alu_a`/`alu_b` 只有一组。故 `pc+imm` 必须独立恒算，与 ALU 并行。

**无条件并行计算与消费端门控**：所有单元始终恒算，即使当前指令不使用其结果（如 BEQ 不跳时目标加法器仍在计算 `pc+imm`）。结果的"生效"由消费端门控决定：

- 寄存器堆写入：由 `reg_write` + `wb_src` 门控（WB 阶段消费）
- PC 更新：由 `branch_taken` 门控，决定取 `branch_target` 还是 `pc+4`（flow_ctrl 消费）

计算与门控解耦，各单元关键路径互不级联——判断与目标加法并行，无"先比较再算加法"的串行依赖。

---

## 1.1 端口定义

### 输入

| 信号 | 宽度 | 来源 | 说明 |
|------|------|------|------|
| `i_pc` | 32 | id_ex.v (o_pc) | 当前指令 PC |
| `i_rs1_data` | 32 | id_ex.v (o_rs1_data) | rs1 读出值 |
| `i_rs2_data` | 32 | id_ex.v (o_rs2_data) | rs2 读出值 / Store 数据 |
| `i_imm` | 32 | id_ex.v (o_imm) | 32 位符号扩展立即数 |
| `i_rd_addr` | 5 | id_ex.v (o_rd_addr) | 目标寄存器地址（透传） |
| `i_alu_opcode` | 4 | id_ex.v (o_alu_opcode) | ALU 运算类型（扁平编码，见 `alu_op_define.vh`） |
| `i_alu_src_a` | **2** | id_ex.v (o_alu_src_a) | A 端口选择：`ALU_A_RS1` / `ALU_A_PC` / `ALU_A_ZERO`（**v1 为 1 bit，已扩宽**） |
| `i_alu_src` | 1 | id_ex.v (o_alu_src) | B 端口选择：0=rs2、1=imm |
| `i_branch_sel` | **2** | id_ex.v (o_branch_sel) | 分支类型：`BRANCH_NONE` / `BRANCH_COND` / `BRANCH_JAL` / `BRANCH_JALR`（**取代 v1 的 1 bit `i_branch`**） |
| `i_mem_read` | 1 | id_ex.v | 读 Memory（透传） |
| `i_mem_write` | 1 | id_ex.v | 写 Memory（透传） |
| `i_mem_width` | 2 | id_ex.v | 访存宽度（透传） |
| `i_mem_sext` | 1 | id_ex.v | 符号扩展（透传） |
| `i_wb_src` | **2** | id_ex.v | 写回源选择：`WB_SRC_ALU` / `WB_SRC_MEM` / `WB_SRC_PC_PLUS4`（**取代 v1 的 1 bit `i_mem_to_reg`**） |
| `i_reg_write` | 1 | id_ex.v | 寄存器写使能（透传） |

### 输出——数据通路（→ ex_mem.v）

| 信号 | 宽度 | 说明 |
|------|------|------|
| `o_alu_result` | 32 | ALU 计算结果 |
| `o_pc_plus4` | **32** | 链接地址（JAL/JALR 写回值，**v2 新增**） |
| `o_rs2_data` | 32 | Store 数据（透传） |
| `o_rd_addr` | 5 | 目标寄存器地址（透传） |

### 输出——控制透传（→ ex_mem.v）

| 信号 | 宽度 | 说明 |
|------|------|------|
| `o_mem_read` | 1 | 读 Memory（透传） |
| `o_mem_write` | 1 | 写 Memory（透传） |
| `o_mem_width` | 2 | 访存宽度（透传） |
| `o_mem_sext` | 1 | 符号扩展（透传） |
| `o_wb_src` | 2 | 写回源选择（透传，v2 新增） |
| `o_reg_write` | 1 | 寄存器写使能（透传） |

### 输出——分支信息（→ flow_ctrl.v）

| 信号 | 宽度 | 说明 |
|------|------|------|
| `o_branch_taken` | 1 | 分支/跳转是否 taken |
| `o_branch_target` | 32 | 跳转目标地址（JAL/BRANCH 为 `pc+imm`，JALR 为 `(rs1+imm)&~1`，**EX 内已闭环**） |

---

## 1.2 内部结构（executor.v）

```verilog
// ---- 操作数选择 MUX（取代 v1 的 op_pair_*.v）----
// alu_src_a: 00=rs1, 01=pc, 10=zero(LUI)
// alu_src:   0=rs2, 1=imm
wire [31:0] alu_a = (i_alu_src_a == `ALU_A_PC)   ? i_pc       :
                    (i_alu_src_a == `ALU_A_ZERO) ? `XLEN_ZERO :
                                                   i_rs1_data;
wire [31:0] alu_b = i_alu_src ? i_imm : i_rs2_data;

// ---- 并行运算单元（全部恒算，无 opcode 门控）----
wire [31:0] pc_plus4    = i_pc + `PC_INCREMENT;              // pc+4 单元
wire [31:0] pc_plus_imm = i_pc + i_imm;                      // 分支目标加法器
wire [31:0] jalr_target = (i_rs1_data + i_imm) & `PC_ALIGN_MASK; // JALR 单元

// ---- ALU（加减 / 位运算 / 判断 3 子单元，接口统一）----
alu u_alu (
    .i_a      (alu_a),
    .i_b      (alu_b),
    .i_opcode (i_alu_opcode),
    .o_result (alu_result)
);

// ---- Branch Unit ----
assign o_branch_taken  = (i_branch_sel != `BRANCH_NONE) &&
                         ((i_branch_sel == `BRANCH_COND) ? alu_result[0] : 1'b1);
assign o_branch_target = (i_branch_sel == `BRANCH_JALR) ? jalr_target : pc_plus_imm;

// ---- 数据通路输出 ----
assign o_alu_result = alu_result;
assign o_pc_plus4   = pc_plus4;
assign o_rs2_data   = i_rs2_data;
assign o_rd_addr    = i_rd_addr;

// ---- 控制透传 ----
assign o_mem_read   = i_mem_read;
assign o_mem_write  = i_mem_write;
assign o_mem_width  = i_mem_width;
assign o_mem_sext   = i_mem_sext;
assign o_wb_src     = i_wb_src;
assign o_reg_write  = i_reg_write;
```

---

## 1.3 操作数选择（alu_a / alu_b）

由 decode 生成的选择信号驱动，**取代 v1 的三个 op_pair 模块**：

| `alu_src_a` | `alu_a` | 典型指令 |
|:---:|---|---|
| `ALU_A_RS1` (00) | `i_rs1_data` | R-type、ADDI、LOAD/STORE 地址、JALR |
| `ALU_A_PC` (01) | `i_pc` | AUIPC、JAL |
| `ALU_A_ZERO` (10) | 0 | LUI |

| `alu_src` | `alu_b` | 典型指令 |
|:---:|---|---|
| 0 | `i_rs2_data` | R-type、BRANCH（比较） |
| 1 | `i_imm` | I/S/U/J-type、LOAD/STORE |

**LUI 的 A=0 由 `ALU_A_ZERO` 编码直接保证**（v1 曾假设"decode 将 rs1_addr 置 x0"，与实际 decode.v 字段提取行为不符，v2 改为选择信号显式取 0，不再依赖 regfile 读出值）。

---

## 1.4 ALU（4 模块）

```
                    alu.v (顶层)
                   /     |      \
                  /      |       \
        alu_arith.v  alu_bit.v  alu_cmp.v
         (加减)     (位运算)    (判断)
```

四个模块均为**纯组合逻辑**，接口统一为 `(i_a, i_b, i_opcode, o_result)`。

### 1.4.1 加减单元（alu_arith.v）

| 条件 | `o_result` |
|------|------------|
| `i_opcode == ALU_ADD` | `i_a + i_b` |
| `i_opcode == ALU_SUB` | `i_a - i_b` |
| 其他 | `32'h0` |

覆盖：R-type ADD/SUB、ADDI、LOAD/STORE 地址（rs1+imm）、LUI（0+imm）、AUIPC（pc+imm）。
> v1 中该单元的 `o_branch_target = pc + imm` 端口**移除**，改由 executor 内独立的分支目标加法器承担（见 §1.2），接口恢复统一。

### 1.4.2 位运算单元（alu_bit.v）

| 条件 | `o_result` |
|------|------------|
| `i_opcode == ALU_SLL` | `i_a << i_b[4:0]` |
| `i_opcode == ALU_SRL` | `i_a >> i_b[4:0]` |
| `i_opcode == ALU_SRA` | `$signed(i_a) >>> i_b[4:0]` |
| `i_opcode == ALU_XOR` | `i_a ^ i_b` |
| `i_opcode == ALU_OR` | `i_a \| i_b` |
| `i_opcode == ALU_AND` | `i_a & i_b` |
| 其他 | `32'h0` |

移位量统一截取 `i_b[4:0]`（RV32I 规范；I 型 shamt 经 decode 零扩展进 imm）。

### 1.4.3 判断单元（alu_cmp.v）

| 条件 | `o_result` |
|------|------------|
| `i_opcode == ALU_SLT` | `$signed(i_a) < $signed(i_b) ? 32'd1 : 32'd0` |
| `i_opcode == ALU_SLTU` | `i_a < i_b ? 32'd1 : 32'd0` |
| `i_opcode == ALU_EQ` | `(i_a == i_b) ? 32'd1 : 32'd0` |
| `i_opcode == ALU_NE` | `(i_a != i_b) ? 32'd1 : 32'd0` |
| `i_opcode == ALU_GE` | `$signed(i_a) >= $signed(i_b) ? 32'd1 : 32'd0` |
| `i_opcode == ALU_GEU` | `i_a >= i_b ? 32'd1 : 32'd0` |
| 其他 | `32'h0` |

输出恒为 0/1 布尔值：供 SLT/SLTI 等写回 rd，也供 BRANCH 指令作 `branch_taken`。

### 1.4.4 alu.v — 顶层选择器

```verilog
module alu (
    input  wire [31:0] i_a,
    input  wire [31:0] i_b,
    input  wire [ 3:0] i_opcode,
    output wire [31:0] o_result
);
```

内部连接：

```
  arith_result ← alu_arith(i_a, i_b, i_opcode)
  bit_result   ← alu_bit  (i_a, i_b, i_opcode)
  cmp_result   ← alu_cmp  (i_a, i_b, i_opcode)
  o_result = (opcode ∈ {ALU_ADD, ALU_SUB})         ? arith_result :
             (opcode ∈ {SLL,SRL,SRA,XOR,OR,AND})    ? bit_result   :
             (opcode ∈ {SLT,SLTU,EQ,NE,GE,GEU})     ? cmp_result   :
                                                      32'h0;
```

`ALU_NOP` (15) 与保留码 (14) → `32'h0`（安全输出）。
**设计优势**：各单元独立，改一种运算不影响其他；M 扩展只需新增子模块并调整 MUX。

---

## 1.5 Branch Unit

### 输入

- `i_branch_sel[1:0]` — 分支类型（decode 生成，**不再依赖 alu_opcode 推断**）
- `alu_result[0]` — 判断单元布尔结果（仅条件分支使用）
- `pc_plus_imm` / `jalr_target` — 跳转目标（EX 内并行计算）

### 判定规则

| `i_branch_sel` | 指令 | `o_branch_taken` | `o_branch_target` |
|:---:|---|---|---|
| `BRANCH_NONE` (00) | 非分支/跳转 | 0 | `pc+imm`（无效） |
| `BRANCH_COND` (01) | BEQ/BNE/BLT/BGE/BLTU/BGEU | `alu_result[0]`（比较结果） | `pc+imm` |
| `BRANCH_JAL` (10) | JAL | 1（无条件） | `pc+imm` |
| `BRANCH_JALR` (11) | JALR | 1（无条件） | `(rs1+imm) & ~1` |

```verilog
assign o_branch_taken  = (i_branch_sel != `BRANCH_NONE) &&
                         ((i_branch_sel == `BRANCH_COND) ? alu_result[0] : 1'b1);
assign o_branch_target = (i_branch_sel == `BRANCH_JALR) ? jalr_target : pc_plus_imm;
```

**JALR 目标在 EX 内自闭环**：v1 曾要求 flow_ctrl 区分 JAL/JALR 并额外取 `o_alu_result` 作 JALR 目标（且该信号须经 ex_mem 才能拿到，时序不成立）。v2 由 JALR 单元独立计算并完成目标 MUX，`flow_ctrl` 只需消费 `o_branch_taken` / `o_branch_target` 两个信号，无需任何二次判断。

---

## 1.6 控制透传

纯 wire 连接，不经任何逻辑（见 §1.2 代码）。透传信号：`o_rs2_data`、`o_rd_addr`、`o_mem_read/write/width/sext`、`o_wb_src`、`o_reg_write`。

---

## 设计原则

1. **纯数据通路**：`executor.v` 无状态、无控制信号生成。所有控制来自 `id_ex.v`，本级仅消费。
2. **无条件并行计算**：一个指令所需的全部运算单元（pc+4、加减、位运算、判断、JALR 目标、分支目标）**一律无条件恒算**，不论当前指令是否使用该结果。单元之间无先后依赖、无串行复用、无状态机。
3. **消费端门控**：计算结果"是否生效"全部由消费端决定，EX 内不做条件计算——
   - ALU 结果是否写回寄存器堆：由 `reg_write` + `wb_src` 门控（WB 阶段消费）
   - 跳转目标是否取代 `pc+4`：由 `branch_taken` 在 PC 更新处门控（flow_ctrl 消费）
   - 例：BEQ 的判断（`rs1==rs2`）与目标加法（`pc+imm`）同时并行计算；比较结果为 0 时目标加法结果虽已算出但被 `branch_taken=0` 丢弃——计算无害，门控在 PC 寄存器处生效
4. **操作数选择信号化**：`alu_a`/`alu_b` 由 decode 生成的选择信号直接选出，不再依赖固定配对模块（op_pair 废弃）。
5. **分支并行**：分支目标加法器、JALR 单元与 ALU 并行工作，不增加关键路径级数。
6. **分支判定零解码**：`i_branch_sel` 直接编码分支类型，EX 不进行任何二次解码。
7. **控制透传**：MEM/WB 控制信号原样穿过 EX Stage。
8. **零逻辑 stalling/flushing**：EX Stage 本身不产生 stall/flush，由 `hazard_ctrl.v` / `flow_ctrl.v` 控制流水线寄存器实现。

## 关键路径分析

**分支路径（决定时钟周期）**：

```
id_ex → alu_a/alu_b MUX → alu_cmp → branch_taken → flow_ctrl → pc_next → pc 建立时间
id_ex → JALR 单元 (rs1+imm → &mask) → branch_target → flow_ctrl → pc_next
```

两条分支路径与 ALU 数据路径并行，各含加法器 + 若干级选择逻辑，需在单周期内满足 PC 寄存器建立时间——**分支重定向路径是全局关键路径**（v1 曾误将 ALU→ex_mem 判为最长路径，实际它只需满足 ex_mem 建立时间，压力更小）。

**数据路径**：

```
id_ex → alu_a/alu_b MUX → ALU (加法/移位) → o_alu_result → ex_mem.i_alu_result
```

**分支惩罚**：EX 级判定分支意味着 taken 时需 flush IF/ID 两级（2 周期惩罚），由 flow_ctrl/hazard_ctrl 处理，EX 不感知。

## 与其他模块的交互

### 与 ID Stage 的接口

id_ex.v 全部输出 → executor.v 全部输入（数据通路值 + 控制总线）。v2 新增/变更的输入：`i_alu_src_a[1:0]`（扩宽）、`i_branch_sel[1:0]`（替代 `i_branch`）、`i_wb_src[1:0]`（替代 `i_mem_to_reg`）。

### 与 MEM Stage 的接口

| 来源 | 信号 | 目标 |
|------|------|------|
| executor.v | `o_alu_result`, `o_pc_plus4`, `o_rs2_data`, `o_rd_addr` | ex_mem.v |
| executor.v | `o_mem_*`, `o_wb_src`, `o_reg_write` | ex_mem.v |

`ex_mem.v` 需新增 `o_pc_plus4` 与 `o_wb_src` 的锁存/透传。

### 与 Pipeline Control 的接口

| 来源 | 信号 | 目标 |
|------|------|------|
| executor.v | `o_branch_taken` | flow_ctrl.v |
| executor.v | `o_branch_target` | flow_ctrl.v |

flow_ctrl 直接消费，**无需区分 JAL/JALR**（v2 已在 EX 内闭环）。

## 对现有信号设计的调整清单（供后续修订 decode / id_ex / 头文件）

按"先 EX 后其他"的顺序，EX 设计落地后需同步调整：

1. **decode.v**：
   - `o_alu_src_a` 由 1 bit 扩为 2 bit；LUI 置 `ALU_A_ZERO`（修复 v1 的 LUI rs1=x0 假设问题）
   - `o_branch`（1 bit）→ `o_branch_sel[1:0]`：BRANCH→`BRANCH_COND`、JAL→`BRANCH_JAL`、JALR→`BRANCH_JALR`、其余→`BRANCH_NONE`
   - `o_mem_to_reg`（1 bit）→ `o_wb_src[1:0]`：普通 ALU→`WB_SRC_ALU`、LOAD→`WB_SRC_MEM`、JAL/JALR→`WB_SRC_PC_PLUS4`
   - JAL/JALR 的 `alu_opcode` 建议置 `ALU_NOP`（结果不使用，写回 pc+4，目标由专门单元计算）
2. **id_ex.v**：控制总线位宽调整（`alu_src_a` +1、`branch_sel` +1、`wb_src` +1、`mem_to_reg` −1，净增约 2 bit），并透传 `i_pc`（已有）
3. **头文件**：
   - `alu_op_define.vh` 新增：`ALU_A_RS1/ALU_A_PC/ALU_A_ZERO`
   - `opcode_define.vh` 新增：`BRANCH_NONE/BRANCH_COND/BRANCH_JAL/BRANCH_JALR`
   - `const_define.vh` 新增：`WB_SRC_ALU/WB_SRC_MEM/WB_SRC_PC_PLUS4`、`PC_ALIGN_MASK 32'hFFFFFFFE`
4. **ex_mem.v / mem_wb.v / wb.v**（未来）：透传 `o_pc_plus4`、`o_wb_src`；wb 阶段按 `wb_src` 三选一写回
5. **if_id.v**：**无需改动**（pc+4 在 EX 级自算）。可选优化：IF 级透传 `pc_plus4` 可省一个加法器（约 32 LUT），若采用则 `i_pc` 输入可移除

## 未来扩展

- **M 扩展（乘除）**：新增 `alu_mul.v` / `alu_div.v` 子模块 + `alu.v` MUX 扩展；乘除为多周期，届时在 EX 插入 stall 或状态机。
- **Forwarding 旁路**：hazard_ctrl 检测 RAW 后，在操作数选择 MUX 前增加旁路 MUX（从 `ex_mem.o_alu_result` / `mem_wb.o_*` 取数）。
- **异常处理**：若支持 CSR/异常，executor 需增加异常相关输入与透传。
- **写回源扩展**：`wb_src[1:0]` 预留编码 2'b11，供未来 CSR 读值等新写回源使用。
