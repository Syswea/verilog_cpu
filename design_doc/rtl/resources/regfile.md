## regfile.v

### 概述

`regfile.v` 实现 32 个整数寄存器（x0–x31），提供**双读口 + 单写口**。读操作为组合逻辑，写操作为时序逻辑（同步写）。

- 读口：由 ID Stage 驱动，读取 `rs1`、`rs2` 对应寄存器的值
- 写口：由 WB Stage 驱动，在时钟上升沿写入结果

x0 寄存器硬连线为 0，任何写入 x0 的操作被忽略，读 x0 始终返回 0。

### 端口定义

**输入**

| 端口名 | 方向 | 宽度 | 来源 | 说明 |
|--------|------|------|------|------|
| `i_clk` | input | 1 | 全局时钟 | 系统时钟 |
| `i_rst_n` | input | 1 | 全局复位 | 异步复位，低有效 |
| `i_rs1_addr` | input | `` `REG_ADDR_WIDTH `` | `decode.v`（ID Stage） | 读口 1 寄存器地址 |
| `i_rs2_addr` | input | `` `REG_ADDR_WIDTH `` | `decode.v`（ID Stage） | 读口 2 寄存器地址 |
| `i_rd_addr` | input | `` `REG_ADDR_WIDTH `` | WB Stage（经 `mem_wb.v`） | 写目标寄存器地址 |
| `i_rd_data` | input | `` `XLEN `` | WB Stage（经 `mem_wb.v`） | 写数据 |
| `i_we` | input | 1 | WB Stage（经 `mem_wb.v`） | 写使能，高有效 |

**输出**

| 端口名 | 方向 | 宽度 | 去向 | 说明 |
|--------|------|------|------|------|
| `o_rs1_data` | output | `` `XLEN `` | `id_ex.v`（ID Stage） | rs1 读出值 |
| `o_rs2_data` | output | `` `XLEN `` | `id_ex.v`（ID Stage） | rs2 读出值 |

### 功能描述

**读操作（组合逻辑）**：

```
o_rs1_data ← regfile[i_rs1_addr]   （i_rs1_addr == 0 时返回 0）
o_rs2_data ← regfile[i_rs2_addr]   （i_rs2_addr == 0 时返回 0）
```

**写操作（时序逻辑）**：

```
always_ff @(posedge i_clk):
  if (i_we && i_rd_addr != 0):  regfile[i_rd_addr] ← i_rd_data
```

**x0 硬连线**：

- 读地址 0 时，输出直接硬连线为 `` `XLEN_ZERO ``，不经过寄存器阵列读口。
- 写地址 0 时，忽略写入，寄存器阵列第 0 项始终保持 0。

**复位行为**：复位时所有寄存器清零（x0 本身即保持为 0）。

### 实现要点

1. **读为组合逻辑**：不需要时钟沿，ID Stage 可在一个周期内获取操作数。
2. **写为时序逻辑**：同步写保证写回与读出的时序隔离，避免同一周期读写冲突。
3. **x0 特殊处理**：
   - 读：直接 bypass 寄存器阵列，输出 `` `XLEN_ZERO ``。
   - 写：`i_rd_addr == 0` 时写使能被门控，不产生写操作。
4. **综合属性**：实际综合时可根据 FPGA 资源选择 distributed RAM 或 block RAM。
   ```verilog
   // (* ram_style = "distributed" *)
   ```
   distributed RAM 适合 32×32 的小型寄存器文件，读写延迟低。
5. **无转发逻辑**：regfile 自身不处理 RAW 冒险，转发由 `hazard_control.v` 中的 forwarding 逻辑在 ID Stage 侧完成。

### 接口时序

**读时序**（组合路径）：

```
     i_rs1_addr  ───[A]────────────[B]───
     o_rs1_data  ───[reg[A]]───────[reg[B]]
```

读地址变化后，数据在组合路径延迟后稳定，**同一周期内可用**。

**写时序**（同步）：

```
         clk
     ─────┴─────┴─────┴─────
     i_we        ──1────0────
     i_rd_addr   ──[C]───────
     i_rd_data   ──[D]───────
                    │
                    ▼  (时钟沿写入)
     regfile[C]  ──[D]───────
```

### 内部存储

使用二维寄存器阵列：

```verilog
reg [`XLEN-1:0] rf [`REG_COUNT-1:0];
```

索引通过 `localparam` 从宏派生，不使用裸数字。

### 与架构的关系

- **读口**被 ID Stage 使用（`decode.v` 提供地址），读出值进入 `id_ex.v`
- **写口**被 WB Stage 使用，数据来自 `wb.v`，经 `mem_wb.v` 传入
- regfile 是全局共享资源，不隶属于任何流水线级
- 详见 [id_stage.md](../stage/id_stage/id_stage.md) 和 [wb_stage.md](../stage/wb_stage/wb_stage.md)

### 未来扩展

- **三读口**：若实现超标量或同时支持 forwarding 源读取，可扩展为三读口。
- **写口优先级**：若引入 CSR 写回，可能需要双写口（或分时复用）。
- **M 扩展**：乘除法结果写回与当前单写口兼容，无需修改。
- **差分复位**：若综合资源紧张，可取消复位（x0 硬连线 + 其余寄存器无需初始值）。
