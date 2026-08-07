# if_id.v 实现描述

## 概述

`if_id.v` 是 IF/ID 流水线寄存器，位于 IF Stage 与 ID Stage 之间。它在时钟上升沿锁存从 IF Stage 传入的指令和 PC，并传递给 ID Stage。

该模块响应流水线控制信号（stall/flush），按优先级控制寄存器行为：flush > stall > 正常更新。

## 端口定义

### 输入

| 端口名 | 方向 | 宽度 | 来源 | 说明 |
|--------|------|------|------|------|
| `i_clk` | input | 1 | 全局时钟 | 系统时钟 |
| `i_rst_n` | input | 1 | 全局复位 | 异步复位，低有效 |
| `i_instruction` | input | 32 | `inst_mem.v` | 当前取出的指令字 |
| `i_pc` | input | 32 | `pc.v` | 当前指令对应的 PC |
| `i_flush` | input | 1 | `flow_control.v` | 流水线冲刷，高有效 |
| `i_stall` | input | 1 | `hazard_control.v` | 流水线暂停，高有效 |

### 输出

| 端口名 | 方向 | 宽度 | 去向 | 说明 |
|--------|------|------|------|------|
| `o_instruction` | output | 32 | `decode.v`（ID Stage） | 指令字 |
| `o_pc` | output | 32 | ID Stage | 当前指令 PC |

## 功能描述

### 核心行为

`if_id.v` 是一个带使能和同步清零的流水线寄存器组：

```
always_ff @(posedge i_clk or negedge i_rst_n):
  if (!i_rst_n):     所有输出寄存器 ← 0
  else if (i_flush):  所有输出寄存器 ← 0（插入 NOP/bubble）
  else if (i_stall):  保持当前值不变
  else:               锁存输入信号
```

### 优先级

| 优先级 | 条件 | 行为 | 场景 |
|--------|------|------|------|
| 1（最高） | `i_rst_n == 0` | 全部清零 | 系统复位 |
| 2 | `i_flush == 1` | o_instruction ← `INST_NOP`，o_pc ← `` `XLEN_ZERO `` | 分支预测错误、异常等需冲刷流水线 |
| 3 | `i_stall == 1` | 保持当前值 | load-use 冲突、资源等待等 |
| 4（默认） | 以上均不满足 | 锁存输入 | 正常流水线推进 |

### flush 时的输出值

当 flush 生效时，`o_instruction` 输出 `` `INST_NOP ``（当前定义为 `32'h0`），`o_pc` 输出 `` `XLEN_ZERO ``。
`o_instruction == `INST_NOP`` 对应 RV32I 的非法指令——ID Stage 应将其视为 bubble，不产生副作用。

`o_pc` 不使用 `` `INST_NOP `` 的原因：PC 值为地址而非指令编码，`` `XLEN_ZERO `` 作为无效地址与 `INST_NOP` 语义不同。

## 实现要点

1. **异步复位 + 同步 flush**：`i_rst_n` 为异步复位，`i_flush` 为同步清零（在时钟沿生效）。
2. **无组合路径**：输出直接来自寄存器，不经过组合逻辑，保证时序收敛。
3. **stall 使能实现**：使用寄存器回环——`i_stall` 有效时选择寄存器当前值，无效时选择输入。
4. **常量引用**：bubble 值使用 `` `INST_NOP `` 宏（定义于 `const_define.vh`），不在模块内 hardcode。

## 接口时序

```
         clk
     ─────┴─────┴─────┴─────
     i_instruction ──[A]──[B]──[C]──
     i_pc           ──[PA]─[PB]─[PC]─
     i_flush        ──0───1───0────
     i_stall        ──0───0───1────
                       │    │    │
                       ▼    ▼    ▼  (寄存器更新)
     o_instruction  ──[A]─[0]─[0]──  (flush 清零后 stall 保持)
```

## 与架构的关系

- 属于 IF Stage 与 ID Stage 之间的边界寄存器，详见 [if_stage.md](../stage/if_stage/if_stage.md)
- 输入来自 `inst_mem.v`（指令）和 `pc.v`（PC）
- 输出送往 ID Stage 的 `decode.v`
- 控制信号来自 `flow_control.v`（flush）和 `hazard_control.v`（stall）

## 未来扩展

- **pc_plus4**：若后续阶段对 `pc + 4` 的需求变得明确（如 JAL 返回地址），可添加 `o_pc_plus4` 输出。当前已有 `o_pc`，下游可自行计算。
- **异常标记**：当 `i_flush` 因异常触发时，可增加 `i_flush_reason` 以区分冲刷原因。
- **压缩指令（C 扩展）**：若支持 RV32C，`o_instruction` 可能需增加指令有效性标志位。
