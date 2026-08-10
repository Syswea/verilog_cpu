`include "const_define.vh"
//=============================================================================
// if_id.v — IF/ID Pipeline Register
//=============================================================================
// Clock-edge register between IF and ID stages.
// Priority: i_rst_n (0→clear) > i_flush (clear) > i_stall (hold) > latch.
//=============================================================================

module if_id (
    input  wire        i_clk,          // system clock
    input  wire        i_rst_n,        // async reset (active low)
    input  wire [31:0] i_instruction,  // instruction word (from inst_mem.v)
    input  wire [31:0] i_pc,           // current PC (from pc.v)
    input  wire        i_flush,        // pipeline flush (from flow_ctrl.v)
    input  wire        i_stall,        // pipeline stall (from hazard_ctrl.v)
    output reg  [31:0] o_instruction,  // instruction word (to decode.v)
    output reg  [31:0] o_pc            // instruction PC (to ID stage)
);

    //-------------------------------------------------------------------------
    // Pipeline register with stall/flush control
    //-------------------------------------------------------------------------

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_instruction <= `INST_NOP;
            o_pc          <= `XLEN_ZERO;
        end else if (i_flush) begin
            o_instruction <= `INST_NOP;
            o_pc          <= `XLEN_ZERO;
        end else if (i_stall) begin
            o_instruction <= o_instruction;
            o_pc          <= o_pc;
        end else begin
            o_instruction <= i_instruction;
            o_pc          <= i_pc;
        end
    end

endmodule
