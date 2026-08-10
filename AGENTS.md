# Verilog CPU 项目概要

在 Xilinx XC7A35T FPGA 上实现 5 级流水线 RISC-V CPU 并最终启动 Linux。

## 项目目标（路线图）

1. RV32I + pipeline control（当前）
2. RV32MA + Zicsr + Zifencei
3. M/S/U 特权级
4. MMU（Sv32）
5. openSBI → 启动 Linux kernel

## 当前进度

**已实现（`verilator --lint-only -Isrc/rtl/defines <file>` 全部通过）：**
- Resources：`src/rtl/resources/pc.v`、`regfile.v`
- IF：`src/rtl/stage/if_stage/pc_next.v`、`inst_mem.v`、`src/rtl/pipeline_reg/if_id.v`
- ID：`src/rtl/stage/id_stage/decode.v`、`src/rtl/pipeline_reg/id_ex.v`
- 头文件：`src/rtl/defines/{const,opcode,alu_op}_define.vh`

**空占位文件（已建未实现）：** `top_core.v`、`flow_ctrl.v`（均在 `src/rtl/pipeline_*` 下）；`ex_mem.v`、`mem_wb.v` 已实现

**尚未开始：** EX 全部（executor/alu*/op_pair_*）、`data_mem.v`、`wb.v`

## 工作流程（必须遵守，详见 coding.md）

每个模块严格按 **设计文档 → 用户审阅 → Verilog 代码** 三步走：

1. 写 `design_doc/rtl/.../<module>.md` 设计描述 → **停止，等待用户确认**
2. 用户明确确认（如"可以开始写 .v"、"通过"）后 → 写 `.v`
3. 用 `verilator --lint-only -Isrc/rtl/defines <file>.v` 检查语法

**核心约束：同一轮对话中完成步骤 1 后必须停止，绝不连续执行步骤 2。**
禁止在 `.v` 中添加 `.md` 未定义的端口/信号；发现设计问题先改 `.md` 再改 `.v`。

设计文档与源码目录镜像：`design_doc/rtl/stage/<stage>/<module>.md` ↔ `src/rtl/stage/<stage>/<module>.v`。

## 编码规范

- 头文件 `include` 只写文件名不带路径（如 `` `include "const_define.vh" ``）；仿真手动加 `-Isrc/rtl/defines`；头文件用 `ifndef/define/endif` 防重
- **所有数值字面量必须用 `` `define `` 宏，模块内禁止裸数字**（无例外）；宽度派生用 `localparam` 从宏计算（如 `$clog2`）
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
| IF | `pc_next.v`（stall > branch > pc+4 优先级）、`inst_mem.v`（ROM）、`if_id.v` |
| ID | `decode.v`（字段提取 + 立即数 + 控制信号，**控制信号唯一来源**，含 flat `alu_opcode`）、`id_ex.v`（147 位，不存原始 funct3/funct7） |
| EX | `executor.v`（ALU + Branch Unit，纯数据通路不译码）、`op_pair_*`（固定 (rs1,rs2)/(rs1,imm)/(pc,imm)）、`alu.v`（arith/bit/cmp 三子单元 + MUX） |
| MEM | `ex_mem.v`、`data_mem.v` |
| WB | `mem_wb.v`、`wb.v`（选写回源写 regfile） |
| Pipeline Ctrl | `flow_ctrl.v`（分支重定向/flush/PC 重定向）、`hazard_ctrl.v`（stall；未来加 forwarding/load-use） |

## 设计原则

1. **数据通路与控制通路分离**：数据模块只算数据，控制模块只产生控制信号
2. **控制信号 ID 阶段集中生成**：decode.v 一次性译码，经流水线寄存器透传，EX/MEM/WB 不二次解码
3. **共享资源独立**：PC 和 RegFile 不属于任何流水线级
4. **流水线控制独立**：hazard/flow 由独立模块处理，执行模块不得直接 stall/flush
5. **可扩展**：预留 M 扩展、CSR、异常、中断、MMU、Cache 扩展空间

## Notes

- 修改架构前先更新 `design_doc/design.md`；参考原理图 `verilog_cpu.drawio.xml`
- 详细规范见 `coding.md`（工作流 + 编码规范全集）、`README.md`（路线图）
- 暂无 testbench/仿真工程；`.reasonix/` 已 gitignore
