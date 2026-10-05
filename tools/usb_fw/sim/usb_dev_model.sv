// ---------------------------------------------------------------------------------------------
// Behavioural USB device (boot keyboard) for testing usb_sie. Deliberately independent of the RTL:
// CRCs use the spec's MSB-first shift-register form (usb_sie uses the reflected form), and bit timing comes
// from real-valued delays rather than a clock. Simulation only.
//
// Behaviour: standard control requests on EP0 (GET_DESCRIPTOR device/config/report, SET_ADDRESS,
// SET_CONFIGURATION, HID SET_IDLE/SET_PROTOCOL; anything else STALLs), EP1 interrupt IN returning queued
// reports or NAK. Checks every packet it receives (PID, CRC5/CRC16, bit stuffing) and counts errors.
// Test hooks: nak_ep1, corrupt_next_crc, queue_report(), and counters/logs the testbench can inspect.
// ---------------------------------------------------------------------------------------------
`timescale 1ns/1ps
module usb_dev_model #(
    parameter bit LS = 0,
    parameter bit MOUSE = 0,                            // boot mouse instead of boot keyboard
    parameter string NAME = "dev"
) (
    inout wire dp,
    inout wire dm
);
    localparam real T = LS ? 666.6667 : 83.3333;      // bit time, ns

    // ---- line: the device's pull-up declares its speed; the other line has the host's pull-down ----
    logic drv = 0, odp, odm;
    assign dp = drv ? odp : 1'bz;
    assign dm = drv ? odm : 1'bz;
    assign (weak1, weak0) dp = LS ? 1'b0 : 1'b1;
    assign (weak1, weak0) dm = LS ? 1'b1 : 1'b0;
    wire lj   = LS ? (!dp && dm) : (dp && !dm);
    wire lk   = LS ? (dp && !dm) : (!dp && dm);
    wire lse0 = !dp && !dm;
    wire jl   = LS ? dm : dp;

    // ---- state visible to the testbench ----
    int    errors = 0, sofs = 0, last_frame = -1, setups = 0, acks_seen = 0, missing_acks = 0;
    realtime last_sof_t = 0;
    real   max_sof_jitter = 0;
    bit    corrupt_next_crc = 0;
    int    nak_ep1 = 0;
    byte   last_setup [8];
    logic [6:0] my_addr = 0;
    bit    configured = 0, boot_protocol = 0;
    byte   reports [$];                                // concatenated 8-byte reports

    task automatic queue_report(input byte r [8]);
        foreach (r[i]) reports.push_back(r[i]);
    endtask

    // ---- descriptors ----
    byte dev_desc [18] = '{8'h12, 8'h01, 8'h10, 8'h01, 8'h00, 8'h00, 8'h00, 8'h08,
                           8'h34, 8'h12, 8'h78, 8'h56, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h01};
    byte hid_kbd [] = '{8'h05, 8'h01, 8'h09, 8'h06, 8'hA1, 8'h01, 8'h05, 8'h07, 8'h19, 8'hE0,
                           8'h29, 8'hE7, 8'h15, 8'h00, 8'h25, 8'h01, 8'h75, 8'h01, 8'h95, 8'h08,
                           8'h81, 8'h02, 8'h95, 8'h01, 8'h75, 8'h08, 8'h81, 8'h01, 8'h95, 8'h06,
                           8'h75, 8'h08, 8'h15, 8'h00, 8'h25, 8'h65, 8'h05, 8'h07, 8'h19, 8'h00,
                           8'h29, 8'h65, 8'h81, 8'h00, 8'hC0};
    byte hid_mouse [] = '{8'h05, 8'h01, 8'h09, 8'h02, 8'hA1, 8'h01, 8'h09, 8'h01, 8'hA1, 8'h00,
                            8'h05, 8'h09, 8'h19, 8'h01, 8'h29, 8'h03, 8'h15, 8'h00, 8'h25, 8'h01,
                            8'h95, 8'h03, 8'h75, 8'h01, 8'h81, 8'h02, 8'h95, 8'h01, 8'h75, 8'h05,
                            8'h81, 8'h01, 8'h05, 8'h01, 8'h09, 8'h30, 8'h09, 8'h31, 8'h15, 8'h81,
                            8'h25, 8'h7F, 8'h75, 8'h08, 8'h95, 8'h02, 8'h81, 8'h06, 8'hC0, 8'hC0};
    byte hid_report [] = MOUSE ? hid_mouse : hid_kbd;
    localparam int RPT_LEN = MOUSE ? 3 : 8;
    byte cfg_desc [34];
    initial cfg_desc = '{8'h09, 8'h02, 8'h22, 8'h00, 8'h01, 8'h01, 8'h00, 8'hA0, 8'h32,
                         8'h09, 8'h04, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01, MOUSE ? 8'h02 : 8'h01, 8'h00,
                         8'h09, 8'h21, 8'h10, 8'h01, 8'h00, 8'h01, 8'h22, 8'(hid_report.size()), 8'h00,
                         8'h07, 8'h05, 8'h81, 8'h03, MOUSE ? 8'h04 : 8'h08, 8'h00, 8'h0A};

    // ---- CRCs, spec form ----
    function automatic logic [4:0] crc5(input logic [10:0] d);           // d[0] is sent first
        logic [4:0] c = 5'h1F;
        for (int i = 0; i < 11; i++) c = (d[i] ^ c[4]) ? ((c << 1) ^ 5'h05) : (c << 1);
        return ~c;                                                       // sent MSB first
    endfunction
    function automatic logic [15:0] crc16(input byte b [$]);
        logic [15:0] c = 16'hFFFF;
        foreach (b[k]) for (int i = 0; i < 8; i++)
            c = (b[k][i] ^ c[15]) ? ((c << 1) ^ 16'h8005) : (c << 1);
        return ~c;                                                       // sent MSB first
    endfunction
    function automatic logic [7:0] rev8(input logic [7:0] v);
        for (int i = 0; i < 8; i++) rev8[i] = v[7 - i];
    endfunction
    function automatic logic [4:0] rev5(input logic [4:0] v);
        for (int i = 0; i < 5; i++) rev5[i] = v[4 - i];
    endfunction

    function automatic void fail(input string msg);
        errors++;
        $display("[%0t] %s: ERROR %s", $time, NAME, msg);
    endfunction

    // ---- receive one packet; called with the line already in K (first SYNC bit) ----
    task automatic rx_packet(output byte pkt [$], output bit ok);
        bit lvl = 1, synced = 0, b;
        int ones = 0, zeros = 0, nbits = 0;
        logic [7:0] cur;
        pkt = {}; ok = 1;
        #(T / 2);
        forever begin
            if (lse0) break;
            b = (jl == lvl); lvl = jl;
            if (!synced) begin
                if (b) begin synced = 1; ones = 1; if (zeros < 5) ok = 0; end
                else zeros++;
            end else if (ones == 6) begin
                if (b) begin ok = 0; fail("bit stuffing violation"); end
                ones = 0;
            end else begin
                ones = b ? ones + 1 : 0;
                cur = {b, cur[7:1]};
                if (++nbits % 8 == 0) pkt.push_back(cur);
                if (nbits == 8 && cur == 8'h3C) begin   // PRE: a low-speed packet for a hub port follows.
                    wait (lse0); wait (!lse0);          // Full-speed devices ignore it, up to its EOP.
                    ok = 0;
                    return;
                end
            end
            #(T);
        end
        if (nbits % 8 != 0) begin ok = 0; fail($sformatf("packet not byte aligned (%0d bits)", nbits)); end
        #(T); if (!lse0) begin ok = 0; fail("EOP SE0 shorter than 2 bits"); end
        wait (!lse0);
        if (pkt.size() == 0 || pkt[0][3:0] != ~pkt[0][7:4]) begin ok = 0; fail("bad PID"); end
    endtask

    // ---- wait for a packet start (K) for up to n bit times ----
    task automatic wait_k(input int n, output bit got);
        got = 0;
        fork
            begin wait (lk); got = 1; end
            #(n * T);
        join_any
        disable fork;
    endtask

    // ---- transmit one packet ----
    task automatic tx_packet(input byte pkt [$]);
        bit lvl = 1;
        int ones = 0;
        byte all [$];
        all = {8'h80};
        foreach (pkt[i]) all.push_back(pkt[i]);
        #(3 * T);                                   // turnaround
        drv = 1;
        foreach (all[k]) for (int i = 0; i < 8; i++) begin
            if (!all[k][i]) lvl = !lvl;
            {odp, odm} = LS ? {!lvl, lvl} : {lvl, !lvl};
            #(T);
            ones = all[k][i] ? ones + 1 : 0;
            if (ones == 6) begin
                lvl = !lvl; {odp, odm} = LS ? {!lvl, lvl} : {lvl, !lvl}; #(T); ones = 0;
            end
        end
        {odp, odm} = 2'b00; #(2 * T);
        {odp, odm} = LS ? 2'b01 : 2'b10; #(T);
        drv = 0;
    endtask

    task automatic tx_handshake(input byte pid);
        tx_packet('{pid});
    endtask

    task automatic tx_data(input bit data1, input byte payload [$]);
        byte p [$];
        logic [15:0] c = crc16(payload);
        if (corrupt_next_crc) begin c ^= 16'h0100; corrupt_next_crc = 0; end
        p = {data1 ? 8'h4B : 8'hC3};
        foreach (payload[i]) p.push_back(payload[i]);
        p.push_back(rev8(c[15:8])); p.push_back(rev8(c[7:0]));          // MSB-first bits, LSB-first bytes
        tx_packet(p);
    endtask

    // check a received DATA packet's CRC16; returns the payload
    function automatic bit check_data(input byte pkt [$], output byte payload [$]);
        logic [15:0] c;
        payload = pkt[1:$-2];
        c = crc16(payload);
        if (pkt[$-1] != rev8(c[15:8]) || pkt[$] != rev8(c[7:0])) begin
            fail($sformatf("DATA CRC16 mismatch: got %02x %02x, expected %02x %02x",
                           pkt[$-1], pkt[$], rev8(c[15:8]), rev8(c[7:0])));
            return 0;
        end
        return 1;
    endfunction

    // ---- control state ----
    byte ctl [$];
    int  ctl_idx = 0;
    bit  ctl_toggle = 1, ctl_stall = 0, ctl_in_data = 0;
    logic [6:0] pending_addr = 0;
    bit  pending_addr_valid = 0;
    bit  ep1_toggle = 0;

    task automatic do_setup(input byte s [$]);
        logic [15:0] wvalue = {s[3], s[2]}, wlength = {s[7], s[6]};
        ctl = {}; ctl_idx = 0; ctl_toggle = 1; ctl_stall = 0; ctl_in_data = s[0][7];
        foreach (last_setup[i]) last_setup[i] = s[i];
        setups++;
        case ({s[0], s[1]})
            16'h8006: begin
                case (wvalue[15:8])
                    8'h01: foreach (dev_desc[i]) ctl.push_back(dev_desc[i]);
                    8'h02: foreach (cfg_desc[i]) ctl.push_back(cfg_desc[i]);
                    default: ctl_stall = 1;
                endcase
            end
            16'h8106: if (wvalue[15:8] == 8'h22) foreach (hid_report[i]) ctl.push_back(hid_report[i]);
                      else ctl_stall = 1;
            16'h0005: begin pending_addr = wvalue[6:0]; pending_addr_valid = 1; end
            16'h0009: configured = wvalue[7:0] != 0;
            16'h210A: ;                                       // SET_IDLE
            16'h210B: boot_protocol = wvalue[7:0] == 0;       // SET_PROTOCOL
            default:  ctl_stall = 1;
        endcase
        while (ctl.size() > wlength) void'(ctl.pop_back());
    endtask

    // ---- main loop ----
    initial begin
        byte pkt [$], payload [$], resp [$];
        bit ok, got;
        realtime t0;
        forever begin
            wait (lk || lse0);
            if (lse0) begin                                   // keep-alive EOP or bus reset
                t0 = $realtime;
                wait (!lse0);
                if ($realtime - t0 > 2500.0) begin
                    my_addr = 0; configured = 0; ep1_toggle = 0; boot_protocol = 0;
                    $display("[%0t] %s: bus reset (%0.1f us)", $time, NAME, ($realtime - t0) / 1000.0);
                end
                continue;
            end
            t0 = $realtime;                                   // packet start, for SOF timing
            rx_packet(pkt, ok);
            if (!ok) continue;
            case (pkt[0])
            8'hA5, 8'h2D, 8'h69, 8'hE1: begin                 // tokens
                logic [10:0] f;
                logic [4:0]  c;
                if (pkt.size() != 3) begin fail("token length"); continue; end
                f = {pkt[2][2:0], pkt[1]};
                c = crc5(f);
                if (pkt[2][7:3] != rev5(c)) begin
                    fail($sformatf("CRC5 mismatch on %02x %02x %02x (expected %02x)",
                                   pkt[0], pkt[1], pkt[2], rev5(c)));
                    continue;
                end
                if (pkt[0] == 8'hA5) begin
                    if (last_frame >= 0 && f != ((last_frame + 1) & 11'h7FF))
                        fail($sformatf("SOF frame %0d after %0d", f, last_frame));
                    if (sofs > 0) begin                       // measured start to start
                        automatic real dev = t0 - last_sof_t - 1.0e6;
                        if (dev < 0) dev = -dev;
                        if (dev > max_sof_jitter) max_sof_jitter = dev;
                    end
                    last_frame = f; last_sof_t = t0; sofs++;
                    continue;
                end
                if (f[6:0] != my_addr) continue;              // not for us
                if (pkt[0] == 8'h2D || pkt[0] == 8'hE1) begin // SETUP / OUT: a DATA packet follows
                    automatic bit is_setup = pkt[0] == 8'h2D;
                    wait_k(16, got);
                    if (!got) begin fail("no DATA after SETUP/OUT"); continue; end
                    rx_packet(pkt, ok);
                    if (!ok || !check_data(pkt, payload)) continue;  // corrupt: no handshake
                    if (f[10:7] != 0) begin tx_handshake(8'h1E); continue; end
                    if (is_setup) begin
                        if (pkt[0] != 8'hC3) fail("SETUP data is not DATA0");
                        if (payload.size() != 8) begin fail("SETUP payload not 8 bytes"); continue; end
                        tx_handshake(8'hD2);
                        do_setup(payload);
                    end else
                        tx_handshake(ctl_stall ? 8'h1E : 8'hD2); // OUT: status stage of a read
                end else begin                                // IN
                    if (f[10:7] == 0) begin
                        if (ctl_stall) begin tx_handshake(8'h1E); continue; end
                        if (ctl_in_data) begin
                            resp = {};
                            for (int i = ctl_idx; i < ctl.size() && i < ctl_idx + 8; i++) resp.push_back(ctl[i]);
                        end else resp = {};               // status stage of a no-data request
                        tx_data(ctl_toggle, resp);
                        wait_k(20, got);
                        if (!got) begin missing_acks++; continue; end
                        rx_packet(pkt, ok);
                        if (ok && pkt[0] == 8'hD2) begin
                            acks_seen++;
                            ctl_idx += resp.size(); ctl_toggle = !ctl_toggle;
                            if (!ctl_in_data && pending_addr_valid) begin
                                my_addr = pending_addr; pending_addr_valid = 0;
                            end
                        end else fail("expected ACK");
                    end else if (f[10:7] == 1) begin
                        if (nak_ep1 > 0 || reports.size() < 8) begin
                            if (nak_ep1 > 0) nak_ep1--;
                            tx_handshake(8'h5A);
                            continue;
                        end
                        resp = reports[0:RPT_LEN-1];
                        tx_data(ep1_toggle, resp);
                        wait_k(20, got);
                        if (!got) begin missing_acks++; continue; end
                        rx_packet(pkt, ok);
                        if (ok && pkt[0] == 8'hD2) begin
                            acks_seen++;
                            repeat (8) void'(reports.pop_front());
                            ep1_toggle = !ep1_toggle;
                        end else fail("expected ACK");
                    end else
                        tx_handshake(8'h1E);
                end
            end
            default: ;                                        // stray packet: ignore
            endcase
        end
    end
endmodule
