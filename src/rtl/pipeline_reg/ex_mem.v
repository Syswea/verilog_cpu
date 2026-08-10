//=============================================================================
// ex_mem.v — EX/MEM Pipeline Register
//=============================================================================
// Latches EX Stage outputs on the clock edge: ALU result (virtual address
// for LOAD/STORE), link address (pc+4), store data, destination register
// and the MEM/WB control bus. Isolates EX combinational logic from MEM.
//
// Total stored width: 109 bits (101 data + 8 control).
//   data:   alu_result(32) + pc_plus4(32) + rs2_data(32) + rd_addr(5)
//   ctrl:   mem_read(1) + mem_write(1) + mem_width(2) + mem_sext(1)
//           + wb_src(2) + reg_write(1)
//
// Priority: i_rst_n (0→clear) > i_flush (clear control, zero data)
//           > i_stall (hold) > latch.
//
// MMU note: o_alu_result is semantically the VIRTUAL address for
// LOAD/STORE; the MMU (future) plugs in AFTER this register, so no
// change is needed here (see mem_stage.md §1.4).
//=============================================================================

`include "const_define.vh"
`include "opcode_define.vh"

module ex_mem (
    // ---- System / Pipeline Control ----
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_flush,         // from flow_ctrl.v
    input  wire        i_stall,         // from hazard_ctrl.v

    // ---- Datapath ----
    input  wire [31:0] i_alu_result,    // from executor.v (ALU result / v_addr)
    input  wire [31:0] i_pc_plus4,      // from executor.v (link address)
    input  wire [31:0] i_rs2_data,      // from executor.v (store data)
    input  wire [ 4:0] i_rd_addr,       // from executor.v

    // ---- Control Bus (from executor.v, passthrough) ----
    input  wire        i_mem_read,
    input  wire        i_mem_write,
    input  wire [ 1:0] i_mem_width,
    input  wire        i_mem_sext,
    input  wire [ 1:0] i_wb_src,
    input  wire        i_reg_write,

    // ---- Datapath Outputs ----
    output reg  [31:0] o_alu_result,    // to data_mem.v (addr) / mem_wb.v
    output reg  [31:0] o_pc_plus4,      // to mem_wb.v
    output reg  [31:0] o_rs2_data,      // to data_mem.v (store data)
    output reg  [ 4:0] o_rd_addr,       // to mem_wb.v → ... → regfile.v

    // ---- Control Bus Outputs ----
    output reg         o_mem_read,      // to data_mem.v
    output reg         o_mem_write,     // to data_mem.v
    output reg  [ 1:0] o_mem_width,     // to data_mem.v
    output reg         o_mem_sext,      // to data_mem.v
    output reg  [ 1:0] o_wb_src,        // to mem_wb.v
    output reg         o_reg_write      // to mem_wb.v
);

    //=========================================================================
    // Pipeline register with stall/flush control
    //=========================================================================
    // Same priority chain as id_ex.v: reset > flush > stall > latch

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            // ---- Reset: all outputs to safe defaults ----
            o_alu_result <= `XLEN_ZERO;
            o_pc_plus4   <= `XLEN_ZERO;
            o_rs2_data   <= `XLEN_ZERO;
            o_rd_addr    <= `REG_X0_ADDR;
            o_mem_read   <= `CTRL_DISABLE;
            o_mem_write  <= `CTRL_DISABLE;
            o_mem_width  <= `MEM_WIDTH_DEFAULT;
            o_mem_sext   <= `CTRL_DISABLE;
            o_wb_src     <= `WB_SRC_ALU;
            o_reg_write  <= `CTRL_DISABLE;

        end else if (i_flush) begin
            // ---- Flush: clear control, zero data (NOP bubble) ----
            o_alu_result <= `XLEN_ZERO;
            o_pc_plus4   <= `XLEN_ZERO;
            o_rs2_data   <= `XLEN_ZERO;
            o_rd_addr    <= `REG_X0_ADDR;
            o_mem_read   <= `CTRL_DISABLE;
            o_mem_write  <= `CTRL_DISABLE;
            o_mem_width  <= `MEM_WIDTH_DEFAULT;
            o_mem_sext   <= `CTRL_DISABLE;
            o_wb_src     <= `WB_SRC_ALU;
            o_reg_write  <= `CTRL_DISABLE;

        end else if (i_stall) begin
            // ---- Stall: hold current values ----
            o_alu_result <= o_alu_result;
            o_pc_plus4   <= o_pc_plus4;
            o_rs2_data   <= o_rs2_data;
            o_rd_addr    <= o_rd_addr;
            o_mem_read   <= o_mem_read;
            o_mem_write  <= o_mem_write;
            o_mem_width  <= o_mem_width;
            o_mem_sext   <= o_mem_sext;
            o_wb_src     <= o_wb_src;
            o_reg_write  <= o_reg_write;

        end else begin
            // ---- Normal: latch inputs ----
            o_alu_result <= i_alu_result;
            o_pc_plus4   <= i_pc_plus4;
            o_rs2_data   <= i_rs2_data;
            o_rd_addr    <= i_rd_addr;
            o_mem_read   <= i_mem_read;
            o_mem_write  <= i_mem_write;
            o_mem_width  <= i_mem_width;
            o_mem_sext   <= i_mem_sext;
            o_wb_src     <= i_wb_src;
            o_reg_write  <= i_reg_write;
        end
    end

endmodule
