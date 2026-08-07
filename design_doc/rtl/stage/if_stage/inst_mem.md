# inst_mem.v 实现描述

## 概述

`inst_mem.v` 是 IF Stage 的指令存储器模块。接收来自 `pc.v` 的取指地址，在单周期内返回对应的 32-bit 指令字。

初期实现为 FPGA 片上 Block RAM 构成的 ROM，组合读出（异步读）。未来可替换为 AXI / Wishbone 总线接口以支持外部指令存储器。

## 端口定义

### 输入

| 端口名 | 方向 | 宽度 | 来源 | 说明 |
|--------|------|------|------|------|
| `i_pc` | input | 32 | `pc.v` | 取指地址（字节地址） |

### 输出

| 端口名 | 方向 | 宽度 | 去向 | 说明 |
|--------|------|------|------|------|
| `o_instruction` | output | 32 | `if_id.v` | 取出的 32-bit 指令字 |

## 功能描述

### 地址到指令的映射

```
o_instruction = memory[i_pc[31:2]]   // 按 32-bit 字索引
```

- 输入地址 `i_pc` 是字节地址，RV32I 指令固定 4 字节对齐
- 取字地址 = `i_pc[31:2]`，低 2 bit 用于索引字内字节（指令情景下恒为 2'b00）
- 输出为对应地址处的 32-bit 指令

### 地址非对齐处理

RISC-V 规范要求：若 `i_pc[1:0] != 2'b00`，应触发 **Instruction Address Misaligned 异常**。

当前实现为简化设计阶段：
- **Verilog RTL**：直接使用 `i_pc[31:2]` 索引，综合后硬件忽略低 2 bit
- **仿真防御**：在 `always_comb` 中加入 `assert (i_pc[1:0] == 2'b00) else $error(...)`，捕获软件的非对齐跳转 bug
- **未来**：异常机制就绪后，改为输出 misaligned 异常信号至 pipeline control，而非静默忽略

这一简化在正常程序中无影响（编译器生成的代码天然对齐），但若分支目标计算错误，仿真中的断言能及时暴露问题。
### 存储器组织

| 属性 | 值 |
|------|-----|
| 深度 | 可配置（默认 1024，即 4 KB） |
| 宽度 | 32 bit |
| 读方式 | 组合读出（异步） |
| 存储类型 | FPGA Block RAM（推断为 ROM） |

### 未映射地址行为

当地址超出初始化范围时，`o_instruction` 输出 32'h0（即 `addi x0, x0, 0`，等效于 NOP）。

## 实现要点

1. **Verilog 实现方式**：使用 `$readmemh` 或 `$readmemb` 从外部 hex/bin 文件加载指令。即在仿真和综合时均支持初始化内容。
2. **组合读出**：使用 `assign` 或 `always_comb`，不引入额外时钟延迟。IF Stage 的时序路径为 PC → inst_mem → if_id，时钟频率受这条路径限制。
3. **复位无关**：ROM 在配置/烧录时已固化，无需复位。
4. **综合属性**：对于 Xilinx 工具链，使用 `(* ram_style = "block" *)` 或类似属性引导综合器映射为 Block RAM。

### 参考实现骨架

```verilog
module inst_mem (
    input  wire [31:0] i_pc,
    output wire [31:0] o_instruction
);

    // 1024 × 32-bit ROM
    reg [31:0] rom [0:1023];

    // 初始化（综合时加载，仿真时从文件读取）
    initial begin
        $readmemh("firmware.hex", rom);
    end

    // 组合读出（含非对齐防御检查）
    assign o_instruction = rom[i_pc[31:2]];

    // 仿真断言：非对齐取指地址
    `ifdef SIMULATION
    always_comb begin
        if (i_pc[1:0] != 2'b00)
            $error("inst_mem: misaligned instruction fetch at pc=0x%h", i_pc);
    end
    `endif

endmodule
```

## 接口时序

```
     i_pc          ────[addr]────
                       │
                       ▼  (组合读出)
     o_instruction ────[inst]────
```

`i_pc` 变化后，`o_instruction` 经过 Block RAM 的读出延迟（典型 ~1-2 ns，取决于 FPGA 型号）后稳定。在目标频率（如 50-100 MHz）下，20 ns 周期内可完成读出并满足 if_id 的建立时间。

## 与架构的关系

- 属于 IF Stage，详见 [if_stage.md](../if_stage.md)
- PC 地址来自 `pc.v`，读出的指令送入 `if_id.v`
- 当前为同步设计的纯组合路径：`pc.v`（寄存器输出）→ `inst_mem.v`（组合）→ `if_id.v`（寄存器输入）

## 未来扩展

- **总线接口**：将内部 ROM 替换为 AXI4-Lite / Wishbone 主设备接口，从外部存储器取指
- **指令 Cache**：在 `inst_mem.v` 和总线之间插入 I-Cache 模块，减少取指延迟
- **MMU 地址转换**：Sv32 模式下，`i_pc` 需先经过 TLB/MMU 转换为物理地址后再访存
- **多字节加载**：若未来支持 C 扩展（16-bit 压缩指令），需要处理非对齐的半字读取
