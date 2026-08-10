//=============================================================================
// data_mem.v — Data Memory (MEM Stage)
//=============================================================================
// Byte-addressed data memory, word-array organization:
//   reg [31:0] mem [0 : DATA_MEM_DEPTH/4 - 1]
// Byte addressing is a semantic contract (RISC-V): i_addr is a byte
// address; word index = i_addr[31:2], byte lane = i_addr[1:0] (little-endian).
//
// - Read:  combinational (async), width/sext decode in combinational path.
//   Combinational read is a HARD REQUIREMENT — it is the premise of the
//   future single-cycle MMU path (see mem_stage.md §1.4). Do NOT make it
//   synchronous.
// - Write: synchronous, 4-bit byte-enable gated by i_mem_write only.
//   flush/stall are handled upstream by ex_mem.v clearing/holding
//   i_mem_write; this module never generates its own write condition.
// - Init:  $readmemh from data file (per design decision); tb preloads
//   data from file.
// - Unmapped addresses (>= DATA_MEM_DEPTH): read 0, write ignored.
// - Misaligned access: sim-only assertion (SH/SW), hardware ignores
//   low address bits (natural alignment).
//=============================================================================

`include "const_define.vh"
`include "opcode_define.vh"

module data_mem (
    input  wire        i_clk,           // system clock (write path only)
    input  wire [31:0] i_addr,          // byte address (physical addr, from ex_mem)
    input  wire [31:0] i_write_data,    // store data (from ex_mem.o_rs2_data)
    input  wire        i_mem_read,      // load enable (from ex_mem.o_mem_read)
    input  wire        i_mem_write,     // store enable (from ex_mem.o_mem_write)
    input  wire [ 1:0] i_mem_width,     // 00=Byte, 01=Half, 10=Word
    input  wire        i_mem_sext,      // 0=zero-extend, 1=sign-extend
    output wire [31:0] o_read_data      // load data (combinational, to mem_wb.v)
);

    //---------------------------------------------------------------------
    // Parameters derived from constants
    //---------------------------------------------------------------------
    localparam DEPTH      = `DATA_MEM_DEPTH;
    localparam WORD_CNT   = DEPTH / 4;
    localparam WORD_IDX_W = $clog2(WORD_CNT);

    //---------------------------------------------------------------------
    // Memory array — word organization (4 bytes per element, little-endian)
    //---------------------------------------------------------------------
    // (* ram_style = "block" *) — uncomment for Xilinx to infer BRAM
    reg [31:0] mem [0:WORD_CNT-1];

    //---------------------------------------------------------------------
    // Initialisation — preload from data file (design decision)
    //---------------------------------------------------------------------
    initial begin
        $readmemh("data_mem.hex", mem);
    end

    //---------------------------------------------------------------------
    // Address decomposition
    //---------------------------------------------------------------------
    wire [WORD_IDX_W-1:0] word_index;   // which 4-byte word
    wire [1:0]            byte_lane;    // which byte inside the word
    wire                  addr_in_range; // word_index fits inside memory

    assign word_index = i_addr[WORD_IDX_W+1:2];
    assign byte_lane  = i_addr[1:0];
    // Unmapped check: any address bit above the word-index range is out of
    // bounds (32-bit compare, matches inst_mem.v style).
    assign addr_in_range = (i_addr[31:WORD_IDX_W+2] == '0);

    //---------------------------------------------------------------------
    // Write path — synchronous, 4-bit byte enable, gated by i_mem_write
    //---------------------------------------------------------------------
    // Byte enables by width:
    //   SW: 1111 | SH: addr[1]?1100:0011 | SB: 0001 << addr[1:0]
    wire [3:0] be;
    assign be = (i_mem_width == `MEM_WIDTH_WORD) ? 4'b1111 :
                (i_mem_width == `MEM_WIDTH_HALF) ? (byte_lane[1] ? 4'b1100 : 4'b0011) :
                (i_mem_width == `MEM_WIDTH_BYTE) ? (4'b0001 << byte_lane) :
                                                   4'b0000;

    // Write data aligned to target byte lane (SH/SB): shift left by lane*8
    wire [31:0] write_lane = i_write_data << {byte_lane, 3'b000};

    always_ff @(posedge i_clk) begin
        if (i_mem_write && addr_in_range) begin
            // Byte-wise write with enable mask (equivalent to read-modify-write)
            if (be[0]) mem[word_index][ 7: 0] <= write_lane[ 7: 0];
            if (be[1]) mem[word_index][15: 8] <= write_lane[15: 8];
            if (be[2]) mem[word_index][23:16] <= write_lane[23:16];
            if (be[3]) mem[word_index][31:24] <= write_lane[31:24];
        end
    end

    //---------------------------------------------------------------------
    // Read path — combinational (must stay combinational, see header)
    //---------------------------------------------------------------------
    // LW: full word | LH: halfword lane | LB: byte lane, then sext/zext
    wire [31:0] word_data;

    assign word_data = addr_in_range
                     ? mem[word_index]
                     : `XLEN_ZERO;   // unmapped: read 0

    // Raw extracted field before extension
    wire [15:0] half_raw;
    wire [ 7:0] byte_raw;
    assign half_raw = byte_lane[1] ? word_data[31:16] : word_data[15: 0];
    assign byte_raw = word_data[byte_lane*8 +: 8];

    assign o_read_data = (i_mem_width == `MEM_WIDTH_WORD) ? word_data :
                         (i_mem_width == `MEM_WIDTH_HALF) ? (i_mem_sext ? {{16{half_raw[15]}}, half_raw}
                                                                        : {16'h0, half_raw}) :
                         (i_mem_width == `MEM_WIDTH_BYTE) ? (i_mem_sext ? {{24{byte_raw[7]}}, byte_raw}
                                                                        : {24'h0, byte_raw}) :
                                                            `XLEN_ZERO;

    //---------------------------------------------------------------------
    // Simulation-only: misaligned access check
    //---------------------------------------------------------------------
    `ifdef VERILATOR
    always_comb begin
        if (i_mem_write || i_mem_read) begin
            if (i_mem_width == `MEM_WIDTH_HALF && byte_lane[0] != 1'b0)
                $error("[data_mem] misaligned halfword access at addr=0x%h", i_addr);
            if (i_mem_width == `MEM_WIDTH_WORD && byte_lane != 2'b00)
                $error("[data_mem] misaligned word access at addr=0x%h", i_addr);
        end
    end
    `endif

endmodule
