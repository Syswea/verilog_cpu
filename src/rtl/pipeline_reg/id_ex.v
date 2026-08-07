//=============================================================================
// id_ex.v — ID/EX Pipeline Register
//=============================================================================
// Latches the complete control bus (from decode.v), register values
// (from regfile.v), and PC (from if_id.v) on the clock edge.
//
// Does NOT store raw funct3/funct7 — decode.v already decoded them.
// Total stored width: 147 bits (133 data + 14 control).
//
// Priority: i_rst_n (0→clear) > i_flush (clear control, zero data)
//           > i_stall (hold) > latch.
//=============================================================================

`include "const_define.vh"
`include "alu_op_define.vh"

module id_ex (
    // ---- System / Pipeline Control ----
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_flush,         // from flow_control.v
    input  wire        i_stall,         // from hazard_control.v

    // ---- Datapath ----
    input  wire [31:0] i_pc,            // from if_id.v
    input  wire [31:0] i_rs1_data,      // from regfile.v (o_rs1_data)
    input  wire [31:0] i_rs2_data,      // from regfile.v (o_rs2_data)
    input  wire [31:0] i_imm,           // from decode.v (o_imm)
    input  wire [ 4:0] i_rd_addr,       // from decode.v (o_rd_addr)

    // ---- Control Bus (from decode.v) ----
    input  wire [ 3:0] i_alu_opcode,
    input  wire        i_alu_src_a,
    input  wire        i_alu_src,
    input  wire        i_branch,
    input  wire        i_mem_read,
    input  wire        i_mem_write,
    input  wire [ 1:0] i_mem_width,
    input  wire        i_mem_sext,
    input  wire        i_mem_to_reg,
    input  wire        i_reg_write,

    // ---- Datapath Outputs ----
    output reg  [31:0] o_pc,            // to executor.v
    output reg  [31:0] o_rs1_data,      // to executor.v (ALU A port)
    output reg  [31:0] o_rs2_data,      // to executor.v (ALU B port / store data)
    output reg  [31:0] o_imm,           // to executor.v
    output reg  [ 4:0] o_rd_addr,       // to ex_mem.v → ... → regfile.v

    // ---- Control Bus Outputs ----
    output reg  [ 3:0] o_alu_opcode,    // to executor.v (ALU)
    output reg         o_alu_src_a,     // to executor.v
    output reg         o_alu_src,       // to executor.v
    output reg         o_branch,        // to flow_control.v
    output reg         o_mem_read,      // to ex_mem.v → MEM Stage
    output reg         o_mem_write,     // to ex_mem.v → MEM Stage
    output reg  [ 1:0] o_mem_width,     // to ex_mem.v → MEM Stage
    output reg         o_mem_sext,      // to ex_mem.v → MEM Stage
    output reg         o_mem_to_reg,    // to ex_mem.v → WB Stage
    output reg         o_reg_write      // to ex_mem.v → WB Stage
);

    //=========================================================================
    // Pipeline register with stall/flush control
    //=========================================================================
    // Same priority chain as if_id.v:
    //   reset > flush > stall > latch

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            // ---- Reset: all outputs to safe defaults ----
            o_pc          <= `XLEN_ZERO;
            o_rs1_data    <= `XLEN_ZERO;
            o_rs2_data    <= `XLEN_ZERO;
            o_imm         <= `XLEN_ZERO;
            o_rd_addr     <= `REG_X0_ADDR;
            o_alu_opcode  <= `ALU_NOP;
            o_alu_src_a   <= `CTRL_DISABLE;
            o_alu_src     <= `CTRL_DISABLE;
            o_branch      <= `CTRL_DISABLE;
            o_mem_read    <= `CTRL_DISABLE;
            o_mem_write   <= `CTRL_DISABLE;
            o_mem_width   <= `MEM_WIDTH_DEFAULT;
            o_mem_sext    <= `CTRL_DISABLE;
            o_mem_to_reg  <= `CTRL_DISABLE;
            o_reg_write   <= `CTRL_DISABLE;

        end else if (i_flush) begin
            // ---- Flush: clear control, zero data (NOP bubble) ----
            o_pc          <= `XLEN_ZERO;
            o_rs1_data    <= `XLEN_ZERO;
            o_rs2_data    <= `XLEN_ZERO;
            o_imm         <= `XLEN_ZERO;
            o_rd_addr     <= `REG_X0_ADDR;
            o_alu_opcode  <= `ALU_NOP;
            o_alu_src_a   <= `CTRL_DISABLE;
            o_alu_src     <= `CTRL_DISABLE;
            o_branch      <= `CTRL_DISABLE;
            o_mem_read    <= `CTRL_DISABLE;
            o_mem_write   <= `CTRL_DISABLE;
            o_mem_width   <= `MEM_WIDTH_DEFAULT;
            o_mem_sext    <= `CTRL_DISABLE;
            o_mem_to_reg  <= `CTRL_DISABLE;
            o_reg_write   <= `CTRL_DISABLE;

        end else if (i_stall) begin
            // ---- Stall: hold current values ----
            o_pc          <= o_pc;
            o_rs1_data    <= o_rs1_data;
            o_rs2_data    <= o_rs2_data;
            o_imm         <= o_imm;
            o_rd_addr     <= o_rd_addr;
            o_alu_opcode  <= o_alu_opcode;
            o_alu_src_a   <= o_alu_src_a;
            o_alu_src     <= o_alu_src;
            o_branch      <= o_branch;
            o_mem_read    <= o_mem_read;
            o_mem_write   <= o_mem_write;
            o_mem_width   <= o_mem_width;
            o_mem_sext    <= o_mem_sext;
            o_mem_to_reg  <= o_mem_to_reg;
            o_reg_write   <= o_reg_write;

        end else begin
            // ---- Normal: latch inputs ----
            o_pc          <= i_pc;
            o_rs1_data    <= i_rs1_data;
            o_rs2_data    <= i_rs2_data;
            o_imm         <= i_imm;
            o_rd_addr     <= i_rd_addr;
            o_alu_opcode  <= i_alu_opcode;
            o_alu_src_a   <= i_alu_src_a;
            o_alu_src     <= i_alu_src;
            o_branch      <= i_branch;
            o_mem_read    <= i_mem_read;
            o_mem_write   <= i_mem_write;
            o_mem_width   <= i_mem_width;
            o_mem_sext    <= i_mem_sext;
            o_mem_to_reg  <= i_mem_to_reg;
            o_reg_write   <= i_reg_write;
        end
    end

endmodule
