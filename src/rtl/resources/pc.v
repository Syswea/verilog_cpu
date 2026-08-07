//=============================================================================
// pc.v — Program Counter register
//=============================================================================
// Stores the current PC value. Receives pc_next from pc_next.v each cycle.
// No stall/flush logic — those are handled upstream by pc_next.v.
//=============================================================================

`include "const_define.vh"

module pc (
    input  wire              i_clk,
    input  wire              i_rst_n,
    input  wire [`XLEN-1:0] i_pc_next,
    output reg  [`XLEN-1:0] o_pc
);

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_pc <= `XLEN_ZERO;
        end else begin
            o_pc <= i_pc_next;
        end
    end

endmodule
