//=============================================================================
// alu_arith.v — Integer arithmetic unit (ADD / SUB)
//=============================================================================
// Pure combinational. Result is gated by i_opcode; any other opcode
// produces `XLEN_ZERO (safe output). Operands i_a / i_b are selected
// upstream (executor.v operand MUX); this unit does not know instruction
// type, only the flat ALU opcode.
//
// Covered instructions: R-type ADD/SUB, ADDI, LOAD/STORE address (rs1+imm),
// LUI (0+imm), AUIPC (pc+imm).
//=============================================================================

`include "const_define.vh"
`include "alu_op_define.vh"

module alu_arith (
    input  wire [31:0] i_a,       // ALU A operand (from executor.v MUX)
    input  wire [31:0] i_b,       // ALU B operand (from executor.v MUX)
    input  wire [ 3:0] i_opcode,  // flat ALU opcode (from decode.v)
    output wire [31:0] o_result   // ADD/SUB result, else zero
);

    assign o_result = (i_opcode == `ALU_ADD) ? (i_a + i_b) :
                      (i_opcode == `ALU_SUB) ? (i_a - i_b) :
                                               `XLEN_ZERO;

endmodule
