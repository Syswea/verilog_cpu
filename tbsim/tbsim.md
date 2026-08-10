# RISC-V CPU 测试设计（tbsim）

## 1. 概述与目标

本文件定义从 **module 级 → stage 级 → top_core 级** 的分层功能验证方案，
覆盖测试工具链、各模块独立验证要点、整体验证功能集，以及测试程序（firmware）
的生成与自检机制。

设计目标：

1. **先局部后整体**：每个 RTL 模块先有独立 testbench（TB），再组合成
   stage 级集成测试，最后做 `top_core` 全流水线程序级验证。
2. **可回归**：一条命令跑完所有测试（`make test-all`），每个用例有
   明确的 pass/fail 判定。
3. **可观测**：无 UART/GPIO，程序结果通过约定的"自检协议"（寄存器/内存
   magic 值 + PC 停止检测）对外暴露。
4. **低依赖**：只用 verilator + riscv64-unknown-elf-gcc + python3，
   不引入商业仿真器。

### 1.1 当前测试对象（RTL 清单）

| 区域 | 模块 | 类型 |
|------|------|------|
| Resources | `pc.v`、`regfile.v` | 时序 |
| IF | `pc_next.v`（组合）、`inst_mem.v`（组合读）、`if_id.v`（时序） | 混合 |
| ID | `decode.v`（组合）、`id_ex.v`（时序） | 混合 |
| EX | `executor.v`、`alu.v`、`alu_arith.v`、`alu_bit.v`、`alu_cmp.v`（全组合） | 组合 |
| MEM | `ex_mem.v`（时序）、`data_mem.v`（组合读/时序写） | 混合 |
| WB | `mem_wb.v`（时序）、`wb.v`（组合） | 混合 |
| Pipeline Ctrl | `flow_ctrl.v`、`hazard_ctrl.v`（全组合） | 组合 |

> 注：`id_ex.v` 的 stall 语义是**灌 NOP**（非保持）；`if_id.v` / `ex_mem.v` /
> `mem_wb.v` 的 stall 语义是**保持**。TB 必须区分验证。

---

## 2. 工具链

### 2.1 已确认环境

| 工具 | 版本 | 用途 |
|------|------|------|
| verilator | 5.020 | lint + 编译仿真 |
| riscv64-unknown-elf-gcc | 已安装 | 汇编测试程序 → firmware.hex |
| python3 | 3.12 | bin→hex 转换、golden 计算、结果校验 |
| gtkwave（可选） | — | FST 波形查看 |

### 2.2 命令模板（统一进 Makefile）

**语法检查（沿用现有流程，每个 .v 提交前必跑）：**

```bash
verilator --lint-only -Isrc/rtl/defines <file>.v
```

**编译并运行一个 module 级 TB（DUT 与 TB 联合编译）：**

```bash
verilator --cc --binary --assert --timing \
    -Isrc/rtl/defines \
    --top-module tb_xxx \
    --Mdir build/obj_xxx \
    src/tbsim/unit/tb_xxx.v src/rtl/.../<dut>.v \
    -o sim_xxx
./build/obj_xxx/sim_xxx
```

**top_core 级 TB 追加观测选项：**

```bash
verilator --cc --binary --assert --timing --public-flat-rw \
    -Isrc/rtl/defines --top-module tb_top_core \
    --Mdir build/obj_top src/tbsim/top/tb_top_core.v \
    $(find src/rtl -name '*.v') -o sim_top
```

要点：

- `--public-flat-rw`（5.020 中 `--public-flat` 已拆分为此选项）：
  让 TB 内可通过层次引用（如 `dut.u_regfile.rf[i]`、`dut.pc`）读取 DUT
  内部信号，用于程序结束检测与结果断言。
- `--trace-fst`（可选）：生成 FST 波形供 gtkwave 分析。
- TB 统一用 `@(posedge clk)` 事件驱动，不用 `#delay` 硬编码时序
  （`--timing` 仅为兼容 RTL 中可能出现的仿真任务保留）。
- RTL 中已内建 `ifdef VERILATOR` 仿真检查（`inst_mem` 取指对齐、
  `data_mem` 访问对齐的 `$error`），编译时自动生效，作为**非法访问哨兵**。

### 2.3 hex 文件路径约定

`inst_mem.v` / `data_mem.v` 内部用相对路径 `$readmemh("firmware.hex", ...)` /
`$readmemh("data_mem.hex", ...)`，路径相对仿真进程 CWD。因此约定：

- 每个仿真的运行目录为 `src/tbsim/top/run/`（Makefile 负责把生成的
  hex 拷入，并在该目录下启动 `sim_top`）。
- module 级 TB 不依赖 hex（直接驱动端口）；需要预载数据时由 TB 自己
  `$readmemh` 绝对/相对路径，与 RTL 解耦。

### 2.4 测试程序生成流程（top_core 级）

```bash
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib \
    -T link.ld -Wl,--build-id=none -o prog.elf prog.s
riscv64-unknown-elf-objcopy -O binary prog.elf prog.bin
python3 tools/bin2hex.py prog.bin > run/firmware.hex
```

- `link.ld`：`.text` 从 `0x0000_0000` 起；数据（只读表）放
  `0x1000` 之后（对应 `data_mem` 字节地址范围 0x0000~0x03FF）。
- `bin2hex.py`：按 4 字节小端拆 word，每行一个 `%08x`（兼容 `$readmemh`）。
- 数据内存预载：`data_mem.hex` 由测试用例配套提供（每行一个 word）。
- 不用 `riscv-gcc` 的 C 运行时；程序用纯汇编 + `.word` 数据区，
  保证可移植与确定性。

---

## 3. 测试分层策略

```
L0  lint（语法/端口一致性）            —— 已有，持续
L1  module 单元测试（每模块一个 TB）   —— 本方案主体
L2  stage 集成测试（5 级各自闭环）     —— 验证级间连接
L3  top_core 全流水线程序测试          —— 指令覆盖/冒险/分支/内存
L4  系统级（长程序/随机/上板冒烟）     —— 预留，进 forwarding 后增强
```

执行顺序：L1 全绿 → L2 全绿 → L3 全绿。每级完成后跑 `make test-all`
防回归。**任何 RTL 改动后至少重跑受影响模块的 L1 + top 的 F1/F3/F4。**

---

## 4. Module 级验证计划（L1）

### 4.1 需要独立验证的模块与理由

| 模块 | 必要性 | 理由 | 优先级 |
|------|:------:|------|:------:|
| `decode.v` | ★★★ 必须 | 最大最复杂的组合逻辑；控制信号**唯一来源**，一处错全流水线错；立即数 6 种格式 + B/J 位重排最易错 | P0 |
| `alu.v` + `alu_arith/bit/cmp` | ★★★ 必须 | 纯组合、边界值多；signed/unsigned、移位、进位拐点 | P0 |
| `executor.v` | ★★★ 必须 | 操作数 MUX + 恒算单元 + Branch Unit 三者交互；JALR 对齐掩码 | P0 |
| `data_mem.v` | ★★★ 必须 | 字节使能/宽度/符号扩展/lane 对齐最易错；越界语义 | P0 |
| `regfile.v` | ★★★ 必须 | x0 硬连线读写、复位清零、双读单写时序 | P0 |
| `hazard_ctrl.v` | ★★★ 必须 | RAW 命中矩阵可穷举（2 producer × 2 source × x0 过滤） | P0 |
| `pc_next.v` | ★★★ 必须 | 优先级（branch > stall > +4）是正确性关键，回归敏感 | P0 |
| 流水线寄存器 `if_id/id_ex/ex_mem/mem_wb` | ★★★ 必须 | 优先级链 reset>flush>stall>latch 每个都不同（hold vs NOP） | P0 |
| `inst_mem.v` | ★★ 需要 | 地址映射、越界返 NOP、对齐检查 | P1 |
| `flow_ctrl.v` | ★★ 需要 | 纯扇出、逻辑简单，但 taken 时的三输出一致性值得锁定 | P1 |
| `wb.v` | ★★ 需要 | 三选一 MUX + reserved 默认值 | P1 |
| `pc.v` | ★ 可并入 | 单寄存器，并入 IF stage 测试即可 | P2 |

### 4.2 各模块测试要点

**decode.v（P0）** —— golden 对照表驱动：
- 覆盖全部 RV32I 指令模板：R（ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND）、
  I（ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI）、LOAD 6 种、
  STORE 3 种、BRANCH 6 种、LUI/AUIPC/JAL/JALR、SYSTEM/MISC-MEM（NOP 化）。
- 每用例断言完整 12 项输出：`rs1/rs2/rd` 字段、`imm`、`alu_opcode`、
  `alu_src_a`、`alu_src`、`branch_sel`、`mem_read/write/width/sext`、
  `wb_src`、`reg_write`。
- 立即数边界：imm[31]=1（符号扩展）、全 1、全 0；SLLI/SRLI/SRAI 的
  shamt 与 funct7 校验（funct7[5] 决定 SRLI/SRAI）；B 型位重排
  （inst[31|7|30:25|11:8]）；J 型位重排（inst[31|19:12|20|30:21]）。
- SUB vs ADD（funct7=0100000）、SRA vs SRL 判别。
- 非法/未定义指令 → 全默认 NOP 值（`reg_write=0`、`alu_opcode=ALU_NOP`…）。
- 组合特性：输入变化 → 输出同拍变化（无寄存器）。

**alu.v + 子单元（P0）**：
- 每 opcode × 边界操作数集：`0`、`1`、`-1(0xFFFFFFFF)`、
  `0x8000_0000`、`0x7FFF_FFFF`、随机值。
- ADD/SUB 进位/借位拐点；SLL/SRL/SRA 的 shamt = 0/1/5/31；
  SRA 对 `0x8000_0000` 符号填充；SLT/SLTU 用 `0x8000_0000` vs
  `0x7FFF_FFFF` 区分 signed/unsigned；EQ/NE/GE/GEU 边界。
- `ALU_NOP`(15) 与保留码(14) → 输出 0；未列 opcode 落入 0。
- 三个子单元独立验证（`alu_arith`/`alu_bit`/`alu_cmp` 各自 TB），
  再验 `alu.v` 的 MUX 分配正确。

**executor.v（P0）**：
- `alu_src_a`：RS1/PC/ZERO 三选一；`alu_src`：rs2/imm 二选一。
- 恒算单元：`pc+4`、`pc+imm`、`(rs1+imm)&~1` 三路并行正确性
  （对 JALR 重点测 rs1+imm 低位为 1 的对齐，如 target=0x...5）。
- Branch Unit：`branch_sel=NONE` → taken=0；`COND` → taken=alu_result[0]
  （用 BEQ 相等/不相等各一）；`JAL/JALR` → taken 恒 1；
  `o_branch_target` 按 JALR/其他二选一。
- 控制信号透传（8 项）与 `rd_addr`/`rs2_data` 直通。

**data_mem.v（P0）**：
- 写后读闭环：SB/SH/SW 分别写入地址 0/1/2/3（byte lane 全覆盖），
  再 LB/LH/LW/LBU/LHU 读回，验证字节使能 `be` 与 lane 位移。
- 符号扩展：写入 `0x80` 于 byte，LBU=0x80 / LB=0xFFFFFF80；
  `0x8000` 于 half，LHU / LH 同理。
- 同一 word 多次部分写（SH 高/低半 + SB 单字节）不互相破坏。
- 越界（addr ≥ 1024）：读 0、写忽略；`addr_in_range` 判定。
- 对齐：SH 奇地址 / SW 非 4 对齐 → 触发 `$error`（仿真哨兵，不判 fail，
  由 TB 单独测"合法访问不触发"）。

**regfile.v（P0）**：
- 复位后全部为 0；写 `rf[i]` 后组合读回（同拍写后读——注意是
  上升沿写入，TB 需在写拍之后一拍读）。
- x0：读恒 0；写 x0 被忽略（rf[0] 保持 0）。
- 双读端口独立；写端口与读端口并发无冲突。

**hazard_ctrl.v（P0）** —— 穷举矩阵：
- producer = ex_mem / mem_wb × source = rs1 / rs2 → 4 类命中各 1 例。
- 过滤条件：`reg_write=0` 不 stall；`rd=x0` 不 stall；rd≠rs1/rs2 不 stall。
- 双命中（rd 同时等于 rs1 与 rs2）→ stall=1（或 逻辑或）。
- 无依赖 → stall=0（关键：相邻两条无依赖指令不得误 stall）。

**pc_next.v（P0）**：
- 优先级三态穷举：branch_valid=1 & stall=1 → target（branch 优先）；
  stall=1 → 保持 pc；默认 → pc+4。

**流水线寄存器（P0）**：
- 每个寄存器分别验证优先级链 `reset > flush > stall > latch`：
  - `if_id`：stall=保持（指令与 pc 冻结）。
  - `id_ex`：stall=灌 NOP（全部输出清为安全默认值，**非保持**）。
  - `ex_mem` / `mem_wb`：stall=保持（top 中未接，但端口语义要锁死）。
- flush：清控制（`reg_write=0`、`mem_write=0`、`branch_sel=NONE`…）。
- 异步复位 `i_rst_n=0` 任意时刻清零。
- 数据通路字段逐位通过性（全 1/全 0/随机模式）。

**inst_mem.v（P1）**：
- pc=0 / pc=0xFFC（末字）/ 越界 pc=0x1000+ → 0（NOP）；
- 取指对齐：pc[1:0]≠0 → `$error`（合法性由 IF 侧保证，此处只验不误报）。

**flow_ctrl.v（P1）**：
- taken=1 → `branch_valid=1`、`branch_target` 直通、双 flush=1；
- taken=0 → 全 0。

**wb.v（P1）**：
- `wb_src` = ALU / MEM / PC_PLUS4 三选一 + 保留值 2'b11 → ALU（安全默认）；
- `rd_addr` / `reg_write` 直通。

**pc.v（P2）**：并入 IF stage 测试。

---

## 5. Stage 级集成测试（L2）

按流水线级把"组合逻辑 + 流水线寄存器 + 资源"闭环，验证**连接与
stall/flush 布线**（单模块 TB 覆盖不到的跨模块路径）：

| 级 | 组合 | TB 内例化 |
|----|------|-----------|
| IF | `pc_next + pc + inst_mem + if_id` | 驱动 branch/stall/flush，检查 `if_id` 输出与 PC 演化 |
| ID | `if_id + decode + regfile + id_ex` | 驱动指令流，检查解码 → 寄存器读 → 锁存 |
| EX | `id_ex + executor` | 驱动控制总线，检查 ALU/分支/透传 |
| MEM | `ex_mem + data_mem` | 驱动读写，检查存储语义 |
| WB | `mem_wb + wb + regfile` | 回写路径闭环：写使能 → 寄存器值 |

L2 复用 L1 的驱动向量，重点断言**级间信号名/宽度/时序对齐**，
并锁定 `id_ex` 灌 NOP 与 `if_id` 保持的联合行为。

---

## 6. top_core 整体验证（L3）

### 6.1 自检协议（无外部 IO 下的结果暴露）

程序运行结束约定（所有测试程序遵守）：

1. 结果写入约定位置：寄存器 `x10`（a0）**且** 内存地址 `0x1000`
   （data_mem 范围内）写 magic 结果值；
2. 程序末尾执行 `1: j 1b` 死循环（PC 停在约定区域）；
3. TB 通过 `--public-flat-rw` 层次引用检测：**PC 连续 2 拍不变** → 判定
   程序结束，然后断言 `dut.u_regfile.rf[10]` 与
   `dut.u_data_mem.mem[0x1000>>2]` 等于 golden；
4. 超时保护：`$time > TIMEOUT`（默认 200k 周期）→ fail，dump 波形；
5. 运行期间 RTL 的 `$error`（对齐违规等）自动判 fail。

### 6.2 功能测试集（F1–F7）

| 组 | 名称 | 覆盖内容 | 判定 |
|----|------|----------|------|
| F1 | 基础指令覆盖 | 全部 RV32I 指令模板各 ≥1 次：R/I 算术逻辑移位、LUI/AUIPC、LOAD/STORE 全宽、BRANCH 全 6 种、JAL/JALR；结果写 x10 | 寄存器 golden |
| F2 | 数据通路链 | 长 ALU 依赖链（相邻/间隔 RAW）、无依赖并行指令交错、立即数大值 | 寄存器 golden |
| F3 | 冒险（RAW） | 相邻依赖（stall 3 拍）、间隔 1/2 拍、x0 不 stall、load-use、连续 load-use 链、写后写/读后写不误 stall | 寄存器 golden + TB 统计 stall 拍数（`dut.hc_stall` 计数） |
| F4 | 分支 | taken/not-taken 各 ≥2、前向/后向偏移、偏移边界（±4KB、±1MB）、JAL 链接值=pc+4、JALR 目标对齐 & x0 链接、分支后紧跟分支（双 flush 正确）、分支与 RAW stall 同时发生（branch 优先） | 寄存器 golden + PC 序列 |
| F5 | 数据内存 | SB/SH/SW 全 lane 写 + LB/LH/LW/LBU/LHU 回读、同 word 部分写、边界地址 0/1023、越界访问（读 0 写忽略）、data_mem.hex 预载回读 | 内存 dump 比对 |
| F6 | 算法压力 | 阶乘、Fibonacci（golden 已知）、循环累加、位操作算法（popcount 等） | 寄存器 golden |
| F7 | 复位/时序 | 复位后前 4 拍无任何 regfile 写副作用（`reg_write` 全 0）；复位后启动 F1 | 波形 + 断言 |

### 6.3 观测点与覆盖率统计

- 层次引用观测：`dut.pc`、`dut.hc_stall`（stall 计数）、
  `dut.fc_flush_if_id`（flush 计数）、`dut.u_regfile.rf[*]`、
  `dut.u_data_mem.mem[*]`。
- 覆盖率清单（人工核对，不做工具覆盖率）：
  每条指令模板 ≥1 次；每个分支类型取/不取各 ≥1；每条 RAW 距离
  （相邻/1/2 拍）≥1；load-use ≥1；flush 路径 ≥1。

---

## 7. 目录结构与文件清单

```
src/tbsim/
├── Makefile                  # 统一入口：lint / unit / stage / top / test-all / clean
├── common/
│   └── tb_util.vh            # 公共宏：时钟生成、结束检测、断言辅助
├── unit/                     # L1：每模块一个 TB（tb_<module>.v）
│   ├── tb_decode.v  tb_alu.v  tb_alu_arith.v  tb_alu_bit.v  tb_alu_cmp.v
│   ├── tb_executor.v  tb_data_mem.v  tb_inst_mem.v  tb_regfile.v
│   ├── tb_hazard_ctrl.v  tb_flow_ctrl.v  tb_pc_next.v  tb_wb.v  tb_pc.v
│   └── tb_if_id.v  tb_id_ex.v  tb_ex_mem.v  tb_mem_wb.v
├── stage/                    # L2
│   ├── tb_if_stage.v  tb_id_stage.v  tb_ex_stage.v  tb_mem_stage.v  tb_wb_stage.v
├── top/                      # L3
│   ├── tb_top_core.v
│   ├── programs/
│   │   ├── f1_base.s  f2_deps.s  f3_hazard.s  f4_branch.s  f5_mem.s
│   │   ├── f6_alg.s  f7_reset.s  link.ld
│   │   └── data_mem.hex       # 测试数据预载（含 magic 结果区）
│   └── run/                   # 运行目录（firmware.hex 生成于此，sim 在此启动）
└── tools/
    ├── bin2hex.py             # binary → verilog hex（每行一个 32 位 word）
    └── check_results.py       # 可选：dump 结果 vs golden
```

### 7.1 设计文档镜像（design_doc/tbsim/）

按"设计文档与源码目录镜像"的约定，`design_doc/tbsim/` 下已建好
与 `src/tbsim/` 一一对应的测试文件夹（当前以 `.gitkeep` 占位，
后续每个测试的设计文档 `<test>.md` 写入对应文件夹）：

```
design_doc/tbsim/
├── tbsim.md                  # 本文件：总体测试设计
├── iteration_log.md          # 迭代日志：每次迭代的错误与修复记录
├── unit/                     # L1：每模块一个测试设计文件夹（18 个）
│   ├── tb_decode/  tb_alu/  tb_alu_arith/  tb_alu_bit/  tb_alu_cmp/
│   ├── tb_executor/  tb_data_mem/  tb_inst_mem/  tb_regfile/
│   ├── tb_hazard_ctrl/  tb_flow_ctrl/  tb_pc_next/  tb_wb/  tb_pc/
│   └── tb_if_id/  tb_id_ex/  tb_ex_mem/  tb_mem_wb/
├── stage/                    # L2：每级一个测试设计文件夹（5 个）
│   └── tb_if_stage/  tb_id_stage/  tb_ex_stage/  tb_mem_stage/  tb_wb_stage/
└── top/                      # L3：整体测试设计文件夹（1 个）
    └── tb_top_core/
```

每个 `<test>.md` 设计文档内容要素（与 RTL 设计文档同等要求）：
1. **概述** — 被测模块/测试目标、测试分层中的位置
2. **测试环境** — 例化关系、激励来源、时钟/复位策略
3. **用例清单** — 每个用例的输入向量、预期输出（golden）、判定方式
4. **断言与哨兵** — pass/fail 判定、`$error`/`$fatal` 使用、超时保护
5. **验收标准** — 该测试通过的定义
6. **未来扩展** — 预留用例（forwarding、MMU、CSR 等）

---

## 8. 执行与验收标准

| 检查 | 命令 | 通过标准 |
|------|------|----------|
| 全部 RTL lint | `make lint` | 每个 `.v` `--lint-only` 零错误 |
| L1 单元测试 | `make unit` | 所有 tb_*.v 编译运行，exit 0 |
| L2 集成测试 | `make stage` | 同上 |
| L3 程序测试 | `make top` | F1–F7 全部 pass（自检协议 + golden） |
| 全量回归 | `make test-all` | 以上全绿 |

**完成定义（DoD）**：L1–L3 全绿；F1–F7 覆盖清单逐项勾选；
任一 RTL 改动后对应 L1 与 top 回归通过。

---

## 9. 未来扩展

- **forwarding（方案 B）落地后**：F3 增加"stall 拍数减少"断言
  （stall 只发生在 load-use）；hazard_ctrl 测试补 forwarding 旁路矩阵。
- **MMU（Sv32）**：`data_mem`/`inst_mem` 测试扩展虚拟→物理地址用例；
  F5 增加地址空间测试；`i_addr` 语义变化时 L2 MEM 级同步更新。
- **CSR/异常**：新增指令覆盖组；`wb_src` 保留码 2'b11（CSR 读）用例。
- **RV32M**：`alu` 增加 mul/div 子单元测试组。
- **上板前**：`make top` 基础上做综合时序检查 + LED 冒烟程序
  （死循环 + 内存递增写，板级可观测）。
