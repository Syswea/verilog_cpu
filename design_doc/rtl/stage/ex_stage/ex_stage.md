# EX Stage 设计描述

## 概述

EX（Execute）Stage 是 5 级流水线的第三级，负责执行所有算术/逻辑/比较运算以及分支跳转判定。**本级是纯数据通路，不含任何控制信号生成逻辑**——所有控制信号已在 ID Stage 的 `decode.v` 中一次性生成，经 `id_ex.v` 透传至本级直接消费。

本级仅包含一个模块：

- `executor.v` — 纯数据通路执行单元（ALU + Branch Unit + 控制透传）

## 模块组成

```
                      id_ex.v (Pipeline Register)
                          │
           ┌──────────────┼──────────────┐
           │ pc, rs1, rs2, imm           │ (控制总线)
           ▼              ▼              ▼
┌──────────────────────────────────────────────────────────┐
│  executor.v                                              │
│                                                          │
│  ┌────────────────────┐  ┌────────────────────┐          │
│  │ op_pair_rs1_rs2.v  │  │ op_pair_pc_imm.v   │          │
│  │  o_a = rs1_data    │  │  o_a = pc          │          │
│  │  o_b = rs2_data    │  │  o_b = imm         │          │
│  └────────┬───────────┘  └────────┬───────────┘          │
│           │ (rs1, rs2)            │ (pc, imm)             │
│  ┌────────────────────┐           │                       │
│  │ op_pair_rs1_imm.v  │           │                       │
│  │  o_a = rs1_data    │           │                       │
│  │  o_b = imm         │           │                       │
│  └────────┬───────────┘           │                       │
│           │ (rs1, imm)            │                       │
│           │         ┌─────────────┘                       │
│           │         │                                     │
│  ┌────────┴────┬────┴───────┬────────────┐               │
│  │  alu.v      │            │            │               │
│  │  ┌──────────┴──┐  ┌──────┴─────┐  ┌──┴────────────┐  │
│  │  │ alu_arith.v │  │ alu_bit.v  │  │  alu_cmp.v    │  │
│  │  │  ADD / SUB  │  │ SLL/SRL/   │  │ EQ/NE/        │  │
│  │  │             │  │ SRA/XOR/   │  │ SLT/SLTU/     │  │
│  │  │ o_branch_   │  │ OR/AND     │  │ GE/GEU        │  │
│  │  │ target      │  └──────┬─────┘  └──────┬────────┘  │
│  │  │ (pc+imm)    │         │                │           │
│  │  └──────┬──────┘         │                │           │
│  │         └────────┬───────┴────────┬───────┘           │
│  │                  │ alu.v (MUX)    │                   │
│  │               alu_result          │                   │
│  └──────────────────┬────────────────┘                   │
│                     │                                    │
│   branch_target ────┤                                    │
│         ┌───────────┴──────────┐                         │
│         │    Branch Unit       │                         │
│         │   (condition eval)   │                         │
│         └──────────┬───────────┘                         │
│                    │ branch_taken                        │
└────────────────────┼──────────────┬──────────────────────┘
                     │              │
                     ▼              ▼
                flow_control.v  ex_mem.v
             (branch_taken,   (ALU result,
              branch_target)   store data,
                               透传控制)
```

**三个操作数对模块（`op_pair_*.v`）始终并行运行**：`op_pair_rs1_rs2.v`、`op_pair_rs1_imm.v`、`op_pair_pc_imm.v` 各自固定产出一种操作数组合，无需控制信号。`alu.v` 根据 `opcode` 为各子模块选择对应的操作数对。分支时，`alu_cmp` 使用 `(rs1, rs2)` 做比较，`alu_arith` 的 `o_branch_target` 使用 `(pc, imm)` 做加法——两者同时产出，不存在冲突。



2. **ALU 计算**：执行算术、逻辑、移位、比较运算（16 种操作码）
3. **分支判定**：根据 `alu_opcode` 判定分支是否 taken，计算跳转目标地址
4. **控制透传**：将 MEM/WB 控制信号原样传递给 `ex_mem.v`

**不包含**：寄存器、控制译码、状态机。

---

#### 1.1 端口定义

**输入**

| 信号 | 宽度 | 来源 | 说明 |
|------|------|------|------|
| `i_pc` | 32 | id_ex.v (o_pc) | 当前指令 PC |
| `i_rs1_data` | 32 | id_ex.v (o_rs1_data) | rs1 读出值 |
| `i_rs2_data` | 32 | id_ex.v (o_rs2_data) | rs2 读出值 / Store 数据 |
| `i_imm` | 32 | id_ex.v (o_imm) | 32 位符号扩展立即数 |
| `i_rd_addr` | 5 | id_ex.v (o_rd_addr) | 目标寄存器地址 |
| `i_alu_opcode` | 4 | id_ex.v (o_alu_opcode) | ALU 运算类型（扁平编码） |
| `i_branch` | 1 | id_ex.v (o_branch) | 是否为分支/跳转指令 |
| `i_mem_read` | 1 | id_ex.v (o_mem_read) | 读 Memory（透传） |
| `i_mem_write` | 1 | id_ex.v (o_mem_write) | 写 Memory（透传） |
| `i_mem_width` | 2 | id_ex.v (o_mem_width) | 访存宽度（透传） |
| `i_mem_sext` | 1 | id_ex.v (o_mem_sext) | 符号扩展（透传） |
| `i_mem_to_reg` | 1 | id_ex.v (o_mem_to_reg) | 写回源选择（透传） |
| `i_reg_write` | 1 | id_ex.v (o_reg_write) | 寄存器写使能（透传） |

**输出——数据通路（→ ex_mem.v）**

| 信号 | 宽度 | 去向 | 说明 |
|------|------|------|------|
| `o_alu_result` | 32 | ex_mem.v | ALU 计算结果 |
| `o_rs2_data` | 32 | ex_mem.v | Store 数据（透传，供 MEM Stage 写入内存） |
| `o_rd_addr` | 5 | ex_mem.v | 目标寄存器地址（透传） |

**输出——控制透传（→ ex_mem.v）**

| 信号 | 宽度 | 说明 |
|------|------|------|
| `o_mem_read` | 1 | 读 Memory（透传） |
| `o_mem_write` | 1 | 写 Memory（透传） |
| `o_mem_width` | 2 | 访存宽度（透传） |
| `o_mem_sext` | 1 | 符号扩展（透传） |
| `o_mem_to_reg` | 1 | 写回源选择（透传） |
| `o_reg_write` | 1 | 寄存器写使能（透传） |

**输出——分支信息（→ flow_control.v）**

| 信号 | 宽度 | 去向 | 说明 |
|------|------|------|------|
| `o_branch_taken` | 1 | flow_control.v | 分支/跳转是否 taken |
| `o_branch_target` | 32 | flow_control.v | 跳转目标地址（用于 PC 重定向） |

---

#### 1.2 内部结构

```
executor.v 内部:

  // ---- 操作数对模块 (并行, 见 §1.3) ----
  wire [31:0] pair_rs1_rs2_a, pair_rs1_rs2_b;  // (rs1, rs2)
  wire [31:0] pair_rs1_imm_a, pair_rs1_imm_b;  // (rs1, imm)
  wire [31:0] pair_pc_imm_a,  pair_pc_imm_b;   // (pc,  imm)

  op_pair_rs1_rs2 u_op_rs1_rs2 (.i_rs1_data, .i_rs2_data,
      .o_a(pair_rs1_rs2_a), .o_b(pair_rs1_rs2_b));
  op_pair_rs1_imm u_op_rs1_imm (.i_rs1_data, .i_imm,
      .o_a(pair_rs1_imm_a), .o_b(pair_rs1_imm_b));
  op_pair_pc_imm  u_op_pc_imm  (.i_pc, .i_imm,
      .o_a(pair_pc_imm_a),  .o_b(pair_pc_imm_b));

  // ---- ALU (4 子模块, 见 §1.4) ----
  alu u_alu (
      .pair_rs1_rs2_a, .pair_rs1_rs2_b,
      .pair_rs1_imm_a, .pair_rs1_imm_b,
      .pair_pc_imm_a,  .pair_pc_imm_b,
      .i_opcode (i_alu_opcode),
      .o_result (o_alu_result),
      .o_branch_target (branch_target)
  );

  // ---- 分支判定 ----
  Branch Unit:
    根据 i_alu_opcode 和 ALU 结果判定 o_branch_taken
```

---

#### 1.3 操作数对模块（3 个 *.v）

RV32I 指令使用的源操作数仅有三种组合。三个独立 `.v` 文件各管一对，**始终并行产出**，无控制信号：

| 模块 | 文件 | `o_a` | `o_b` | 典型指令 |
|------|------|-------|-------|----------|
| 寄存器对 | `op_pair_rs1_rs2.v` | `i_rs1_data` | `i_rs2_data` | R-type, BRANCH (比较) |
| 立即数对 | `op_pair_rs1_imm.v` | `i_rs1_data` | `i_imm` | I-type, LOAD, STORE, JALR |
| PC 立即数对 | `op_pair_pc_imm.v` | `i_pc` | `i_imm` | AUIPC, JAL, BRANCH (目标) |

每个模块为纯 wire 连接（组合逻辑），接口统一：

```verilog
module op_pair_xxx (
    input  wire [31:0] i_rs1_data,  // (rs1_rs2 和 rs1_imm 使用)
    input  wire [31:0] i_rs2_data,  // (仅 rs1_rs2 使用)
    input  wire [31:0] i_pc,        // (仅 pc_imm 使用)
    input  wire [31:0] i_imm,       // (rs1_imm 和 pc_imm 使用)
    output wire [31:0] o_a,
    output wire [31:0] o_b
);
```

LUI 指令（需要 \((0, imm)\) ）由 `op_pair_rs1_imm` 自然支持：decode 将 `rs1_addr` 设为 x0，regfile 读出 0，即 `o_a = 0`。

三个模块的输出全部连入 `alu.v`，由 `alu.v` 根据 `opcode` 为各子模块 (`alu_arith`/`alu_bit`/`alu_cmp`) 选择正确的操作数对。

#### 1.4 ALU（4 模块拆分）

ALU 按运算类别拆分为 4 个独立 `.v` 文件，由一个顶层模块 `alu.v` 实例化并选择输出：

```
                    alu.v (顶层)
                   /     |      \
                  /      |       \
        alu_arith.v  alu_bit.v  alu_cmp.v
         (加减)     (移位/逻辑)   (比较)
```

**模块清单**：

| 文件 | 职责 | 覆盖操作码 |
|------|------|------------|
| `alu_arith.v` | 整型算术运算 | `ALU_ADD` (0), `ALU_SUB` (1) |
| `alu_bit.v` | 位运算 + 移位 | `ALU_SLL` (2), `ALU_SRL` (6), `ALU_SRA` (7), `ALU_XOR` (5), `ALU_OR` (8), `ALU_AND` (9) |
| `alu_cmp.v` | 比较运算（布尔输出） | `ALU_SLT` (3), `ALU_SLTU` (4), `ALU_EQ` (10), `ALU_NE` (11), `ALU_GE` (12), `ALU_GEU` (13) |
| `alu.v` | 顶层选择器 | 根据 `opcode` 选择子模块输出；`ALU_NOP` (15) / 保留 (14) 输出 `32'h0` |

四个模块均为**纯组合逻辑**，无寄存器。

---

##### 1.4.1 alu_arith.v — 整型算术单元

**接口**：
```verilog
module alu_arith (
    input  wire [31:0] i_a,
    input  wire [31:0] i_pc,
    input  wire [31:0] i_imm,
    input  wire [31:0] i_b,
    input  wire [ 3:0] i_opcode,
    output wire [31:0] o_result
);
```

**运算**：
| 条件 | `o_result` |
|------|------------|
| `i_opcode == ALU_ADD` | `i_a + i_b` |
| `i_opcode == ALU_SUB` | `i_a - i_b` |
| 其他 | `32'h0`（无效操作码，安全输出） |

**额外输出**：`o_branch_target = i_pc + i_imm`（始终计算，不受 i_opcode 影响）。供 Branch Unit 获取跳转目标地址。

---

##### 1.4.2 alu_bit.v — 位运算 + 移位单元

**接口**：同上 `(i_a, i_b, i_opcode, o_result)`

**运算**：
| 条件 | `o_result` |
|------|------------|
| `i_opcode == ALU_SLL` | `i_a << i_b[4:0]` |
| `i_opcode == ALU_SRL` | `i_a >> i_b[4:0]` |
| `i_opcode == ALU_SRA` | `$signed(i_a) >>> i_b[4:0]` |
| `i_opcode == ALU_XOR` | `i_a ^ i_b` |
| `i_opcode == ALU_OR` | `i_a \| i_b` |
| `i_opcode == ALU_AND` | `i_a & i_b` |
| 其他 | `32'h0` |

移位量统一截取 `i_b[4:0]`（RV32I 规范）。

---

##### 1.4.3 alu_cmp.v — 比较单元

**接口**：同上 `(i_a, i_b, i_opcode, o_result)`

**运算**：所有比较输出布尔值（0 或 1），供 Branch Unit 直接用作 `branch_taken`。

| 条件 | `o_result` |
|------|------------|
| `i_opcode == ALU_SLT` | `$signed(i_a) < $signed(i_b) ? 32'd1 : 32'd0` |
| `i_opcode == ALU_SLTU` | `i_a < i_b ? 32'd1 : 32'd0` |
| `i_opcode == ALU_EQ` | `(i_a == i_b) ? 32'd1 : 32'd0` |
| `i_opcode == ALU_NE` | `(i_a != i_b) ? 32'd1 : 32'd0` |
| `i_opcode == ALU_GE` | `$signed(i_a) >= $signed(i_b) ? 32'd1 : 32'd0` |
| `i_opcode == ALU_GEU` | `i_a >= i_b ? 32'd1 : 32'd0` |
| 其他 | `32'h0` |

---

##### 1.4.4 alu.v — 顶层 ALU 选择器

**职责**：实例化上述三个子模块，根据 `i_opcode` 选择正确的结果输出。所有子模块并联运行，由组合 MUX 选出最终结果。

**接口**：
```verilog
module alu (
    input  wire [31:0] i_a,
    input  wire [31:0] i_b,
    input  wire [ 3:0] i_opcode,
    output wire [31:0] o_result
);
```

**内部连接**：
```
  arith_result ← alu_arith(i_a, i_b, i_opcode)
  bit_result   ← alu_bit  (i_a, i_b, i_opcode)
  cmp_result   ← alu_cmp  (i_a, i_b, i_opcode)
  o_result = (opcode ∈ {ALU_ADD, ALU_SUB})         ? arith_result :
             (opcode ∈ {SLL,SRL,SRA,XOR,OR,AND})    ? bit_result   :
             (opcode ∈ {SLT,SLTU,EQ,NE,GE,GEU})     ? cmp_result   :
                                                      32'h0;
```

**选择逻辑**：纯组合 `assign` 或 `always_comb`，由 `i_opcode` 的高位或范围译码驱动 MUX。

**默认输出**：`ALU_NOP` (15) 或保留码 (14) → `32'h0`。

**设计优势**：
- 各计算单元独立，修改一种运算不影响其他。
- 便于未来扩展（如 M 扩展乘法器只需新增模块并调整 alu.v 的 MUX）。
- 子模块接口统一（`i_a, i_b, i_opcode → o_result`），替换/复用方便。


**输入**：
- `i_branch` — 标识是否为分支/跳转指令
- `i_alu_opcode` — ALU 操作码（区分比较类型）
- `o_alu_result[0]` — ALU 比较结果（对于 EQ/NE/SLT/GE 等，输出为 0 或 1 的布尔值）
- `alu_a`, `alu_b` — 供 JAL/JALR 直接判定 taken

**输出**：
- `o_branch_taken` — 是否跳转
- `o_branch_target` — 跳转目标地址（`i_pc + i_imm`，由 `alu_arith.v` 的 `o_branch_target` 端口提供）

**判定规则**：

| 指令类型 | `i_branch` | 判定方式 |
|----------|:---:|------|
| 非分支/跳转 | 0 | `o_branch_taken = 0` |
| BRANCH (BEQ/BNE/…) | 1 | `o_branch_taken = o_alu_result[0]`（ALU 比较结果） |
| JAL | 1 | `o_branch_taken = 1`（无条件跳转） |
| JALR | 1 | `o_branch_taken = 1`（无条件跳转） |
| NOP (flush bubble) | 0 | `o_branch_taken = 0` |

**区分 JAL/JALR 与 BRANCH**：当前 `i_branch` 仅标记"是否为分支/跳转"，无法区分条件分支和无条件跳转。但可以结合 `i_alu_opcode` 判断：
- 若 `i_alu_opcode` 为 `ALU_EQ/NE/SLT/SLTU/GE/GEU` → 条件分支，`o_branch_taken` 由 ALU 结果决定
- 若 `i_alu_opcode` 为 `ALU_ADD` 且 `i_branch=1` → JAL/JALR（ALU 计算跳转目标，无条件跳转）

**简化实现**：Branch Unit 同时检查 `i_branch` 和 `i_alu_opcode`：

```verilog
// 分支目标（始终计算）
assign o_branch_target = alu_arith_branch_target;  // 来自 alu_arith.o_branch_target

// 分支判定
always_comb begin
    if (!i_branch)
        o_branch_taken = 1'b0;
    else if (i_alu_opcode == `ALU_ADD)   // JAL / JALR: unconditional
        o_branch_taken = 1'b1;
    else                                 // BRANCH: ALU comparison result
        o_branch_taken = o_alu_result[0];
end
```

> 注：JALR 的跳转目标实际为 `rs1 + imm`，但 ALU 已计算此值（`alu_a = rs1, alu_b = imm`）。flow_control.v 需要从 `o_alu_result` 而非 `o_branch_target` 获取 JALR 的目标地址。当前分支目标 `pc + imm` 对 JAL 正确，JALR 由 flow_control 根据 opcode 判断取 `o_alu_result` 而非 `o_branch_target`。

---

#### 1.6 控制信号透传

以下信号不做任何处理，直接从输入连接到同名输出，传递至 `ex_mem.v`：

| 信号 | 说明 |
|------|------|
| `o_rs2_data` | Store 数据原样透传 |
| `o_rd_addr` | 目标寄存器地址原样透传 |
| `o_mem_read`, `o_mem_write` | 访存使能 |
| `o_mem_width`, `o_mem_sext` | 访存参数 |
| `o_mem_to_reg`, `o_reg_write` | 写回控制 |

这是纯 wire 连接，不经过任何逻辑：

```verilog
assign o_rs2_data   = i_rs2_data;
assign o_rd_addr    = i_rd_addr;
assign o_mem_read   = i_mem_read;
assign o_mem_write  = i_mem_write;
assign o_mem_width  = i_mem_width;
assign o_mem_sext   = i_mem_sext;
assign o_mem_to_reg = i_mem_to_reg;
assign o_reg_write  = i_reg_write;
```

## 设计原则

1. **纯数据通路**：`executor.v` 无状态、无控制信号生成。所有控制来自 `id_ex.v`，本级仅消费。
2. **单一 ALU**：所有算术、逻辑、移位、比较共用一个 ALU，由 `alu_opcode` 扁平编码驱动。
3. **分支并行**：分支目标加法器与 ALU 并行工作，不增加关键路径延迟。
4. **控制透传**：MEM/WB 控制信号原样穿过 EX Stage，不做任何修改。
5. **零逻辑 stalling/flushing**：EX Stage 本身不产生 stall/flush——这些由 `hazard_control.v` 和 `flow_control.v` 通过控制 `id_ex.v` / `ex_mem.v` 的流水线寄存器来实现。

## 关键路径分析

**最长组合路径**：

```
id_ex.o_rs1_data → Operand MUX → ALU (加法/移位) → o_alu_result → ex_mem.i_alu_result
```

- Operand MUX：1 级选择器（~0.2 ns）
- ALU 加法：32-bit 进位链（~5 ns in XC7A35T -2 speed grade）
- 总计：< 6 ns，对应 > 166 MHz

**分支路径**（时序更短）：

```
alu_arith: pc + imm → o_branch_target → Branch Unit
id_ex.o_rs1/o_rs2  → ALU 比较 → branch_taken → flow_control
```

两条路径并行，总延迟约等于 ALU 比较延迟（~3 ns）。

## 与其他模块的交互

### 与 ID Stage 的接口

| 来源 | 信号 | 目标 | 说明 |
|------|------|------|------|
| id_ex.v | 全部输出 | executor.v (全部输入) | 数据通路值 + 控制总线 |

详见 `id_ex.v` 的端口定义。

### 与 MEM Stage 的接口

| 来源 | 信号 | 目标 | 说明 |
|------|------|------|------|
| executor.v | `o_alu_result`, `o_rs2_data`, `o_rd_addr` | ex_mem.v | 计算结果、Store 数据、目标寄存器 |
| executor.v | `o_mem_*`, `o_reg_write` 等 | ex_mem.v | 控制信号透传 |

`ex_mem.v` 是 EX/MEM 流水线寄存器，负责锁存以上信号并传递给 MEM Stage。

### 与 Pipeline Control 的接口

| 来源 | 信号 | 目标 | 说明 |
|------|------|------|------|
| executor.v | `o_branch_taken` | flow_control.v | 分支是否 taken |
| executor.v | `o_branch_target` | flow_control.v | 跳转目标地址（来自 `alu_arith.o_branch_target`） |

对于 JALR，flow_control 需额外获取 `o_alu_result` 作为跳转目标（JALR 目标 = rs1 + imm，由 ALU 计算）。该信号通过 `ex_mem.v` 或直接从 executor 输出获取。

## 未来扩展

- **M 扩展（乘除）**：在 ALU 中增加 `ALU_MUL`, `ALU_MULH`, `ALU_DIV`, `ALU_REM` 等操作码。
  - 乘除法为多周期操作，需在 executor 中增加状态机或在 EX Stage 插入 stall。
  - 若引入多周期，`ex_mem.v` 需增加 `stall` 控制以保持 EX 输出有效。
- **Forwarding 旁路**：hazard_control 检测 RAW 冲突后，在 executor 的操作数 MUX 前增加 forwarding MUX，从 `ex_mem.o_alu_result` 或 `mem_wb.o_*` 旁路数据。
- **JALR 目标地址**：当前分支目标统一为 `pc + imm`，对 JALR 不适用（JALR 目标 = rs1 + imm）。flow_control 需区分 JAL 和 JALR，对后者取 ALU 结果作为跳转目标。
- **异常处理**：若后续支持 CSR 和异常，executor 需增加 `i_exception` 输入（来自 decode）和异常信息透传。
