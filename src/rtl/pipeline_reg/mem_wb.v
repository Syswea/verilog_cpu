//=============================================================================
// mem_wb.v — MEM/WB Pipeline Register
//=============================================================================
// Latches WB-stage inputs on the clock edge: ALU result, link address
// (pc+4), load read data, destination register and the WB control bus
// (wb_src, reg_write). MEM-stage signals (mem_read/write/width/sext) are
// consumed in MEM and deliberately NOT latched (minimal width).
//
// Total stored width: 104 bits (101 data + 3 control).
//   data: alu_result(32) + pc_plus4(32) + read_data(32) + rd_addr(5)
//   ctrl: wb_src(2) + reg_write(1)
//
// Priority: i_rst_n (0→clear) > i_flush (clear control, zero data)
//           > i_stall (hold) > latch.
//
// stall/flush are required even though WB is the last stage: on load-use
// freeze the whole pipeline holds (WB must not advance and overwrite a
// wrong register), on branch flush stale instructions must not write back.
//=============================================================================

`include "const_define.vh"
`include "opcode_define.vh"

module mem_wb (
    // ---- System / Pipeline Control ----
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_flush,         // from flow_ctrl.v
    input  wire        i_stall,         // from hazard_ctrl.v

    // ---- Datapath ----
    input  wire [31:0] i_alu_result,    // from ex_mem.v (ALU result)
    input  wire [31:0] i_pc_plus4,      // from ex_mem.v (link address)
    input  wire [31:0] i_read_data,     // from data_mem.v (load data)
    input  wire [ 4:0] i_rd_addr,       // from ex_mem.v

    // ---- Control Bus (from ex_mem.v, passthrough) ----
    input  wire [ 1:0] i_wb_src,        // writeback source select
    input  wire        i_reg_write,     // regfile write enable

    // ---- Datapath Outputs ----
    output reg  [31:0] o_alu_result,    // to wb.v
    output reg  [31:0] o_pc_plus4,      // to wb.v
    output reg  [31:0] o_read_data,     // to wb.v
    output reg  [ 4:0] o_rd_addr,       // to wb.v → regfile.v

    // ---- Control Bus Outputs ----
    output reg  [ 1:0] o_wb_src,        // to wb.v
    output reg         o_reg_write      // to wb.v → regfile.v
);

    //=========================================================================
    // Pipeline register with stall/flush control
    //=========================================================================
    // Same priority chain as id_ex.v / ex_mem.v: reset > flush > stall > latch

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            // ---- Reset: all outputs to safe defaults ----
            o_alu_result <= `XLEN_ZERO;
            o_pc_plus4   <= `XLEN_ZERO;
            o_read_data  <= `XLEN_ZERO;
            o_rd_addr    <= `REG_X0_ADDR;
            o_wb_src     <= `WB_SRC_ALU;
            o_reg_write  <= `CTRL_DISABLE;

        end else if (i_flush) begin
            // ---- Flush: clear control, zero data (NOP bubble) ----
            o_alu_result <= `XLEN_ZERO;
            o_pc_plus4   <= `XLEN_ZERO;
            o_read_data  <= `XLEN_ZERO;
            o_rd_addr    <= `REG_X0_ADDR;
            o_wb_src     <= `WB_SRC_ALU;
            o_reg_write  <= `CTRL_DISABLE;

        end else if (i_stall) begin
            // ---- Stall: hold current values ----
            o_alu_result <= o_alu_result;
            o_pc_plus4   <= o_pc_plus4;
            o_read_data  <= o_read_data;
            o_rd_addr    <= o_rd_addr;
            o_wb_src     <= o_wb_src;
            o_reg_write  <= o_reg_write;

        end else begin
            // ---- Normal: latch inputs ----
            o_alu_result <= i_alu_result;
            o_pc_plus4   <= i_pc_plus4;
            o_read_data  <= i_read_data;
            o_rd_addr    <= i_rd_addr;
            o_wb_src     <= i_wb_src;
            o_reg_write  <= i_reg_write;
        end
    end

endmodule
