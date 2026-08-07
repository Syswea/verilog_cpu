# Verilog CPU 项目概要

## 项目目标

实现一个 **5 级流水线 RISC-V CPU**（Verilog），最终在 Xilinx XC7A35T FPGA 上启动 Linux。

- 当前 ISA：RV32I
- 未来扩展：RV32IMA、Zicsr、Zifencei
- 特权级：M / S / U
- MMU：Sv32

## 总体架构

经典 5 级流水线，数据通路与控制通路分离：

```
        Resources (pc.v, regfile.v)
              ↑              ↑
  IF → ID → EX → MEM → WB  ─┘
        ↑
  Pipeline Control (flow_control.v, hazard_control.v)
```

## 模块清单

### Resources（全局共享）
| 文件 | 职责 |
|------|------|
| `pc.v` | 存储/更新 PC，接收 pc_next |
| `regfile.v` | 32 个整数寄存器，双读口 + 单写口 |

### IF Stage
| 文件 | 职责 |
|------|------|
| `pc_next.v` | 计算下一条 PC（含分支重定向、stall） |
| `inst_mem.v` | 指令存储器（ROM/Bus） |
| `if_id.v` | IF/ID 流水线寄存器（存指令，未来加 pc/pc+4） |

### ID Stage
| 文件 | 职责 |
|------|------|
| `decode.v` | 统一译码模块：字段提取 + 立即数生成 + 控制信号生成（含 ALU 操作码），为控制信号唯一来源 |
| `id_ex.v` | ID/EX 流水线寄存器（寄存器值 + 立即数 + 控制信号） |

### EX Stage
| 文件 | 职责 |
|------|------|
| `executor.v` | 执行单元（ALU + Branch Unit） |
| `op_pair_rs1_rs2.v` | 操作数对模块：固定产出 (rs1_data, rs2_data) |
| `op_pair_rs1_imm.v` | 操作数对模块：固定产出 (rs1_data, imm) |
| `op_pair_pc_imm.v` | 操作数对模块：固定产出 (pc, imm) |
| `alu_arith.v` | 整型算术单元（ADD / SUB） |
| `alu_bit.v` | 位运算 + 移位单元（SLL/SRL/SRA/XOR/OR/AND） |
| `alu_cmp.v` | 比较单元（SLT/SLTU/EQ/NE/GE/GEU） |
| `alu.v` | 顶层 ALU 选择器（实例化上述 3 个 + MUX） |

### MEM Stage
| 文件 | 职责 |
|------|------|
| `ex_mem.v` | EX/MEM 流水线寄存器（ALU 结果、目标寄存器、地址、控制） |
| `data_mem.v` | 数据存储器（load/store） |

### WB Stage
| 文件 | 职责 |
|------|------|
| `mem_wb.v` | MEM/WB 流水线寄存器 |
| `wb.v` | 写回阶段，选择写回源，写入 regfile |

### Pipeline Control
| 文件 | 职责 |
|------|------|
| `flow_control.v` | 分支重定向、流水线 flush、PC 重定向 |
| `hazard_control.v` | 流水线 stall，控制所有流水线寄存器；未来处理 RAW/forwarding/load-use |

## 设计原则

1. **数据通路与控制通路分离**：数据模块只算数据，控制模块只产生控制信号。
2. **控制信号 ID 阶段集中生成**：所有控制信号在 ID 阶段一次性译码完成（含 ALU 操作码），经流水线寄存器透传至后续阶段，EX/MEM/WB 不再进行控制信号的二次解码。
3. **共享资源独立**：PC 和 RegFile 不属于任何流水线级。
4. **流水线控制独立**：hazard/flow 控制由独立模块处理，执行模块不应直接 stall/flush。
5. **可扩展**：架构设计预留了 M 扩展、CSR、异常、中断、MMU、Cache 的扩展空间。

## 开发约定

- 按上述架构增量实现各 Verilog 模块
- 修改架构前先更新 [design_doc/design.md](design_doc/design.md)
- 参考原理图：[verilog_cpu.drawio.xml](verilog_cpu.drawio.xml)
