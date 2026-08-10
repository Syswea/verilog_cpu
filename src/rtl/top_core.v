//=============================================================================
// top_core.v — RISC-V CPU top level (5-stage pipeline)
//=============================================================================
// Instantiates and interconnects all submodules:
//   Resources: pc.v, regfile.v
//   IF:        pc_next.v, inst_mem.v, if_id.v
//   ID:        decode.v, id_ex.v
//   EX:        executor.v (wraps alu.v + alu_arith/bit/cmp)
//   MEM:       ex_mem.v, data_mem.v
//   WB:        mem_wb.v, wb.v
//   Pipeline Control: flow_ctrl.v, hazard_ctrl.v
//
// Pure wiring — no logic. External interface: i_clk / i_rst_n only
// (future: bus, interrupt, debug ports appended here).
//
// Control-plane connections:
//   - branch_taken/target → flow_ctrl → pc_next (PC redirect) + if_id/id_ex (flush)
//   - hazard_ctrl (RAW detect) → stall → pc_next, if_id (freeze), id_ex (NOP)
//   - ex_mem / mem_wb: i_flush=0, i_stall=0 (Plan A: producers must advance
//     to WB to write back; branch flush never reaches later stages)
// MMU (future) plugs between ex_mem.o_alu_result and data_mem.i_addr.
//=============================================================================

`include "const_define.vh"

module top_core (
    input  wire i_clk,       // global clock
    input  wire i_rst_n      // async reset, active low
);

    //---------------------------------------------------------------------
    // Internal nets
    //---------------------------------------------------------------------
    // PC / IF
    wire [31:0] pc;                  // pc.v → inst_mem/if_id/pc_next/id_ex
    wire [31:0] pc_next;             // pc_next.v → pc.v
    wire [31:0] inst;                // inst_mem.v → if_id.v
    wire [31:0] if_id_inst;          // if_id.v → decode.v
    wire [31:0] if_id_pc;            // if_id.v → id_ex.v

    // ID (decode → regfile / id_ex / hazard_ctrl)
    wire [ 4:0] rs1_addr, rs2_addr, id_rd_addr;
    wire [31:0] id_imm;
    wire [ 3:0] id_alu_opcode;
    wire [ 1:0] id_alu_src_a;
    wire        id_alu_src;
    wire [ 1:0] id_branch_sel;
    wire        id_mem_read, id_mem_write, id_mem_sext;
    wire [ 1:0] id_mem_width;
    wire [ 1:0] id_wb_src;
    wire        id_reg_write;

    // regfile read data
    wire [31:0] rs1_data, rs2_data;

    // ID/EX → EX
    wire [31:0] ex_pc, ex_rs1_data, ex_rs2_data, ex_imm;
    wire [ 4:0] ex_rd_addr;
    wire [ 3:0] ex_alu_opcode;
    wire [ 1:0] ex_alu_src_a;
    wire        ex_alu_src;
    wire [ 1:0] ex_branch_sel;
    wire        ex_mem_read, ex_mem_write, ex_mem_sext;
    wire [ 1:0] ex_mem_width;
    wire [ 1:0] ex_wb_src;
    wire        ex_reg_write;

    // EX → ex_mem / flow_ctrl
    wire [31:0] ex_alu_result, ex_pc_plus4, ex_rs2_data_out;
    wire [ 4:0] ex_rd_addr_out;
    wire        ex_branch_taken;
    wire [31:0] ex_branch_target;
    // EX control passthrough outputs (id_ex input → executor output, distinct names)
    wire        ex_mem_read_out, ex_mem_write_out, ex_mem_sext_out;
    wire [ 1:0] ex_mem_width_out;
    wire [ 1:0] ex_wb_src_out;
    wire        ex_reg_write_out;

    // ex_mem → MEM / mem_wb / hazard_ctrl
    wire [31:0] mem_alu_result, mem_pc_plus4, mem_rs2_data;
    wire [ 4:0] mem_rd_addr;
    wire        mem_mem_read, mem_mem_write, mem_mem_sext;
    wire [ 1:0] mem_mem_width;
    wire [ 1:0] mem_wb_src;
    wire        mem_reg_write;
    wire [31:0] mem_read_data;   // data_mem.v → mem_wb.v

    // mem_wb → wb
    wire [31:0] wb_alu_result, wb_pc_plus4, wb_read_data;
    wire [ 4:0] wb_rd_addr;
    wire [ 1:0] wb_wb_src;
    wire        wb_reg_write;

    // wb → regfile
    wire [31:0] wb_rd_data;
    wire [ 4:0] wb_rd_addr_out;
    wire        wb_reg_write_out;

    // Pipeline control
    wire        fc_branch_valid;
    wire [31:0] fc_branch_target;
    wire        fc_flush_if_id, fc_flush_id_ex;
    wire        hc_stall;

    //---------------------------------------------------------------------
    // Resources
    //---------------------------------------------------------------------
    pc u_pc (
        .i_clk      (i_clk),
        .i_rst_n    (i_rst_n),
        .i_pc_next  (pc_next),
        .o_pc       (pc)
    );

    regfile u_regfile (
        .i_clk      (i_clk),
        .i_rst_n    (i_rst_n),
        .i_rs1_addr (rs1_addr),
        .i_rs2_addr (rs2_addr),
        .i_rd_addr  (wb_rd_addr_out),
        .i_rd_data  (wb_rd_data),
        .i_we       (wb_reg_write_out),
        .o_rs1_data (rs1_data),
        .o_rs2_data (rs2_data)
    );

    //---------------------------------------------------------------------
    // IF Stage
    //---------------------------------------------------------------------
    pc_next u_pc_next (
        .i_pc            (pc),
        .i_branch_target (fc_branch_target),
        .i_branch_valid  (fc_branch_valid),
        .i_stall         (hc_stall),
        .o_pc_next       (pc_next)
    );

    inst_mem u_inst_mem (
        .i_pc           (pc),
        .o_instruction  (inst)
    );

    if_id u_if_id (
        .i_clk          (i_clk),
        .i_rst_n        (i_rst_n),
        .i_instruction  (inst),
        .i_pc           (pc),
        .i_flush        (fc_flush_if_id),
        .i_stall        (hc_stall),
        .o_instruction  (if_id_inst),
        .o_pc           (if_id_pc)
    );

    //---------------------------------------------------------------------
    // ID Stage
    //---------------------------------------------------------------------
    decode u_decode (
        .i_instruction (if_id_inst),
        .o_rs1_addr    (rs1_addr),
        .o_rs2_addr    (rs2_addr),
        .o_rd_addr     (id_rd_addr),
        .o_imm         (id_imm),
        .o_alu_opcode  (id_alu_opcode),
        .o_alu_src_a   (id_alu_src_a),
        .o_alu_src     (id_alu_src),
        .o_branch_sel  (id_branch_sel),
        .o_mem_read    (id_mem_read),
        .o_mem_write   (id_mem_write),
        .o_mem_width   (id_mem_width),
        .o_mem_sext    (id_mem_sext),
        .o_wb_src      (id_wb_src),
        .o_reg_write   (id_reg_write)
    );

    id_ex u_id_ex (
        .i_clk          (i_clk),
        .i_rst_n        (i_rst_n),
        .i_flush        (fc_flush_id_ex),
        .i_stall        (hc_stall),
        .i_pc           (if_id_pc),
        .i_rs1_data     (rs1_data),
        .i_rs2_data     (rs2_data),
        .i_imm          (id_imm),
        .i_rd_addr      (id_rd_addr),
        .i_alu_opcode   (id_alu_opcode),
        .i_alu_src_a    (id_alu_src_a),
        .i_alu_src      (id_alu_src),
        .i_branch_sel   (id_branch_sel),
        .i_mem_read     (id_mem_read),
        .i_mem_write    (id_mem_write),
        .i_mem_width    (id_mem_width),
        .i_mem_sext     (id_mem_sext),
        .i_wb_src       (id_wb_src),
        .i_reg_write    (id_reg_write),
        .o_pc           (ex_pc),
        .o_rs1_data     (ex_rs1_data),
        .o_rs2_data     (ex_rs2_data),
        .o_imm          (ex_imm),
        .o_rd_addr      (ex_rd_addr),
        .o_alu_opcode   (ex_alu_opcode),
        .o_alu_src_a    (ex_alu_src_a),
        .o_alu_src      (ex_alu_src),
        .o_branch_sel   (ex_branch_sel),
        .o_mem_read     (ex_mem_read),
        .o_mem_write    (ex_mem_write),
        .o_mem_width    (ex_mem_width),
        .o_mem_sext     (ex_mem_sext),
        .o_wb_src       (ex_wb_src),
        .o_reg_write    (ex_reg_write)
    );

    //---------------------------------------------------------------------
    // EX Stage
    //---------------------------------------------------------------------
    executor u_executor (
        .i_pc            (ex_pc),
        .i_rs1_data      (ex_rs1_data),
        .i_rs2_data      (ex_rs2_data),
        .i_imm           (ex_imm),
        .i_rd_addr       (ex_rd_addr),
        .i_alu_opcode    (ex_alu_opcode),
        .i_alu_src_a     (ex_alu_src_a),
        .i_alu_src       (ex_alu_src),
        .i_branch_sel    (ex_branch_sel),
        .i_mem_read      (ex_mem_read),
        .i_mem_write     (ex_mem_write),
        .i_mem_width     (ex_mem_width),
        .i_mem_sext      (ex_mem_sext),
        .i_wb_src        (ex_wb_src),
        .i_reg_write     (ex_reg_write),
        .o_alu_result    (ex_alu_result),
        .o_pc_plus4      (ex_pc_plus4),
        .o_rs2_data      (ex_rs2_data_out),
        .o_rd_addr       (ex_rd_addr_out),
        .o_mem_read      (ex_mem_read_out),
        .o_mem_write     (ex_mem_write_out),
        .o_mem_width     (ex_mem_width_out),
        .o_mem_sext      (ex_mem_sext_out),
        .o_wb_src        (ex_wb_src_out),
        .o_reg_write     (ex_reg_write_out),
        .o_branch_taken  (ex_branch_taken),
        .o_branch_target (ex_branch_target)
    );

    //---------------------------------------------------------------------
    // MEM Stage
    //---------------------------------------------------------------------
    ex_mem u_ex_mem (
        .i_clk          (i_clk),
        .i_rst_n        (i_rst_n),
        .i_flush        (1'b0),        // branch flush does not reach EX/MEM
        .i_stall        (1'b0),        // Plan A: producer must advance
        .i_alu_result   (ex_alu_result),
        .i_pc_plus4     (ex_pc_plus4),
        .i_rs2_data     (ex_rs2_data_out),
        .i_rd_addr      (ex_rd_addr_out),
        .i_mem_read     (ex_mem_read_out),
        .i_mem_write    (ex_mem_write_out),
        .i_mem_width    (ex_mem_width_out),
        .i_mem_sext     (ex_mem_sext_out),
        .i_wb_src       (ex_wb_src_out),
        .i_reg_write    (ex_reg_write_out),
        .o_alu_result   (mem_alu_result),
        .o_pc_plus4     (mem_pc_plus4),
        .o_rs2_data     (mem_rs2_data),
        .o_rd_addr      (mem_rd_addr),
        .o_mem_read     (mem_mem_read),
        .o_mem_write    (mem_mem_write),
        .o_mem_width    (mem_mem_width),
        .o_mem_sext     (mem_mem_sext),
        .o_wb_src       (mem_wb_src),
        .o_reg_write    (mem_reg_write)
    );

    data_mem u_data_mem (
        .i_clk          (i_clk),
        .i_addr         (mem_alu_result),   // physical addr (v_addr passthrough, MMU future)
        .i_write_data   (mem_rs2_data),
        .i_mem_read     (mem_mem_read),
        .i_mem_write    (mem_mem_write),
        .i_mem_width    (mem_mem_width),
        .i_mem_sext     (mem_mem_sext),
        .o_read_data    (mem_read_data)
    );

    //---------------------------------------------------------------------
    // WB Stage
    //---------------------------------------------------------------------
    mem_wb u_mem_wb (
        .i_clk          (i_clk),
        .i_rst_n        (i_rst_n),
        .i_flush        (1'b0),        // branch flush does not reach MEM/WB
        .i_stall        (1'b0),        // Plan A: producer must advance
        .i_alu_result   (mem_alu_result),
        .i_pc_plus4     (mem_pc_plus4),
        .i_read_data    (mem_read_data),
        .i_rd_addr      (mem_rd_addr),
        .i_wb_src       (mem_wb_src),
        .i_reg_write    (mem_reg_write),
        .o_alu_result   (wb_alu_result),
        .o_pc_plus4     (wb_pc_plus4),
        .o_read_data    (wb_read_data),
        .o_rd_addr      (wb_rd_addr),
        .o_wb_src       (wb_wb_src),
        .o_reg_write    (wb_reg_write)
    );

    wb u_wb (
        .i_alu_result   (wb_alu_result),
        .i_read_data    (wb_read_data),
        .i_pc_plus4     (wb_pc_plus4),
        .i_wb_src       (wb_wb_src),
        .i_rd_addr      (wb_rd_addr),
        .i_reg_write    (wb_reg_write),
        .o_rd_data      (wb_rd_data),
        .o_rd_addr      (wb_rd_addr_out),
        .o_reg_write    (wb_reg_write_out)
    );

    //---------------------------------------------------------------------
    // Pipeline Control
    //---------------------------------------------------------------------
    flow_ctrl u_flow_ctrl (
        .i_branch_taken  (ex_branch_taken),
        .i_branch_target (ex_branch_target),
        .o_branch_valid  (fc_branch_valid),
        .o_branch_target (fc_branch_target),
        .o_flush_if_id   (fc_flush_if_id),
        .o_flush_id_ex   (fc_flush_id_ex)
    );

    hazard_ctrl u_hazard_ctrl (
        .i_rs1_addr         (rs1_addr),
        .i_rs2_addr         (rs2_addr),
        .i_ex_mem_rd        (mem_rd_addr),
        .i_ex_mem_reg_write (mem_reg_write),
        .i_mem_wb_rd        (wb_rd_addr),
        .i_mem_wb_reg_write (wb_reg_write),
        .o_stall            (hc_stall)
    );

endmodule
