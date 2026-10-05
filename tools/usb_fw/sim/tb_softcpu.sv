// Phase-0 testbench: PicoRV32 runs the firmware image and prints through the simulation console.
`timescale 1ns/1ps
module tb_softcpu;
    logic clk = 0, reset = 1;
    always #8.333 clk = ~clk;                 // 60 MHz
    logic [31:0] dbg;
    usb_softcpu #(.FIRMWARE("usb_host_fw.mem")) dut (.clk(clk), .reset(reset), .dbg_word(dbg),
        .usb_dp_i(2'b00), .usb_dm_i(2'b00), .usb_dp_o(), .usb_dm_o(), .usb_oe());
    initial begin
        repeat (10) @(posedge clk);
        reset = 0;
        wait (dbg == 32'd5);
        $display("tb: dbg_word reached 5 at %0t ns -- PASS", $time);
        $finish;
    end
    initial begin #2_000_000; $display("tb: TIMEOUT, dbg_word = %0d -- FAIL", dbg); $finish; end
endmodule
