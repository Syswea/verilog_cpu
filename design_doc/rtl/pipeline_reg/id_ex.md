# id_ex.v 实现描述

## 概述

`id_ex.v` 是 ID/EX 流水线寄存器，位于 ID Stage 与 EX Stage 之间。它在时钟上升沿锁存 `decode.v` 产出的完整控制总线、`regfile.v` 读出的寄存器值、以及来自 `if_id.v` 的 PC，并统一传递给 EX Stage。

该模块响应流水线控制信号（stall/flush），按优先级控制寄存器行为：flush > stall > 正常更新。
**不存储原始 funct3/funct7**——ID 阶段已完成全部解码，只锁存解码后的扁平化控制信号。

## 端口定义

### 输入

| 端口名 | 方向 | 宽度 | 来源 | 说明 |
|--------|------|------|------|------|
| **系统 / 控制** |||||
| `i_clk` | input | 1 | 全局时钟 | 系统时钟 |
| `i_rst_n` | input | 1 | 全局复位 | 异步复位，低有效 |
| `i_flush` | input | 1 | `flow_ctrl.v` | 流水线冲刷，高有效 |
| `i_stall` | input | 1 | `hazard_ctrl.v` | 流水线暂停，高有效 |
| **数据通路** |||||
| `i_pc` | input | 32 | `if_id.v` (o_pc) | 当前指令 PC |
| `i_rs1_data` | input | 32 | `regfile.v` (o_rs1_data) | rs1 读出值 |
| `i_rs2_data` | input | 32 | `regfile.v` (o_rs2_data) | rs2 读出值 |
| `i_imm` | input | 32 | `decode.v` (o_imm) | 32 位符号扩展立即数 |
| `i_rd_addr` | input | 5 | `decode.v` (o_rd_addr) | 目标寄存器地址 |
| **控制信号束** |||||
| `i_alu_opcode` | input | 4 | `decode.v` (o_alu_opcode) | ALU 运算类型（扁平编码） |
| `i_alu_src_a` | input | 2 | `decode.v` (o_alu_src_a) | ALU A 口选择（00=rs1, 01=pc, 10=0） |
| `i_alu_src` | input | 1 | `decode.v` (o_alu_src) | ALU B 口选择（0=rs2, 1=imm） |
| `i_branch_sel` | input | 2 | `decode.v` (o_branch_sel) | 分支类型（00=无, 01=条件分支, 10=JAL, 11=JALR） |
| `i_mem_read` | input | 1 | `decode.v` (o_mem_read) | 读数据存储器使能 |
| `i_mem_write` | input | 1 | `decode.v` (o_mem_write) | 写数据存储器使能 |
| `i_mem_width` | input | 2 | `decode.v` (o_mem_width) | 访存宽度（00=Byte, 01=Half, 10=Word） |
| `i_mem_sext` | input | 1 | `decode.v` (o_mem_sext) | Load 符号扩展（0=零扩展, 1=符号扩展） |
| `i_wb_src` | input | 2 | `decode.v` (o_wb_src) | 写回源选择（00=ALU, 01=内存, 10=pc+4） |
| `i_reg_write` | input | 1 | `decode.v` (o_reg_write) | 寄存器写使能 |

### 输出

| 端口名 | 方向 | 宽度 | 去向 | 说明 |
|--------|------|------|------|------|
| `o_pc` | output | 32 | `executor.v` | 当前指令 PC |
| `o_rs1_data` | output | 32 | `executor.v` (ALU A 口) | rs1 读出值 |
| `o_rs2_data` | output | 32 | `executor.v` (ALU B 口 / Store 数据) | rs2 读出值 |
| `o_imm` | output | 32 | `executor.v` | 32 位立即数 |
| `o_rd_addr` | output | 5 | `ex_mem.v` → `mem_wb.v` → `regfile.v` | 目标寄存器地址 |
| `o_alu_opcode` | output | 4 | `executor.v` (ALU) | ALU 运算类型 |
| `o_alu_src_a` | output | 2 | `executor.v` | ALU A 口选择 |
| `o_alu_src` | output | 1 | `executor.v` | ALU B 口选择 |
| `o_branch_sel` | output | 2 | `flow_ctrl.v` | 分支类型编码，用于冲刷判断 |
| `o_mem_read` | output | 1 | `ex_mem.v` → MEM Stage | 读 Memory |
| `o_mem_write` | output | 1 | `ex_mem.v` → MEM Stage | 写 Memory |
| `o_mem_width` | output | 2 | `ex_mem.v` → MEM Stage | 访存宽度 |
| `o_mem_sext` | output | 1 | `ex_mem.v` → MEM Stage | 符号扩展 |
| `o_wb_src` | output | 2 | `ex_mem.v` → WB Stage | 写回源选择 |
| `o_reg_write` | output | 1 | `ex_mem.v` → WB Stage | 寄存器写使能 |

## 功能描述

### 核心行为

`id_ex.v` 是一个带使能和同步清零的宽流水线寄存器组，共锁存 **150 位**数据与控制信号：

| 分组 | 位宽 | 内容 |
|------|------|------|
| 数据通路 | 32+32+32+32+5 = 133 | PC, rs1_data, rs2_data, imm, rd_addr |
| 控制信号 | 4+2+1+2+1+1+2+1+2+1 = 17 | alu_opcode, alu_src_a, alu_src, branch_sel, mem_*, wb_src, reg_write |
| **合计** | **150** | |

```
always_ff @(posedge i_clk or negedge i_rst_n):
  if (!i_rst_n):              全部输出 ← 安全默认值
  else if (i_flush):          控制总线清零, 数据通路 ← 0
  else if (i_stall):          保持当前值不变
  else:                       锁存所有输入信号
```

### 优先级

| 优先级 | 条件 | 行为 | 场景 |
|--------|------|------|------|
| 1（最高） | `i_rst_n == 0` | 全部清零 | 系统复位 |
| 2 | `i_flush == 1` | 控制线全部清零（reg_write=0, branch_sel=BRANCH_NONE, mem_read=0, mem_write=0），数据线清为 `` `XLEN_ZERO `` | 分支跳转冲刷、异常等 |
| 3 | `i_stall == 1` | 保持当前值 | load-use 冲突、资源等待 |
| 4（默认） | 以上均不满足 | 锁存输入 | 正常流水线推进 |

### flush 时的输出值

| 信号组 | flush 后值 | 说明 |
|--------|------------|------|
| 控制信号（全部） | 0 | `reg_write=0`: 不写寄存器；`mem_read=0, mem_write=0`: 不访存；`branch_sel=BRANCH_NONE`: 不触发分支冲刷；`wb_src=WB_SRC_ALU` |
| 数据通路值 | `` `XLEN_ZERO `` | PC、寄存器值、立即数归零 |
| `rd_addr` | `` `REG_X0_ADDR `` | 指向 x0（写回无影响） |

flush 后 `executor.v` 收到一个"全零 NOP"——ALU 执行 `ALU_NOP`（alu_opcode=4'hF），不产生任何副作用。

## 实现要点

1. **异步复位 + 同步 flush/stall**：`i_rst_n` 为异步复位，`i_flush` 和 `i_stall` 在时钟沿生效。
2. **无组合路径**：输出直接来自寄存器，不经过组合逻辑，保证时序收敛。
3. **控制总线打包**：17 条控制信号一起寄存，flush 时统一清零，避免部分清零导致的中间态。
4. **不存储 funct3/funct7**：`decode.v` 已完成全部解码——控制总线中不含原始指令字段，节省寄存器位宽。
5. **常量引用**：清零值使用 `` `XLEN_ZERO `` 和 `` `ALU_NOP `` 等宏，不在模块内 hardcode。
6. **stall 实现**：`i_stall` 有效时，寄存器保持当前输出值不变（自回环），实现与 `if_id.v` 一致。

## 接口时序

```
         clk
     ─────┴─────┴─────┴─────┴─────
     i_flush          ──1────0────────
     i_stall          ──0────0───1────
     i_alu_opcode     ──[0]──[B]──[C]──
     i_rs1_data       ──[A1]─[B1]─[C1]─
                       │     │    │
                       ▼     ▼    ▼     (寄存器更新)
     o_alu_opcode     ──[0]──[B]──[B]──  (flush 清零→正常→stall 保持 B)
     o_rs1_data       ──[0]──[B1]─[B1]─
```

- 第 2 周期：flush 生效，输出全部清零
- 第 3 周期：正常锁存，输出 = 输入
- 第 4 周期：stall 生效，输出保持上一周期的值

## 与架构的关系

- 属于 ID Stage 与 EX Stage 之间的边界寄存器，详见 [id_stage.md](../stage/id_stage/id_stage.md)
- **数据输入来源**：
  - `decode.v` → 立即数、控制信号束、目标寄存器地址
  - `regfile.v` → rs1/rs2 读出值
  - `if_id.v` → PC
- **控制信号来源**：`flow_ctrl.v`（flush）、`hazard_ctrl.v`（stall）
- **输出去向**：
  - `executor.v` — 数据通路值 + 控制信号（ALU、Branch Unit 直接消费）
  - `ex_mem.v` — 控制信号 + rd_addr（透传至 MEM/WB）
  - `flow_ctrl.v` — `o_branch_sel`（分支类型编码）
  - `hazard_ctrl.v` — `o_rd_addr`（RAW 冲突检测）

```
decode.v ──┬─ imm, rd_addr, 控制────────────────────┐
           │                                         │
regfile.v ─┼─ rs1_data, rs2_data ──┐                │
           │                       ▼                ▼
if_id.v  ──┴─ pc ────────────►  id_ex.v  ──────► executor.v
                                  │  │             ex_mem.v
                                  │  └── branch_sel ► flow_ctrl.v
                                  └──── rd_addr ──► hazard_ctrl.v
```

## 未来扩展

- **异常标记**：当 `i_flush` 因异常触发时，可增加 `i_exception` / `i_exception_cause` 等信号以传递异常信息至后续阶段。
- **M 扩展**：若 MUL/DIV 指令需要旁路 EX 阶段结果，不影响 `id_ex.v` 的接口（控制位宽已预留）。
- **Forwarding 元数据**：`o_rd_addr` 已传递，hazard_ctrl 可据此检测 RAW 冲突并生成 forwarding 控制信号。
