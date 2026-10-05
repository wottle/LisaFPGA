// Phase-2 testbench: the real firmware on PicoRV32 drives both usb_sie ports end to end.
// Port 0: full-speed boot keyboard. Port 1: low-speed boot mouse. Run: sh tools/usb_fw/sim/run.sh tb_fw
`timescale 1ns/1ps
module tb_fw;
    logic clk = 0, reset = 1;
    always #8.3333 clk = ~clk;                       // 60 MHz

    wire  [1:0] dp, dm;
    logic [1:0] dp_o, dm_o, oe;
    logic        kbd_report, mouse_report;
    logic [55:0] kbd_data;
    logic [18:0] mouse_data;
    logic [31:0] dbg;

    usb_softcpu #(.FIRMWARE("usb_host_fw.mem")) dut (
        .clk(clk), .reset(reset),
        .usb_dp_i(dp), .usb_dm_i(dm), .usb_dp_o(dp_o), .usb_dm_o(dm_o), .usb_oe(oe),
        .kbd_report(kbd_report), .kbd_data(kbd_data), .mouse_report(mouse_report), .mouse_data(mouse_data),
        .dbg_word(dbg));
    for (genvar p = 0; p < 2; p++) begin : pins
        assign dp[p] = oe[p] ? dp_o[p] : 1'bz;
        assign dm[p] = oe[p] ? dm_o[p] : 1'bz;
    end

    usb_dev_model #(.LS(0), .MOUSE(0), .NAME("kbd")) kbd (.dp(dp[0]), .dm(dm[0]));
    usb_dev_model #(.LS(1), .MOUSE(1), .NAME("mouse")) mouse (.dp(dp[1]), .dm(dm[1]));

    int failures = 0;
    function automatic void check(input bit cond, input string msg);
        if (!cond) begin failures++; $display("[%0t] tb: FAIL %s", $time, msg); end
        else $display("[%0t] tb: ok   %s", $time, msg);
    endfunction

    // capture the Lisa-side reports
    logic [55:0] kbd_seen [$];
    logic [18:0] mouse_seen [$];
    always @(posedge clk) begin
        if (kbd_report)   kbd_seen.push_back(kbd_data);
        if (mouse_report) mouse_seen.push_back(mouse_data);
    end

    initial begin
        repeat (20) @(posedge clk);
        reset = 0;
        // debounce 100 ms + reset 50 ms + recovery 20 ms + enumeration
        wait (kbd.boot_protocol && mouse.boot_protocol);
        check(kbd.configured && mouse.configured, "both devices enumerated, configured and put in boot protocol");
        check(kbd.my_addr != 0 && mouse.my_addr != 0 && kbd.my_addr != mouse.my_addr,
              $sformatf("distinct addresses: keyboard %0d, mouse %0d", kbd.my_addr, mouse.my_addr));

        // keyboard: Shift + 'a' + 'b', then rollover to 'b' alone, then release
        kbd.queue_report('{8'h02, 8'h00, 8'h04, 8'h05, 8'h00, 8'h00, 8'h00, 8'h00});
        kbd.queue_report('{8'h00, 8'h00, 8'h05, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00});
        kbd.queue_report('{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00});
        // mouse: left button, move right 5 / up 3, then release
        mouse.queue_report('{8'h01, 8'h05, 8'hFD, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00});
        mouse.queue_report('{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00});
        #(60_000_000);                               // 60 ms: several polling intervals for both

        check(kbd_seen.size() == 3, $sformatf("keyboard: %0d reports reached the Lisa side", kbd_seen.size()));
        if (kbd_seen.size() == 3) begin
            check(kbd_seen[0] == {8'h02, 8'h00, 8'h00, 8'h00, 8'h00, 8'h05, 8'h04},
                  $sformatf("  report 1 = %014h (Shift, a, b)", kbd_seen[0]));
            check(kbd_seen[1] == {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h05},
                  $sformatf("  report 2 = %014h (b)", kbd_seen[1]));
            check(kbd_seen[2] == 56'd0, $sformatf("  report 3 = %014h (released)", kbd_seen[2]));
        end
        check(mouse_seen.size() == 2, $sformatf("mouse: %0d reports reached the Lisa side", mouse_seen.size()));
        if (mouse_seen.size() == 2) begin
            check(mouse_seen[0] == {3'b001, 8'h05, 8'hFD}, $sformatf("  report 1 = %05h (left, +5, -3)", mouse_seen[0]));
            check(mouse_seen[1] == 19'd0, $sformatf("  report 2 = %05h (released)", mouse_seen[1]));
        end
        check(kbd.errors == 0 && mouse.errors == 0,
              $sformatf("device models saw no protocol errors (kbd %0d, mouse %0d)", kbd.errors, mouse.errors));
        $display("tb: %s (%0d failures)", failures ? "FAIL" : "PASS", failures);
        $finish;
    end
    initial begin #600_000_000; $display("tb: TIMEOUT -- FAIL"); $finish; end
endmodule
