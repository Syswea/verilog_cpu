//=============================================================================
// flow_ctrl.v — Pipeline Flow Control (branch redirect + flush)
//=============================================================================
// Pure combinational signal fan-out: converts the EX-stage branch decision
// (branch_taken) into PC redirection (branch_valid / branch_target for
// pc_next.v) and a two-stage flush (if_id / id_ex).
//
// No branch-type decoding: branch_sel is generated in decode.v and the
// branch target is already resolved inside executor.v (JAL/BRANCH = pc+imm,
// JALR = (rs1+imm)&~1). This module only distributes the boolean result.
//
// Two-stage flush rationale: the branch is resolved in EX; at that moment
// the IF/ID and ID/EX stages hold the two wrongly-fetched sequential
// instructions (2-cycle branch penalty). They are flushed to NOP bubbles.
// ex_mem / mem_wb are NOT flushed — the instructions there precede the
// branch and are correct (e.g. the branch's own JAL link-address writeback).
//
// CRITICAL timing: in the SAME cycle-N edge, pc.v loads branch_target AND
// if_id / id_ex are cleared. The branch instruction itself (in ex_mem) is
// untouched and continues its reg_write / pc_plus4 writeback normally.
//=============================================================================

module flow_ctrl (
    // ---- From executor.v (EX Stage) ----
    input  wire        i_branch_taken,   // branch/jump taken (EX decision)
    input  wire [31:0] i_branch_target,  // resolved target (pc+imm / (rs1+imm)&~1)

    // ---- To pc_next.v (PC redirection) ----
    output wire        o_branch_valid,   // redirect PC to o_branch_target
    output wire [31:0] o_branch_target,  // redirect target (passthrough)

    // ---- To pipeline registers (two-stage flush) ----
    output wire        o_flush_if_id,    // flush IF/ID (wrong path inst 1)
    output wire        o_flush_id_ex     // flush ID/EX (wrong path inst 2)
);

    //---------------------------------------------------------------------
    // Signal fan-out — pure combination, no logic
    //---------------------------------------------------------------------
    assign o_branch_valid  = i_branch_taken;
    assign o_branch_target = i_branch_target;   // passthrough, unmodified

    assign o_flush_if_id   = i_branch_taken;    // taken → clear both stages
    assign o_flush_id_ex   = i_branch_taken;

endmodule
