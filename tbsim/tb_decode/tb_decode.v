//=============================================================================
// tb_decode.v — decode.v 单元测试（L1, P0）
//=============================================================================
// 纯组合测试：驱动 i_instruction，同拍采样全部输出，逐项与 golden 比较。
// 用例覆盖（对应 design_doc/tbsim/tb_decode/tb_decode.md §3）：
//   R/I/S/B/U/J 全模板 + LOAD/STORE 全宽 + 立即数位重排/边界 + NOP 化 + 行为锁定。
//
// 编码来源：所有指令编码均经 riscv64-unknown-elf-gcc -march=rv32i 汇编后
// objcopy 提取验证（见 tb_decode.md §2.2 交叉通道），非手工推导。
// 本文件中的指令编码与期望值（寄存器地址、imm 等）均为测试数据
// （golden 向量），不属于 RTL 逻辑常量。
//=============================================================================

`include "const_define.vh"
`include "opcode_define.vh"
`include "alu_op_define.vh"

module tb_decode;

    //---------------------------------------------------------------------
    // DUT 驱动与观测
    //---------------------------------------------------------------------
    reg  [31:0] inst;           // i_instruction（输入：指令编码）

    wire [ 4:0] rs1_addr, rs2_addr, rd_addr;
    wire [31:0] imm;
    wire [ 3:0] alu_opcode;
    wire [ 1:0] alu_src_a;
    wire        alu_src;
    wire [ 1:0] branch_sel;
    wire        mem_read, mem_write;
    wire [ 1:0] mem_width;
    wire        mem_sext;
    wire [ 1:0] wb_src;
    wire        reg_write;

    decode u_dut (
        .i_instruction (inst),
        .o_rs1_addr    (rs1_addr),
        .o_rs2_addr    (rs2_addr),
        .o_rd_addr     (rd_addr),
        .o_imm         (imm),
        .o_alu_opcode  (alu_opcode),
        .o_alu_src_a   (alu_src_a),
        .o_alu_src     (alu_src),
        .o_branch_sel  (branch_sel),
        .o_mem_read    (mem_read),
        .o_mem_write   (mem_write),
        .o_mem_width   (mem_width),
        .o_mem_sext    (mem_sext),
        .o_wb_src      (wb_src),
        .o_reg_write   (reg_write)
    );

    //---------------------------------------------------------------------
    // 寄存器地址 golden（测试数据）
    //---------------------------------------------------------------------
    localparam X10 = 5'd10;
    localparam X11 = 5'd11;
    localparam X12 = 5'd12;
    localparam X15 = 5'd15;
    localparam X31 = 5'd31;

    //---------------------------------------------------------------------
    // 指令编码向量（输入数据，经工具链验证）
    //---------------------------------------------------------------------
    // R 型（rs1=x10, rs2=x15, rd=x31）
    localparam R1_ADD   = 32'h00F50FB3;   // add  x31,x10,x15
    localparam R2_SUB   = 32'h40F50FB3;   // sub  x31,x10,x15
    localparam R3_SLL   = 32'h00F51FB3;   // sll  x31,x10,x15
    localparam R4_SLT   = 32'h00F52FB3;   // slt  x31,x10,x15
    localparam R5_SLTU  = 32'h00F53FB3;   // sltu x31,x10,x15
    localparam R6_XOR   = 32'h00F54FB3;   // xor  x31,x10,x15
    localparam R7_SRL   = 32'h00F55FB3;   // srl  x31,x10,x15
    localparam R8_SRA   = 32'h40F55FB3;   // sra  x31,x10,x15
    localparam R9_OR    = 32'h00F56FB3;   // or   x31,x10,x15
    localparam R10_AND  = 32'h00F57FB3;   // and  x31,x10,x15

    // I 型 OP-IMM（rs1=x10, rd=x31）
    localparam I1_ADDI_N1  = 32'hFFF50F93;  // addi x31,x10,-1   → imm=-1
    localparam I1b_ADDI_7FF= 32'h7FF50F93;  // addi x31,x10,2047 → imm=0x7FF
    localparam I2_SLTI     = 32'hFFF52F93;  // slti x31,x10,-1
    localparam I3_SLTIU    = 32'hFFF53F93;  // sltiu x31,x10,-1
    localparam I4_XORI     = 32'hFFF54F93;  // xori x31,x10,-1
    localparam I5_ORI      = 32'hFFF56F93;  // ori  x31,x10,-1
    localparam I6_ANDI     = 32'hFFF57F93;  // andi x31,x10,-1
    localparam I7_SLLI_31  = 32'h01F51F93;  // slli x31,x10,31  → shamt=31
    localparam I7b_SLLI_0  = 32'h00051F93;  // slli x31,x10,0   → shamt=0
    localparam I8_SRLI     = 32'h00355F93;  // srli x31,x10,3   → shamt=3
    localparam I9_SRAI     = 32'h40355F93;  // srai x31,x10,3   → shamt=3

    // LOAD（rs1=x11, rd=x10）
    localparam L1_LB   = 32'h00458503;  // lb  x10, 4(x11)
    localparam L2_LH_N = 32'hFFC59503;  // lh  x10,-4(x11)   → 负偏移（缺陷1回归）
    localparam L3_LW   = 32'h0085A503;  // lw  x10, 8(x11)
    localparam L4_LBU  = 32'h0045C503;  // lbu x10, 4(x11)
    localparam L5_LHU_N= 32'hFF85D503;  // lhu x10,-8(x11)   → 负偏移（缺陷1回归）

    // STORE（rs1=x11, rs2=x15）
    localparam S1_SB   = 32'h00F58223;  // sb  x15, 4(x11)
    localparam S2_SH_N = 32'hFEF59F23;  // sh  x15,-2(x11)   → 负偏移
    localparam S3_SW   = 32'h00F5A423;  // sw  x15, 8(x11)
    localparam S4_SB28 = 32'h00F58E23;  // sb  x15,28(x11)   → S 型 imm 位重排

    // BRANCH（rs1=x10, rs2=x15）
    localparam B1_BEQ   = 32'h00F50E63;  // beq  x10,x15,+28  → B 型位重排
    localparam B2_BNE   = 32'h00F51E63;  // bne  x10,x15,+28
    localparam B3_BLT   = 32'h00F54E63;  // blt  x10,x15,+28
    localparam B4_BGE   = 32'h00F55E63;  // bge  x10,x15,+28
    localparam B5_BLTU  = 32'h00F56E63;  // bltu x10,x15,+28
    localparam B6_BGEU  = 32'h00F57E63;  // bgeu x10,x15,+28
    localparam B7_BEQ_N = 32'hFEF50EE3;  // beq  x10,x15,-4   → 负偏移

    // U 型
    localparam U1_LUI      = 32'h00001537;  // lui   x10,0x1
    localparam U1b_LUI_NEG = 32'hFFFFF537;  // lui   x10,0xFFFFF → imm=0xFFFFF000
    localparam U2_AUIPC    = 32'h00001517;  // auipc x10,0x1

    // J 型
    localparam J1_JAL_256 = 32'h10000FEF;  // jal x31,+256  → J 型位重排
    localparam J1b_JAL_N  = 32'hFFDFFFEF;  // jal x31,-4
    localparam J2_JALR    = 32'hFF060FE7;  // jalr x31,-16(x12)

    // NOP 化 / 非法
    localparam N1_ECALL = 32'h00000073;  // ecall
    localparam N2_EBREAK= 32'h00100073;  // ebreak
    localparam N3_FENCE = 32'h0FF0000F;  // fence（标准默认 pred/succ）
    localparam N4_ILLEG = 32'h00000000;  // 未定义 opcode
    localparam N5_SYSTEM= 32'h12000073;  // SFENCE.VMA（SYSTEM 保留，Zicsr 未实现）

    // 行为锁定
    localparam X1_NOP   = 32'h00000013;  // addi x0,x0,0（INST_NOP）
    localparam X2_ILLSLLI=32'h41F51F93;  // 非法 SLLI（funct7=0100000, funct3=001）

    //---------------------------------------------------------------------
    // 判定统计
    //---------------------------------------------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    //---------------------------------------------------------------------
    // check task — 逐项比较 14 项输出（期望 vs 实际）
    //---------------------------------------------------------------------
    task automatic check;
        input [ 4:0] exp_rs1;
        input [ 4:0] exp_rs2;
        input [ 4:0] exp_rd;
        input [31:0] exp_imm;
        input [ 3:0] exp_alu_opcode;
        input [ 1:0] exp_alu_src_a;
        input        exp_alu_src;
        input [ 1:0] exp_branch_sel;
        input        exp_mem_read;
        input        exp_mem_write;
        input [ 1:0] exp_mem_width;
        input        exp_mem_sext;
        input [ 1:0] exp_wb_src;
        input        exp_reg_write;
        input [255:0] name;

        integer fail = 0;
        begin
            if (rs1_addr !== exp_rs1) begin
                $display("  [%0s] rs1_addr:  got=%0d exp=%0d", name, rs1_addr, exp_rs1);
                fail = 1;
            end
            if (rs2_addr !== exp_rs2) begin
                $display("  [%0s] rs2_addr:  got=%0d exp=%0d", name, rs2_addr, exp_rs2);
                fail = 1;
            end
            if (rd_addr !== exp_rd) begin
                $display("  [%0s] rd_addr:   got=%0d exp=%0d", name, rd_addr, exp_rd);
                fail = 1;
            end
            if (imm !== exp_imm) begin
                $display("  [%0s] imm:       got=0x%08h exp=0x%08h", name, imm, exp_imm);
                fail = 1;
            end
            if (alu_opcode !== exp_alu_opcode) begin
                $display("  [%0s] alu_opcode: got=%0d exp=%0d", name, alu_opcode, exp_alu_opcode);
                fail = 1;
            end
            if (alu_src_a !== exp_alu_src_a) begin
                $display("  [%0s] alu_src_a:  got=%0d exp=%0d", name, alu_src_a, exp_alu_src_a);
                fail = 1;
            end
            if (alu_src !== exp_alu_src) begin
                $display("  [%0s] alu_src:    got=%0d exp=%0d", name, alu_src, exp_alu_src);
                fail = 1;
            end
            if (branch_sel !== exp_branch_sel) begin
                $display("  [%0s] branch_sel: got=%0d exp=%0d", name, branch_sel, exp_branch_sel);
                fail = 1;
            end
            if (mem_read !== exp_mem_read) begin
                $display("  [%0s] mem_read:   got=%0d exp=%0d", name, mem_read, exp_mem_read);
                fail = 1;
            end
            if (mem_write !== exp_mem_write) begin
                $display("  [%0s] mem_write:  got=%0d exp=%0d", name, mem_write, exp_mem_write);
                fail = 1;
            end
            if (mem_width !== exp_mem_width) begin
                $display("  [%0s] mem_width:  got=%0d exp=%0d", name, mem_width, exp_mem_width);
                fail = 1;
            end
            if (mem_sext !== exp_mem_sext) begin
                $display("  [%0s] mem_sext:   got=%0d exp=%0d", name, mem_sext, exp_mem_sext);
                fail = 1;
            end
            if (wb_src !== exp_wb_src) begin
                $display("  [%0s] wb_src:     got=%0d exp=%0d", name, wb_src, exp_wb_src);
                fail = 1;
            end
            if (reg_write !== exp_reg_write) begin
                $display("  [%0s] reg_write:  got=%0d exp=%0d", name, reg_write, exp_reg_write);
                fail = 1;
            end

            if (fail == 0) pass_cnt = pass_cnt + 1;
            else           fail_cnt = fail_cnt + 1;
        end
    endtask

    //---------------------------------------------------------------------
    // 用例执行
    //---------------------------------------------------------------------
    // 字段期望说明：decode 无条件输出 inst[19:15]/inst[24:20]/inst[11:7]，
    // 因此 rs2 字段在 I 型=shamt 或 imm[4:0]、U 型=imm[10:5]、J 型=imm[10:1]；
    // rd 字段在 S 型=imm[4:0]、B 型={imm[4:1],imm[11]}（位重排的一部分）。
    initial begin
        $display("=== tb_decode: start ===");

        // ---------- R 型（公共：rs1=X10 rs2=X15 rd=X31 imm=0 src_a=RS1
        //          src=0 branch=NONE mrd=0 mwr=0 mw=BYTE sext=0 wb=ALU rw=1）----------
        inst = R1_ADD;   #1; check(X10, X15, X31, 32'h0, `ALU_ADD, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R1_ADD");
        inst = R2_SUB;   #1; check(X10, X15, X31, 32'h0, `ALU_SUB, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R2_SUB");
        inst = R3_SLL;   #1; check(X10, X15, X31, 32'h0, `ALU_SLL, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R3_SLL");
        inst = R4_SLT;   #1; check(X10, X15, X31, 32'h0, `ALU_SLT, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R4_SLT");
        inst = R5_SLTU;  #1; check(X10, X15, X31, 32'h0, `ALU_SLTU, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R5_SLTU");
        inst = R6_XOR;   #1; check(X10, X15, X31, 32'h0, `ALU_XOR, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R6_XOR");
        inst = R7_SRL;   #1; check(X10, X15, X31, 32'h0, `ALU_SRL, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R7_SRL");
        inst = R8_SRA;   #1; check(X10, X15, X31, 32'h0, `ALU_SRA, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R8_SRA");
        inst = R9_OR;    #1; check(X10, X15, X31, 32'h0, `ALU_OR, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R9_OR");
        inst = R10_AND;  #1; check(X10, X15, X31, 32'h0, `ALU_AND, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "R10_AND");

        // ---------- I 型 OP-IMM（公共：rs1=X10 rd=X31 src_a=RS1 src=1
        //          branch=NONE mrd=0 mwr=0 mw=BYTE sext=0 wb=ALU rw=1）----------
        inst = I1_ADDI_N1;   #1; check(X10, 5'd31, X31, 32'hFFFFFFFF, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I1_ADDI_N1");
        inst = I1b_ADDI_7FF; #1; check(X10, 5'd31, X31, 32'h000007FF, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I1b_ADDI_7FF");
        inst = I2_SLTI;      #1; check(X10, 5'd31, X31, 32'hFFFFFFFF, `ALU_SLT, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I2_SLTI");
        inst = I3_SLTIU;     #1; check(X10, 5'd31, X31, 32'hFFFFFFFF, `ALU_SLTU, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I3_SLTIU");
        inst = I4_XORI;      #1; check(X10, 5'd31, X31, 32'hFFFFFFFF, `ALU_XOR, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I4_XORI");
        inst = I5_ORI;       #1; check(X10, 5'd31, X31, 32'hFFFFFFFF, `ALU_OR, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I5_ORI");
        inst = I6_ANDI;      #1; check(X10, 5'd31, X31, 32'hFFFFFFFF, `ALU_AND, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I6_ANDI");
        inst = I7_SLLI_31;   #1; check(X10, 5'd31, X31, 32'h0000001F, `ALU_SLL, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I7_SLLI_31");
        inst = I7b_SLLI_0;   #1; check(X10, 5'd0,  X31, 32'h00000000, `ALU_SLL, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I7b_SLLI_0");
        inst = I8_SRLI;      #1; check(X10, 5'd3,  X31, 32'h00000003, `ALU_SRL, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I8_SRLI");
        inst = I9_SRAI;      #1; check(X10, 5'd3,  X31, 32'h00000003, `ALU_SRA, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                       1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "I9_SRAI");

        // ---------- LOAD（公共：rs1=X11 rd=X10 src_a=RS1 src=1 op=ADD
        //          branch=NONE mrd=1 mwr=0 wb=MEM rw=1；rs2=imm[4:0]）----------
        inst = L1_LB;    #1; check(X11, 5'd4,  X10, 32'h00000004, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                   1'b1, 1'b0, `MEM_WIDTH_BYTE, 1'b1, `WB_SRC_MEM, 1'b1, "L1_LB");
        inst = L2_LH_N;  #1; check(X11, 5'd28, X10, 32'hFFFFFFFC, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                   1'b1, 1'b0, `MEM_WIDTH_HALF, 1'b1, `WB_SRC_MEM, 1'b1, "L2_LH_N");
        inst = L3_LW;    #1; check(X11, 5'd8,  X10, 32'h00000008, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                   1'b1, 1'b0, `MEM_WIDTH_WORD, 1'b1, `WB_SRC_MEM, 1'b1, "L3_LW");
        inst = L4_LBU;   #1; check(X11, 5'd4,  X10, 32'h00000004, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                   1'b1, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_MEM, 1'b1, "L4_LBU");
        inst = L5_LHU_N; #1; check(X11, 5'd24, X10, 32'hFFFFFFF8, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                   1'b1, 1'b0, `MEM_WIDTH_HALF, 1'b0, `WB_SRC_MEM, 1'b1, "L5_LHU_N");

        // ---------- STORE（公共：rs1=X11 rs2=X15 src_a=RS1 src=1 op=ADD
        //          branch=NONE mrd=0 mwr=1 wb=ALU rw=0）----------
        inst = S1_SB;   #1; check(X11, X15, 5'd4, 32'h00000004, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                  1'b0, 1'b1, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "S1_SB");
        inst = S2_SH_N; #1; check(X11, X15, 5'd30, 32'hFFFFFFFE, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                  1'b0, 1'b1, `MEM_WIDTH_HALF, 1'b0, `WB_SRC_ALU, 1'b0, "S2_SH_N");
        inst = S3_SW;   #1; check(X11, X15, 5'd8, 32'h00000008, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                  1'b0, 1'b1, `MEM_WIDTH_WORD, 1'b0, `WB_SRC_ALU, 1'b0, "S3_SW");
        inst = S4_SB28; #1; check(X11, X15, 5'd28, 32'h0000001C, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                  1'b0, 1'b1, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "S4_SB28");

        // ---------- BRANCH（公共：rs1=X10 rs2=X15 rd=0 src_a=RS1 src=0
        //          branch=COND mrd=0 mwr=0 mw=BYTE sext=0 wb=ALU rw=0）----------
        inst = B1_BEQ;   #1; check(X10, X15, 5'd28, 32'h0000001C, `ALU_EQ, `ALU_A_RS1, 1'b0, `BRANCH_COND,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "B1_BEQ");
        inst = B2_BNE;   #1; check(X10, X15, 5'd28, 32'h0000001C, `ALU_NE, `ALU_A_RS1, 1'b0, `BRANCH_COND,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "B2_BNE");
        inst = B3_BLT;   #1; check(X10, X15, 5'd28, 32'h0000001C, `ALU_SLT, `ALU_A_RS1, 1'b0, `BRANCH_COND,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "B3_BLT");
        inst = B4_BGE;   #1; check(X10, X15, 5'd28, 32'h0000001C, `ALU_GE, `ALU_A_RS1, 1'b0, `BRANCH_COND,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "B4_BGE");
        inst = B5_BLTU;  #1; check(X10, X15, 5'd28, 32'h0000001C, `ALU_SLTU, `ALU_A_RS1, 1'b0, `BRANCH_COND,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "B5_BLTU");
        inst = B6_BGEU;  #1; check(X10, X15, 5'd28, 32'h0000001C, `ALU_GEU, `ALU_A_RS1, 1'b0, `BRANCH_COND,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "B6_BGEU");
        inst = B7_BEQ_N; #1; check(X10, X15, 5'd29, 32'hFFFFFFFC, `ALU_EQ, `ALU_A_RS1, 1'b0, `BRANCH_COND,
                                   1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "B7_BEQ_N");

        // ---------- U 型（公共：rd=X10 src=1 op=ADD branch=NONE mrd=0 mwr=0
        //          mw=BYTE sext=0 wb=ALU rw=1；rs1=0 rs2=imm[10:5]=0）----------
        inst = U1_LUI;      #1; check(5'd0, 5'd0, X10, 32'h00001000, `ALU_ADD, `ALU_A_ZERO, 1'b1, `BRANCH_NONE,
                                      1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "U1_LUI");
        inst = U1b_LUI_NEG; #1; check(5'd31, 5'd31, X10, 32'hFFFFF000, `ALU_ADD, `ALU_A_ZERO, 1'b1, `BRANCH_NONE,
                                      1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "U1b_LUI_NEG");
        inst = U2_AUIPC;    #1; check(5'd0, 5'd0, X10, 32'h00001000, `ALU_ADD, `ALU_A_PC, 1'b1, `BRANCH_NONE,
                                      1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "U2_AUIPC");

        // ---------- J 型（公共：op=NOP src=0 branch=JAL/JALR wb=PC_PLUS4 rw=1
        //          mrd=0 mwr=0 mw=BYTE sext=0；rs1/rs2/rd 见各行）----------
        inst = J1_JAL_256; #1; check(5'd0, 5'd0,  X31, 32'h00000100, `ALU_NOP, `ALU_A_RS1, 1'b0, `BRANCH_JAL,
                                     1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_PC_PLUS4, 1'b1, "J1_JAL_256");
        inst = J1b_JAL_N;  #1; check(5'd31, 5'd29, X31, 32'hFFFFFFFC, `ALU_NOP, `ALU_A_RS1, 1'b0, `BRANCH_JAL,
                                     1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_PC_PLUS4, 1'b1, "J1b_JAL_N");
        inst = J2_JALR;    #1; check(X12, 5'd16, X31, 32'hFFFFFFF0, `ALU_NOP, `ALU_A_RS1, 1'b0, `BRANCH_JALR,
                                     1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_PC_PLUS4, 1'b1, "J2_JALR");

        // ---------- NOP 化 / 非法（全默认：rs1=0 rs2=0 rd=0 imm=0 op=NOP
        //          src_a=RS1 src=0 branch=NONE mrd=0 mwr=0 mw=BYTE sext=0
        //          wb=ALU rw=0）----------
        inst = N1_ECALL;  #1; check(5'd0, 5'd0, 5'd0, 32'h0, `ALU_NOP, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                    1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "N1_ECALL");
        inst = N2_EBREAK; #1; check(5'd0, 5'd1, 5'd0, 32'h0, `ALU_NOP, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                    1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "N2_EBREAK");
        inst = N3_FENCE;  #1; check(5'd0, 5'd31, 5'd0, 32'h0, `ALU_NOP, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                    1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "N3_FENCE");
        inst = N4_ILLEG;  #1; check(5'd0, 5'd0, 5'd0, 32'h0, `ALU_NOP, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                    1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "N4_ILLEG");
        inst = N5_SYSTEM; #1; check(5'd0, 5'd0, 5'd0, 32'h0, `ALU_NOP, `ALU_A_RS1, 1'b0, `BRANCH_NONE,
                                    1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b0, "N5_SYSTEM");

        // ---------- 行为锁定 ----------
        inst = X1_NOP;    #1; check(5'd0, 5'd0, 5'd0, 32'h0, `ALU_ADD, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                    1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "X1_NOP");
        inst = X2_ILLSLLI;#1; check(X10, 5'd31, X31, 32'h0000001F, `ALU_SLL, `ALU_A_RS1, 1'b1, `BRANCH_NONE,
                                    1'b0, 1'b0, `MEM_WIDTH_BYTE, 1'b0, `WB_SRC_ALU, 1'b1, "X2_ILLSLLI");

        // ---------- 汇总 ----------
        $display("=== tb_decode: PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt > 0) $fatal(1, "[tb_decode] %0d case(s) failed", fail_cnt);
        else              $display("[tb_decode] ALL PASS");
        $finish;
    end

endmodule
