# Verilog CPU 项目概要

在 Xilinx XC7A35T FPGA 上实现 5 级流水线 RISC-V CPU 并最终启动 Linux。

## 项目目标（路线图）

1. RV32I + pipeline control（当前）
2. RV32MA + Zicsr + Zifencei
3. M/S/U 特权级
4. MMU（Sv32）
5. openSBI → 启动 Linux kernel

## 当前进度

**已实现（`verilator --lint-only -Isrc/rtl/defines <file>` 全部通过；`src/rtl/top_core.v` 为顶层可整体编译）：**
- Resources：`pc.v`、`regfile.v`（x0 硬连线为 0）
- IF：`pc_next.v`（`branch_valid > stall > pc+4` 优先级）、`inst_mem.v`（ROM）、`if_id.v`
- ID：`decode.v`（字段提取 + 立即数 + 控制信号，**控制信号唯一来源**，含 flat `alu_opcode`）、`id_ex.v`（150 位，stall 语义=灌 NOP，不存原始 funct3/funct7）
- EX：`executor.v`（操作数 MUX + 并行恒算单元 + Branch Unit）、`alu.v` + `alu_arith/bit/cmp` 三子单元（**op_pair_\* 已废弃**，改由 `alu_src_a[1:0]`/`alu_src` 信号选操作数）
- MEM：`ex_mem.v`（109 位）、`data_mem.v`（字数组、组合读、$readmemh 预载；MMU 预留：`i_addr` 语义=物理地址）
- WB：`mem_wb.v`（104 位）、`wb.v`（`wb_src[1:0]` 三选一：ALU/MEM/pc+4）
- Pipeline Ctrl：`flow_ctrl.v`（分支重定向 + 两级 flush，纯组合扇出）、`hazard_ctrl.v`（方案 A：动态 RAW stall，无 forwarding）
- 头文件：`src/rtl/defines/{const,opcode,alu_op}_define.vh`

**待办：** testbench（`src/tbsim/` 占位）、forwarding（方案 B，hazard_ctrl.md 已设计未实现）、MMU（Sv32）、CSR/异常

## 工作流程（必须遵守）

每个模块严格按 **设计文档 → 用户审阅 → Verilog 代码** 三步走：

1. 写 `design_doc/rtl/.../<module>.md` 设计描述 → **停止，等待用户确认**
2. 用户明确确认（如"可以开始写 .v"、"通过"）后 → 写 `.v`
3. 用 `verilator --lint-only -Isrc/rtl/defines <file>.v` 检查语法

**核心约束：同一轮对话中完成步骤 1 后必须停止，绝不连续执行步骤 2。**
禁止在 `.v` 中添加 `.md` 未定义的端口/信号；发现设计问题先改 `.md` 再改 `.v`。

设计文档与源码目录镜像：`design_doc/rtl/stage/<stage>/<module>.md` ↔ `src/rtl/stage/<stage>/<module>.v`。

### 设计文档内容要素（每个 `<module>.md` 必须覆盖）

1. **概述** — 模块职责、在流水线中的位置
2. **端口定义** — 输入/输出表，含信号名、宽度、来源/去向、说明
3. **功能描述** — 核心行为（逻辑公式、优先级、边界条件）
4. **实现要点** — 组合/时序、复位策略、综合注意事项
5. **接口时序** — 关键路径，与其他模块的交互
6. **未来扩展** — 预留接口和待完善项

### 代码实现时的约束

- 严格按照设计文档的端口和功能编写 `.v`
- **禁止在 `.v` 中添加 `.md` 未定义的端口、信号或功能**；发现需求缺失先回退改 `.md`，用户确认后再改 `.v`
- 发现设计问题时**先改 `.md` 再改 `.v`**，保持文档与代码一致
- 涉及新常量时，同步更新 `const_define.vh`

## 编码规范

- 头文件 `include` 只写文件名不带路径（如 `` `include "const_define.vh" ``）；仿真手动加 `-Isrc/rtl/defines`；头文件用 `ifndef/define/endif` 防重
- **所有数值字面量必须用 `` `define `` 宏，模块内禁止裸数字**（无例外）；宽度派生用 `localparam` 从宏计算（如 `$clog2`）
- 地址索引从宏派生的 `localparam` 计算，不写死 bit 范围（如 `localparam ADDR_HI = ADDR_LO + $clog2(DEPTH) - 1`），使模块随宏修改自动适配
- 端口命名：input 前缀 `i_`，output 前缀 `o_`；每行一个信号并注释来源/去向
- 模块内组织顺序：localparam → 寄存器声明 → initial → assign → always_comb/always_ff
- 组合逻辑优先 `assign`/`?:` 链；`always_comb` 分支必须完整覆盖（防锁存器）
- 仿真专用代码用 `` `ifdef VERILATOR `` / `` `ifdef SIMULATION `` 包裹；Xilinx 综合属性（如 `(* ram_style = "block" *)`）以注释保留
- 每个 `.v` 顶部写标准文件头注释（模块名 + 一句话职责 + 关键行为）

## 总体架构

经典 5 级流水线，数据通路与控制通路分离：

```
        Resources (pc.v, regfile.v)
              ↑              ↑
  IF → ID → EX → MEM → WB  ─┘
        ↑
  Pipeline Control (flow_ctrl.v, hazard_ctrl.v)
```

| 区域 | 模块 |
|------|------|
| Resources | `pc.v`（存/更新 PC）、`regfile.v`（32 寄存器，双读单写，x0 硬连线为 0） |
| IF | `pc_next.v`（branch_valid > stall > pc+4）、`inst_mem.v`（ROM）、`if_id.v` |
| ID | `decode.v`（字段提取 + 立即数 + 控制信号，**控制信号唯一来源**，含 flat `alu_opcode`）、`id_ex.v`（150 位，不存原始 funct3/funct7，stall 灌 NOP） |
| EX | `executor.v`（操作数 MUX：`alu_src_a[1:0]` 选 rs1/pc/0、`alu_src` 选 rs2/imm；pc+4/pc+imm/JALR 恒算单元；Branch Unit 用 `branch_sel[1:0]` 零译码判定）、`alu.v`（arith/bit/cmp 三子单元 + MUX） |
| MEM | `ex_mem.v`、`data_mem.v`（字数组、组合读；`i_addr`=物理地址，MMU 插在 ex_mem 之后） |
| WB | `mem_wb.v`、`wb.v`（`wb_src[1:0]` 三选一写回 regfile；pc 更新由控制面独立完成，双写解耦） |
| Pipeline Ctrl | `flow_ctrl.v`（分支重定向/flush/PC 重定向）、`hazard_ctrl.v`（方案 A 动态 RAW stall；未来加 forwarding/load-use） |

## 设计原则

1. **数据通路与控制通路分离**：数据模块只算数据，控制模块只产生控制信号
2. **控制信号 ID 阶段集中生成**：decode.v 一次性译码，经流水线寄存器透传，EX/MEM/WB 不二次解码
3. **共享资源独立**：PC 和 RegFile 不属于任何流水线级
4. **流水线控制独立**：hazard/flow 由独立模块处理，执行模块不得直接 stall/flush
5. **可扩展**：预留 M 扩展、CSR、异常、中断、MMU、Cache 扩展空间
6. **无条件并行计算、消费端门控**：EX 各运算单元恒算，结果是否生效由消费端（reg_write / branch_valid）决定

## Notes

- 修改架构前先更新 `design_doc/design.md`；参考原理图 `verilog_cpu.drawio.xml`
- 详细架构规范见 `design_doc/design.md`、路线图见 `README.md`
- testbench 尚未实现（`src/tbsim/` 占位）；`.reasonix/` 已 gitignore
