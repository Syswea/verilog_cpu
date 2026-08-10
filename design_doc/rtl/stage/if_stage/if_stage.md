# IF Stage 设计描述

## 概述

IF（Instruction Fetch）Stage 是 5 级流水线的第一级，负责在每个时钟周期从指令存储器取出一条指令，并通过 IF/ID 流水线寄存器传递给下一级（ID Stage）。

本级不包含 PC 寄存器本身（PC 属于全局 Resources），但包含驱动 PC 更新的组合逻辑（`pc_next.v`）、指令存储器（`inst_mem.v`）和流水线寄存器（`if_id.v`）。

## 模块组成

```
                   Pipeline Control
              ┌──────────────────────┐
              │ flow_ctrl.v       │
              │ hazard_ctrl.v     │
              └──┬──────────┬────────┘
                 │          │
 branch_valid    │          │ stall
 branch_target   │          │
                 ▼          │
  ┌──────────┐              │
  │pc_next.v ├──pc_next──► pc.v (resources)
  └──────────┘              │
                            │
  pc.v ──► inst_mem.v ──────┤
                            ▼
              ┌─────────────────────────┐
              │  if_id.v (stall/flush)  │────► ID Stage
              └─────────────────────────┘
```

数据流向：`pc.v` → `inst_mem.v` → `if_id.v` → ID Stage

## 模块详解

### 1. pc_next.v

**职责**：计算下一条 PC（纯组合逻辑）。

**输入**：

| 信号 | 来源 | 说明 |
|------|------|------|
| `pc` | pc.v | 当前 PC |
| `branch_target` | flow_ctrl.v | 分支/跳转目标地址 |
| `branch_valid` | flow_ctrl.v | 分支/跳转是否有效 |
| `stall` | hazard_ctrl.v | 流水线暂停信号 |

**输出**：

| 信号 | 目标 | 说明 |
|------|------|------|
| `pc_next` | pc.v | 下一周期的 PC 值 |

**行为**：

- 正常：`pc_next = pc + 4`
- 分支重定向：若 `branch_valid` 有效，`pc_next = branch_target`
- Stall：若 `stall` 有效，`pc_next = pc`（保持）
- 优先级：stall > branch_redirect > 正常递增

该模块不包含任何寄存器，仅为纯组合逻辑。PC 寄存器本身归属于 `resources/pc.v`。

### 2. inst_mem.v

**职责**：指令存储器接口，根据地址输出指令字。

**输入**：

| 信号 | 来源 | 说明 |
|------|------|------|
| `pc` | pc.v | 取指地址（32-bit） |

**输出**：

| 信号 | 目标 | 说明 |
|------|------|------|
| `instruction` | if_id.v | 32-bit 指令字 |

**实现说明**：

- 初期实现为组合读出的 ROM（使用 FPGA Block RAM）
- 未来扩展为 AXI / Wishbone 总线接口以支持外部存储器
- 对于 RV32I，指令固定为 32-bit 对齐，最低 2 bit 可忽略

### 3. if_id.v

**职责**：IF/ID 流水线寄存器，存储当前取出的指令并传递给 ID Stage。同时响应 stall 和 flush 控制信号。

**输入**：

| 信号 | 来源 | 说明 |
|------|------|------|
| `instruction` | inst_mem.v | 当前取出的指令 |
| `pc` | pc.v | 当前指令对应的 PC |
| `pc_plus4` | — | PC+4（用于后续阶段的地址计算） |
| `stall` | hazard_ctrl.v | 流水线暂停 |
| `flush` | flow_ctrl.v | 流水线冲刷 |

**输出**：

| 信号 | 目标 | 说明 |
|------|------|------|
| `instruction` | decode.v（ID Stage） | 指令字 |
| `pc` | ID Stage | 当前指令 PC |
| `pc_plus4` | ID Stage | PC+4 |

**行为**：

- 正常：寄存器在每个时钟上升沿锁存输入信号
- Stall 有效：保持当前值不变
- Flush 有效：输出清零（插入 NOP / bubble）
- 优先级：flush > stall > 正常更新

**存储内容**：

| 信号 | 宽度 | 说明 |
|------|------|------|
| `instruction` | 32 bit | 指令字 |
| `pc` | 32 bit | 当前指令地址 |
| `pc_plus4` | 32 bit | PC+4 |

`pc` 和 `pc_plus4` 为未来扩展预留（当前 RV32I 基本实现中 ID Stage 未必需要，但保留存储以保持架构一致性）。

## 与其他模块的交互

### 与控制通路的交互

| 来源 | 信号 | 目标 | 说明 |
|------|------|------|------|
| hazard_ctrl.v | `stall` | pc_next.v, if_id.v | 暂停取指和流水线推进 |
| flow_ctrl.v | `flush` | if_id.v | 冲刷无效指令 |
| flow_ctrl.v | `branch_valid`, `branch_target` | pc_next.v | 分支重定向 PC |

### 与 Resources 的交互

| 来源 | 信号 | 目标 | 说明 |
|------|------|------|------|
| pc_next.v | `pc_next` | pc.v | 更新 PC |
| pc.v | `pc` | inst_mem.v, if_id.v | 当前指令地址 |

### 与 ID Stage 的交互

| 来源 | 信号 | 目标 | 说明 |
|------|------|------|------|
| if_id.v | `instruction`, `pc`, `pc_plus4` | ID Stage | 传递给下一流水级 |

## 设计原则

1. **组合逻辑与状态分离**：`pc_next.v` 是纯组合逻辑，`if_id.v` 是纯寄存器，`inst_mem.v` 初期为组合 ROM。
2. **本级不拥有 PC 寄存器**：PC 是全局资源，IF Stage 只负责计算 `pc_next`，不持有 PC 状态。
3. **控制响应遵循优先级**：flush > stall > normal，确保异常/分支处理优先于暂停。
4. **为未来预留带宽**：`if_id.v` 当前存储 `pc` 和 `pc_plus4`，为异常处理、分支预测等后续功能预留。

## 未来扩展

- **分支预测**：在 `pc_next.v` 中增加静态/动态分支预测逻辑
- **总线接口**：将 `inst_mem.v` 的简单 ROM 替换为 AXI/Wishbone 总线接口，支持外部指令存储器
- **指令 Cache**：在 IF Stage 与总线之间插入指令 Cache
- **MMU**：取指地址需要经过地址转换（Sv32），届时在 `pc.v` 与 `inst_mem.v` 之间插入 TLB/MMU 查询逻辑
