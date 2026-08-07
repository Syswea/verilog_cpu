//=============================================================================
// decode.v — Unified ID stage decoder
//=============================================================================
// Performs all ID-stage work in a single module:
//   1. Field extraction (opcode, funct3, funct7, register addresses)
//   2. Immediate generation (I/S/B/U/J/shift-amount formats)
//   3. Control signal generation (alu_opcode, branch, mem, wb, etc.)
//
// This is the single source of truth for all pipeline control signals.
// All outputs are combinational (no registers inside decode.v).
//
// The ID/EX pipeline register (id_ex.v) latches these outputs for EX stage.
//=============================================================================

`include "const_define.vh"
`include "opcode_define.vh"
`include "alu_op_define.vh"

module decode (
    input  wire [31:0] i_instruction,   // from if_id.v (o_instruction)

    // ---- Register Addresses ----
    output wire [ 4:0] o_rs1_addr,      // to regfile.v (i_rs1_addr)
    output wire [ 4:0] o_rs2_addr,      // to regfile.v (i_rs2_addr)
    output wire [ 4:0] o_rd_addr,       // to id_ex.v → WB Stage

    // ---- Immediate ----
    output wire [31:0] o_imm,           // to id_ex.v → EX Stage

    // ---- Control Signal Bundle ----
    output wire [ 3:0] o_alu_opcode,    // to id_ex.v → executor.v (ALU op)
    output wire        o_alu_src_a,     // to id_ex.v → executor.v (A-port sel)
    output wire        o_alu_src,       // to id_ex.v → executor.v (B-port sel)
    output wire        o_branch,        // to id_ex.v → flow_control.v
    output wire        o_mem_read,      // to id_ex.v → MEM Stage
    output wire        o_mem_write,     // to id_ex.v → MEM Stage
    output wire [ 1:0] o_mem_width,     // to id_ex.v → MEM Stage
    output wire        o_mem_sext,      // to id_ex.v → MEM Stage
    output wire        o_mem_to_reg,    // to id_ex.v → WB Stage
    output wire        o_reg_write      // to id_ex.v → WB Stage
);

    //=========================================================================
    // Internal wires: extracted instruction fields
    //=========================================================================

    wire [6:0] opcode;
    wire [2:0] funct3;
    wire [6:0] funct7;
    wire       inst_30;

    //=========================================================================
    // Block 1: Field Extraction (pure assign)
    //=========================================================================
    // Extract standard RISC-V fields.  No format discrimination here —
    // format-specific interpretation is done in Block 2 and Block 3.

    assign opcode      = i_instruction[6:0];
    assign funct3      = i_instruction[14:12];
    assign funct7      = i_instruction[31:25];
    assign inst_30     = i_instruction[30];
    assign o_rs1_addr  = i_instruction[19:15];
    assign o_rs2_addr  = i_instruction[24:20];
    assign o_rd_addr   = i_instruction[11:7];

    //=========================================================================
    // Block 2: Immediate Generation (always_comb)
    //=========================================================================
    // Reconstruct 32-bit sign-extended immediate from instruction bits
    // based on the instruction format (determined by opcode).

    reg [31:0] imm;

    always_comb begin
        case (opcode)
            // I-type:  LOAD, OP-IMM, JALR
            `OPCODE_LOAD,
            `OPCODE_OPIMM,
            `OPCODE_JALR: begin
                case (funct3)
                    // shift-amount (SLLI / SRLI / SRAI):
                    // 5-bit zero-extended shamt from inst[24:20]
                    `FUNCT3_SLL,
                    `FUNCT3_SR:
                        imm = {27'b0, i_instruction[24:20]};
                    // standard I-immediate
                    default:
                        imm = {{20{i_instruction[31]}}, i_instruction[31:20]};
                endcase
            end

            // S-type: STORE
            `OPCODE_STORE:
                imm = {{20{i_instruction[31]}},
                       i_instruction[31:25],
                       i_instruction[11:7]};

            // B-type: BRANCH
            `OPCODE_BRANCH:
                imm = {{20{i_instruction[31]}},
                       i_instruction[7],
                       i_instruction[30:25],
                       i_instruction[11:8],
                       1'b0};

            // U-type: LUI, AUIPC
            `OPCODE_LUI,
            `OPCODE_AUIPC:
                imm = {i_instruction[31:12], 12'b0};

            // J-type: JAL
            `OPCODE_JAL:
                imm = {{12{i_instruction[31]}},
                       i_instruction[19:12],
                       i_instruction[20],
                       i_instruction[30:21],
                       1'b0};

            // All others (SYSTEM, MISC-MEM, etc.)
            default: imm = `XLEN_ZERO;
        endcase
    end

    assign o_imm = imm;

    //=========================================================================
    // Block 3: Control Signal Generation (always_comb)
    //=========================================================================
    // Generate ALL pipeline control signals.  This is the single source of
    // control for EX / MEM / WB stages.  No secondary decoding downstream.

    reg [ 3:0] alu_opcode;
    reg        alu_src_a;
    reg        alu_src;
    reg        branch;
    reg        mem_read;
    reg        mem_write;
    reg [ 1:0] mem_width;
    reg        mem_sext;
    reg        mem_to_reg;
    reg        reg_write;

    always_comb begin
        // ---- Safe defaults (NOP / illegal instruction) ----
        alu_opcode  = `ALU_NOP;
        alu_src_a   = 1'b0;
        alu_src     = 1'b0;
        branch      = 1'b0;
        mem_read    = 1'b0;
        mem_write   = 1'b0;
        mem_width   = `MEM_WIDTH_BYTE;
        mem_sext    = 1'b0;
        mem_to_reg  = 1'b0;
        reg_write   = 1'b0;

        case (opcode)

            //-----------------------------------------------------------------
            // R-type (OP)
            //-----------------------------------------------------------------
            `OPCODE_OP: begin
                reg_write = 1'b1;
                alu_src   = 1'b0;   // rs2
                case (funct3)
                    `FUNCT3_ADD:
                        alu_opcode = (funct7 == `FUNCT7_VARIANT && inst_30)
                                   ? `ALU_SUB : `ALU_ADD;
                    `FUNCT3_SLL:
                        alu_opcode = `ALU_SLL;
                    `FUNCT3_SLT:
                        alu_opcode = `ALU_SLT;
                    `FUNCT3_SLTU:
                        alu_opcode = `ALU_SLTU;
                    `FUNCT3_XOR:
                        alu_opcode = `ALU_XOR;
                    `FUNCT3_SR:
                        alu_opcode = (funct7 == `FUNCT7_VARIANT && inst_30)
                                   ? `ALU_SRA : `ALU_SRL;
                    `FUNCT3_OR:
                        alu_opcode = `ALU_OR;
                    `FUNCT3_AND:
                        alu_opcode = `ALU_AND;
                    default: ;
                endcase
            end

            //-----------------------------------------------------------------
            // I-type (OP-IMM)
            //-----------------------------------------------------------------
            `OPCODE_OPIMM: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;   // imm
                case (funct3)
                    `FUNCT3_ADD:
                        alu_opcode = `ALU_ADD;
                    `FUNCT3_SLT:
                        alu_opcode = `ALU_SLT;
                    `FUNCT3_SLTU:
                        alu_opcode = `ALU_SLTU;
                    `FUNCT3_XOR:
                        alu_opcode = `ALU_XOR;
                    `FUNCT3_OR:
                        alu_opcode = `ALU_OR;
                    `FUNCT3_AND:
                        alu_opcode = `ALU_AND;
                    `FUNCT3_SLL:
                        alu_opcode = `ALU_SLL;   // funct7[5]==0 guaranteed
                    `FUNCT3_SR:
                        alu_opcode = (funct7 == `FUNCT7_VARIANT && inst_30)
                                   ? `ALU_SRA : `ALU_SRL;
                    default: ;
                endcase
            end

            //-----------------------------------------------------------------
            // I-type (LOAD)
            //-----------------------------------------------------------------
            `OPCODE_LOAD: begin
                reg_write   = 1'b1;
                alu_src     = 1'b1;   // imm (address offset)
                alu_opcode  = `ALU_ADD;
                mem_to_reg  = 1'b1;   // data from memory
                mem_read    = 1'b1;
                case (funct3)
                    `FUNCT3_LB:  begin mem_sext = 1'b1; mem_width = `MEM_WIDTH_BYTE; end
                    `FUNCT3_LH:  begin mem_sext = 1'b1; mem_width = `MEM_WIDTH_HALF; end
                    `FUNCT3_LW:  begin mem_sext = 1'b1; mem_width = `MEM_WIDTH_WORD; end
                    `FUNCT3_LBU: begin mem_sext = 1'b0; mem_width = `MEM_WIDTH_BYTE; end
                    `FUNCT3_LHU: begin mem_sext = 1'b0; mem_width = `MEM_WIDTH_HALF; end
                    default: ;
                endcase
            end

            //-----------------------------------------------------------------
            // S-type (STORE)
            //-----------------------------------------------------------------
            `OPCODE_STORE: begin
                alu_src    = 1'b1;   // imm (address offset)
                alu_opcode = `ALU_ADD;
                mem_write  = 1'b1;
                case (funct3)
                    `FUNCT3_SB: mem_width = `MEM_WIDTH_BYTE;
                    `FUNCT3_SH: mem_width = `MEM_WIDTH_HALF;
                    `FUNCT3_SW: mem_width = `MEM_WIDTH_WORD;
                    default: ;
                endcase
            end

            //-----------------------------------------------------------------
            // B-type (BRANCH)
            //-----------------------------------------------------------------
            `OPCODE_BRANCH: begin
                branch    = 1'b1;
                alu_src   = 1'b0;   // rs2
                case (funct3)
                    `FUNCT3_BEQ:  alu_opcode = `ALU_EQ;
                    `FUNCT3_BNE:  alu_opcode = `ALU_NE;
                    `FUNCT3_BLT:  alu_opcode = `ALU_SLT;
                    `FUNCT3_BGE:  alu_opcode = `ALU_GE;
                    `FUNCT3_BLTU: alu_opcode = `ALU_SLTU;
                    `FUNCT3_BGEU: alu_opcode = `ALU_GEU;
                    default: ;
                endcase
            end

            //-----------------------------------------------------------------
            // U-type (LUI)
            //-----------------------------------------------------------------
            `OPCODE_LUI: begin
                reg_write  = 1'b1;
                alu_src    = 1'b1;   // imm (upper immediate)
                alu_opcode = `ALU_ADD;
                // ALU: A=0 (rs1=x0 reads zero), B=imm → result = imm
            end

            //-----------------------------------------------------------------
            // U-type (AUIPC)
            //-----------------------------------------------------------------
            `OPCODE_AUIPC: begin
                reg_write  = 1'b1;
                alu_src_a  = 1'b1;   // PC
                alu_src    = 1'b1;   // imm
                alu_opcode = `ALU_ADD;
            end

            //-----------------------------------------------------------------
            // J-type (JAL)
            //-----------------------------------------------------------------
            `OPCODE_JAL: begin
                reg_write  = 1'b1;
                alu_src_a  = 1'b1;   // PC  (for jump target calc)
                alu_src    = 1'b1;   // imm
                alu_opcode = `ALU_ADD;
                // NOTE: PC+4 link-address writeback path is TBD.
                //       For now, alu_opcode drives the jump target.
            end

            //-----------------------------------------------------------------
            // I-type (JALR)
            //-----------------------------------------------------------------
            `OPCODE_JALR: begin
                reg_write  = 1'b1;
                alu_src    = 1'b1;   // imm
                alu_opcode = `ALU_ADD;
                // NOTE: PC+4 link-address writeback path is TBD.
                //       ALU computes rs1 + imm = jump target.
            end

            //-----------------------------------------------------------------
            // SYSTEM (ECALL / EBREAK) — treated as NOP for now
            // MISC-MEM (FENCE / FENCE.I / PAUSE) — treated as NOP for now
            // default: all defaults (NOP), no side effects
            //-----------------------------------------------------------------
            default: ;
        endcase
    end

    // ---- Drive output ports from internal regs ----
    assign o_alu_opcode = alu_opcode;
    assign o_alu_src_a  = alu_src_a;
    assign o_alu_src    = alu_src;
    assign o_branch     = branch;
    assign o_mem_read   = mem_read;
    assign o_mem_write  = mem_write;
    assign o_mem_width  = mem_width;
    assign o_mem_sext   = mem_sext;
    assign o_mem_to_reg = mem_to_reg;
    assign o_reg_write  = reg_write;

endmodule
