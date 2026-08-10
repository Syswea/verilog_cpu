//=============================================================================
// alu.v — Top-level ALU selector (instantiates arith / bit / cmp)
//=============================================================================
// Pure combinational. All three sub-units run in parallel and are always
// computing; i_opcode selects which result propagates to o_result.
// ALU_NOP (15) / reserved (14) → `XLEN_ZERO.
//
// Extensibility: an M-extension multiplier/divider is added as a new
// sub-unit plus one more MUX branch here.
//=============================================================================

`include "const_define.vh"
`include "alu_op_define.vh"

module alu (
    input  wire [31:0] i_a,       // ALU A operand (from executor.v MUX)
    input  wire [31:0] i_b,       // ALU B operand (from executor.v MUX)
    input  wire [ 3:0] i_opcode,  // flat ALU opcode (from decode.v)
    output wire [31:0] o_result   // selected ALU result
);

    //---------------------------------------------------------------------
    // Sub-unit results (all computed in parallel, unconditionally)
    //---------------------------------------------------------------------
    wire [31:0] arith_result;
    wire [31:0] bit_result;
    wire [31:0] cmp_result;

    alu_arith u_alu_arith (
        .i_a      (i_a),
        .i_b      (i_b),
        .i_opcode (i_opcode),
        .o_result (arith_result)
    );

    alu_bit u_alu_bit (
        .i_a      (i_a),
        .i_b      (i_b),
        .i_opcode (i_opcode),
        .o_result (bit_result)
    );

    alu_cmp u_alu_cmp (
        .i_a      (i_a),
        .i_b      (i_b),
        .i_opcode (i_opcode),
        .o_result (cmp_result)
    );

    //---------------------------------------------------------------------
    // Result MUX by opcode class
    //---------------------------------------------------------------------
    // arith: ADD(0), SUB(1)
    // bit:   SLL(2), XOR(5), SRL(6), SRA(7), OR(8), AND(9)
    // cmp:   SLT(3), SLTU(4), EQ(10), NE(11), GE(12), GEU(13)
    // other: NOP(15), reserved(14) → zero
    assign o_result = (i_opcode == `ALU_ADD || i_opcode == `ALU_SUB)      ? arith_result :
                      (i_opcode == `ALU_SLL || i_opcode == `ALU_SRL ||
                       i_opcode == `ALU_SRA || i_opcode == `ALU_XOR ||
                       i_opcode == `ALU_OR  || i_opcode == `ALU_AND)      ? bit_result   :
                      (i_opcode == `ALU_SLT || i_opcode == `ALU_SLTU ||
                       i_opcode == `ALU_EQ  || i_opcode == `ALU_NE  ||
                       i_opcode == `ALU_GE  || i_opcode == `ALU_GEU)      ? cmp_result   :
                                                                            `XLEN_ZERO;

endmodule
