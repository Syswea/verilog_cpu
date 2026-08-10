# pc_next.v 实现描述

## 概述

`pc_next.v` 是 IF Stage 的组合逻辑模块，负责计算下一时钟周期的 PC 值。它不包含任何寄存器——PC 寄存器归属 `resources/pc.v`。

该模块根据流水线控制信号（stall、branch）选择 PC 的来源：正常递增（+4）、分支重定向、或保持（stall）。

## 端口定义

### 输入

| 端口名 | 方向 | 宽度 | 来源 | 说明 |
|--------|------|------|------|------|
| `i_pc` | input | 32 | `pc.v` | 当前 PC 值 |
| `i_branch_target` | input | 32 | `flow_ctrl.v` | 分支/跳转目标地址 |
| `i_branch_valid` | input | 1 | `flow_ctrl.v` | 分支/跳转有效标志 |
| `i_stall` | input | 1 | `hazard_ctrl.v` | 流水线暂停信号，高有效 |

### 输出

| 端口名 | 方向 | 宽度 | 去向 | 说明 |
|--------|------|------|------|------|
| `o_pc_next` | output | 32 | `pc.v` | 下一周期的 PC 值 |

## 功能描述

### 核心逻辑

`pc_next.v` 是一个纯组合逻辑的 MUX，按优先级选择 `o_pc_next`：

```
if (i_stall)           o_pc_next = i_pc;              // 保持
else if (i_branch_valid) o_pc_next = i_branch_target; // 分支重定向
else                     o_pc_next = i_pc + 32'd4;    // 正常递增
```

### 优先级说明

| 优先级 | 条件 | 行为 | 场景 |
|--------|------|------|------|
| 1（最高） | `i_stall == 1` | PC 保持不变 | load-use 冲突、数据前推未就绪等 |
| 2 | `i_branch_valid == 1` | PC 跳转到分支目标 | 分支指令在 EX 阶段解析后重定向 |
| 3（默认） | 以上均不满足 | PC+4 | 正常顺序取指 |

设计考量：stall 优先级最高，因为当流水线被暂停时，即使有分支重定向请求也不应改变 PC——被暂停的指令还没有完成。

## 实现要点

1. **纯组合逻辑**：不含 `always_ff`，使用 `always_comb` 或连续赋值（`assign`）。
2. **无状态**：不生成锁存器，所有分支必须完整覆盖。
3. **地址对齐**：RV32I 指令均为 4 字节对齐，直接 `+4` 即可，无需处理非对齐跳转（非对齐跳转由异常机制处理）。
4. **复位无关**：该模块不包含寄存器，无需复位信号。PC 的初始值由 `pc.v` 的复位逻辑负责。

## 接口时序

```
         clk
     ─────┴─────
     i_pc        ────[valid]────
     i_stall     ────[0 or 1]───
     i_branch_*  ────[0 or 1]───
                       │
                       ▼  (组合逻辑，同周期)
     o_pc_next   ────[result]───
```

所有输入到输出的延迟为纯组合路径，`o_pc_next` 在同一周期内稳定，供 `pc.v` 在下一时钟沿采样。

## 与架构的关系

- 属于 IF Stage，详见 [if_stage.md](../if_stage.md)
- PC 寄存器由 `resources/pc.v` 实现，`pc_next.v` 只负责计算
- 分支信号来自 [flow_ctrl.v](../../../src/rtl/pipeline_ctrl/flow_ctrl.v)，stall 来自 [hazard_ctrl.v](../../../src/rtl/pipeline_ctrl/hazard_ctrl.v)

## 未来扩展

- **分支预测**：可在该模块中增加预测逻辑（如 BTB / BHT），预测 `pc_next` 时使用预测目标而非单纯 `pc + 4`；当 `i_branch_valid` 到来时进行校验和修复
- **异常入口**：将来增加 `i_exception_pc` 输入，优先级介于 stall 和 branch 之间，用于异常/中断的 PC 重定向
