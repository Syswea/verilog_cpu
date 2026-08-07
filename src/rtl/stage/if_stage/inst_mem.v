`include "const_define.vh"
//=============================================================================
// inst_mem.v — Instruction Memory (IF Stage)
//=============================================================================
// Combinational-read ROM, initialized via $readmemh.
// Unmapped addresses return 32'h0 (NOP: addi x0, x0, 0).
//=============================================================================

module inst_mem (
    input  wire [31:0] i_pc,             // instruction address, byte-aligned (from pc.v)
    output wire [31:0] o_instruction     // 32-bit instruction word (to if_id.v)
);

    localparam DEPTH    = `INST_MEM_DEPTH;
    localparam ADDR_LO  = 2;
    localparam ADDR_HI  = ADDR_LO + $clog2(DEPTH) - 1;

    // (* ram_style = "block" *) — uncomment for Xilinx to infer BRAM
    reg [31:0] rom [0:DEPTH-1];

    //-------------------------------------------------------------------------
    // Initialisation
    //-------------------------------------------------------------------------

    initial begin
        $readmemh("firmware.hex", rom);
    end

    //-------------------------------------------------------------------------
    // Combinational read
    //-------------------------------------------------------------------------

    wire [31:0] word_addr_ext;
    assign word_addr_ext = {22'h0, i_pc[ADDR_HI:ADDR_LO]};

    assign o_instruction = (word_addr_ext < 32'(DEPTH))
                         ? rom[i_pc[ADDR_HI:ADDR_LO]]
                         : 32'h0;

    //-------------------------------------------------------------------------
    // Simulation-only: misaligned access check
    //-------------------------------------------------------------------------

    `ifdef VERILATOR
    always_comb begin
        if (i_pc[1:0] != 2'b00)
            $error("[inst_mem] misaligned instruction fetch at pc=0x%h", i_pc);
    end
    `endif

endmodule
