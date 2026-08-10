# tb_decode — decode.v 单元测试设计

## 1. 概述

- **被测模块**：`src/rtl/stage/id_stage/decode.v`（ID 阶段统一译码器）
- **测试分层**：L1（module 级），P0 优先级
- **测试目标**：
  1. 验证全部 RV32I 指令模板的字段提取（rs1/rs2/rd）、立即数生成（6 种格式）、
     控制信号生成（12 项输出）正确性；
  2. 锁定"非法/未定义指令 → 全默认 NOP 值"的安全行为；
  3. **暴露当前已知缺陷**（见 §5），为修复提供回归基线。
- **模块性质**：纯组合逻辑，无时钟、无复位、无内部状态。

### 1.1 decode.v 端口（测试观察面）

| 信号 | 宽度 | 说明 |
|------|------|------|
| `i_instruction` | 32 | 输入指令字（来自 if_id） |
| `o_rs1_addr` / `o_rs2_addr` / `o_rd_addr` | 5 | 寄存器地址字段 |
| `o_imm` | 32 | 立即数（6 种格式） |
| `o_alu_opcode` | 4 | flat ALU 操作码 |
| `o_alu_src_a` | 2 | A 端口源：RS1 / PC / ZERO |
| `o_alu_src` | 1 | B 端口源：0=rs2, 1=imm |
| `o_branch_sel` | 2 | NONE / COND / JAL / JALR |
| `o_mem_read` / `o_mem_write` | 1 | 内存读写使能 |
| `o_mem_width` | 2 | BYTE / HALF / WORD |
| `o_mem_sext` | 1 | 符号/零扩展 |
| `o_wb_src` | 2 | ALU / MEM / PC_PLUS4 |
| `o_reg_write` | 1 | 寄存器写使能 |

---

## 2. 测试环境

### 2.1 例化关系

```
tb_decode
    └── decode u_dut (
            .i_instruction (inst),
            .o_rs1_addr / .o_rs2_addr / .o_rd_addr / .o_imm
            .o_alu_opcode / .o_alu_src_a / .o_alu_src / .o_branch_sel
            .o_mem_read / .o_mem_write / .o_mem_width / .o_mem_sext
            .o_wb_src / .o_reg_write
        )
```

### 2.2 激励与采样

- **无时钟**：TB 以 `initial` 顺序块驱动 `inst`，同拍（无延迟）采样全部输出。
- **激励来源（双通道）**：
  - 主通道：手工构造指令编码（golden 由编码规则直接推导，最确定）；
  - 交叉通道（可选，`ifdef` 包裹）：用 `riscv64-unknown-elf-gcc -march=rv32i`
    汇编少量指令，`objcopy -O binary` 提取编码，作为"真实工具链编码"抽查，
    防手工编码错误。
- **判定封装**：TB 内定义 `task check(inst, exp_rs1, exp_rs2, exp_rd, exp_imm,
  exp_alu_opcode, exp_alu_src_a, exp_alu_src, exp_branch_sel, exp_mem_read,
  exp_mem_write, exp_mem_width, exp_mem_sext, exp_wb_src, exp_reg_write)`，
  逐项比较，任一不符 → `$error` 并记录用例号。
- **复位策略**：不适用（纯组合）。

### 2.3 编译命令

```bash
verilator --cc --binary --assert -Isrc/rtl/defines \
    --top-module tb_decode --Mdir build/obj_tb_decode \
    src/tbsim/unit/tb_decode.v src/rtl/stage/id_stage/decode.v -o sim_tb_decode
./build/obj_tb_decode/sim_tb_decode
```

---

## 3. 用例清单

> 约定：用例中未列出的输出项，其期望值见各节"公共期望"；
> 每条指令编码用 `{funct7, rs2, rs1, funct3, rd, opcode}` 手写注释标注。

### 3.1 字段提取（全部指令通用）

对每个指令模板，断言 `o_rs1_addr = inst[19:15]`、`o_rs2_addr = inst[24:20]`、
`o_rd_addr = inst[11:7]`。用非平凡地址值（如 rs1=x10、rs2=x15、rd=x31）避免
全 0 掩盖错误。

### 3.2 R-type（OP，opcode=7'b0110011）

公共期望：`reg_write=1`、`alu_src_a=RS1`、`alu_src=0`（rs2）、
`branch_sel=NONE`、`mem_read=0`、`mem_write=0`、`wb_src=ALU`、`o_imm=0`。

| 用例 | 指令 | funct7/funct3 | 期望 `alu_opcode` | 备注 |
|------|------|---------------|-------------------|------|
| R1 | ADD | 0000000/000 | ADD | funct7=0000000 |
| R2 | SUB | 0100000/000 | SUB | **funct7=0100000 判别** |
| R3 | SLL | 0000000/001 | SLL | |
| R4 | SLT | 0000000/010 | SLT | |
| R5 | SLTU | 0000000/011 | SLTU | |
| R6 | XOR | 0000000/100 | XOR | |
| R7 | SRL | 0000000/101 | SRL | funct7=0000000 |
| R8 | SRA | 0100000/101 | SRA | **inst_30=1 判别** |
| R9 | OR | 0000000/110 | OR | |
| R10 | AND | 0000000/111 | AND | |

### 3.3 I-type 算术（OP-IMM，opcode=7'b0010011）

公共期望：`reg_write=1`、`alu_src_a=RS1`、`alu_src=1`（imm）、
`branch_sel=NONE`、`mem_read=0`、`mem_write=0`、`wb_src=ALU`。

| 用例 | 指令 | funct3 | 期望 `alu_opcode` | imm 期望 |
|------|------|--------|-------------------|----------|
| I1 | ADDI | 000 | ADD | 符号扩展 |
| I2 | SLTI | 010 | SLT | 符号扩展 |
| I3 | SLTIU | 011 | SLTU | 符号扩展 |
| I4 | XORI | 100 | XOR | 符号扩展 |
| I5 | ORI | 110 | OR | 符号扩展 |
| I6 | ANDI | 111 | AND | 符号扩展 |
| I7 | SLLI | 001 | SLL | `{27'b0, shamt}` 零扩展 |
| I8 | SRLI | 101, funct7=0000000 | SRL | `{27'b0, shamt}` |
| I9 | SRAI | 101, funct7=0100000 | SRA | `{27'b0, shamt}` |

**imm 符号扩展边界**（I1 变体）：`inst[31]=1`（如 imm=-1）→
`o_imm=0xFFFFFFFF`；`inst[31]=0`（如 imm=0x7FF）→ `o_imm=0x000007FF`。

**shamt 边界**（I7 变体）：shamt=0 → imm=0；shamt=31 → imm=31。

### 3.4 LOAD（opcode=7'b0000011）

公共期望：`reg_write=1`、`alu_src=1`（imm 为地址偏移）、`alu_opcode=ADD`、
`wb_src=MEM`、`mem_read=1`、`mem_write=0`、`branch_sel=NONE`、`alu_src_a=RS1`。

| 用例 | 指令 | funct3 | `mem_width` | `mem_sext` |
|------|------|--------|-------------|------------|
| L1 | LB | 000 | BYTE | 1 |
| L2 | LH | 001 | HALF | 1 |
| L3 | LW | 010 | WORD | 1 |
| L4 | LBU | 100 | BYTE | 0 |
| L5 | LHU | 101 | HALF | 0 |

**负偏移验证（L2/L5）**：LH 的 funct3=001 与 `FUNCT3_SLL` 相同、LHU 的
funct3=101 与 `FUNCT3_SR` 相同——历史上 decode.v 曾因此把 LOAD 的负偏移
立即数误按 shamt 零扩展（缺陷 1，已于 2026-08-10 修复，见 §5）。现在期望：
LH/LHU 负偏移立即数一律 I 型符号扩展（如 imm=-4 → `0xFFFFFFFC`）。

### 3.5 STORE（opcode=7'b0100011）

公共期望：`reg_write=0`、`alu_src=1`（imm 为地址偏移）、`alu_opcode=ADD`、
`alu_src_a=RS1`、`mem_read=0`、`mem_write=1`、`branch_sel=NONE`、`wb_src=ALU`。

| 用例 | 指令 | funct3 | `mem_width` |
|------|------|--------|-------------|
| S1 | SB | 000 | BYTE |
| S2 | SH | 001 | HALF |
| S3 | SW | 010 | WORD |

**S 型 imm 位重排验证**：构造 `inst[31:25]=7'b1010101, inst[11:7]=5'b10001`
→ 期望 `o_imm = {{20{1'b1}}, 7'b1010101, 5'b10001}`（inst[31]=1 符号扩展）。
另测 inst[31]=0 的零扩展。

### 3.6 BRANCH（opcode=7'b1100011）

公共期望：`reg_write=0`、`alu_src=0`（rs2）、`branch_sel=COND`、
`mem_read=0`、`mem_write=0`、`alu_src_a=RS1`、`wb_src=ALU`。

| 用例 | 指令 | funct3 | 期望 `alu_opcode` |
|------|------|--------|-------------------|
| B1 | BEQ | 000 | EQ |
| B2 | BNE | 001 | NE |
| B3 | BLT | 100 | SLT |
| B4 | BGE | 101 | GE |
| B5 | BLTU | 110 | SLTU |
| B6 | BGEU | 111 | GEU |

**B 型 imm 位重排验证**：构造偏移 +28（0x1C，编码
`imm[12]=0, imm[11]=0, imm[10:5]=0, imm[4:1]=0b1110, imm[0]=0`），即
`inst[31]=0, inst[7]=0, inst[30:25]=000000, inst[11:8]=1110` →
期望 `o_imm=32'h1C`。再测负偏移 -4（0xFFFFFFFC，全 1 扩展）。

### 3.7 LUI / AUIPC（U 型）

| 用例 | 指令 | opcode | 期望 |
|------|------|--------|------|
| U1 | LUI | 0110111 | `imm=inst[31:12]<<12`；`alu_src_a=ZERO`、`alu_src=1`、`alu_opcode=ADD`、`reg_write=1` |
| U2 | AUIPC | 0010111 | `imm=inst[31:12]<<12`；`alu_src_a=PC`、`alu_src=1`、`alu_opcode=ADD`、`reg_write=1` |

**U 型 imm 边界**：`inst[31:12]=0x00001` → `imm=0x00001000`；
`inst[31:12]=0xFFFFF`（inst[31]=1）→ `imm=0xFFFFF000`。

### 3.8 JAL / JALR

| 用例 | 指令 | 期望 |
|------|------|------|
| J1 | JAL（1101111） | `branch_sel=JAL`、`wb_src=PC_PLUS4`、`reg_write=1`、`alu_opcode=NOP`、`mem_read/write=0` |
| J2 | JALR（1100111, funct3=000） | `branch_sel=JALR`、`wb_src=PC_PLUS4`、`reg_write=1`、`alu_opcode=NOP` |

**J 型 imm 位重排验证**：构造 offset +0x100（编码
`imm[20]=inst[31]=0, imm[19:12]=inst[19:12]=00000001, imm[11]=inst[20]=0,
imm[10:1]=inst[30:21]=0000000000`）→ 期望 `o_imm=32'h100`。
另测负偏移 -4（全 1 扩展）。

### 3.9 NOP 化指令与非法指令

公共期望（全部默认值）：`alu_opcode=NOP`、`alu_src_a=RS1`、`alu_src=0`、
`branch_sel=NONE`、`mem_read=0`、`mem_write=0`、`mem_width=BYTE`、
`mem_sext=0`、`wb_src=ALU`、`reg_write=0`、`o_imm=0`。

| 用例 | 指令 | 备注 |
|------|------|------|
| N1 | ECALL（SYSTEM, 00000000000000000000000001110011） | 当前 NOP 化 |
| N2 | EBREAK（SYSTEM, 00000000000100000000000001110011） | 当前 NOP 化 |
| N3 | FENCE（MISC-MEM, 0000000_00000_00000_000_00000_0001111） | 当前 NOP 化 |
| N4 | 未定义 opcode（如 7'b0000000） | 全默认 |
| N5 | SYSTEM 非 ECALL/EBREAK 保留编码（如 0x12000073 SFENCE.VMA） | 全默认（当前 Zicsr 未实现） |

### 3.10 行为约定锁定（防回归）

| 用例 | 指令 | 期望 | 锁定原因 |
|------|------|------|----------|
| X1 | `addi x0, x0, 0`（INST_NOP 编码） | `reg_write=1`、`alu_opcode=ADD`、`imm=0` | decode **不**过滤 x0，x0 写保护在 regfile；流水线气泡由 id_ex 的 flush/stall 灌入，与 decode 无关。此行为是设计约定，防止未来误"优化" |
| X2 | 非法 SLLI（funct7=0100000, funct3=001） | 当前实现宽松解码为 `ALU_SLL` | 记录当前行为（RISC-V 规范要求保留），列为观察项而非失败项 |

---

## 4. 断言与哨兵

- **判定方式**：`task check(...)` 逐项比较，不符 → `$error("[tb_decode] case %0d: signal=%s got=0x%h exp=0x%h", ...)`；所有用例结束后 `$display("[tb_decode] PASS %0d/%0d", pass, total)`，若有失败以 `$fatal` 结束（非 0 退出码）。
- **超时保护**：不适用（纯组合，无时钟）。
- **哨兵**：无内部 `$error` 风险（decode.v 无仿真断言块）；TB 自身的 `$error` 即唯一失败信号。
- **已知缺陷用例处理**：缺陷 1（§5）已于 2026-08-10 修复，L2/L5 负偏移
  用例现按正确行为为 golden（GREEN）。X2 观察项按当前实现行为锁定。

---

## 5. 已知缺陷（测试暴露，待修复）

**缺陷 1 — LOAD 立即数误判（LH/LHU）** — ✅ 已修复（2026-08-10）

- 位置：`decode.v` Block 2（imm 生成），`OPCODE_LOAD` 与 `OPCODE_OPIMM`/`OPCODE_JALR`
  共用 `case(funct3)` 的 shamt 分支。
- 触发：LH（funct3=001=`FUNCT3_SLL`）或 LHU（funct3=101=`FUNCT3_SR`）
  且 `inst[31]=1`（负偏移）→ `o_imm = {27'b0, inst[24:20]}`（错误零扩展），
  正确应为 `{{20{inst[31]}}, inst[31:20]}` 符号扩展。
- 影响：负偏移 load 的地址计算错误，实际程序可触发。
- **修复内容**：`OPCODE_LOAD` 已从共享分支中拆出，imm 一律 I 型符号扩展；
  shift-amount 分支仅保留给 `OPCODE_OPIMM` 的 SLLI/SRLI/SRAI
  （JALR 的 funct3 恒为 000，走符号扩展分支，不受影响）。
  同步更新：`id_stage.md` §1.2（立即数表格 + 修复记录）。

**观察项 1 — 非法 SLLI 宽松解码**：funct7=0100000 的 SLLI 未按保留指令处理，
当前输出 `ALU_SLL`。RV32I 规范要求保留；暂不修，记录行为。

---

## 6. 验收标准

1. §3 用例（不含"修复后转 GREEN"的缺陷用例）全部 PASS；
2. 缺陷 1 用例在修复前按实际行为记录并标记 RED，修复 decode.v 后转 GREEN；
3. `verilator --lint-only -Isrc/rtl/defines src/rtl/stage/id_stage/decode.v` 零错误；
4. TB 编译运行退出码 0，`[tb_decode] PASS n/n` 全量通过。

---

## 7. 未来扩展

- **RV32M**：OP 的 funct7=0000001（MUL/DIV 系列）→ 新增 `alu_opcode` 期望；
  非法 funct3 组合随 M 扩展调整。
- **CSR / Zicsr**：SYSTEM opcode 细分（CSRRW/CSRRS/...），`wb_src` 保留码
  2'b11（CSR 读）用例。
- **FENCE.I / Zifencei**：MISC-MEM 分支从 NOP 化改为具体控制信号。
- **工具链交叉验证**：`ifdef` 交叉通道扩展为覆盖全部指令模板的汇编抽查。
