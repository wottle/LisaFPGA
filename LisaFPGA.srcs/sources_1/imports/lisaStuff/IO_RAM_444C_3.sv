`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 09/23/2025 05:41:58 PM
// Design Name: Apple Lisa Floppy Controller RAM (444C-3)
// Module Name: IO_RAM_444C_3
// Project Name: LisaFPGA
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


// LisaFPGA fork (2026-10-15, written with an AI assistant): this RAM used to latch on `negedge _CS`, where _CS is
// IO_board's _FDC_RAM_CS_processed -- a fabric register used as a clock, on general routing, with no clock defined, so
// Vivado never timed the address, data or R/W against it. Whether floppy sectors (which all pass through this RAM)
// arrived intact depended on each build's placement: some builds read disks, others gave "not in the standard Lisa
// Office System format". It now runs on C16M and does the same read or write on the C16M edge at which _CS falls,
// told one edge ahead by _CS_next (_FDC_RAM_CS_muxed, the register _CS copies). The operation lands on exactly the
// edge where the old falling edge happened, so read data appears at the same time as before; every access path was
// checked to present the same address, data and R/W on that edge. The 6504 side is now ordinary timed C16M logic;
// the 68K side (A, BD) is bounded in the XDC (set_max_delay -datapath_only on the fdcram_* cells), since the 68K
// holds them for its whole bus cycle and the strobe comes several C16M cycles after its synchronised _AS.
module IO_RAM_444C_3(
    input logic clk,          // C16M
    input logic [9:0] A,
    input logic spoof_88,
    input logic _CS,          // _FDC_RAM_CS_processed: the RAM drives D_out while this is low
    input logic _CS_next,     // the value _CS takes at the next clk edge (_FDC_RAM_CS_muxed)
    input logic R_W,
    input logic [3:0] D_in,
    output wire [3:0] D_out
    );

    // The RAM array itself; 1024 x 4 Bits. The fdcram_ names are what the XDC constrains.
    `ifdef SIMULATION
        logic [3:0] fdcram_mem [0:1023] = '{default:4'b0000};
    `else
        logic [3:0] fdcram_mem [0:1023];
    `endif

    logic [3:0] fdcram_q = 4'b0000;
    assign D_out = (!_CS) ? fdcram_q : 4'bz;

    always_ff @(posedge clk) begin
        // The chip is being selected: _CS is high now and goes low at this edge
        if (_CS && !_CS_next) begin
            // If it's a read, then forward the data on to the output
            if (R_W) begin
                // If we're trying to access address 0x018 (FCC030), and spoof88 is set, then return 0x8 instead of the actual contents
                // This way, we can trick the Lisa into thinking this is a 2/10 by returning ROM revision 88 instead of A8 if the user wants
                if (A == 10'h018 && spoof_88) begin
                    fdcram_q <= 4'h8;
                end else begin
                    // Otherwise, just return the actual contents of the RAM at the specified address
                    fdcram_q <= fdcram_mem[A];
                end
            // If it's a write, then grab the 4 bits off the bus and write them to RAM
            end else begin
                fdcram_mem[A] <= D_in;
            end
        end
    end

endmodule