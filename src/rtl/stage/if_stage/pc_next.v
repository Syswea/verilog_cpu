`include "const_define.vh"
//=============================================================================
// pc_next.v — Next-PC computation (IF Stage)
//=============================================================================
// Pure combinational logic. No registers, no clock, no reset.
// Priority: i_stall > i_branch_valid > pc + 4
//=============================================================================

module pc_next (
    input  wire [31:0] i_pc,             // current PC (from pc.v)
    input  wire [31:0] i_branch_target,  // branch/JAL/JALR target (from flow_control.v)
    input  wire        i_branch_valid,   // branch redirect active (from flow_control.v)
    input  wire        i_stall,          // pipeline stall (from hazard_control.v)
    output wire [31:0] o_pc_next         // next-cycle PC (to pc.v)
);

    wire [31:0] pc_plus4;

    assign pc_plus4 = i_pc + `PC_INCREMENT;

    assign o_pc_next = i_stall         ? i_pc            :
                       i_branch_valid  ? i_branch_target :
                                         pc_plus4;

endmodule
