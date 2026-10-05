// Phase-3 testbench: the real firmware enumerates a hub and the devices behind it.
// Board port 0: a full-speed hub with a full-speed keyboard on hub port 1, a LOW-speed mouse on hub
// port 2 (so every packet to it needs a PRE) and nothing on port 3. Board port 1: empty.
// Run: sh tools/usb_fw/sim/run.sh tb_hub
`timescale 1ns/1ps
module tb_hub;
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
    assign (weak1, weak0) dp[1] = 1'b0;              // the host's pull-downs on the empty port
    assign (weak1, weak0) dm[1] = 1'b0;

    wire [3:1] hdp, hdm;
    usb_hub_model #(.NPORTS(3), .NAME("hub")) hub (.dp(dp[0]), .dm(dm[0]), .ddp(hdp), .ddm(hdm));
    usb_dev_model #(.LS(0), .MOUSE(0), .NAME("kbd"))   kbd   (.dp(hdp[1]), .dm(hdm[1]));
    usb_dev_model #(.LS(1), .MOUSE(1), .NAME("mouse")) mouse (.dp(hdp[2]), .dm(hdm[2]));

    int failures = 0;
    function automatic void check(input bit cond, input string msg);
        if (!cond) begin failures++; $display("[%0t] tb: FAIL %s", $time, msg); end
        else $display("[%0t] tb: ok   %s", $time, msg);
    endfunction

    logic [55:0] kbd_seen [$];
    logic [18:0] mouse_seen [$];
    always @(posedge clk) begin
        if (kbd_report)   kbd_seen.push_back(kbd_data);
        if (mouse_report) mouse_seen.push_back(mouse_data);
    end

    initial begin
        repeat (20) @(posedge clk);
        reset = 0;
        fork
            wait (kbd.boot_protocol && mouse.boot_protocol);
            #(800_000_000);
        join_any
        disable fork;
        check(hub.configured, $sformatf("hub enumerated and configured (address %0d)", hub.my_addr));
        check(kbd.boot_protocol, $sformatf("full-speed keyboard behind the hub enumerated (address %0d)", kbd.my_addr));
        check(mouse.boot_protocol, $sformatf("low-speed mouse behind the hub enumerated via PRE (address %0d)", mouse.my_addr));
        check(hub.pre_packets > 0, $sformatf("hub saw %0d PRE packets", hub.pre_packets));

        kbd.queue_report('{8'h00, 8'h00, 8'h04, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00});
        kbd.queue_report('{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00});
        mouse.queue_report('{8'h02, 8'hFE, 8'h07, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00});
        #(60_000_000);
        check(kbd_seen.size() == 2 && kbd_seen[0] == 56'h04 && kbd_seen[1] == 56'h0,
              $sformatf("keyboard reports through the hub: %0d", kbd_seen.size()));
        check(mouse_seen.size() == 1 && mouse_seen[0] == {3'b010, 8'hFE, 8'h07},
              $sformatf("mouse report through the hub (PRE both ways): %0d", mouse_seen.size()));

        check(hub.errors == 0 && kbd.errors == 0 && mouse.errors == 0,
              $sformatf("models saw no protocol errors (hub %0d, kbd %0d, mouse %0d)", hub.errors, kbd.errors, mouse.errors));
        $display("tb: %s (%0d failures)", failures ? "FAIL" : "PASS", failures);
        $finish;
    end
    initial begin #1_200_000_000; $display("tb: TIMEOUT -- FAIL"); $finish; end
endmodule
