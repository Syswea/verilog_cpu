//=============================================================================
// hazard_ctrl.v — Pipeline Hazard Control (RAW detection, Plan A)
//=============================================================================
// Pure combinational. Detects RAW (read-after-write) dependencies between
// the ID-stage instruction (decode output rs1/rs2) and instructions still
// in the pipeline that have NOT yet written back (ex_mem / mem_wb with
// reg_write=1 and rd != x0). On a match, asserts o_stall.
//
// Plan A (no forwarding): every RAW stalls until the producer writes back
// (3 cycles for adjacent, 2 / 1 for further apart). Forwarding (Plan B) is
// designed in hazard_ctrl.md but NOT implemented here.
//
// Stall fan-out (Plan A semantics):
//   - pc_next:     freeze PC   (stall takes effect only when no branch)
//   - if_id:       hold        (use stays in ID, re-reads regfile each cycle)
//   - id_ex:       inject NOP  (bubble, so producer can advance to WB)
//   - ex_mem/mem_wb: NOT connected to stall (producer must advance to write back)
//
// Structural hazards: none (single regfile write port, exclusive access,
// split instruction/data memory, mutually-exclusive mem_read/mem_write).
// Control hazards: handled by flow_ctrl.v, not here.
//=============================================================================

`include "const_define.vh"

module hazard_ctrl (
    // ---- ID-stage instruction source addresses (from decode.v) ----
    input  wire [ 4:0] i_rs1_addr,       // rs1 address of use instruction
    input  wire [ 4:0] i_rs2_addr,       // rs2 address of use instruction

    // ---- Pipeline producer status (from ex_mem.v) ----
    input  wire [ 4:0] i_ex_mem_rd,      // EX/MEM destination register
    input  wire        i_ex_mem_reg_write, // EX/MEM regfile write enable

    // ---- Pipeline producer status (from mem_wb.v) ----
    input  wire [ 4:0] i_mem_wb_rd,      // MEM/WB destination register
    input  wire        i_mem_wb_reg_write, // MEM/WB regfile write enable

    // ---- Output ----
    output wire        o_stall           // freeze PC + IF/ID, NOP into ID/EX
);

    //---------------------------------------------------------------------
    // RAW match helper (wire function via continuous assign)
    //---------------------------------------------------------------------
    // A producer write is visible to the use instruction only if the
    // producer has NOT yet written back. Matches:
    //   reg_write && rd != x0 && (rd == rs1 || rd == rs2)
    // x0 filter: writing x0 is a no-op, never stalls.

    wire ex_mem_rs1_hit = i_ex_mem_reg_write &&
                          (i_ex_mem_rd != `REG_X0_ADDR) &&
                          (i_ex_mem_rd == i_rs1_addr);
    wire ex_mem_rs2_hit = i_ex_mem_reg_write &&
                          (i_ex_mem_rd != `REG_X0_ADDR) &&
                          (i_ex_mem_rd == i_rs2_addr);
    wire mem_wb_rs1_hit = i_mem_wb_reg_write &&
                          (i_mem_wb_rd != `REG_X0_ADDR) &&
                          (i_mem_wb_rd == i_rs1_addr);
    wire mem_wb_rs2_hit = i_mem_wb_reg_write &&
                          (i_mem_wb_rd != `REG_X0_ADDR) &&
                          (i_mem_wb_rd == i_rs2_addr);

    assign o_stall = ex_mem_rs1_hit | ex_mem_rs2_hit |
                     mem_wb_rs1_hit | mem_wb_rs2_hit;

endmodule
