// ---------------------------------------------------------------------------------------------
// Behavioural full-speed USB hub for testing the soft-CPU host's hub driver and PRE path. Simulation only.
//
// Two parts:
//  * the hub function on the upstream link: EP0 standard + hub-class requests (hub descriptor, port
//    power / reset / status / change bits), EP1 interrupt IN returning the port status-change bitmap;
//  * a bit-level repeater. Host traffic is copied to every enabled full-speed port; a packet that follows a
//    PRE is copied to the enabled low-speed ports instead, with D+/D- swapped (low-speed J is D- high).
//    A downstream device's response is copied upstream, swapped back for low speed. No delay is added, so
//    the host's turnaround timing sees the device directly, as with a real hub (minus its few ns).
// Ports with nothing attached read as unpowered/empty. Port reset drives SE0 downstream for 10 ms.
// ---------------------------------------------------------------------------------------------
`timescale 1ns/1ps
module usb_hub_model #(
    parameter int NPORTS = 3,
    parameter string NAME = "hub"
) (
    inout wire dp,
    inout wire dm,
    inout wire [NPORTS:1] ddp,
    inout wire [NPORTS:1] ddm
);
    localparam real T  = 83.3333;                      // full-speed bit time, ns
    localparam real TL = 666.6667;                     // low-speed bit time, ns

    // ---- upstream line: full-speed pull-up ----
    logic drv = 0, odp, odm;
    logic up_en = 0, up_ls = 0;
    int   up_src = 1;
    assign dp = drv ? odp : up_en ? (up_ls ? ddm[up_src] : ddp[up_src]) : 1'bz;
    assign dm = drv ? odm : up_en ? (up_ls ? ddp[up_src] : ddm[up_src]) : 1'bz;
    assign (weak1, weak0) dp = 1'b1;
    assign (weak1, weak0) dm = 1'b0;
    wire lj = dp && !dm, lk = !dp && dm, lse0 = !dp && !dm;

    // ---- downstream ports ----
    logic [NPORTS:1] down_fs = 0, down_ls = 0, rst_drv = 0;
    bit   powered [1:NPORTS], connected [1:NPORTS], enabled [1:NPORTS], port_ls [1:NPORTS];
    bit   c_conn [1:NPORTS], c_reset [1:NPORTS];
    realtime rst_until [1:NPORTS];
    for (genvar p = 1; p <= NPORTS; p++) begin : dport
        assign ddp[p] = rst_drv[p] ? 1'b0 : down_fs[p] ? dp : down_ls[p] ? dm : 1'bz;
        assign ddm[p] = rst_drv[p] ? 1'b0 : down_fs[p] ? dm : down_ls[p] ? dp : 1'bz;
    end

    int errors = 0, resets = 0, pre_packets = 0;
    logic [6:0] my_addr = 0;
    bit configured = 0;

    function automatic void fail(input string msg);
        errors++;
        $display("[%0t] %s: ERROR %s", $time, NAME, msg);
    endfunction

    // ---- presence, connect/disconnect detection and port reset timing, every 1 us ----
    initial begin
        int absent [1:NPORTS];
        foreach (powered[p]) begin
            powered[p] = 0; connected[p] = 0; enabled[p] = 0; port_ls[p] = 0;
            c_conn[p] = 0; c_reset[p] = 0; absent[p] = 0;
        end
        forever begin
            #1000;
            for (int p = 1; p <= NPORTS; p++) begin
                bit present;
                if (rst_drv[p]) begin
                    if ($realtime >= rst_until[p]) begin
                        rst_drv[p] = 0; enabled[p] = 1; c_reset[p] = 1;
                    end
                    continue;
                end
                if (!powered[p] || down_fs[p] || down_ls[p] || (up_en && up_src == p)) continue;
                present = ddp[p] === 1'b1 || ddm[p] === 1'b1;
                absent[p] = present ? 0 : absent[p] + 1;
                if (present && !connected[p]) begin
                    connected[p] = 1; c_conn[p] = 1; port_ls[p] = ddm[p] === 1'b1;
                    $display("[%0t] %s: port %0d connect (%s speed)", $time, NAME, p, port_ls[p] ? "low" : "full");
                end else if (!present && connected[p] && absent[p] >= 3) begin
                    connected[p] = 0; enabled[p] = 0; c_conn[p] = 1;
                    $display("[%0t] %s: port %0d disconnect", $time, NAME, p);
                end
            end
        end
    end

    // ---- repeater, downstream: host packets to the enabled ports ----
    initial begin
        logic [7:0] pid;
        bit lvl, b;
        forever begin
            wait (lk && !drv && !up_en);                       // the host starts a packet
            for (int p = 1; p <= NPORTS; p++) if (enabled[p] && !port_ls[p]) down_fs[p] = 1;
            // decode SYNC + PID at full speed to recognise PRE
            lvl = 1; #(T / 2);
            for (int i = 0; i < 16; i++) begin
                b = dp == lvl; lvl = dp;
                if (i >= 8) pid[i - 8] = b;
                #(T);
            end
            if (pid == 8'h3C) begin                            // PRE: next packet is for low-speed ports
                pre_packets++;
                wait (lj); wait (lk);
                for (int p = 1; p <= NPORTS; p++) if (enabled[p] && port_ls[p]) down_ls[p] = 1;
                wait (lse0); wait (!lse0); #(TL);
            end else begin
                wait (lse0); wait (!lse0); #(T);
            end
            down_fs = 0; down_ls = 0;
        end
    end

    // ---- repeater, upstream: a downstream device's response to the host ----
    initial begin
        forever begin
            automatic int src = 0;
            wait (!up_en && down_fs == 0 && down_ls == 0);
            // a device starts a packet: K in its own polarity
            for (int p = 1; p <= NPORTS; p++)
                if (enabled[p] && !rst_drv[p] && (port_ls[p] ? (ddp[p] === 1'b1 && ddm[p] === 1'b0)
                                                              : (ddp[p] === 1'b0 && ddm[p] === 1'b1))) src = p;
            if (!src) begin @(ddp, ddm, up_en, down_fs, down_ls); continue; end
            up_src = src; up_ls = port_ls[src]; up_en = 1;
            wait (ddp[src] === 1'b0 && ddm[src] === 1'b0);    // its EOP
            wait (ddp[src] === 1'b1 || ddm[src] === 1'b1);
            #(port_ls[src] ? TL : T);
            up_en = 0;
        end
    end

    // ======================================================================================
    // The hub function on the upstream link (the same packet code as usb_dev_model, full speed)
    // ======================================================================================
    function automatic logic [4:0] crc5(input logic [10:0] d);
        logic [4:0] c = 5'h1F;
        for (int i = 0; i < 11; i++) c = (d[i] ^ c[4]) ? ((c << 1) ^ 5'h05) : (c << 1);
        return ~c;
    endfunction
    function automatic logic [15:0] crc16(input byte b [$]);
        logic [15:0] c = 16'hFFFF;
        foreach (b[k]) for (int i = 0; i < 8; i++)
            c = (b[k][i] ^ c[15]) ? ((c << 1) ^ 16'h8005) : (c << 1);
        return ~c;
    endfunction
    function automatic logic [7:0] rev8(input logic [7:0] v);
        for (int i = 0; i < 8; i++) rev8[i] = v[7 - i];
    endfunction
    function automatic logic [4:0] rev5(input logic [4:0] v);
        for (int i = 0; i < 5; i++) rev5[i] = v[4 - i];
    endfunction

    // receive a packet; returns ok=0 silently for anything not meant for the hub function
    task automatic rx_packet(output byte pkt [$], output bit ok);
        bit lvl = 1, synced = 0, b;
        int ones = 0, nbits = 0;
        logic [7:0] cur;
        pkt = {}; ok = 1;
        #(T / 2);
        forever begin
            if (lse0) break;
            b = (dp == lvl); lvl = dp;
            if (!synced) begin
                if (b) begin synced = 1; ones = 1; end
            end else if (ones == 6) begin
                ones = 0;
            end else begin
                ones = b ? ones + 1 : 0;
                cur = {b, cur[7:1]};
                if (++nbits % 8 == 0) pkt.push_back(cur);
                if (nbits == 8 && cur == 8'h3C) begin wait (lse0); wait (!lse0); ok = 0; return; end
            end
            #(T);
        end
        wait (!lse0);
        if (nbits % 8 != 0 || pkt.size() == 0 || pkt[0][3:0] != ~pkt[0][7:4]) ok = 0;
    endtask

    task automatic wait_k(input int n, output bit got);
        got = 0;
        fork : wk
            begin wait (lk); got = 1; end
            #(n * T);
        join_any
        disable wk;
    endtask

    task automatic tx_packet(input byte pkt [$]);
        bit lvl = 1;
        int ones = 0;
        byte all [$];
        all = {8'h80};
        foreach (pkt[i]) all.push_back(pkt[i]);
        #(3 * T);
        drv = 1;
        foreach (all[k]) for (int i = 0; i < 8; i++) begin
            if (!all[k][i]) lvl = !lvl;
            {odp, odm} = {lvl, !lvl};
            #(T);
            ones = all[k][i] ? ones + 1 : 0;
            if (ones == 6) begin lvl = !lvl; {odp, odm} = {lvl, !lvl}; #(T); ones = 0; end
        end
        {odp, odm} = 2'b00; #(2 * T);
        {odp, odm} = 2'b10; #(T);
        drv = 0;
    endtask

    task automatic tx_data(input bit data1, input byte payload [$]);
        byte p [$];
        logic [15:0] c = crc16(payload);
        p = {data1 ? 8'h4B : 8'hC3};
        foreach (payload[i]) p.push_back(payload[i]);
        p.push_back(rev8(c[15:8])); p.push_back(rev8(c[7:0]));
        tx_packet(p);
    endtask

    byte dev_desc [18] = '{8'h12, 8'h01, 8'h10, 8'h01, 8'h09, 8'h00, 8'h00, 8'h08,
                           8'hAC, 8'h05, 8'h06, 8'h10, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h01};
    byte cfg_desc [25] = '{8'h09, 8'h02, 8'h19, 8'h00, 8'h01, 8'h01, 8'h00, 8'hA0, 8'h32,
                           8'h09, 8'h04, 8'h00, 8'h00, 8'h01, 8'h09, 8'h00, 8'h00, 8'h00,
                           8'h07, 8'h05, 8'h81, 8'h03, 8'h01, 8'h00, 8'h0C};
    byte hub_desc [9]  = '{8'h09, 8'h29, 8'(NPORTS), 8'h0D, 8'h00, 8'h32, 8'h64, 8'h00, 8'hFF};

    byte ctl [$];
    int  ctl_idx = 0;
    bit  ctl_toggle = 1, ctl_stall = 0, ctl_in_data = 0, ep1_toggle = 0;
    logic [6:0] pending_addr = 0;
    bit  pending_addr_valid = 0;

    task automatic do_setup(input byte s [$]);
        logic [15:0] wvalue = {s[3], s[2]}, windex = {s[5], s[4]}, wlength = {s[7], s[6]};
        int p = windex[7:0];
        ctl = {}; ctl_idx = 0; ctl_toggle = 1; ctl_stall = 0; ctl_in_data = s[0][7];
        case ({s[0], s[1]})
            16'h8006: case (wvalue[15:8])
                          8'h01: foreach (dev_desc[i]) ctl.push_back(dev_desc[i]);
                          8'h02: foreach (cfg_desc[i]) ctl.push_back(cfg_desc[i]);
                          default: ctl_stall = 1;
                      endcase
            16'hA006: foreach (hub_desc[i]) ctl.push_back(hub_desc[i]);      // hub descriptor
            16'hA000: ctl = {8'h00, 8'h00, 8'h00, 8'h00};                    // GET_STATUS(hub)
            16'h0005: begin pending_addr = wvalue[6:0]; pending_addr_valid = 1; end
            16'h0009: configured = wvalue[7:0] != 0;
            16'h2001: ;                                                       // CLEAR_HUB_FEATURE
            16'hA300, 16'h2303, 16'h2301: begin
                if (p < 1 || p > NPORTS) ctl_stall = 1;
                else if (s[1] == 8'h00) begin                                // GET_PORT_STATUS
                    logic [15:0] st = 0, ch = 0;
                    st[0] = connected[p]; st[1] = enabled[p]; st[4] = rst_drv[p]; st[8] = powered[p];
                    st[9] = connected[p] && port_ls[p];
                    ch[0] = c_conn[p]; ch[4] = c_reset[p];
                    ctl = {st[7:0], st[15:8], ch[7:0], ch[15:8]};
                end else if (s[1] == 8'h03) case (wvalue)                    // SET_PORT_FEATURE
                    8:  powered[p] = 1;
                    4:  if (connected[p]) begin
                            rst_drv[p] = 1; enabled[p] = 0; rst_until[p] = $realtime + 10.0e6; resets++;
                        end
                    default: ;
                endcase else case (wvalue)                                   // CLEAR_PORT_FEATURE
                    1:  enabled[p] = 0;
                    16: c_conn[p] = 0;
                    20: c_reset[p] = 0;
                    default: ;
                endcase
            end
            default: ctl_stall = 1;
        endcase
        while (ctl.size() > wlength) void'(ctl.pop_back());
    endtask

    initial begin
        byte pkt [$], payload [$], resp [$];
        bit ok, got;
        realtime t0;
        forever begin
            wait ((lk || lse0) && !up_en);
            if (lse0) begin
                t0 = $realtime;
                wait (!lse0);
                if ($realtime - t0 > 2500.0) begin                   // bus reset: the hub starts over
                    my_addr = 0; configured = 0; ep1_toggle = 0;
                    foreach (powered[p]) begin
                        powered[p] = 0; enabled[p] = 0; connected[p] = 0; c_conn[p] = 0; c_reset[p] = 0;
                    end
                    $display("[%0t] %s: bus reset", $time, NAME);
                end
                continue;
            end
            rx_packet(pkt, ok);
            if (!ok) continue;
            case (pkt[0])
            8'hA5, 8'h2D, 8'h69, 8'hE1: begin
                logic [10:0] f;
                if (pkt.size() != 3) continue;
                f = {pkt[2][2:0], pkt[1]};
                if (pkt[2][7:3] != rev5(crc5(f))) begin fail("CRC5"); continue; end
                if (pkt[0] == 8'hA5 || f[6:0] != my_addr) continue;
                if (pkt[0] == 8'h2D || pkt[0] == 8'hE1) begin
                    automatic bit is_setup = pkt[0] == 8'h2D;
                    wait_k(16, got);
                    if (!got) continue;
                    rx_packet(pkt, ok);
                    if (!ok) continue;
                    payload = pkt[1:$-2];
                    if ({pkt[$-1], pkt[$]} != {rev8(crc16(payload) >> 8), rev8(crc16(payload))}) begin
                        fail("DATA CRC16"); continue;
                    end
                    if (is_setup) begin tx_packet('{8'hD2}); do_setup(payload); end
                    else if (ctl_stall) tx_packet('{8'h1E});
                    else tx_packet('{8'hD2});
                end else begin                                            // IN
                    if (f[10:7] == 0) begin
                        if (ctl_stall) begin tx_packet('{8'h1E}); continue; end
                        resp = {};
                        if (ctl_in_data)
                            for (int i = ctl_idx; i < ctl.size() && i < ctl_idx + 8; i++) resp.push_back(ctl[i]);
                        tx_data(ctl_toggle, resp);
                        wait_k(20, got);
                        if (!got) continue;
                        rx_packet(pkt, ok);
                        if (ok && pkt[0] == 8'hD2) begin
                            ctl_idx += resp.size(); ctl_toggle = !ctl_toggle;
                            if (!ctl_in_data && pending_addr_valid) begin
                                my_addr = pending_addr; pending_addr_valid = 0;
                            end
                        end
                    end else if (f[10:7] == 1) begin                      // status change bitmap
                        automatic byte bm = 0;
                        for (int p = 1; p <= NPORTS; p++) if (c_conn[p] || c_reset[p]) bm[p] = 1;
                        if (bm == 0) begin tx_packet('{8'h5A}); continue; end
                        tx_data(ep1_toggle, '{bm});
                        wait_k(20, got);
                        if (!got) continue;
                        rx_packet(pkt, ok);
                        if (ok && pkt[0] == 8'hD2) ep1_toggle = !ep1_toggle;
                    end else
                        tx_packet('{8'h1E});
                end
            end
            default: ;
            endcase
        end
    end
endmodule
