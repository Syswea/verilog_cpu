//=============================================================================
// const_define.vh — Global constant definitions for the RISC-V CPU
//=============================================================================
// Include this file in every Verilog module. Vivado will add the path to
// the include search list; use plain filename without relative path.
//
// Usage:
//   `include "const_define.vh"
//=============================================================================

`ifndef CONST_DEFINE_VH
`define CONST_DEFINE_VH

//-----------------------------------------------------------------------------
// Instruction Memory
//-----------------------------------------------------------------------------

`define INST_MEM_DEPTH      1024   // ROM depth (words)
`define INST_MEM_ADDR_WIDTH 10     // $clog2(INST_MEM_DEPTH)

//-----------------------------------------------------------------------------
// Instruction encoding
//-----------------------------------------------------------------------------

`define INST_NOP            32'h0  // NOP / bubble value (addi x0, x0, 0)
`define XLEN_ZERO          32'h0  // XLEN-width zero value
`define XLEN_ONE           32'h1  // XLEN-width one value (comparison result)

//-----------------------------------------------------------------------------
// General CPU parameters
//-----------------------------------------------------------------------------

`define XLEN                32     // data width (RV32)
`define PC_INCREMENT        4      // PC step per instruction (RV32: 4 bytes)

//-----------------------------------------------------------------------------
// Register File
//-----------------------------------------------------------------------------

`define REG_COUNT           32     // integer register count
`define REG_ADDR_WIDTH      5      // $clog2(REG_COUNT)
`define REG_X0_ADDR         {`REG_ADDR_WIDTH{1'b0}}  // x0 register address

//-----------------------------------------------------------------------------
// Data Memory
//-----------------------------------------------------------------------------

`define DATA_MEM_DEPTH      1024   // data memory depth (bytes)
`define DATA_MEM_ADDR_WIDTH 10     // $clog2(DATA_MEM_DEPTH)

//-----------------------------------------------------------------------------
// Control signal defaults
//-----------------------------------------------------------------------------
// Default values used during reset and flush to produce safe NOP behavior.

`define CTRL_DISABLE        1'b0   // 1-bit control signal: disabled / false
`define CTRL_ENABLE         1'b1   // 1-bit control signal: enabled  / true

//-----------------------------------------------------------------------------
// Memory access defaults
//-----------------------------------------------------------------------------

`define MEM_WIDTH_DEFAULT   2'b00  // Memory access width default (Byte, safe)
`define MEM_SEXT_DEFAULT    1'b0   // Sign-extension default (zero-extend, safe)
`define MEM_TO_REG_DEFAULT  1'b0   // Writeback source default (ALU result)

//-----------------------------------------------------------------------------
// Writeback source selection (wb_src, 2-bit)
//-----------------------------------------------------------------------------
// Selects which value is written back to the register file in WB stage.
// Replaces the v1 1-bit mem_to_reg (ALU vs MEM) with a 3-way select that
// also covers JAL/JALR link-address (pc+4) writeback.

`define WB_SRC_ALU         2'd0   // write back ALU result
`define WB_SRC_MEM         2'd1   // write back memory read data
`define WB_SRC_PC_PLUS4    2'd2   // write back pc+4 (JAL/JALR link address)
                                 // 2'd3 reserved (future: CSR read value, etc.)

//-----------------------------------------------------------------------------
// Branch / jump address alignment
//-----------------------------------------------------------------------------

`define PC_ALIGN_MASK      32'hFFFFFFFE  // clear LSB — JALR target alignment

`endif // CONST_DEFINE_VH
