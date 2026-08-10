//=============================================================================
// alu_cmp.v — Comparison unit (SLT/SLTU/EQ/NE/GE/GEU)
//=============================================================================
// Pure combinational. Every comparison outputs a 0/1 boolean — used both
// as the write-back value for SLT/SLTI... and directly as branch_taken
// for conditional branches (Branch Unit reads o_result[0]).
//=============================================================================

`include "const_define.vh"
`include "alu_op_define.vh"

module alu_cmp (
    input  wire [31:0] i_a,       // ALU A operand (from executor.v MUX)
    input  wire [31:0] i_b,       // ALU B operand (from executor.v MUX)
    input  wire [ 3:0] i_opcode,  // flat ALU opcode (from decode.v)
    output wire [31:0] o_result   // boolean 0/1 result, else zero
);

    assign o_result = (i_opcode == `ALU_SLT)  ? (($signed(i_a) <  $signed(i_b)) ? `XLEN_ONE : `XLEN_ZERO) :
                      (i_opcode == `ALU_SLTU) ? ((i_a < i_b)                     ? `XLEN_ONE : `XLEN_ZERO) :
                      (i_opcode == `ALU_EQ)   ? ((i_a == i_b)                    ? `XLEN_ONE : `XLEN_ZERO) :
                      (i_opcode == `ALU_NE)   ? ((i_a != i_b)                    ? `XLEN_ONE : `XLEN_ZERO) :
                      (i_opcode == `ALU_GE)   ? (($signed(i_a) >= $signed(i_b)) ? `XLEN_ONE : `XLEN_ZERO) :
                      (i_opcode == `ALU_GEU)  ? ((i_a >= i_b)                    ? `XLEN_ONE : `XLEN_ZERO) :
                                               `XLEN_ZERO;

endmodule
