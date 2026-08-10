# 迭代日志（iteration log）

记录每次测试/开发迭代中出现的错误与修复。格式：
`日期 | 模块 | 错误描述 → 修复方式 → 验证结果`（简要，不展开细节）。

---

## 迭代 1：tb_decode 单元测试 + decode.v 缺陷修复（2026-08-10）

**目的**：编写 decode.v 的 L1 单元测试（tb_decode），并暴露/修复设计缺陷。

**错误与修复**：

1. **decode.v 设计缺陷（LOAD 立即数误判）**
   - 错误：`OPCODE_LOAD` 与 `OPCODE_OPIMM`/`OPCODE_JALR` 共用 `case(funct3)`
     的 shamt 分支；LH（funct3=001）、LHU（funct3=101）负偏移 imm 被错误
     零扩展为 `{27'b0, inst[24:20]}`。
   - 修复：`OPCODE_LOAD` 拆为独立分支，imm 一律 I 型符号扩展；
     shamt 分支仅保留给 OP-IMM。同步更新 `id_stage.md`（立即数表格+修复记录）
     与 `tb_decode.md`（缺陷状态改 GREEN）。
   - 验证：临时 TB 7 项检查 PASS；全项目 lint OK。

2. **临时 TB 编码笔误（3 FAIL）**
   - 错误：手工拼位串时 SLLI/SRAI/SRLI 的 shamt 位段写错（期望 31/3，
     实际编码了 11），导致首跑 3 项 FAIL。
   - 修复：改为用 `riscv64-unknown-elf-gcc -march=rv32i` 汇编真实指令、
     objcopy 提取编码作为 golden——消除手工拼码错误。
   - 验证：临时 TB 全 PASS。

3. **verilator 编译问题**
   - 错误：`%Warning-IMPLICITSTATIC`（task 隐式 static，内部局部变量共享）；
     `Cannot write build/...`（build 目录不存在）。
   - 修复：`task automatic check;`；预建 build 目录（后由 Makefile 自动建）。

4. **正式 TB 首跑 34 PASS / 16 FAIL（期望值错误，非 DUT 错误）**
   - 错误：我误以为 S/B/J 型指令的 rd/rs 字段应输出 0；实际 decode 无条件
     输出 `inst[11:7]`/`inst[24:20]`/`inst[19:15]`，这些位在 S/B/J 型中是
     立即数位重排的一部分（S 型 rd=imm[4:0]、B 型 rd={imm[4:1],imm[11]}、
     J 型 rs1=imm[20]、LUI rs1=imm[20] 等）。
   - 修复：修正 16 处期望值；在 TB 注释中写明字段语义。
   - 验证：50/50 PASS，`make lint` + `make sim` 通过，退出码 0。

5. **.gitignore 格式错误**
   - 错误：追加 `build/` 时与 `.reasonix` 挤在同一行（缺换行），导致
     `.reasonix` 实际未被忽略。
   - 修复：重写 `.gitignore` 为两行（`.reasonix`、`build/`）。
   - 验证：`git check-ignore` 两者均命中。

**遗留/观察项**：非法 SLLI（funct7=0100000）当前宽松解码为 `ALU_SLL`
（RV32I 规范要求保留），记为观察项 X2，暂不修。

**当前目录约定**：每个测试一个文件夹（`src/tbsim/<test>/` + 对应
`design_doc/tbsim/<test>/`），TB 与 Makefile 放测试文件夹下；
编译产物 `build/` 已 gitignore。
