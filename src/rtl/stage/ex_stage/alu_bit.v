//=============================================================================
// alu_bit.v — Bitwise + shift unit (SLL/SRL/SRA/XOR/OR/AND)
//=============================================================================
// Pure combinational. Result is gated by i_opcode; any other opcode
// produces `XLEN_ZERO (safe output).
//
// Shift amount is always i_b[4:0] (RV32I spec). For I-type shifts the
// shamt arrives zero-extended inside i_imm by decode.v.
//=============================================================================

`include "const_define.vh"
`include "alu_op_define.vh"

module alu_bit (
    input  wire [31:0] i_a,       // ALU A operand (from executor.v MUX)
    input  wire [31:0] i_b,       // ALU B operand (shift amount / logic B)
    input  wire [ 3:0] i_opcode,  // flat ALU opcode (from decode.v)
    output wire [31:0] o_result   // shift/logic result, else zero
);

    assign o_result = (i_opcode == `ALU_SLL) ? (i_a << i_b[4:0])          :
                      (i_opcode == `ALU_SRL) ? (i_a >> i_b[4:0])          :
                      (i_opcode == `ALU_SRA) ? ($signed(i_a) >>> i_b[4:0]) :
                      (i_opcode == `ALU_XOR) ? (i_a ^ i_b)                :
                      (i_opcode == `ALU_OR)  ? (i_a | i_b)                :
                      (i_opcode == `ALU_AND) ? (i_a & i_b)                :
                                               `XLEN_ZERO;

endmodule
