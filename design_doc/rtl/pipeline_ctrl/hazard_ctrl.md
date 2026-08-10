# hazard_ctrl.v 设计描述

## 概述

`hazard_ctrl.v` 是流水线控制模块（Pipeline Control），负责**数据冒险（RAW）检测与处理**。当前 RV32I 阶段的核心职责：

1. **检测 RAW 依赖**：ID 级指令的 rs1/rs2 是否依赖流水线中尚未写回 regfile 的指令
2. **产生 stall**：冻结 PC 与 IF/ID，ID/EX 灌入 NOP bubble，等待 producer 写回
3. **（方案 B，推荐后续）产生 forwarding 选择信号**：普通 RAW 旁路 EX/MEM、MEM/WB 数据，仅 load-use 插 1 拍 stall

**不处理**：控制冒险（分支/跳转，归 `flow_ctrl.v`）、结构冒险（本项目无——见 §1.3）。

## 冒险分析：本项目实际存在哪些 hazard

### 1.1 数据冒险（RAW）—— 必须处理

regfile 读是**组合**的（ID 级每周期读）、写是**沿触发**的（WB 级末沿写）。因此 producer 的结果要等它走完 EX→MEM→WB 并在 WB 末沿写入 regfile 后，下一条指令才能在 ID 级读到。

**关键时序事实（本项目 regfile 配置）**：producer 在 WB 级末沿写 regfile；use 指令在 ID 级读 regfile 并**在进入 ID/EX 时锁存**。故 use 锁存到新值的前提是：**use 进 ID/EX 的时钟沿必须晚于 producer 的 WB 写沿**。

无转发时，这意味着 use 要等 producer 走完剩余流水线再进 EX。以"producer 在 EX 级、use 在 ID 级"（紧邻指令）为例：

```
沿 t1: producer → ID/EX(EX级);  use → IF/ID(ID级)      ← 此刻检测到 RAW
沿 t2: producer → ex_mem(MEM);  use 冻结在 IF/ID        ← stall
沿 t3: producer → mem_wb(WB);   use 冻结在 IF/ID        ← stall
沿 t4: producer 写 regfile;     use 冻结在 IF/ID        ← stall
沿 t5: use → ID/EX, 锁存 t4–t5 周期 regfile 读 = 新值  ✓
```

**紧邻 RAW 需要 3 拍 stall**（producer 在 ex_mem 时 2 拍、在 mem_wb 时 1 拍——stall 检测条件持续命中直到 producer 离开 mem_wb）。

### 1.2 load-use 特例

load 数据在 **MEM 周期末**才从 `data_mem` 组合读出、`t3 沿`锁进 mem_wb。load 在 EX 级（id_ex）时其数据尚未存在，**任何转发都来不及**——必须 stall。这是 RAW 中唯一"必须先 stall"的情况；普通 RAW 在方案 B 中可由 forwarding 化解。

### 1.3 结构冒险 —— 不存在

- regfile：单写口，WB 级独占，每周期至多一条指令写回（无写回冲突）
- 指令/数据存储器：分离地址空间（当前），且一条指令要么 load 要么 store（`mem_read`/`mem_write` 互斥，decode 保证），无访存冲突
- 单周期访存，无多周期资源占用

故无 structural hazard，`hazard_ctrl` 无需处理。

---

## 方案 A（最简，**已实现**）：无转发，全 RAW stall

> **实现状态**：`hazard_ctrl.v` 已实现并通过 lint。配套修改已落地：`id_ex.v` 的 `i_stall` 语义改为灌 NOP、`pc_next.v` 优先级改为 `branch_valid > stall`。本方案无 forwarding。

### 检测条件

ID 级指令（decode 输出的 `rs1_addr`/`rs2_addr`）与流水线中尚未写回的 producer 匹配：

```
stall = (ex_mem.reg_write  && ex_mem.rd  != x0 && (ex_mem.rd  == rs1 || ex_mem.rd  == rs2))
     || (mem_wb.reg_write  && mem_wb.rd  != x0 && (mem_wb.rd  == rs1 || mem_wb.rd  == rs2))
```

其中 rs1/rs2 取 **decode 的组合输出**（`decode.o_rs1_addr/o_rs2_addr`，等价于 `if_id` 指令字段，避免重复提取）。

> 不含 load-use 特判：所有 RAW 一视同仁，producer 在 ex_mem/mem_wb 时都 stall 到其写回。逻辑最简单，性能最差（紧邻依赖 3 拍、跨一级 2 拍、跨两级 1 拍）。

### 动态判断（每周期实时检测，非固定 stall）

**`o_stall` 是动态组合信号，不是固定常数**。每个时钟周期，`hazard_ctrl.v` 都实时比较当前 ID 级指令（decode 输出的 `rs1_addr`/`rs2_addr`）与流水线中尚未写回的 producer（`ex_mem` / `mem_wb` 的 `rd`）：

```verilog
// hazard_ctrl.v — 纯组合，每周期重新求值
assign o_stall = ex_mem_rs1_hit | ex_mem_rs2_hit |
                 mem_wb_rs1_hit | mem_wb_rs2_hit;
// 每个 hit = reg_write && rd != x0 && (rd == rs1 || rd == rs2)
```

**stall 的持续时间由"冲突持续存在"自然决定，不是预编程的拍数**：

| 周期 | producer 位置 | 检测结果 | o_stall |
|------|--------------|---------|:---:|
| t1 | 进入 EX | ex_mem/mem_wb 是旧指令，无冲突 | 0 |
| t2 | ex_mem（MEM） | ex_mem.rd == rs → 命中 | **1** |
| t3 | mem_wb（WB） | mem_wb.rd == rs → 命中 | **1** |
| t4 | 写回 regfile | ex_mem/mem_wb 已换新指令，无命中 | **0**（放行） |

- producer 在 `ex_mem` 时命中 1 拍、在 `mem_wb` 时命中 1 拍，写回后检测自然放行——**紧邻 RAW 的"3 拍"是上述过程的自然累积，不是硬编码 `stall=3`**
- producer 越远 stall 越短（跨一级 2 拍、跨两级 1 拍），无关指令零 stall——同一段组合逻辑自动适应，无需计数状态
- use 指令冻结在 IF/ID，每周期组合读 regfile：一旦 producer 写回，下一拍就读到新值，无需数拍等待

### stall 的扇出（关键，与直觉不同）

| 目标 | 行为 | 依据 |
|------|------|------|
| `pc_next` (PC) | **冻结**（保持） | use 之前的指令不前进 |
| `if_id` | **冻结**（保持） | use 停在 ID 级，每周期重新组合读 regfile |
| `id_ex` | **灌 NOP**（bubble） | 防止 use 被复制进 EX；producer/load 必须能前进 |
| `ex_mem` | **不接 stall**（正常推进） | producer/load 必须前进（EX→MEM→WB）才能写回 |
| `mem_wb` | **不接 stall**（正常推进） | 同上 |

**⚠️ 配套修改（已落地）**：`id_ex.v` 的 `i_stall` 语义已从"保持"改为**灌 NOP**（复用复位/flush 分支的安全默认值：`alu_opcode=ALU_NOP`、`reg_write=0`、`branch_sel=BRANCH_NONE` 等）。若保持，load-use 时 load 卡在 EX、use 卡在 ID，检测条件持续命中 → **死锁**。`pc_next.v` 优先级已改为 `branch_valid > stall`（见 flow_ctrl.md）。

### 输入/输出端口

**输入**：`i_rs1_addr`、`i_rs2_addr`（decode 输出）；`i_ex_mem_rd`、`i_ex_mem_reg_write`；`i_mem_wb_rd`、`i_mem_wb_reg_write`

**输出**：`o_stall`（→ pc_next、if_id、id_ex 三处）

### 验证要点

- 普通 RAW：`add t0,a0,a1 / add t1,t0,a2` → 插 3 拍 bubble，t0 写回后 t1 读到新值
- 链式依赖：`add → sub → xor` 逐级 3 拍
- load-use：`lw t0,0(a0) / add t1,t0,t2` → 3 拍
- 不相关指令：`add t0,a0,a1 / add t1,a2,a3` → 零 stall（验证不误伤）

---

## 方案 B（forwarding，**仅设计不实现**，后续阶段落地）

> **状态**：本章为后续设计预留，当前 `hazard_ctrl.v` 不包含 forwarding 逻辑。实现时按此章节扩展接口与数据通路。

### 原理

- **普通 RAW（非 load）**：producer 的 ALU 结果在 EX 末沿已算好（`ex_mem.o_alu_result`），或在 WB 级（`mem_wb` 三选一输出）——**旁路到 EX 操作数 MUX，零 stall**
- **load-use**：load 数据 MEM 末沿才有，EX/MEM→EX 旁路来不及，需 **1 拍 stall + MEM/WB→EX 旁路**

### forwarding 检测与选择（EX 级）

use 在 EX 级（id_ex）时，其 rs1/rs2 与后方 producer 匹配：

```
if (ex_mem.reg_write && ex_mem.rd != x0 && ex_mem.rd == rs)  → 选 ex_mem.o_alu_result（最近者优先）
else if (mem_wb.reg_write && mem_wb.rd != x0 && mem_wb.rd == rs)
      → 按 mem_wb.wb_src 选：WB_SRC_ALU→o_alu_result / WB_SRC_MEM→o_read_data / WB_SRC_PC_PLUS4→o_pc_plus4
```

### load-use stall（仅此情况插 1 拍）

```
stall = id_ex.mem_read && id_ex.rd != x0 && (id_ex.rd == rs1 || id_ex.rd == rs2)
```

- 检测用 **id_ex**（load 在 EX 级）+ **decode 输出**（use 在 ID 级）
- stall 1 拍后 load 进 MEM、再进 WB，MEM 末沿数据锁进 mem_wb，下一周期由 **MEM/WB→EX 旁路**供给 EX 级的 use（见 §1.1 时序：`t3 沿` use 进 EX 用旁路数据，正确）

### 需要的接口改动（比方案 A 大）

| 模块 | 改动 |
|------|------|
| `id_ex.v` | ① `i_stall` 语义改为灌 NOP；② **新增 `o_rs1_addr`/`o_rs2_addr` 锁存**（+10 bit，forwarding 检测需 EX 级 rs 地址） |
| `executor.v` | 操作数 MUX 扩展：`alu_a`/`alu_b` 增加旁路源（`ex_mem.o_alu_result`、`mem_wb` 三选一数据）+ 2 组旁路选择信号输入 |
| `hazard_ctrl.v` | 输出 `o_stall` + `o_fwd_a_sel`/`o_fwd_b_sel`（2 位，编码：无/EX_MEM/MEM_WB） |
| `top_core.v` | 连接旁路数据通路（ex_mem/mem_wb → executor） |

### 验证要点

- 普通 RAW：零 stall（`add` 后紧邻 `add` 使用其 rd）
- load-use：1 拍 stall（`lw` 后紧邻使用）
- store 数据旁路：`add t0,... / sw t0,0(a1)`（rs2 旁路）
- JAL/JALR 的 pc+4 写回被使用：MEM/WB 旁路选 `o_pc_plus4`

---

## 与 flow_ctrl 的交互

| 场景 | 规则 |
|------|------|
| 同拍：分支 taken + RAW stall | **flush 优先**：if_id/id_ex 内部优先级已是 `flush > stall`，分支冲刷丢弃错误路径指令；RAW stall 让位（该指令本就要被冲刷） |
| `pc_next` 的 `branch_valid` vs `stall` | **branch_valid 优先**（需按 flow_ctrl.md 调整 pc_next.v 优先级） |

## 设计原则

1. **只产生 stall / forwarding 选择**：不产生 flush、不碰 PC 目标（flow_ctrl 的事），两者在消费端汇合
2. **数据通路不改**：forwarding 只是操作数 MUX 的额外输入，executor 仍不译码、不产生控制
3. **x0 与 reg_write 过滤**：rd=x0 或 reg_write=0 的"写"不参与检测（避免误 stall / 误转发）
4. **最近者优先**：多条 producer 写同一寄存器时，旁路取流水线中最近的（ex_mem 优先于 mem_wb）

## 未来扩展

- **MMU TLB miss stall**：load 在 MEM 等待页表遍历（多周期）时，**ex_mem 保持**（冻结）、PC/IF/ID 冻结、ID/EX 灌 NOP——此时 ex_mem 的 `i_stall`（保持语义）启用，与 load-use 的"ex_mem 不接"不冲突（不同场景）
- **M 扩展多周期**：MUL/DIV 多周期时 EX 需保持，`id_ex` 的保持语义届时视需要恢复/补充
- **双发射/乱序**：远超出当前架构，预留 stall/forwarding 接口的扩展空间
