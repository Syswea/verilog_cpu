//=============================================================================
// alu_op_define.vh — ALU opcode constants (flat encoding, 4-bit)
//=============================================================================
// Used by decode.v (output) and executor.v (input).
// Encoding includes arithmetic, logic, shift, and branch comparison ops.
//=============================================================================

`ifndef ALU_OP_DEFINE_VH
`define ALU_OP_DEFINE_VH

//-----------------------------------------------------------------------------
// Arithmetic / Logic
//-----------------------------------------------------------------------------

`define ALU_ADD        4'd0   // A + B
`define ALU_SUB        4'd1   // A - B
`define ALU_SLL        4'd2   // A << B[4:0]
`define ALU_XOR        4'd5   // A ^ B
`define ALU_OR         4'd8   // A | B
`define ALU_AND        4'd9   // A & B

//-----------------------------------------------------------------------------
// Shift
//-----------------------------------------------------------------------------

`define ALU_SRL        4'd6   // A >> B[4:0]  (logical)
`define ALU_SRA        4'd7   // A >> B[4:0]  (arithmetic)

//-----------------------------------------------------------------------------
// Comparison (used by both arithmetic and branch)
//-----------------------------------------------------------------------------

`define ALU_SLT        4'd3   // signed(A) < signed(B)
`define ALU_SLTU       4'd4   // unsigned(A) < unsigned(B)
`define ALU_EQ         4'd10  // A == B
`define ALU_NE         4'd11  // A != B
`define ALU_GE         4'd12  // signed(A) >= signed(B)
`define ALU_GEU        4'd13  // unsigned(A) >= unsigned(B)

//-----------------------------------------------------------------------------
// Special
//-----------------------------------------------------------------------------

`define ALU_NOP        4'd15  // result = 0  (NOP / illegal instruction)

`endif // ALU_OP_DEFINE_VH
