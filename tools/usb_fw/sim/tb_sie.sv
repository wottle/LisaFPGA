// Phase-1 testbench: usb_sie driven directly through its registers against usb_dev_model.
// Port 0 has a full-speed device, port 1 a low-speed one. Run: sh tools/usb_fw/sim/run.sh tb_sie
`timescale 1ns/1ps
module tb_sie;
    logic clk = 0, reset = 1;
    always #8.3333 clk = ~clk;                       // 60 MHz

    // ---- two ports, each an SIE + IOBUF model + device model ----
    wire [1:0] dp, dm;
    logic [1:0] dp_o, dm_o, oe, we;
    logic [7:0]  addr;
    logic [31:0] wdata, rdata [2];
    for (genvar p = 0; p < 2; p++) begin : port
        usb_sie sie (.clk(clk), .reset(reset), .bus_we(we[p]), .bus_addr(addr), .bus_wdata(wdata),
                     .bus_wstrb(4'hF), .bus_rdata(rdata[p]),
                     .dp_i(dp[p]), .dm_i(dm[p]), .dp_o(dp_o[p]), .dm_o(dm_o[p]), .oe(oe[p]));
        assign dp[p] = oe[p] ? dp_o[p] : 1'bz;
        assign dm[p] = oe[p] ? dm_o[p] : 1'bz;
    end
    usb_dev_model #(.LS(0), .NAME("fs_dev")) fs_dev (.dp(dp[0]), .dm(dm[0]));
    usb_dev_model #(.LS(1), .NAME("ls_dev")) ls_dev (.dp(dp[1]), .dm(dm[1]));

    int failures = 0;
    function automatic void check(input bit cond, input string msg);
        if (!cond) begin failures++; $display("[%0t] tb: FAIL %s", $time, msg); end
        else $display("[%0t] tb: ok   %s", $time, msg);
    endfunction

    // ---- register access ----
    task automatic wr(input int p, input logic [7:0] a, input logic [31:0] d);
        @(posedge clk); addr <= a; wdata <= d; we <= 2'b01 << p;
        @(posedge clk); we <= 0;
    endtask
    task automatic rd(input int p, input logic [7:0] a, output logic [31:0] d);
        @(posedge clk); addr <= a;
        @(posedge clk); @(posedge clk); d = rdata[p];
    endtask

    localparam CTRL = 8'h00, STATUS = 8'h04, CMD = 8'h08, RESULT = 8'h0C;
    localparam SETUP = 8'h2D, IN = 8'h69, OUT = 8'hE1;

    // run one transaction; returns RESULT
    task automatic xfer(input int p, input logic [7:0] pid, input int a, input int ep, input bit data1,
                        input bit ls, input int len, output logic [31:0] res);
        logic [31:0] st;
        wr(p, CMD, {1'b0, 7'(len), 2'b0, 1'b0, ls, data1, 4'(ep), 7'(a), pid});
        do rd(p, STATUS, st); while (st[2]);
        rd(p, RESULT, res);
    endtask

    task automatic load_setup(input int p, input byte s [8]);
        wr(p, 8'h40, {s[3], s[2], s[1], s[0]});
        wr(p, 8'h44, {s[7], s[6], s[5], s[4]});
    endtask

    task automatic read_rx(input int p, input int n, output byte b [$]);
        logic [31:0] w;
        b = {};
        for (int i = 0; i < n; i += 4) begin
            rd(p, 8'h80 + i, w);
            for (int k = 0; k < 4 && i + k < n; k++) b.push_back(w[k*8 +: 8]);
        end
    endtask

    // full control read: SETUP, IN data stage(s), OUT status
    task automatic control_read(input int p, input int a, input bit ls, input byte s [8], input int mps,
                                output byte data [$], output logic [3:0] last_status);
        logic [31:0] r;
        byte chunk [$];
        bit tog = 1;
        int want = {s[7], s[6]};
        data = {};
        load_setup(p, s);
        xfer(p, SETUP, a, 0, 0, ls, 8, r);
        last_status = r[3:0];
        if (r[3:0] != 1) return;
        while (data.size() < want) begin
            xfer(p, IN, a, 0, tog, ls, 0, r);
            last_status = r[3:0];
            if (r[3:0] == 2) continue;                  // NAK: retry
            if (r[3:0] != 4) return;
            read_rx(p, r[14:8], chunk);
            foreach (chunk[i]) data.push_back(chunk[i]);
            tog = !tog;
            if (r[14:8] < mps) break;
        end
        xfer(p, OUT, a, 0, 1, ls, 0, r);
        last_status = r[3:0];
    endtask

    task automatic control_nodata(input int p, input int a, input bit ls, input byte s [8],
                                  output logic [3:0] last_status);
        logic [31:0] r;
        load_setup(p, s);
        xfer(p, SETUP, a, 0, 0, ls, 8, r);
        last_status = r[3:0];
        if (r[3:0] != 1) return;
        do xfer(p, IN, a, 0, 1, ls, 0, r); while (r[3:0] == 2);
        last_status = (r[3:0] == 4 && r[14:8] == 0) ? 4'd1 : r[3:0];
    endtask

    // ---- the tests, run once per port ----
    task automatic test_port(input int p, input bit ls);
        logic [31:0] st, r;
        byte d [$];
        logic [3:0] s;
        string sp = ls ? "LS" : "FS";

        rd(p, STATUS, st);
        check(st[0] == 1 && st[1] == !ls, $sformatf("%s attach detected, speed bit %0d", sp, st[1]));
        wr(p, CTRL, {ls, 1'b1, 1'b0});                  // bus reset (port_ls set for LS)
        #(1_000_000);                                   // 1 ms (enough for the model)
        wr(p, CTRL, {ls, 1'b0, 1'b1});                  // release, enable SOF / keep-alive
        #(3_000_000);

        // GET_DESCRIPTOR(device, 18) at address 0, max packet 8
        control_read(p, 0, ls, '{8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h12, 8'h00}, 8, d, s);
        check(s == 1 && d.size() == 18 && d[0] == 8'h12 && d[1] == 8'h01 && d[8] == 8'h34,
              $sformatf("%s GET_DESCRIPTOR(device) -> %0d bytes, status %0d", sp, d.size(), s));

        // the exact SETUP packet the spike captured: the model checks its CRC16 (A2 54)
        control_read(p, 0, ls, '{8'h80, 8'h06, 8'h00, 8'h02, 8'h00, 8'h00, 8'h18, 8'h00}, 8, d, s);
        check(s == 1 && d.size() == 24 && d[0] == 8'h09 && d[1] == 8'h02,
              $sformatf("%s GET_DESCRIPTOR(config, 24) -> %0d bytes", sp, d.size()));

        // SET_ADDRESS 5, then talk to address 5
        control_nodata(p, 0, ls, '{8'h00, 8'h05, 8'h05, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, s);
        check(s == 1, $sformatf("%s SET_ADDRESS(5)", sp));
        control_nodata(p, 5, ls, '{8'h00, 8'h09, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}, s);
        check(s == 1, $sformatf("%s SET_CONFIGURATION(1) at address 5", sp));

        // no device at address 9: timeout
        xfer(p, IN, 9, 1, 0, ls, 0, r);
        check(r[3:0] == 5, $sformatf("%s IN to absent address -> TIMEOUT (status %0d)", sp, r[3:0]));

        // unsupported request: STALL in the data stage
        load_setup(p, '{8'h80, 8'h06, 8'h00, 8'h07, 8'h00, 8'h00, 8'h08, 8'h00});
        xfer(p, SETUP, 5, 0, 0, ls, 8, r);
        xfer(p, IN, 5, 0, 1, ls, 0, r);
        check(r[3:0] == 3, $sformatf("%s unsupported descriptor -> STALL (status %0d)", sp, r[3:0]));

        // interrupt endpoint: NAK, then a report
        xfer(p, IN, 5, 1, 0, ls, 0, r);
        check(r[3:0] == 2, $sformatf("%s EP1 with nothing queued -> NAK", sp));
        if (ls) ls_dev.queue_report('{8'h02, 8'h00, 8'h04, 8'h05, 8'h00, 8'h00, 8'h00, 8'h00});
        else    fs_dev.queue_report('{8'h02, 8'h00, 8'h04, 8'h05, 8'h00, 8'h00, 8'h00, 8'h00});
        xfer(p, IN, 5, 1, 0, ls, 0, r);
        read_rx(p, 8, d);
        check(r[3:0] == 4 && r[14:8] == 8 && r[23:16] == 8'hC3 && d[0] == 8'h02 && d[2] == 8'h04 && d[3] == 8'h05,
              $sformatf("%s EP1 report -> status %0d, %0d bytes, PID %02x", sp, r[3:0], r[14:8], r[23:16]));

        // corrupted CRC: engine reports it and does not ACK, so the device resends the same data
        if (ls) begin ls_dev.queue_report('{8'h00, 8'h00, 8'h06, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}); ls_dev.corrupt_next_crc = 1; end
        else    begin fs_dev.queue_report('{8'h00, 8'h00, 8'h06, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00}); fs_dev.corrupt_next_crc = 1; end
        xfer(p, IN, 5, 1, 1, ls, 0, r);
        check(r[3:0] == 6, $sformatf("%s corrupted CRC -> CRC error (status %0d)", sp, r[3:0]));
        xfer(p, IN, 5, 1, 1, ls, 0, r);
        read_rx(p, 8, d);
        check(r[3:0] == 4 && r[23:16] == 8'h4B && d[2] == 8'h06, $sformatf("%s retry after CRC error -> DATA1 resent", sp));

        // back-to-back INs for 5 ms: every SOF must stay on time (the frame guard)
        if (ls) ls_dev.nak_ep1 = 100000; else fs_dev.nak_ep1 = 100000;
        repeat (ls ? 400 : 2000) xfer(p, IN, 5, 1, 0, ls, 0, r);
        if (ls) ls_dev.nak_ep1 = 0; else fs_dev.nak_ep1 = 0;
    endtask

    initial begin
        addr = 0; wdata = 0; we = 0;
        repeat (20) @(posedge clk);
        reset = 0;
        #(10_000);
        test_port(0, 0);
        test_port(1, 1);
        check(fs_dev.sofs > 5 && fs_dev.max_sof_jitter < 100.0,
              $sformatf("FS: %0d SOFs, worst deviation from 1 ms %0.1f ns", fs_dev.sofs, fs_dev.max_sof_jitter));
        check(ls_dev.sofs == 0, "LS: no SOF tokens on a low-speed port (keep-alives only)");
        check(fs_dev.errors == 0 && ls_dev.errors == 0,
              $sformatf("device models saw no protocol errors (fs %0d, ls %0d)", fs_dev.errors, ls_dev.errors));
        $display("tb: %s (%0d failures)", failures ? "FAIL" : "PASS", failures);
        $finish;
    end
    initial begin #200_000_000; $display("tb: TIMEOUT -- FAIL"); $finish; end
endmodule
