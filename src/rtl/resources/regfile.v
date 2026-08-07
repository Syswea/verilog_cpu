//=============================================================================
// regfile.v — 32-entry integer register file (x0–x31)
//=============================================================================
// Dual read ports (combinational) + single write port (sequential).
// x0 is hardwired to zero: reads return 0, writes are ignored.
//=============================================================================

`include "const_define.vh"

module regfile (
    input  wire                      i_clk,
    input  wire                      i_rst_n,
    input  wire [`REG_ADDR_WIDTH-1:0] i_rs1_addr,
    input  wire [`REG_ADDR_WIDTH-1:0] i_rs2_addr,
    input  wire [`REG_ADDR_WIDTH-1:0] i_rd_addr,
    input  wire [`XLEN-1:0]           i_rd_data,
    input  wire                      i_we,
    output wire [`XLEN-1:0]           o_rs1_data,
    output wire [`XLEN-1:0]           o_rs2_data
);

    //---------------------------------------------------------------------
    // Register array
    //---------------------------------------------------------------------
    reg [`XLEN-1:0] rf [0:`REG_COUNT-1];

    //---------------------------------------------------------------------
    // Read ports — combinational, x0 bypass
    //---------------------------------------------------------------------
    assign o_rs1_data = (i_rs1_addr == `REG_X0_ADDR)
                      ? `XLEN_ZERO
                      : rf[i_rs1_addr];

    assign o_rs2_data = (i_rs2_addr == `REG_X0_ADDR)
                      ? `XLEN_ZERO
                      : rf[i_rs2_addr];

    //---------------------------------------------------------------------
    // Write port — sequential, x0 write ignored
    //---------------------------------------------------------------------
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            integer _i;
            for (_i = 0; _i < `REG_COUNT; _i = _i + 1) begin
                rf[_i] <= `XLEN_ZERO;
            end
        end else if (i_we && (i_rd_addr != `REG_X0_ADDR)) begin
            rf[i_rd_addr] <= i_rd_data;
        end
    end

endmodule
