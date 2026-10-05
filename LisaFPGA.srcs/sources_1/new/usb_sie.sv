// ---------------------------------------------------------------------------------------------
// usb_sie -- USB 1.1 host packet engine for one root port, driven by the soft CPU (usb_softcpu.sv).
// See docs/usb_softcpu_host_design.md.
//
// Everything with a microsecond deadline happens here; the CPU deals only in whole transactions:
//   * line state, attach/detach and speed detection, bus reset (held for as long as the CPU asks)
//   * SOF every 1 ms on a full-speed port, keep-alive EOP on a low-speed one
//   * one transaction per CMD write: token (CRC5), optional DATA0/1 (CRC16) for SETUP/OUT, the
//     response with a turnaround timeout, CRC16 check, and the ACK for IN data -- the 7.5 bit-time
//     deadline for that ACK is far too short for software
//   * a transaction is held back if it could still be running when the next SOF is due
//
// Polarity vs rate. CTRL.port_ls says what is attached to the PORT (a low-speed device directly): it sets
// line polarity and SOF vs keep-alive. CMD.ls says the TRANSACTION runs at 1.5 Mb/s. They differ for a
// low-speed device behind a hub: the port keeps full-speed polarity and SOFs, and each host packet is
// preceded by a full-speed PRE packet (CMD.pre) so the hub opens its low-speed ports.
//
// Bit timing at 60 MHz: 5 clocks/bit full speed, 40 low speed. The receiver resynchronises on every edge
// and samples mid-bit.
//
// Register map (byte offsets, 32-bit access):
//   0x00 CTRL    RW  [0] sof_en  [1] bus_reset (drive SE0 while set)  [2] port_ls
//   0x04 STATUS  R   [0] attached  [1] attached_fs  [2] busy  [3] done  [5:4] {dp,dm} now  [26:16] frame
//   0x08 CMD     W   [7:0] token PID  [14:8] addr  [18:15] endp  [19] DATA1  [20] ls  [21] pre
//                    [30:24] OUT/SETUP payload length (0-64). Writing starts the transaction.
//   0x0C RESULT  R   [3:0] status  [14:8] rx_len (data bytes, IN only)  [23:16] received PID
//   0x40-0x7C    TX buffer (OUT/SETUP payload), 16 words, little-endian bytes
//   0x80-0xC0    RX buffer (IN payload, followed by its two CRC bytes), 17 words
// Result status: 1 ACK, 2 NAK, 3 STALL, 4 DATA (IN payload received and ACKed), 5 TIMEOUT,
//                6 CRC error, 7 PID/bit-stuff error, 8 babble
// ---------------------------------------------------------------------------------------------
module usb_sie #(
    parameter int CLK_MHZ = 60
) (
    input  logic        clk,
    input  logic        reset,
    // register bus from the CPU
    input  logic        bus_we,          // one-cycle write strobe, already qualified by address decode
    input  logic [7:0]  bus_addr,
    input  logic [31:0] bus_wdata,
    input  logic [3:0]  bus_wstrb,
    output logic [31:0] bus_rdata,       // registered
    // pins
    input  logic        dp_i,
    input  logic        dm_i,
    output logic        dp_o,
    output logic        dm_o,
    output logic        oe
);
    localparam int FS_DIV = CLK_MHZ / 12;       // 5
    localparam int LS_DIV = CLK_MHZ * 2 / 3;    // 40
    localparam int FRAME  = CLK_MHZ * 1000;     // clocks per 1 ms frame
    localparam int ATTACH = CLK_MHZ * 5 / 2;    // 2.5 us of steady line state = attach / detach
    // A transaction may start only this many clocks before the next SOF. Worst cases: 64-byte full-speed
    // IN ~720 bit times = 3600 clocks; 8-byte low-speed transaction with PRE ~220 bit times = 8800 clocks.
    localparam int GUARD_FS = 4500;
    localparam int GUARD_LS = 10000;

    localparam logic [7:0] PID_IN = 8'h69, PID_SOF = 8'hA5, PID_DATA0 = 8'hC3, PID_DATA1 = 8'h4B,
                           PID_ACK = 8'hD2, PID_NAK = 8'h5A, PID_STALL = 8'h1E, PID_PRE = 8'h3C;
    localparam logic [3:0] ST_ACK = 1, ST_NAK = 2, ST_STALL = 3, ST_DATA = 4, ST_TIMEOUT = 5,
                           ST_CRC = 6, ST_PID = 7, ST_BABBLE = 8;

    // ---- CRC helpers, reflected (LSB-first) form ----
    function automatic logic [4:0] crc5_of(input logic [10:0] d);
        logic [4:0] c = 5'h1F;
        for (int i = 0; i < 11; i++) c = (c[0] ^ d[i]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
        return ~c;
    endfunction
    function automatic logic [15:0] crc16_step(input logic [15:0] c, input logic b);
        return (c[0] ^ b) ? ((c >> 1) ^ 16'hA001) : (c >> 1);
    endfunction

    // ---- registers ----
    logic        sof_en, bus_reset, port_ls;
    logic [7:0]  c_pid;
    logic [6:0]  c_addr;
    logic [3:0]  c_endp;
    logic        c_data1, c_ls, c_pre;
    logic [6:0]  c_len;
    logic        cmd_pending, busy, done;
    logic [3:0]  r_status;
    logic [6:0]  r_len;
    logic [7:0]  r_pid;
    logic [31:0] txbuf [0:15];
    logic [7:0]  rxbuf [0:67];
    logic [10:0] frame_no;

    // ---- line input ----
    logic [1:0] dp_s, dm_s;
    always_ff @(posedge clk) begin
        dp_s <= {dp_s[0], dp_i};
        dm_s <= {dm_s[0], dm_i};
    end
    wire dp_q = dp_s[1], dm_q = dm_s[1];
    wire se0  = !dp_q && !dm_q;
    wire jl   = port_ls ? dm_q : dp_q;          // 1 = J

    // ---- line output ----
    logic drv, drv_se0, lvl;                    // lvl: 1 = J
    always_comb begin
        oe   = drv || bus_reset;
        dp_o = (drv_se0 || bus_reset) ? 1'b0 : (port_ls ? !lvl :  lvl);
        dm_o = (drv_se0 || bus_reset) ? 1'b0 : (port_ls ?  lvl : !lvl);
    end

    // ---- attach detection: 2.5 us of steady SE0 / non-SE0 while nobody is driving ----
    logic [$clog2(ATTACH+1)-1:0] steady;
    logic attached, attached_fs, se0_prev;
    always_ff @(posedge clk) begin
        se0_prev <= se0;
        if (reset) begin
            steady <= '0; attached <= 1'b0; attached_fs <= 1'b0;
        end else if (oe || se0 != se0_prev) begin
            steady <= '0;
        end else if (steady != ATTACH) begin
            steady <= steady + 1;
        end else begin
            attached <= !se0;
            if (!se0 && !attached) attached_fs <= dp_q;
        end
    end

    // ---- frame timer ----
    logic [$clog2(FRAME)-1:0] frame_tmr;
    logic sof_pending;

    // ---- transmit / receive state ----
    typedef enum logic [3:0] {
        S_IDLE, S_TX_BITS, S_TX_EOP, S_TX_J, S_PRE_IDLE, S_GAP, S_WAIT_RESP, S_RX, S_RX_DONE, S_HOLD
    } state_t;
    state_t state;

    typedef enum logic [2:0] { K_TOKEN, K_SOF, K_DATA, K_ACK, K_PRE } kind_t;
    kind_t pkt_kind, pkt_after_pre;
    typedef enum logic [2:0] { N_IDLE, N_DATA, N_WAIT, N_ACK, N_FINISH } next_t;
    next_t after_tx;                           // what follows the packet being sent

    logic [5:0]  div;                          // clocks per bit for the current packet
    logic [5:0]  bit_cnt;
    wire         bit_tick = bit_cnt == div - 1;
    logic [6:0]  byte_idx, n_bytes;
    logic [7:0]  sh;
    logic [3:0]  bits_left;
    logic [2:0]  ones;
    logic        stuff, last_done;
    logic [15:0] crc;
    logic [3:0]  cnt;                          // bit counter for EOP / gaps
    logic [3:0]  gap_bits;
    logic        job_in;                       // current transaction is IN
    logic [10:0] wait_cnt;
    logic [3:0]  hold_status;

    // receiver
    logic [5:0]  rx_cnt;
    logic        jl_prev, rx_lvl, synced, stuff_err, babble;
    logic [2:0]  zeros, r_ones;
    logic [7:0]  rsh;
    logic [2:0]  r_bitpos;
    logic [6:0]  r_nbytes;
    logic [9:0]  r_bits;
    logic [15:0] r_crc;

    function automatic logic [7:0] byte_at(input kind_t k, input logic [6:0] i, input logic [15:0] c);
        logic [15:0] tok;
        tok = (k == K_SOF) ? {crc5_of(frame_no), frame_no} : {crc5_of({c_endp, c_addr}), c_endp, c_addr};
        if (i == 0) return 8'h80;              // SYNC
        if (i == 1) case (k)
            K_TOKEN: return c_pid;
            K_SOF:   return PID_SOF;
            K_DATA:  return c_data1 ? PID_DATA1 : PID_DATA0;
            K_ACK:   return PID_ACK;
            default: return PID_PRE;
        endcase
        if (k == K_TOKEN || k == K_SOF) return (i == 2) ? tok[7:0] : tok[15:8];
        if (i < c_len + 2) return txbuf[(i - 2) >> 2][((i - 2) & 3) * 8 +: 8];
        return (i == c_len + 2) ? ~c[7:0] : ~c[15:8];
    endfunction

    function automatic logic [6:0] len_of(input kind_t k);
        case (k)
            K_TOKEN, K_SOF: return 4;
            K_DATA:         return c_len + 4;
            default:        return 2;          // ACK, PRE
        endcase
    endfunction

    // TX bit step, combinational
    wire       tx_b      = sh[0];
    wire       in_crc    = pkt_kind == K_DATA && byte_idx >= 2 && byte_idx < c_len + 2;
    wire [15:0] crc_next = in_crc ? crc16_step(crc, tx_b) : crc;

    task automatic launch(input kind_t k, input logic with_pre, input logic low_speed);
        // with_pre: send a full-speed PRE first, then k at low speed
        pkt_kind      <= with_pre ? K_PRE : k;
        pkt_after_pre <= k;
        div           <= (low_speed && !with_pre) ? LS_DIV : FS_DIV;
        n_bytes       <= len_of(with_pre ? K_PRE : k);
        byte_idx      <= 0;
        sh            <= 8'h80;
        bits_left     <= 8;
        ones          <= 0;
        stuff         <= 1'b0;
        last_done     <= 1'b0;
        crc           <= 16'hFFFF;
        bit_cnt       <= 0;
        lvl           <= 1'b1;
        drv           <= 1'b1;
        drv_se0       <= 1'b0;
        state         <= S_TX_BITS;
    endtask

    task automatic finish(input logic [3:0] st);
        r_status <= st;
        busy     <= 1'b0;
        done     <= 1'b1;
        drv      <= 1'b0;
        state    <= S_IDLE;
    endtask

    // A reception we did not ACK: the device is still waiting for a handshake, for up to 18 bit times.
    // Keep the bus quiet past that before reporting, so the next token cannot be taken for one.
    task automatic hold(input logic [3:0] st);
        hold_status <= st;
        wait_cnt    <= 0;
        state       <= S_HOLD;
    endtask

    always_ff @(posedge clk) begin
        // ---- CPU writes ----
        if (bus_we) begin
            case (bus_addr)
                8'h00: {port_ls, bus_reset, sof_en} <= bus_wdata[2:0];
                8'h08: begin
                    {c_len, c_pre, c_ls, c_data1, c_endp, c_addr, c_pid} <=
                        {bus_wdata[30:24], bus_wdata[21:0]};
                    cmd_pending <= 1'b1; busy <= 1'b1; done <= 1'b0; r_status <= 0;
                end
                default: ;
            endcase
            if (bus_addr[7:6] == 2'b01)
                for (int b = 0; b < 4; b++)
                    if (bus_wstrb[b]) txbuf[bus_addr[5:2]][b*8 +: 8] <= bus_wdata[b*8 +: 8];
        end

        // ---- frame timer ----
        if (frame_tmr == FRAME - 1) begin
            frame_tmr <= 0;
            if (sof_en) sof_pending <= 1'b1;
        end else
            frame_tmr <= frame_tmr + 1;

        jl_prev <= jl;
        if (state != S_IDLE && state != S_WAIT_RESP && state != S_RX && state != S_RX_DONE)
            bit_cnt <= bit_tick ? 0 : bit_cnt + 1;

        case (state)
        S_IDLE: begin
            drv <= 1'b0;
            if (bus_reset) begin
                sof_pending <= 1'b0;
            end else if (sof_pending) begin
                sof_pending <= 1'b0;
                frame_no    <= frame_no + 1;
                if (port_ls) begin                  // keep-alive: low-speed EOP
                    div <= LS_DIV; bit_cnt <= 0; cnt <= 0;
                    drv <= 1'b1; drv_se0 <= 1'b1; lvl <= 1'b1;
                    after_tx <= N_IDLE; state <= S_TX_EOP;
                end else begin
                    launch(K_SOF, 1'b0, 1'b0);
                    after_tx <= N_IDLE;
                end
            end else if (cmd_pending && (!sof_en ||
                         frame_tmr < FRAME - (c_ls ? GUARD_LS : GUARD_FS))) begin
                cmd_pending <= 1'b0;
                job_in      <= c_pid == PID_IN;
                after_tx    <= (c_pid == PID_IN) ? N_WAIT : N_DATA;
                launch(K_TOKEN, c_pre, c_ls);
            end
        end

        S_TX_BITS: if (bit_tick) begin
            if (stuff) begin
                lvl <= !lvl; stuff <= 1'b0; ones <= 0;
            end else if (last_done) begin
                if (pkt_kind == K_PRE) begin        // no EOP after PRE: idle (J) for 4 FS bits
                    lvl <= 1'b1; cnt <= 0; state <= S_PRE_IDLE;
                end else begin
                    drv_se0 <= 1'b1; cnt <= 0; state <= S_TX_EOP;
                end
            end else begin
                if (!tx_b) lvl <= !lvl;
                if (tx_b) begin
                    ones <= ones + 1;
                    if (ones == 5) stuff <= 1'b1;
                end else
                    ones <= 0;
                crc <= crc_next;
                if (bits_left == 1) begin
                    if (byte_idx + 1 < n_bytes) begin
                        byte_idx  <= byte_idx + 1;
                        sh        <= byte_at(pkt_kind, byte_idx + 1, crc_next);
                        bits_left <= 8;
                    end else
                        last_done <= 1'b1;
                end else begin
                    sh        <= sh >> 1;
                    bits_left <= bits_left - 1;
                end
            end
        end

        S_PRE_IDLE: if (bit_tick) begin
            if (cnt == 3) launch(pkt_after_pre, 1'b0, 1'b1);
            else cnt <= cnt + 1;
        end

        S_TX_EOP: if (bit_tick) begin
            if (cnt == 1) begin drv_se0 <= 1'b0; lvl <= 1'b1; state <= S_TX_J; end
            else cnt <= cnt + 1;
        end

        S_TX_J: if (bit_tick) begin                 // one bit of J, then release the bus
            drv <= 1'b0;
            case (after_tx)
                N_IDLE:   state <= S_IDLE;
                N_DATA:   begin gap_bits <= 2; cnt <= 0; state <= S_GAP; end
                N_WAIT:   begin wait_cnt <= 0; state <= S_WAIT_RESP; end
                default:  finish(ST_DATA);         // N_FINISH: our ACK is out
            endcase
        end

        S_GAP: if (bit_tick) begin
            if (cnt == gap_bits - 1) begin
                if (after_tx == N_DATA) begin
                    after_tx <= N_WAIT;
                    launch(K_DATA, c_pre, c_ls);
                end else begin                      // N_ACK
                    after_tx <= N_FINISH;
                    launch(K_ACK, c_pre, c_ls);
                end
            end else
                cnt <= cnt + 1;
        end

        S_WAIT_RESP: begin
            div      <= c_ls ? LS_DIV : FS_DIV;
            wait_cnt <= wait_cnt + 1;
            if (!se0 && !jl) begin                  // K: start of SYNC
                rx_cnt <= 1; rx_lvl <= 1'b1; synced <= 1'b0; zeros <= 0; r_ones <= 0;
                stuff_err <= 1'b0; babble <= 1'b0; r_bitpos <= 0; r_nbytes <= 0; r_bits <= 0;
                r_crc <= 16'hFFFF; state <= S_RX;
            end else if (wait_cnt == (c_ls ? 24 * LS_DIV : 24 * FS_DIV))
                finish(ST_TIMEOUT);
        end

        S_RX: begin
            rx_cnt <= (jl != jl_prev) ? 1 : ((rx_cnt == div - 1) ? 0 : rx_cnt + 1);
            if (rx_cnt == div / 2) begin
                if (se0) begin
                    state <= S_RX_DONE;
                end else begin
                    automatic logic b = jl == rx_lvl;
                    rx_lvl <= jl;
                    r_bits <= r_bits + 1;
                    if (r_bits == 10'd1000) babble <= 1'b1;
                    if (!synced) begin
                        if (b) begin
                            if (zeros >= 3) begin synced <= 1'b1; r_ones <= 1; end
                            else stuff_err <= 1'b1;
                        end else if (zeros != 7) zeros <= zeros + 1;
                    end else if (r_ones == 6) begin // stuffed bit: must be 0, dropped
                        if (b) stuff_err <= 1'b1;
                        r_ones <= 0;
                    end else begin
                        r_ones   <= b ? r_ones + 1 : 0;
                        rsh      <= {b, rsh[7:1]};
                        r_bitpos <= r_bitpos + 1;
                        if (r_nbytes != 0) r_crc <= crc16_step(r_crc, b);
                        if (r_bitpos == 7) begin
                            if (r_nbytes == 0)      r_pid <= {b, rsh[7:1]};
                            else if (r_nbytes <= 67) rxbuf[r_nbytes - 1] <= {b, rsh[7:1]};
                            else                    babble <= 1'b1;
                            if (r_nbytes != 7'h7F) r_nbytes <= r_nbytes + 1;
                        end
                    end
                end
            end
            if (babble) hold(ST_BABBLE);
        end

        S_RX_DONE: begin
            // Decide. A good IN data packet gets an ACK after a short gap (4 bit times from the start of
            // the EOP, i.e. about 2 after it ends); everything else completes now.
            automatic logic pid_ok = r_pid[3:0] == ~r_pid[7:4] && r_bitpos == 0 && !stuff_err && synced;
            if (!pid_ok)
                hold(ST_PID);
            else if (r_pid == PID_NAK && r_nbytes == 1)
                finish(ST_NAK);
            else if (r_pid == PID_STALL && r_nbytes == 1)
                finish(ST_STALL);
            else if (!job_in)
                finish((r_pid == PID_ACK && r_nbytes == 1) ? ST_ACK : ST_PID);
            else if (r_pid != PID_DATA0 && r_pid != PID_DATA1)
                hold(ST_PID);
            else if (r_nbytes < 3 || r_crc != 16'hB001)
                hold(ST_CRC);
            else begin
                r_len    <= r_nbytes - 3;
                after_tx <= N_ACK;
                gap_bits <= 4; cnt <= 0; bit_cnt <= 0;
                state    <= S_GAP;
            end
        end
        S_HOLD: begin
            wait_cnt <= wait_cnt + 1;
            if (wait_cnt == (c_ls ? 24 * LS_DIV : 24 * FS_DIV)) finish(hold_status);
        end

        default: state <= S_IDLE;
        endcase

        if (reset) begin
            state <= S_IDLE; drv <= 1'b0; drv_se0 <= 1'b0; lvl <= 1'b1;
            sof_en <= 1'b0; bus_reset <= 1'b0; port_ls <= 1'b0;
            cmd_pending <= 1'b0; busy <= 1'b0; done <= 1'b0; r_status <= 0;
            frame_tmr <= 0; frame_no <= 0; sof_pending <= 1'b0;
        end
    end

    // ---- CPU reads ----
    always_ff @(posedge clk) begin
        case (bus_addr[7:6])
            2'b00: case (bus_addr[3:0])
                4'h0: bus_rdata <= {29'd0, port_ls, bus_reset, sof_en};
                4'h4: bus_rdata <= {5'd0, frame_no, 10'd0, dp_q, dm_q, done, busy, attached_fs, attached};
                4'h8: bus_rdata <= {1'b0, c_len, 2'b0, c_pre, c_ls, c_data1, c_endp, c_addr, c_pid};
                default: bus_rdata <= {8'd0, r_pid, 1'b0, r_len, 4'd0, r_status};
            endcase
            2'b01:   bus_rdata <= txbuf[bus_addr[5:2]];
            default: begin
                automatic logic [6:0] base = {bus_addr[6:2], 2'b00};   // 0x80-0xC0 -> bytes 0-67
                bus_rdata <= (base > 64) ? 32'd0 :
                             {rxbuf[base + 3], rxbuf[base + 2], rxbuf[base + 1], rxbuf[base]};
            end
        endcase
    end
endmodule
