# MEM Stage 设计描述（v2 — 简化 + MMU 预留）

## 概述

MEM（Memory Access）Stage 是 5 级流水线的第四级，负责**数据存储器访问**（load / store）以及将 EX 结果与控制信号锁存后传递给 WB Stage。

**v2 修订要点**：

- **简单优先**：当前目标是用 testbench 仿真验证逻辑正确性，故 `data_mem.v` 采用最简实现（字节数组、组合读、同步字节使能写），不引入总线接口、Cache 等复杂结构。
- **MMU 预留**：为未来 Sv32 MMU 实现**预留接口与插入点**——访存地址在架构上明确分为两段：**虚拟地址**（`v_addr`，ex_mem 锁存）与**物理地址**（`p_addr`，data_mem 消费）。当前 MMU 未实现，`p_addr = v_addr` 直通（identity mapping），零额外硬件；未来只需在插入点新增 MMU 模块，**ex_mem / data_mem 两端接口均不改变**。

本级包含两个模块：

- `ex_mem.v` — EX/MEM 流水线寄存器（锁存 EX 结果、Store 数据、目标寄存器、MEM/WB 控制）
- `data_mem.v` — 数据存储器（load / store，字节寻址，**地址语义 = 物理地址**）

> `mem_wb.v`（MEM/WB 流水线寄存器）与 `wb.v`（写回）属于 WB Stage，见 [wb_stage 设计文档]（待建）。`data_mem.v` 读出的 load 数据直接进入 `mem_wb.v`，不经过 `ex_mem.v`（详见 §1.3 时序说明）。

## 模块组成

```
              executor.v (EX Stage)
                   │
        ┌──────────┼──────────────────────────────┐
        │          │                              │
        ▼          ▼                              ▼
  ┌────────────────────────────────────────────────────┐
  │  ex_mem.v (EX/MEM 流水线寄存器)                      │
  │  alu_result(=虚拟地址 v_addr)  rs2_data(=Store 数据) │
  │  pc_plus4  rd_addr  mem_*  wb_src  reg_write        │
  └──────┬───────────────────┬─────────────────────────┘
         │ v_addr            │ alu_result, pc_plus4,
         ▼                   │ rd_addr, wb_src, reg_write
  ┌──────────────────────┐   │
  │  [MMU 预留插入点]     │   │   ← 当前直通：p_addr = v_addr
  │   Sv32 地址翻译       │   │     未来插入 mmu 模块：
  │   (v_addr→p_addr)    │   │     ex_mem.o_alu_result → mmu → data_mem.i_addr
  └──────┬───────────────┘   │     （详见 §1.4 MMU 接口预留）
         │ p_addr            │
         ▼                   ▼
  ┌──────────────────┐       │
  │  data_mem.v      │       │
  │  (load/store)    │       │
  └──────┬───────────┘       │
         │ read_data (load)  │
         ▼                   ▼
  ┌────────────────────────────────────────────────────┐
  │  mem_wb.v (MEM/WB 流水线寄存器，属 WB Stage)          │
  │  read_data  alu_result  pc_plus4  rd_addr  wb_src   │
  │  reg_write                                          │
  └──────────────────────┬──────────────────────────────┘
                         ▼
                    wb.v → regfile.v
```

**数据流向要点**：

- **访存地址 = 虚拟地址**（`ex_mem.o_alu_result`，LOAD/STORE 的 `rs1+imm` 由 EX 的 ALU 算出）→ 经 MMU 预留点（当前直通）→ **物理地址** → `data_mem.i_addr`
- Store 数据 = `ex_mem.o_rs2_data`（executor 原样透传）
- load 读数据 = `data_mem.o_read_data` → **直接进 `mem_wb.v`**（不经过 ex_mem）
- 写回数据三选一（`alu_result` / `read_data` / `pc_plus4`）由 `wb_src[1:0]` 在 WB Stage 选择

---

## 1.1 ex_mem.v — EX/MEM 流水线寄存器

### 职责

在时钟沿锁存 EX Stage 的全部输出，隔离 EX 组合逻辑与 MEM 阶段，并响应 `stall` / `flush`。**不存储原始指令字段**——控制信号已由 decode 扁平化译码。

### 端口定义

**输入**

| 信号 | 宽度 | 来源 | 说明 |
|------|------|------|------|
| `i_clk` | 1 | 全局时钟 | 系统时钟 |
| `i_rst_n` | 1 | 全局复位 | 异步复位，低有效 |
| `i_flush` | 1 | flow_ctrl.v | 流水线冲刷，高有效 |
| `i_stall` | 1 | hazard_ctrl.v | 流水线暂停，高有效 |
| `i_alu_result` | 32 | executor.v (o_alu_result) | ALU 结果；LOAD/STORE 时为**虚拟地址** |
| `i_pc_plus4` | 32 | executor.v (o_pc_plus4) | 链接地址（JAL/JALR 写回值） |
| `i_rs2_data` | 32 | executor.v (o_rs2_data) | Store 数据 |
| `i_rd_addr` | 5 | executor.v (o_rd_addr) | 目标寄存器地址 |
| `i_mem_read` | 1 | executor.v (o_mem_read) | 读数据存储器使能 |
| `i_mem_write` | 1 | executor.v (o_mem_write) | 写数据存储器使能 |
| `i_mem_width` | 2 | executor.v (o_mem_width) | 访存宽度（00=Byte, 01=Half, 10=Word） |
| `i_mem_sext` | 1 | executor.v (o_mem_sext) | Load 符号扩展（0=零扩展, 1=符号扩展） |
| `i_wb_src` | 2 | executor.v (o_wb_src) | 写回源选择（00=ALU, 01=内存, 10=pc+4） |
| `i_reg_write` | 1 | executor.v (o_reg_write) | 寄存器写使能 |

**输出**

| 信号 | 宽度 | 去向 | 说明 |
|------|------|------|------|
| `o_alu_result` | 32 | MMU 预留点 → data_mem.v（地址）/ mem_wb.v | ALU 结果 / **虚拟地址** |
| `o_pc_plus4` | 32 | mem_wb.v | 链接地址 |
| `o_rs2_data` | 32 | data_mem.v（写数据） | Store 数据 |
| `o_rd_addr` | 5 | mem_wb.v → wb.v → regfile.v | 目标寄存器地址 |
| `o_mem_read` | 1 | data_mem.v | 读使能 |
| `o_mem_write` | 1 | data_mem.v | 写使能 |
| `o_mem_width` | 2 | data_mem.v | 访存宽度 |
| `o_mem_sext` | 1 | data_mem.v | 符号扩展 |
| `o_wb_src` | 2 | mem_wb.v | 写回源选择 |
| `o_reg_write` | 1 | mem_wb.v | 寄存器写使能 |

**锁存位宽**：数据 32+32+32+5 = 101，控制 1+1+2+1+2+1 = 8，合计 **109 位**。

### 行为（与 id_ex.v 一致）

```
always_ff @(posedge i_clk or negedge i_rst_n):
  if (!i_rst_n):              全部输出 ← 安全默认值
  else if (i_flush):          控制清零（mem_read=0, mem_write=0, reg_write=0），数据 ← 0
  else if (i_stall):          保持当前值
  else:                       锁存所有输入
```

复位 / flush 默认值：`alu_result/pc_plus4/rs2_data ← XLEN_ZERO`，`rd_addr ← REG_X0_ADDR`，`mem_read/mem_write ← 0`，`mem_width ← MEM_WIDTH_DEFAULT`，`mem_sext ← 0`，`wb_src ← WB_SRC_ALU`，`reg_write ← 0`（安全 NOP bubble）。

> ex_mem 锁存的 `alu_result` 语义定义为**虚拟地址**，但端口与信号名不变——MMU 未来插在它**之后**，故 ex_mem 无需任何改动。

---

## 1.2 data_mem.v — 数据存储器（最简实现）

### 职责

执行 load / store。接收**物理地址**、写数据、访存控制（读/写/宽度/符号扩展），组合读出 load 数据，时钟沿写入 store 数据。

### 端口定义

| 信号 | 方向 | 宽度 | 来源 / 去向 | 说明 |
|------|------|------|------------|------|
| `i_clk` | input | 1 | 全局时钟 | 系统时钟（仅写路径使用） |
| `i_addr` | input | 32 | MMU 预留点（当前 = ex_mem.o_alu_result 直通） | 访存**物理地址**（字节地址） |
| `i_write_data` | input | 32 | ex_mem.v (o_rs2_data) | Store 写数据 |
| `i_mem_read` | input | 1 | ex_mem.v (o_mem_read) | 读使能 |
| `i_mem_write` | input | 1 | ex_mem.v (o_mem_write) | 写使能 |
| `i_mem_width` | input | 2 | ex_mem.v (o_mem_width) | 访存宽度：00=Byte, 01=Half, 10=Word |
| `i_mem_sext` | input | 1 | ex_mem.v (o_mem_sext) | Load 符号扩展：0=零扩展, 1=符号扩展 |
| `o_read_data` | output | 32 | mem_wb.v | load 读出数据（组合读出） |

### 存储器组织（最简）

| 属性 | 值 |
|------|-----|
| 组织 | **字数组** `reg [31:0] mem [0 : DATA_MEM_DEPTH/4-1]`（每元素 4 字节，字节编址语义不变） |
| 深度 | 可配置（默认 1024 字节 = 1 KB，常量 `DATA_MEM_DEPTH`，待加入 const_define.vh） |
| 读方式 | 组合读出（异步），同 inst_mem.v |
| 写方式 | 同步写，4-bit 字节使能（`i_mem_write` 门控，BRAM 原生结构） |
| 字节序 | 小端（RISC-V 默认），byte lane = `i_addr[1:0]` |
| 初始化 | **`$readmemh` 从数据文件预载**（tb 仿真数据来源，用户确认）；文件每行 4 字节（一个字），格式同 inst_mem 的 firmware.hex |
| 存储类型 | 仿真阶段不限定；综合时用 `(* ram_style = "block" *)` 注释引导 BRAM |

> **字数组 vs 字节数组**：两者都实现 RISC-V 字节编址（架构语义），差别只在存储组织（实现层）。字数组用高 30 位 `addr[31:2]` 选字、低 2 位 `addr[1:0]` 选字内字节（小端 byte lane），直接匹配 BRAM 的 4-bit WE 结构，为综合铺路；字节数组更直观但综合时展开成本高。本文档选**字数组**。

### 写路径（同步，4-bit 字节使能 + 数据 lane 移位）

按 `mem_width` 与 `i_addr[1:0]` 生成 4-bit 字节使能：

| 宽度 | 字节使能 `be[3:0]` | 说明 |
|------|-------------------|------|
| SW (Word) | `4'b1111` | 写 4 字节（忽略 `i_addr[1:0]`） |
| SH (Half) | `i_addr[1] ? 4'b1100 : 4'b0011` | 写对齐半字（忽略 `i_addr[0]`） |
| SB (Byte) | `4'b0001 << i_addr[1:0]` | 写单字节 |

**写数据 lane 移位（最易错处，务必按此实现）**：

```
write_data_lane = i_write_data << (i_addr[1:0] * 8)   // 数据左移到目标字节 lane
mem[word_index] <= (mem[word_index] & ~be) | (write_data_lane & be)
// word_index = i_addr[31:2]；be 按 8-bit 粒度展开为 32-bit 掩码
```

实现方式：`always_ff @(posedge i_clk) if (i_mem_write) begin` 内，对每个字节 lane `l`：`if (be[l]) mem[word_index][l*8 +: 8] <= i_write_data[l*8 +: 8];`（逐字节写，直观且等价）。

**写安全**：写条件只来自 `ex_mem.o_mem_write`。flush 时 ex_mem 将 `mem_write` 清零、stall 时保持旧值，data_mem 均不会重复写——本模块不自行生成写条件。

### 读路径（组合）

```
按宽度与小端拼接，再按 mem_sext 扩展（word_index = i_addr[31:2]）：
  LW: o_read_data = mem[word_index]                                            （32 bit 直通）
  LH: o_read_data = sext/zext( mem[word_index][i_addr[1]*16 +: 16] )           （半字 lane）
  LB: o_read_data = sext/zext( mem[word_index][i_addr[1:0]*8 +: 8] )           （字节 lane）
```

- `i_mem_sext=1`：符号扩展（LB/LH）；`=0`：零扩展（LBU/LHU）
- 读与写互斥（`mem_read` 与 `mem_write` 不会同时为 1，由 decode 保证）
- **组合读是 MMU 单周期路径的前提**（§1.4），实现中不得改为同步读（见关键路径分析）

### 未映射地址行为（仿真友好）

地址超出 `DATA_MEM_DEPTH` 范围：读返回 0，写忽略，并（可选）打印 `$warning`。教学简化，与 inst_mem 的未映射返回 NOP 思路一致，便于仿真暴露地址计算 bug。

### 地址空间分离（当前）

当前 `inst_mem`（4 KB，地址 0x0 起）与 `data_mem`（1 KB，地址 0x0 起）是**分离的地址空间**，各用各的起始地址。仿真时注意程序不要向指令区地址写数据（未映射读 0 不会暴露此问题）。未来 Linux 启动需统一为冯·诺依曼内存模型（单一地址空间）时再合并。

### 对齐简化与仿真防御

RISC-V 规范要求非对齐访存触发 **Load/Store Address Misaligned 异常**。当前阶段软件保证对齐（编译器生成），与 inst_mem 相同策略：

- RTL：SH 忽略 `i_addr[0]`，SW 忽略 `i_addr[1:0]`（硬件层面自然对齐）
- 仿真防御：`always_comb` 断言 `SH → i_addr[0]==0`、`SW → i_addr[1:0]==00`、`SB` 无限制，非法则 `$error`，及时暴露软件 bug
- 未来：异常机制就绪后输出 misaligned 信号至 pipeline control（见 §1.4）

---

## 1.3 时序与数据流

```
EX 周期末:   ex_mem.v 锁存 alu_result(=v_addr), rs2_data, pc_plus4, rd_addr, 控制
MEM 周期内:  [MMU 预留点：p_addr = v_addr 直通] → data_mem.v 组合读 (load) / 同步写 (store)
MEM 周期末:  mem_wb.v 锁存 read_data(load) 或 alu_result(ALU 写回), pc_plus4, rd_addr, wb_src, reg_write
WB 周期:     wb.v 按 wb_src 三选一写回 regfile
```

**关键点：load 数据不经过 ex_mem**。data_mem 在 MEM 周期内组合读出，`o_read_data` 直接送 `mem_wb.v` 输入，在 MEM 周期末锁存。若让 read_data 先经过 ex_mem，会多延迟一拍导致数据错位。

Store 时序：`mem[addr] <= write_data` 发生在 MEM 周期末的时钟沿（`i_mem_write=1` 时）。

---

## 1.4 MMU 接口预留（Sv32，未来实现）

当前阶段不实现 MMU，但**接口契约已定死**，未来实现时无需改动 ex_mem / data_mem：

### 插入位置

```
ex_mem.o_alu_result (v_addr[31:0]) ──► mmu.i_v_addr
                                      │
                                      ▼
                                    mmu 模块（Sv32 翻译，未来）
                                      │
                                      ▼
                               mmu.o_p_addr[31:0] ──► data_mem.i_addr
```

- 当前实现：`p_addr = v_addr` 直通（identity mapping，等价于 MMU 旁路 / M-mode 直访物理地址）
- 直通在 **top_core.v 连线处**实现（`data_mem.i_addr ← ex_mem.o_alu_result`），data_mem 内部不感知 MMU

### 未来 MMU 模块的接口清单（预留规划，非当前实现）

| 信号 | 方向 | 说明 |
|------|------|------|
| `i_v_addr[31:0]` | input | 虚拟地址（来自 ex_mem.o_alu_result） |
| `i_priv[1:0]` | input | 当前特权级（来自 CSR，未来） |
| `i_translate` | input | 地址翻译使能（如 `mstatus.MPRV` 等，未来） |
| `o_p_addr[31:0]` | output | 物理地址（→ data_mem.i_addr） |
| `o_page_fault` | output | 页故障（→ flow_ctrl / 异常处理，未来） |
| `o_misaligned` | output | 非对齐异常（未来可移入 MMU 或 data_mem） |
| `stall` | output | TLB miss 时请求流水线 stall（→ hazard_ctrl，未来） |

### 预留的时序边界

- **TLB 命中路径**：`ex_mem → mmu（组合翻译）→ data_mem（组合读）→ mem_wb` 必须在单周期内完成——未来 MMU 是 MEM 周期组合路径的一部分，这是其关键路径代价
- **TLB miss**：需多周期页表遍历，届时 MMU 输出 `stall` 冻结流水线（hazard_ctrl 消费），与 load-use stall 机制复用

### 对当前设计的约束

- `data_mem.i_addr` **永远只接物理地址**（现在 = v_addr 直通，未来 = mmu.o_p_addr）
- `ex_mem.o_alu_result` **永远只输出虚拟地址**（ALU 结果语义不变）
- 异常信号当前不实现，仅在本节预留清单，避免给简单实现增加冗余端口

---

## 设计原则

1. **纯数据通路**：MEM Stage 无控制信号生成，全部来自 decode 透传；`data_mem` 只做读写，`ex_mem` 只做锁存。
2. **简单优先（仿真验证）**：单周期访存、组合读、同步写、字节数组，无总线 / 无 Cache / 无 MMU 实体。
3. **接口先于实现**：虚拟地址 / 物理地址边界与 MMU 插入点提前定义，未来扩展不改两端接口。
4. **单周期访存**：load 组合读出 + MEM 周期末锁存，无需额外等待周期（load-use 冲突由 hazard_ctrl 处理，MEM 阶段自身不插 stall）。
5. **写使能门控**：`mem_write` 未使能时 RAM 不写，天然无副作用（非法指令默认 `mem_write=0`）。
6. **控制透传**：`wb_src` / `reg_write` / `rd_addr` 原样穿过 MEM 到 WB。
7. **零逻辑 stalling/flushing**：`ex_mem.v` 的 stall/flush 由 `hazard_ctrl.v` / `flow_ctrl.v` 控制，MEM 内部不感知。

## 关键路径分析

**load 路径（MEM 阶段最长的组合路径）**：

```
ex_mem.o_alu_result(v_addr) → [MMU 直通/预留] → data_mem 组合读出 → o_read_data → mem_wb 建立时间
```

- 当前（无 MMU）：BRAM 异步读延迟（~1-2 ns），50-100 MHz 下充裕
- 未来（有 MMU）：路径增加组合翻译级数，TLB 命中时仍须单周期完成；这是 MMU 引入的时序代价

写路径（`i_write_data → 字节选通 → RAM 写`）满足 RAM 写建立时间即可，压力更小。

## 与其他模块的交互

### 与 EX Stage

| 来源 | 信号 | 目标 |
|------|------|------|
| executor.v | `o_alu_result`(v_addr), `o_pc_plus4`, `o_rs2_data`, `o_rd_addr` | ex_mem.v |
| executor.v | `o_mem_read/write/width/sext`, `o_wb_src`, `o_reg_write` | ex_mem.v |

### 与 WB Stage

| 来源 | 信号 | 目标 |
|------|------|------|
| ex_mem.v | `o_alu_result`, `o_pc_plus4`, `o_rd_addr`, `o_wb_src`, `o_reg_write` | mem_wb.v |
| data_mem.v | `o_read_data` | mem_wb.v |

### 与 Pipeline Control

| 来源 | 信号 | 目标 |
|------|------|------|
| hazard_ctrl.v | `stall` | ex_mem.v |
| flow_ctrl.v | `flush` | ex_mem.v |
| （未来）mmu | `o_page_fault` / `stall` | flow_ctrl.v / hazard_ctrl.v |

## 常量需求（待加入 const_define.vh）

```
`define DATA_MEM_DEPTH      1024   // data memory depth (bytes)
`define DATA_MEM_ADDR_WIDTH 10     // $clog2(DATA_MEM_DEPTH)
```

## 未来扩展

- **MMU（Sv32）**：按 §1.4 插入点实现，地址翻译 + 页故障 + TLB miss stall，不改 ex_mem / data_mem 接口；前提是 data_mem 保持组合读
- **load-use hazard**：`ex_mem.o_rd_addr` + `o_mem_read` 已透传，正是 hazard_ctrl 检测 load-use 冲突的两个输入（LW 后紧跟使用 rd 的指令需插 1 拍 stall）——接口已就位，待 hazard_ctrl 实现时直接消费
- **异常写回抑制**：未来 load 触发页故障/非对齐时，该指令不得写回寄存器——异常信号需一路透传到 WB 并与 `reg_write` 协同抑制写回（当前不实现，预留规划）
- **forwarding**：`mem_wb.o_read_data` 作为 forwarding 源之一（旁路到 EX 操作数 MUX）
- **总线接口**：data_mem 替换为 AXI4-Lite / Wishbone 从设备接口，支持外部存储器
- **Cache**：在 MMU 与总线之间插入 D-Cache
- **异常**：非对齐访存输出 misaligned 信号；页故障异常处理
- **字节序 / 多通道**：如未来支持 RV64 或 C 扩展，调整 lane 逻辑
