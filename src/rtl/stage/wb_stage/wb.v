//=============================================================================
// wb.v — Write-Back selector (WB Stage)
//=============================================================================
// Pure combinational. Selects the write-back source by wb_src[1:0]:
//   WB_SRC_ALU      → i_alu_result  (R-type, ADDI, LUI, AUIPC, ...)
//   WB_SRC_MEM      → i_read_data   (LB/LH/LW/LBU/LHU)
//   WB_SRC_PC_PLUS4 → i_pc_plus4    (JAL/JALR link address)
//   reserved (2'b11) → i_alu_result (safe default, future CSR read, etc.)
//
// rd_addr / reg_write pass through unchanged. x0 write protection is
// handled inside regfile.v — not duplicated here.
//
// PC update is NOT this stage's concern: the pc register is written by
// flow_ctrl/pc_next/pc.v on the EX-cycle edge (control plane), fully
// decoupled from this write-back path (see design.md "dual-write").
//=============================================================================

`include "const_define.vh"
`include "opcode_define.vh"

module wb (
    // ---- Datapath inputs (from mem_wb.v) ----
    input  wire [31:0] i_alu_result,    // ALU result
    input  wire [31:0] i_read_data,     // load read data
    input  wire [31:0] i_pc_plus4,      // link address (JAL/JALR)
    input  wire [ 1:0] i_wb_src,        // writeback source select
    input  wire [ 4:0] i_rd_addr,       // destination register (passthrough)
    input  wire        i_reg_write,     // regfile write enable (passthrough)

    // ---- Outputs (to regfile.v) ----
    output wire [31:0] o_rd_data,       // write-back data
    output wire [ 4:0] o_rd_addr,       // destination register
    output wire        o_reg_write      // regfile write enable
);

    //---------------------------------------------------------------------
    // Write-back source MUX (2-level, 3-way + safe default)
    //---------------------------------------------------------------------
    assign o_rd_data = (i_wb_src == `WB_SRC_MEM)      ? i_read_data :
                       (i_wb_src == `WB_SRC_PC_PLUS4) ? i_pc_plus4  :
                                                        i_alu_result;  // ALU / reserved

    //---------------------------------------------------------------------
    // Passthrough
    //---------------------------------------------------------------------
    assign o_rd_addr   = i_rd_addr;
    assign o_reg_write = i_reg_write;

endmodule
