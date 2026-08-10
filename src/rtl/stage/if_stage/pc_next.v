`include "const_define.vh"
//=============================================================================
// pc_next.v — Next-PC computation (IF Stage)
//=============================================================================
// Pure combinational logic. No registers, no clock, no reset.
// Priority: i_branch_valid > i_stall > pc + 4
//
// branch_valid takes priority over stall: a taken branch redirects the PC
// in the same cycle (the two wrong-path instructions are flushed by
// flow_ctrl), while stall only freezes PC when no branch redirect is
// active. If stall had priority, a branch taken simultaneously with a RAW
// stall would be silently dropped — a correctness bug.
//=============================================================================

module pc_next (
    input  wire [31:0] i_pc,             // current PC (from pc.v)
    input  wire [31:0] i_branch_target,  // branch/JAL/JALR target (from flow_ctrl.v)
    input  wire        i_branch_valid,   // branch redirect active (from flow_ctrl.v)
    input  wire        i_stall,          // pipeline stall (from hazard_ctrl.v)
    output wire [31:0] o_pc_next         // next-cycle PC (to pc.v)
);

    wire [31:0] pc_plus4;

    assign pc_plus4 = i_pc + `PC_INCREMENT;

    assign o_pc_next = i_branch_valid  ? i_branch_target :
                       i_stall         ? i_pc            :
                                         pc_plus4;

endmodule
