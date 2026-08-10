# top_core.v 设计描述

## 概述

`top_core.v` 是 RISC-V CPU 的**顶层模块**，将全部子模块实例化并连接成完整的 5 级流水线：Resources（pc / regfile）、IF（pc_next / inst_mem / if_id）、ID（decode / id_ex）、EX（executor / alu 系列 / ex_mem）、MEM（data_mem / mem_wb）、WB（wb）、Pipeline Control（flow_ctrl / hazard_ctrl）。

**职责**：
- 实例化所有模块并完成端口互连
- 提供全局时钟 `i_clk` / 复位 `i_rst_n` 输入
- 不包含任何业务逻辑（纯连线）；所有控制逻辑在子模块中
- 当前无外部总线接口；仿真时以 tb 驱动时钟/复位并观测内部信号

## 顶层端口

| 信号 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `i_clk` | input | 1 | 全局时钟 |
| `i_rst_n` | input | 1 | 异步复位，低有效 |

> 未来扩展（总线、中断、调试口）在此追加；当前最小接口便于 tb 仿真。

## 模块实例与互连

### 1. Resources

```
pc u_pc (
    .i_clk, .i_rst_n,
    .i_pc_next (pc_next),     // ← pc_next.v 输出
    .o_pc      (pc)           // → inst_mem, if_id, pc_next, id_ex
);

regfile u_regfile (
    .i_clk, .i_rst_n,
    .i_rs1_addr (rs1_addr),   // ← decode.v
    .i_rs2_addr (rs2_addr),   // ← decode.v
    .i_rd_addr  (wb_rd_addr), // ← wb.v
    .i_rd_data  (wb_rd_data), // ← wb.v
    .i_we       (wb_reg_write),// ← wb.v
    .o_rs1_data (rs1_data),   // → id_ex.v
    .o_rs2_data (rs2_data)    // → id_ex.v
);
```

### 2. IF Stage

```
pc_next u_pc_next (
    .i_pc            (pc),             // ← pc.v
    .i_branch_target (fc_branch_target),// ← flow_ctrl.v
    .i_branch_valid  (fc_branch_valid),// ← flow_ctrl.v
    .i_stall         (hc_stall),       // ← hazard_ctrl.v
    .o_pc_next       (pc_next)         // → pc.v
);

inst_mem u_inst_mem (
    .i_pc           (pc),
    .o_instruction  (inst)             // → if_id.v
);

if_id u_if_id (
    .i_clk, .i_rst_n,
    .i_instruction (inst),
    .i_pc          (pc),
    .i_flush       (fc_flush_if_id),   // ← flow_ctrl.v
    .i_stall       (hc_stall),         // ← hazard_ctrl.v
    .o_instruction (if_id_inst),       // → decode.v
    .o_pc          (if_id_pc)          // → id_ex.v
);
```

### 3. ID Stage

```
decode u_decode (
    .i_instruction (if_id_inst),
    .o_rs1_addr    (rs1_addr),         // → regfile, hazard_ctrl
    .o_rs2_addr    (rs2_addr),         // → regfile, hazard_ctrl
    .o_rd_addr     (id_rd_addr),       // → id_ex
    .o_imm         (id_imm),           // → id_ex
    .o_alu_opcode  (id_alu_opcode),    // → id_ex
    .o_alu_src_a   (id_alu_src_a),     // → id_ex
    .o_alu_src     (id_alu_src),       // → id_ex
    .o_branch_sel  (id_branch_sel),    // → id_ex
    .o_mem_read    (id_mem_read),      // → id_ex
    .o_mem_write   (id_mem_write),     // → id_ex
    .o_mem_width   (id_mem_width),     // → id_ex
    .o_mem_sext    (id_mem_sext),      // → id_ex
    .o_wb_src      (id_wb_src),        // → id_ex
    .o_reg_write   (id_reg_write)      // → id_ex
);

id_ex u_id_ex (
    .i_clk, .i_rst_n,
    .i_flush       (fc_flush_id_ex),   // ← flow_ctrl.v
    .i_stall       (hc_stall),         // ← hazard_ctrl.v
    .i_pc          (if_id_pc),
    .i_rs1_data    (rs1_data),
    .i_rs2_data    (rs2_data),
    .i_imm         (id_imm),
    .i_rd_addr     (id_rd_addr),
    .i_alu_opcode  (id_alu_opcode),    // …全部控制信号…
    .o_pc          (ex_pc),            // → executor
    .o_rs1_data    (ex_rs1_data),
    .o_rs2_data    (ex_rs2_data),
    .o_imm         (ex_imm),
    .o_rd_addr     (ex_rd_addr),
    .o_alu_opcode  (ex_alu_opcode),
    .o_alu_src_a   (ex_alu_src_a),
    .o_alu_src     (ex_alu_src),
    .o_branch_sel  (ex_branch_sel),
    .o_mem_read    (ex_mem_read),
    .o_mem_write   (ex_mem_write),
    .o_mem_width   (ex_mem_width),
    .o_mem_sext    (ex_mem_sext),
    .o_wb_src      (ex_wb_src),
    .o_reg_write   (ex_reg_write)
);
```

### 4. EX Stage

```
executor u_executor (
    .i_pc            (ex_pc),
    .i_rs1_data      (ex_rs1_data),
    .i_rs2_data      (ex_rs2_data),
    .i_imm           (ex_imm),
    .i_rd_addr       (ex_rd_addr),
    .i_alu_opcode    (ex_alu_opcode),
    .i_alu_src_a     (ex_alu_src_a),
    .i_alu_src       (ex_alu_src),
    .i_branch_sel    (ex_branch_sel),
    .i_mem_read      (ex_mem_read),   // …全部控制透传…
    .o_alu_result    (ex_alu_result), // → ex_mem, flow_ctrl(JALR 已闭环无需)
    .o_pc_plus4      (ex_pc_plus4),   // → ex_mem
    .o_rs2_data      (ex_rs2_data),   // → ex_mem
    .o_rd_addr       (ex_rd_addr),    // → ex_mem
    .o_branch_taken  (ex_branch_taken),// → flow_ctrl
    .o_branch_target (ex_branch_target)// → flow_ctrl
);
```

> executor 内含 alu.v 及 alu_arith/bit/cmp 子实例，top 不直接实例化 ALU（由 executor 封装）。`o_branch_taken` / `o_branch_target` 走 flow_ctrl 再达 pc_next（控制面集中）。

### 5. MEM Stage

```
ex_mem u_ex_mem (
    .i_clk, .i_rst_n,
    .i_flush (1'b0),          // 分支冲刷不达 EX/MEM（见 flow_ctrl）
    .i_stall (1'b0),          // 方案 A：EX/MEM 不接 stall（producer 前进）
    .i_alu_result (ex_alu_result),
    .i_pc_plus4   (ex_pc_plus4),
    .i_rs2_data   (ex_rs2_data),
    .i_rd_addr    (ex_rd_addr),
    .i_mem_read   (ex_mem_read),   // …控制透传…
    .o_alu_result (mem_alu_result),// → data_mem(地址), mem_wb
    .o_pc_plus4   (mem_pc_plus4),  // → mem_wb
    .o_rs2_data   (mem_rs2_data),  // → data_mem(写数据)
    .o_rd_addr    (mem_rd_addr),   // → mem_wb
    .o_mem_read   (mem_mem_read),  // → data_mem
    .o_mem_write  (mem_mem_write), // → data_mem
    .o_mem_width  (mem_mem_width), // → data_mem
    .o_mem_sext   (mem_mem_sext),  // → data_mem
    .o_wb_src     (mem_wb_src),    // → mem_wb
    .o_reg_write  (mem_reg_write)  // → mem_wb
);

data_mem u_data_mem (
    .i_clk,
    .i_addr        (mem_alu_result),   // 物理地址（当前=虚拟地址直通，MMU 预留）
    .i_write_data  (mem_rs2_data),
    .i_mem_read    (mem_mem_read),
    .i_mem_write   (mem_mem_write),
    .i_mem_width   (mem_mem_width),
    .i_mem_sext    (mem_mem_sext),
    .o_read_data   (mem_read_data)     // → mem_wb
);
```

### 6. WB Stage

```
mem_wb u_mem_wb (
    .i_clk, .i_rst_n,
    .i_flush (1'b0),          // 分支冲刷不达 MEM/WB
    .i_stall (1'b0),          // 方案 A：MEM/WB 不接 stall
    .i_alu_result (mem_alu_result),
    .i_pc_plus4   (mem_pc_plus4),
    .i_read_data  (mem_read_data),
    .i_rd_addr    (mem_rd_addr),
    .i_wb_src     (mem_wb_src),
    .i_reg_write  (mem_reg_write),
    .o_alu_result (wb_alu_result),
    .o_pc_plus4   (wb_pc_plus4),
    .o_read_data  (wb_read_data),
    .o_rd_addr    (wb_rd_addr),
    .o_wb_src     (wb_wb_src),
    .o_reg_write  (wb_reg_write)
);

wb u_wb (
    .i_alu_result (wb_alu_result),
    .i_read_data  (wb_read_data),
    .i_pc_plus4   (wb_pc_plus4),
    .i_wb_src     (wb_wb_src),
    .i_rd_addr    (wb_rd_addr),
    .i_reg_write  (wb_reg_write),
    .o_rd_data    (wb_rd_data),     // → regfile
    .o_rd_addr    (wb_rd_addr_out), // → regfile
    .o_reg_write  (wb_reg_write_out)// → regfile
);
```

### 7. Pipeline Control

```
flow_ctrl u_flow_ctrl (
    .i_branch_taken  (ex_branch_taken),
    .i_branch_target (ex_branch_target),
    .o_branch_valid  (fc_branch_valid),   // → pc_next
    .o_branch_target (fc_branch_target),  // → pc_next
    .o_flush_if_id   (fc_flush_if_id),    // → if_id
    .o_flush_id_ex   (fc_flush_id_ex)     // → id_ex
);

hazard_ctrl u_hazard_ctrl (
    .i_rs1_addr         (rs1_addr),        // ← decode
    .i_rs2_addr         (rs2_addr),        // ← decode
    .i_ex_mem_rd        (mem_rd_addr),     // ← ex_mem
    .i_ex_mem_reg_write (mem_reg_write),   // ← ex_mem
    .i_mem_wb_rd        (wb_rd_addr),      // ← mem_wb
    .i_mem_wb_reg_write (wb_reg_write),    // ← mem_wb
    .o_stall            (hc_stall)         // → pc_next, if_id, id_ex
);
```

## 关键连线说明

| 信号 | 特殊语义 |
|------|---------|
| `ex_mem.i_flush` / `i_stall`、`mem_wb.i_flush` / `i_stall` | **恒接 0**（方案 A 明确：分支冲刷与 RAW stall 都不达后半段，producer 必须前进写回） |
| `if_id.i_stall` | 接 `hc_stall`（use 冻结在 ID 重读 regfile） |
| `id_ex.i_stall` | 接 `hc_stall`（灌 NOP，见 hazard_ctrl） |
| `data_mem.i_addr` | 接 `mem_alu_result`（虚拟地址直通，MMU 未来插在中间） |
| `flow_ctrl` 输入 | 接 executor 的 `o_branch_taken`/`o_branch_target`（控制面集中） |
| `hazard_ctrl` 输入 rs | 接 decode 的 `o_rs1_addr`/`o_rs2_addr`（组合输出，每周期反映 ID 级指令） |

## 复位 / 初始状态

- 复位后：pc=0（pc.v）、if_id 输出 `INST_NOP`、全部流水线寄存器输出安全默认值（reg_write=0、branch_sel=BRANCH_NONE 等）
- 前 5 拍为流水线填充（IF→WB 逐级进入），第 1 条指令在约第 5 拍写回
- 复位释放后从地址 0 开始执行（inst_mem 内容由 firmware.hex 预载）

## 验证（tb 规划，暂未实现）

- 简单指令序列（R-type/I-type 写回正确）
- RAW hazard（动态 stall 时长正确）
- taken / 非 taken 分支（同沿三件事 + 零副作用）
- 分支 + stall 同拍（flush 优先）
- load / store 读写回环（宽度 × 地址偏移）
- JAL / JALR（pc+4 写回 + 目标正确）

## 未来扩展

- **MMU（Sv32）**：在 `ex_mem.o_alu_result` 与 `data_mem.i_addr` 之间插入 mmu 模块（不改两端）
- **总线接口**：inst_mem / data_mem 替换为 AXI4-Lite / Wishbone
- **异常/中断**：flow_ctrl 增加异常重定向输入（mtvec），复用 flush/valid 通路
- **forwarding（方案 B）**：hazard_ctrl 增加旁路选择信号，executor 操作数 MUX 增加旁路源
- **外部调试口 / CSR**：顶层追加端口
