# flow_ctrl.v 设计描述

## 概述

`flow_ctrl.v` 是流水线控制模块（Pipeline Control），负责**分支/跳转重定向**：把 EX Stage 的分支判定结果（`branch_taken`）转化为两件事：

1. **PC 重定向**：输出 `branch_valid` / `branch_target` 给 `pc_next.v`，使 `pc.v` 在当拍末沿跳转到目标地址
2. **流水线冲刷**：输出 `flush` 给 IF/ID、ID/EX 两级流水线寄存器，清除分支错误路径上的指令（分支惩罚 2 拍）

**本级是纯组合逻辑，无寄存器、无状态**。它不做任何分支类型判断（`branch_sel` 已在 decode 生成、executor 已闭环目标），本质是"分支判定信号的**扇出分配器**"。

## 模块组成与位置

```
executor.v (EX Stage)
   │  o_branch_taken, o_branch_target
   ▼
flow_ctrl.v
   │
   ├── o_branch_valid  ──────────────────────► pc_next.v (i_branch_valid)
   ├── o_branch_target ──────────────────────► pc_next.v (i_branch_target)
   ├── o_flush_if_id   ──────────────────────► if_id.v (i_flush)
   └── o_flush_id_ex   ──────────────────────► id_ex.v (i_flush)
```

- 目标寄存器：`pc_next.v`（PC 重定向）、`if_id.v` / `id_ex.v`（冲刷）
- **不冲刷** EX/MEM、MEM/WB：这两级中的指令在分支指令之前，是正确的，继续推进
- 与 `hazard_ctrl.v` 并列：flow 管"跳转重定向"，hazard 管"暂停"（stall），互不产生对方的信号

## 端口定义

### 输入

| 信号 | 宽度 | 来源 | 说明 |
|------|------|------|------|
| `i_branch_taken` | 1 | executor.v (o_branch_taken) | 分支/跳转是否 taken（EX 判定） |
| `i_branch_target` | 32 | executor.v (o_branch_target) | 跳转目标（JAL/BRANCH=pc+imm，JALR=(rs1+imm)&~1，EX 已闭环） |

### 输出

| 信号 | 宽度 | 去向 | 说明 |
|------|------|------|------|
| `o_branch_valid` | 1 | pc_next.v (i_branch_valid) | PC 重定向有效（= i_branch_taken） |
| `o_branch_target` | 32 | pc_next.v (i_branch_target) | 重定向目标地址（透传） |
| `o_flush_if_id` | 1 | if_id.v (i_flush) | 冲刷 IF/ID（错误路径第 1 条） |
| `o_flush_id_ex` | 1 | id_ex.v (i_flush) | 冲刷 ID/EX（错误路径第 2 条） |

## 功能描述

### 核心逻辑

纯组合，本质是信号扇出：

```verilog
assign o_branch_valid  = i_branch_taken;
assign o_branch_target = i_branch_target;   // 透传，无修改

assign o_flush_if_id   = i_branch_taken;    // taken → 两级同时冲刷
assign o_flush_id_ex   = i_branch_taken;
```

### 为什么是两级冲刷（分支惩罚 2 拍）

分支在 **EX 阶段**判定，此时流水线里已进入两条错误指令：

| 周期 N（EX 判定 taken） | 流水线位置 | 指令 | 处置 |
|------------------------|-----------|------|------|
| EX | 分支指令 | 正确，继续 | — |
| ID | 第 N+1 条（顺序执行） | **错误路径** | flush |
| IF | 第 N+2 条（顺序执行） | **错误路径** | flush |
| EX/MEM、MEM/WB | 分支之前的指令 | 正确 | 不动 |

`o_flush_if_id` / `o_flush_id_ex` 在周期 N 末沿生效：两级寄存器清零为 NOP bubble（`reg_write=0`、`branch_sel=BRANCH_NONE` 等安全默认），不产生副作用。PC 在**同一末沿**更新为目标地址。周期 N+1 起从目标地址正常取指。

### 与 hazard_ctrl 的交互（关键）

**场景**：EX 判定分支 taken 的同时，ID 阶段检测到 load-use 冲突（ID 指令依赖 EX/MEM 中 load 的结果）。此时 `stall` 与 `branch_valid` 同拍有效。

**处理规则**：

| 信号对 | 优先级 | 依据 |
|--------|--------|------|
| IF/ID、ID/EX 的 `flush` vs `stall` | **flush 优先** | 两级流水线寄存器内部优先级已是 `flush > stall`（if_id.v / id_ex.v 已实现）——分支错误路径的指令必须丢弃，即使 hazard 想保持它重放 |
| `pc_next` 的 `branch_valid` vs `stall` | **branch_valid 优先**（需修改） | 分支跳转是"必须执行的控制流改变"；stall 只是"推迟取新指令"。若 stall 优先，PC 保持不动，分支跳转被静默丢弃 → 严重错误 |

**⚠️ 配套修改建议**：当前 `pc_next.v` 优先级是 `i_stall > i_branch_valid`（stall 优先），与上述规则冲突。需调整为 `branch_valid > stall`：

```verilog
// pc_next.v（已按此修改落地）
assign o_pc_next = i_branch_valid ? i_branch_target :
                   i_stall        ? i_pc            :
                                     pc_plus4;
```

语义：有分支重定向时直接跳转（同时两级 flush 已清掉错误路径，无需保持 PC）；无分支时 stall 冻结 PC。该修改不改变无分支场景行为。**该调整已实现**（`src/rtl/stage/if_stage/pc_next.v`）。

## 设计原则

1. **纯组合**：无寄存器、无时钟、无状态，只做信号扇出与透传。
2. **零译码**：不判断分支类型（JAL/JALR/条件分支），`branch_sel` 已在 decode 生成、executor 已闭环目标，flow_ctrl 只看 `branch_taken` 布尔值。
3. **单一职责**：只负责"跳转重定向 + 冲刷"，不产生 stall（那是 hazard_ctrl 的事）。
4. **冲刷目标固定**：分支在 EX 判定 → 冲刷 IF/ID、ID/EX 两级；若未来分支提前到 ID（分支预测），冲刷目标相应减少，此处设计随流水线改动而变。

## 时序

```
周期 N（组合）:   executor 判定 taken → flow_ctrl 扇出 valid/flush → pc_next 选目标
周期 N 末沿:      pc.v <= target;  if_id / id_ex 清零（flush 生效）
周期 N+1:         从 target 取指；流水线恢复
```

分支重定向路径（关键路径）：
```
id_ex → executor（比较/加法）→ flow_ctrl（扇出）→ pc_next（MUX）→ pc 建立时间
```
此路径是决定时钟周期的关键路径之一（与 EX 组合路径并行），flow_ctrl 本身只增加一级扇出（<0.2 ns）。

## 与其他模块的交互

### 与 EX Stage

| 来源 | 信号 | 目标 |
|------|------|------|
| executor.v | `o_branch_taken`, `o_branch_target` | flow_ctrl.v |

### 与 IF / 流水线寄存器

| 来源 | 信号 | 目标 |
|------|------|------|
| flow_ctrl.v | `o_branch_valid`, `o_branch_target` | pc_next.v |
| flow_ctrl.v | `o_flush_if_id` | if_id.v |
| flow_ctrl.v | `o_flush_id_ex` | id_ex.v |

### 与 hazard_ctrl（并列，无直接连线）

| 模块 | 输出 | 消费方 |
|------|------|--------|
| flow_ctrl.v | `branch_valid`/`branch_target`/`flush` | pc_next / if_id / id_ex |
| hazard_ctrl.v | `stall` | pc_next / 全部流水线寄存器 |

两者在消费端（pc_next、流水线寄存器）汇合，优先级规则见上。

## 未来扩展

- **异常/中断重定向**：异常与中断也走 PC 重定向 + 冲刷，可复用本模块的 flush/valid 通路，届时增加 `i_exception` / `i_exception_target`（如 mtvec）输入，按优先级（异常 > 分支）合并
- **分支预测**：若分支判定提前到 ID（取指即预测），flush 目标减为一级，flow_ctrl 变为"预测失败才冲刷"，接口不变
- **CSR/JALR 特判**：不需要——目标已由 executor 闭环（JALR 取 rs1+imm）
