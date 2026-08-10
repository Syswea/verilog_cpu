# WB Stage 设计描述

## 概述

WB（Write-Back）Stage 是 5 级流水线的第五级（末级），负责**将最终结果写回寄存器堆**：按 `wb_src` 三选一选择写回源（ALU 结果 / 内存读数据 / pc+4 链接地址），并在 WB 周期末沿写入 `regfile.v`。本级是纯数据通路，控制信号全部来自 ID Stage（decode 生成）透传，WB 不产生任何控制信号。

本级包含两个模块：

- `mem_wb.v` — MEM/WB 流水线寄存器（锁存写回所需的数据与控制）
- `wb.v` — 写回选择器（纯组合，按 `wb_src` 三选一）

`regfile.v` 属于 Resources（全局共享资源），写口由 WB Stage 驱动。

## 模块组成

```
              ex_mem.v (MEM Stage)
                   │
        ┌──────────┼───────────────────────────┐
        │          │                           │
        ▼          ▼                           ▼
  ┌────────────────────────────────────────────────────┐
  │  mem_wb.v (MEM/WB 流水线寄存器)                      │
  │  alu_result  pc_plus4  read_data  rd_addr          │
  │  wb_src  reg_write                                  │
  └──────┬──────────┬──────────┬──────────┬────────────┘
         │          │          │          │
         ▼          ▼          ▼          │
  ┌─────────────────────────────────────┐ │
  │  wb.v (写回选择器，纯组合)             │ │
  │  o_rd_data = wb_src 三选一:          │ │
  │    WB_SRC_ALU → alu_result          │ │
  │    WB_SRC_MEM → read_data           │ │
  │    WB_SRC_PC_PLUS4 → pc_plus4       │ │
  └───────────────┬─────────────────────┘ │
                  │ o_rd_data             │ o_rd_addr, o_reg_write (透传)
                  ▼                       ▼
            ┌──────────────────────────────────┐
            │  regfile.v (Resources, 写口)       │
            │  i_rd_addr  i_rd_data  i_we       │
            └──────────────────────────────────┘
```

**数据流向要点**：

- **写回三源**：`alu_result`（算术/逻辑结果）、`read_data`（load 数据，来自 data_mem 组合读）、`pc_plus4`（JAL/JALR 链接地址）——由 `wb_src[1:0]` 在 wb.v 选择
- `read_data` 在 MEM 周期由 `data_mem` 组合读出，**MEM 末沿锁进 mem_wb**（不经过 ex_mem）
- `rd_addr` / `reg_write` 经 mem_wb → wb 原样透传至 regfile 写口
- **写回时机**：wb.v 输出在 WB 周期内稳定，WB 周期末沿写入 regfile（regfile 写口为时序逻辑）

---

## 1.1 mem_wb.v — MEM/WB 流水线寄存器

### 职责

在时钟沿锁存 WB 阶段所需的数据与控制：ALU 结果、链接地址、load 读数据、目标寄存器、写回源、写使能。响应 `stall` / `flush`。**不锁存 MEM 阶段已用完的信号**（`mem_read/write/width/sext` 在 MEM 消费后即可丢弃）。

### 端口定义

**输入**

| 信号 | 宽度 | 来源 | 说明 |
|------|------|------|------|
| `i_clk` | 1 | 全局时钟 | 系统时钟 |
| `i_rst_n` | 1 | 全局复位 | 异步复位，低有效 |
| `i_flush` | 1 | flow_ctrl.v | 流水线冲刷，高有效 |
| `i_stall` | 1 | hazard_ctrl.v | 流水线暂停，高有效 |
| `i_alu_result` | 32 | ex_mem.v (o_alu_result) | ALU 结果 |
| `i_pc_plus4` | 32 | ex_mem.v (o_pc_plus4) | 链接地址（JAL/JALR） |
| `i_read_data` | 32 | data_mem.v (o_read_data) | load 读数据 |
| `i_rd_addr` | 5 | ex_mem.v (o_rd_addr) | 目标寄存器地址 |
| `i_wb_src` | 2 | ex_mem.v (o_wb_src) | 写回源选择 |
| `i_reg_write` | 1 | ex_mem.v (o_reg_write) | 寄存器写使能 |

**输出**

| 信号 | 宽度 | 去向 | 说明 |
|------|------|------|------|
| `o_alu_result` | 32 | wb.v | ALU 结果 |
| `o_pc_plus4` | 32 | wb.v | 链接地址 |
| `o_read_data` | 32 | wb.v | load 读数据 |
| `o_rd_addr` | 5 | wb.v → regfile.v (i_rd_addr) | 目标寄存器地址 |
| `o_wb_src` | 2 | wb.v | 写回源选择 |
| `o_reg_write` | 1 | wb.v → regfile.v (i_we) | 寄存器写使能 |

**锁存位宽**：数据 32+32+32+5 = 101，控制 2+1 = 3，合计 **104 位**。

### 行为（与其他流水线寄存器一致）

```
always_ff @(posedge i_clk or negedge i_rst_n):
  if (!i_rst_n):              全部输出 ← 安全默认值
  else if (i_flush):          控制清零（reg_write=0），数据 ← 0
  else if (i_stall):          保持当前值
  else:                       锁存所有输入
```

复位 / flush 默认值：`alu_result/pc_plus4/read_data ← XLEN_ZERO`，`rd_addr ← REG_X0_ADDR`，`wb_src ← WB_SRC_ALU`，`reg_write ← 0`（安全 NOP，不写寄存器）。

> **flush/stall 的必要性**：即使 WB 是末级，也必须接 `stall`（load-use 冻结时整条流水线停，WB 数据不得继续推进导致写错寄存器）与 `flush`（分支冲刷时清除可能误写的指令），与其它流水线寄存器保持一致的优先级链。

---

## 1.2 wb.v — 写回选择器

### 职责

纯组合逻辑，按 `wb_src[1:0]` 从三个写回源中选择一个，驱动 regfile 写口。不包含任何寄存器。

### 端口定义

| 信号 | 方向 | 宽度 | 来源 / 去向 | 说明 |
|------|------|------|------------|------|
| `i_alu_result` | input | 32 | mem_wb.v (o_alu_result) | ALU 结果 |
| `i_read_data` | input | 32 | mem_wb.v (o_read_data) | load 读数据 |
| `i_pc_plus4` | input | 32 | mem_wb.v (o_pc_plus4) | 链接地址 |
| `i_wb_src` | input | 2 | mem_wb.v (o_wb_src) | 写回源选择 |
| `i_rd_addr` | input | 5 | mem_wb.v (o_rd_addr) | 目标寄存器地址（透传） |
| `i_reg_write` | input | 1 | mem_wb.v (o_reg_write) | 寄存器写使能（透传） |
| `o_rd_data` | output | 32 | regfile.v (i_rd_data) | 写回数据 |
| `o_rd_addr` | output | 5 | regfile.v (i_rd_addr) | 目标寄存器地址 |
| `o_reg_write` | output | 1 | regfile.v (i_we) | 寄存器写使能 |

### 选择逻辑

| `wb_src` | 写回源 | 典型指令 |
|:---:|---|---|
| `WB_SRC_ALU` (00) | `i_alu_result` | R-type、ADDI、LUI、AUIPC、SLTI 等 |
| `WB_SRC_MEM` (01) | `i_read_data` | LB/LH/LW/LBU/LHU |
| `WB_SRC_PC_PLUS4` (10) | `i_pc_plus4` | JAL、JALR |
| (11) 保留 | `i_alu_result`（安全默认） | 未来 CSR 读值等 |

```verilog
assign o_rd_data = (i_wb_src == `WB_SRC_MEM)      ? i_read_data :
                   (i_wb_src == `WB_SRC_PC_PLUS4) ? i_pc_plus4  :
                                                    i_alu_result;  // 含保留编码 11

assign o_rd_addr    = i_rd_addr;    // 纯透传
assign o_reg_write  = i_reg_write;  // 纯透传
```

### 与 regfile 的接口时序

```
WB 周期内:   wb.v 组合选出 o_rd_data（mem_wb 输出稳定后即有效）
WB 周期末沿: regfile 在 posedge clk 写入 rf[i_rd_addr] <= o_rd_data（i_we=1 且 rd≠x0）
```

regfile 写口自带 x0 忽略逻辑（`regfile.v` 已实现），wb.v 无需额外处理。

> **与 pc 更新的关系（双写解耦）**：JAL/JALR 的 `pc` 与 `rd` 是两个独立写目标，不同拍生效——`pc` 由控制面（flow_ctrl → pc_next → pc.v）在 EX 判定当拍末沿重定向，**与 WB 无关**；`rd`（pc+4）才由本阶段（wb_src=WB_SRC_PC_PLUS4）在 WB 末沿写入 regfile。详见 design.md「Write-Back and PC Update are Decoupled」。

---

## 设计原则

1. **纯数据通路**：WB Stage 无控制信号生成，`wb_src` / `reg_write` 全部来自 decode 透传。
2. **写回源 ID 阶段决定**：`wb_src` 由 decode 一次性生成（LOAD→MEM、JAL/JALR→PC_PLUS4、其余→ALU），WB 只做选择不译码。
3. **单一选择器**：wb.v 三选一，保留编码走安全默认（ALU 结果）。
4. **最小锁存**：mem_wb 只锁存 WB 需要的数据（MEM 阶段的 mem_* 控制已消费，不锁存），位宽最小（104 位）。
5. **stall/flush 一致**：mem_wb 与其它流水线寄存器同优先级链，保证 load-use 冻结与分支冲刷时写回不越位。

## 关键路径分析

**写回路径**：

```
mem_wb（寄存器输出）→ wb.v 三选一 MUX → regfile 写口 → regfile 时序写（WB 末沿）
```

- wb.v 是 2 级 MUX（组合），延迟 < 1 ns，在 50-100 MHz 下充裕
- regfile 写口为时序逻辑，写建立时间由 MUX 延迟 + regfile 内部逻辑决定，压力小
- 关键路径不在 WB——WB 是末级，无下游组合逻辑

## 与其他模块的交互

### 与 MEM Stage

| 来源 | 信号 | 目标 |
|------|------|------|
| ex_mem.v | `o_alu_result`, `o_pc_plus4`, `o_rd_addr`, `o_wb_src`, `o_reg_write` | mem_wb.v |
| data_mem.v | `o_read_data` | mem_wb.v |

### 与 Resources

| 来源 | 信号 | 目标 |
|------|------|------|
| wb.v | `o_rd_data`, `o_rd_addr`, `o_reg_write` | regfile.v (i_rd_data/i_rd_addr/i_we) |

### 与 Pipeline Control

| 来源 | 信号 | 目标 |
|------|------|------|
| hazard_ctrl.v | `stall` | mem_wb.v |
| flow_ctrl.v | `flush` | mem_wb.v |

## 未来扩展

- **Forwarding**：`mem_wb.o_alu_result` / `o_read_data` / `o_rd_addr` / `o_reg_write` 是 forwarding 的源（旁路回 EX 操作数 MUX），hazard_ctrl 实现时直接消费
- **CSR 写回**：`wb_src` 保留编码 11 供 CSR 读值写回
- **异常写回抑制**：未来异常（页故障/非对齐）发生时，WB 需抑制写回（与 `reg_write` 协同清零）——预留异常信号透传至 mem_wb/wb 的规划
- **多写口**：若引入转发/双发射，regfile 写口需扩展（当前单写口）

## 常量需求

无新增（`WB_SRC_*` 已在 const_define.vh 定义）。
