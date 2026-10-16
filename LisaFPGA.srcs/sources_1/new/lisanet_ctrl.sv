// ---------------------------------------------------------------------------------------------
// lisanet_ctrl -- the WiFi board's control channel into the FPGA. Written with an AI assistant.
// See docs/lisanet_link_protocol.md, "FPGA control frames".
//
// The WiFi board's link TX (J21 GPIO5) passes through the FPGA to whichever ESP32 is serving its SD card -- or to
// nothing in NORMAL mode. This module listens on that line in EVERY mode for frames addressed to the FPGA itself:
//
//   C3 3C 96 69 | cmd | seq | len | payload[len] | CRC-32 (zlib, over cmd..payload, little-endian)
//
// and answers on J21 GPIO4 (the line back to the WiFi board) with cmd | 0x80 and a leading status byte. The SD servers
// look for A5 5A and skip everything else, so control frames pass them by; the WiFi board picks seq so a control frame
// never contains A5. The 4-byte marker plus the CRC mean SD traffic -- even uploaded file data -- effectively never
// parses as a control frame. In the WiFi modes GPIO4 normally carries the serving ESP32's TX, so a reply only starts
// after that line has been idle for REPLY_GUARD clocks; the WiFi board only sends a control frame while it has no SD
// request outstanding, so the ESP32 is silent.
//
// Commands:  0x01 STATUS                       -> status, version, bytes 0-10 of HDMI_Interface's status block, the
//                                                 die temperature (the XADC's raw 16-bit code, 12-bit result in
//                                                 bits 15:4; degrees C = code * 503.975 / 65536 - 273.15), then
//                                                 status bytes 11-12 (version 2 and later)
//            0x02 SET    u8 reg, u16 value     -> status. reg 1 video mode, 2 H offset, 3 V offset (the live mode's),
//                                                 4 max contrast, 5 CPU speed (0 = switches, 1-4), 6 ESP32 mode (0-2),
//                                                 8 scanlines, 9 inverse video, 10 CPU ROM (0 H, 1 3A), 11 I/O ROM
//                                                 (0 Sony, 1 Twiggy), 12 RAM size (0 = switches, 1-4 = 512K-2MB)
//            0x03 ACTION u8 action             -> status. 1 save settings, 2 press the power button, 3 press reset,
//                                                 4 press NMI
// Status: 0 OK, 1 BAD_REQUEST, 2 LOCKED (regs 6 and 10-12 while the Lisa is on), 3 TIMEOUT, 4 UNKNOWN_CMD.
//
// Settings live in HDMI_Interface (clk_pixel domain), which applies a write on its next frame tick with the same
// limits and locks as the on-screen menu. web_req is {toggle, reg[3:0], value[10:0]}: the data is set, then the
// toggle flips, and the module waits for web_ack (clk_pixel domain) to follow before taking another.
// ---------------------------------------------------------------------------------------------
module lisanet_ctrl (
    input  logic        clk,          // sysclk_fabric, 125 MHz
    input  logic        rx_pin,       // J21 GPIO5: WiFi board -> FPGA (asynchronous)
    input  logic        sd_tx_pin,    // the serving ESP32's TX toward the WiFi board, or 1 when none (asynchronous)
    output logic        tx,           // to J21 GPIO4 while tx_en
    output logic        tx_en = 1'b0,
    input  logic [103:0] status_in,   // from HDMI_Interface, clk_pixel domain; sampled twice and compared
    output logic [15:0] web_req = 16'd0,
    input  logic        web_ack,      // clk_pixel domain toggle
    output logic        pwr_press = 1'b0,   // level, ~250 ms: a virtual press of the Lisa's power button
    output logic        rst_press = 1'b0,   // level, ~250 ms: a virtual press of the reset button
    output logic        nmi_press = 1'b0    // level, ~250 ms: a virtual press of the NMI button
);
    localparam logic [7:0] VERSION     = 8'd2;   // 2: status bytes 11-12, SET regs 8-12, ACTION 4
    localparam int         REPLY_GUARD = 2500;        // 20 us = 40 bit times of idle on the ESP32's TX first
    localparam int         BYTE_GAP    = 12500;       // 100 us without a byte abandons a half-received frame
    localparam int         ACK_TIMEOUT = 25_000_000;  // 200 ms for HDMI_Interface to take a write (frames are <= 34 ms)
    localparam int         PRESS_TIME  = 31_250_000;  // 250 ms button press

    // ---- 2 Mbaud UART at 125 MHz: 62.5 clocks a bit, done as alternating 62 / 63 -------------------------------
    (* ASYNC_REG = "TRUE" *) logic rx_int = 1'b1, rx_s = 1'b1;
    (* ASYNC_REG = "TRUE" *) logic sd_int = 1'b1, sd_s = 1'b1;
    always_ff @(posedge clk) begin
        rx_int <= rx_pin;    rx_s <= rx_int;
        sd_int <= sd_tx_pin; sd_s <= sd_int;
    end

    typedef enum logic [1:0] {R_IDLE, R_START, R_DATA, R_STOP} rstate_t;
    rstate_t     rstate = R_IDLE;
    logic [6:0]  rcnt = 7'd0;
    logic        rtog = 1'b0;
    logic [2:0]  rbit = 3'd0;
    logic [7:0]  rshift = 8'd0;
    logic        rx_valid = 1'b0;
    logic [7:0]  rx_byte = 8'd0;
    always_ff @(posedge clk) begin
        rx_valid <= 1'b0;
        case (rstate)
            R_IDLE:  if (!rx_s) begin rstate <= R_START; rcnt <= 7'd30; end           // to the middle of the start bit
            R_START: if (rcnt != 7'd0) rcnt <= rcnt - 1'b1;
                     else if (!rx_s) begin rstate <= R_DATA; rbit <= 3'd0; rtog <= 1'b0; rcnt <= 7'd61; end
                     else rstate <= R_IDLE;                                             // a glitch, not a start bit
            R_DATA:  if (rcnt != 7'd0) rcnt <= rcnt - 1'b1;
                     else begin
                         rshift <= {rx_s, rshift[7:1]};                                 // LSB first
                         rtog   <= ~rtog;
                         rcnt   <= rtog ? 7'd61 : 7'd62;
                         if (rbit == 3'd7) rstate <= R_STOP; else rbit <= rbit + 1'b1;
                     end
            R_STOP:  if (rcnt != 7'd0) rcnt <= rcnt - 1'b1;
                     else begin
                         if (rx_s) begin rx_valid <= 1'b1; rx_byte <= rshift; end       // a framing error is dropped
                         rstate <= R_IDLE;
                     end
        endcase
    end

    logic        tx_start = 1'b0;
    logic [7:0]  tx_data = 8'd0;
    logic        tx_busy = 1'b0;
    logic [9:0]  tshift = 10'h3FF;
    logic [3:0]  tbit = 4'd0;
    logic [6:0]  tcnt = 7'd0;
    logic        ttog = 1'b0;
    logic        tx_line = 1'b1;
    assign tx = tx_line;
    always_ff @(posedge clk) begin
        if (!tx_busy) begin
            tx_line <= 1'b1;
            if (tx_start) begin
                tshift  <= {1'b1, tx_data, 1'b0};                                       // stop, data, start
                tx_line <= 1'b0;
                tx_busy <= 1'b1;
                tbit <= 4'd0; ttog <= 1'b0; tcnt <= 7'd61;
            end
        end else if (tcnt != 7'd0) begin
            tcnt <= tcnt - 1'b1;
        end else begin
            ttog <= ~ttog;
            tcnt <= ttog ? 7'd61 : 7'd62;
            if (tbit == 4'd9) begin tx_busy <= 1'b0; tx_line <= 1'b1; end
            else begin tbit <= tbit + 1'b1; tx_line <= tshift[tbit + 1'b1]; end
        end
    end

    // ---- Die temperature from the XADC -----------------------------------------------------------------------
    // Single-channel mode on the temperature sensor, averaging 16 samples, ADCCLK = 125 MHz / 5 = 25 MHz (26 max).
    // Read over DRP every 2^20 clocks (~8 ms). JTAG (Vivado's hardware manager) can still read the XADC alongside.
    logic [15:0] temp_raw = 16'd0;
    logic [15:0] xadc_do;
    logic        xadc_drdy;
    logic        xadc_den = 1'b0;
    logic [19:0] xadc_timer = 20'd0;
`ifdef SYNTHESIS
    XADC #(
        .INIT_40(16'h1000),     // averaging 16, channel 0 (temperature)
        .INIT_41(16'h3000),     // sequencer: single channel, continuous
        .INIT_42(16'h0500)      // ADCCLK divider 5
    ) xadc_inst (
        .DCLK(clk), .RESET(1'b0), .DADDR(7'h00), .DEN(xadc_den), .DI(16'h0000), .DWE(1'b0),
        .DO(xadc_do), .DRDY(xadc_drdy),
        .CONVST(1'b0), .CONVSTCLK(1'b0), .VP(), .VN(), .VAUXP(16'h0000), .VAUXN(16'h0000),
        .ALM(), .OT(), .CHANNEL(), .EOC(), .EOS(), .BUSY(), .JTAGBUSY(), .JTAGLOCKED(), .JTAGMODIFIED(), .MUXADDR()
    );
`else
    // Simulation stand-in: answers a read one clock later with 40.0 C (code 0x9F12)
    always_ff @(posedge clk) begin xadc_drdy <= xadc_den; end
    assign xadc_do = 16'h9F12;
`endif
    always_ff @(posedge clk) begin
        xadc_timer <= xadc_timer + 1'b1;
        xadc_den   <= (xadc_timer == 20'hFFFFF);
        if (xadc_drdy) temp_raw <= xadc_do;
    end

    // ---- Status snapshot and the write handshake ---------------------------------------------------------------
    logic [103:0] status_q = 104'd0;
    (* ASYNC_REG = "TRUE" *) logic ack_int = 1'b0, ack_s = 1'b0;
    always_ff @(posedge clk) begin
        status_q <= status_in;       // bounded by the clock-level set_max_delay; compared twice before use
        ack_int  <= web_ack;
        ack_s    <= ack_int;
    end

    // ---- Frame handling ------------------------------------------------------------------------------------------
    typedef enum logic [4:0] {
        P_S0, P_S1, P_S2, P_S3, P_CMD, P_SEQ, P_LEN, P_PAY, P_CRC, P_CHECK,
        X_DISPATCH, X_SNAP1, X_SNAP2, X_SET, X_WAIT_ACK, X_RESPOND,
        T_CRC, T_GUARD, T_SEND, T_WAIT
    } pstate_t;
    pstate_t     ps = P_S0;
    logic [7:0]  cmd = 8'd0, seq = 8'd0, len = 8'd0;
    logic [7:0]  pay [0:7];
    logic [3:0]  pidx = 4'd0;
    logic [31:0] rcrc = 32'd0;
    logic [1:0]  cidx = 2'd0;
    logic [13:0] gap = 14'd0;
    logic [31:0] crc = 32'hFFFFFFFF;
    logic [7:0]  cbyte = 8'd0;
    logic [3:0]  cbits = 4'd0;      // CRC bits still to process for cbyte
    logic [103:0] snap = 104'd0;
    logic [5:0]  snap_wait = 6'd0;
    logic [24:0] wait_cnt = 25'd0;
    logic [7:0]  status = 8'd0;
    // The response: C3 3C 96 69, cmd|80, seq, len, payload (status + up to 15 bytes), CRC-32
    logic [7:0]  rbuf [0:27];
    logic [4:0]  rlen = 5'd0, ridx = 5'd0;    // rlen = bytes from cmd|80 through the payload
    logic [24:0] pwr_cnt = 25'd0, rst_cnt = 25'd0, nmi_cnt = 25'd0;
    logic [11:0] guard = 12'd0;


    // Status block fields, all from snap (see HDMI_Interface's ctrl_status for the packing)
    logic lisa_on_snap;
    assign lisa_on_snap = snap[9];

    always_ff @(posedge clk) begin
        tx_start <= 1'b0;

        // CRC-32, one bit a clock (a byte every 625 clocks leaves plenty of time)
        if (cbits != 4'd0) begin
            crc   <= {1'b0, crc[31:1]} ^ ((crc[0] ^ cbyte[0]) ? 32'hEDB88320 : 32'd0);
            cbyte <= {1'b0, cbyte[7:1]};
            cbits <= cbits - 1'b1;
        end

        // Virtual button presses
        if (pwr_cnt != 25'd0) pwr_cnt <= pwr_cnt - 1'b1;
        if (rst_cnt != 25'd0) rst_cnt <= rst_cnt - 1'b1;
        if (nmi_cnt != 25'd0) nmi_cnt <= nmi_cnt - 1'b1;
        pwr_press <= (pwr_cnt != 25'd0);
        rst_press <= (rst_cnt != 25'd0);
        nmi_press <= (nmi_cnt != 25'd0);

        // A half-received frame is abandoned after BYTE_GAP clocks without a byte
        if (ps >= P_S1 && ps <= P_CRC) begin
            if (rx_valid) gap <= 14'd0;
            else if (gap == BYTE_GAP[13:0]) ps <= P_S0;
            else gap <= gap + 1'b1;
        end else gap <= 14'd0;

        case (ps)
            // ---- Receive -------------------------------------------------------------------------------------
            P_S0: if (rx_valid && rx_byte == 8'hC3) ps <= P_S1;
            P_S1: if (rx_valid) ps <= (rx_byte == 8'h3C) ? P_S2 : (rx_byte == 8'hC3) ? P_S1 : P_S0;
            P_S2: if (rx_valid) ps <= (rx_byte == 8'h96) ? P_S3 : (rx_byte == 8'hC3) ? P_S1 : P_S0;
            P_S3: if (rx_valid) begin
                      if (rx_byte == 8'h69) begin ps <= P_CMD; crc <= 32'hFFFFFFFF; end
                      else ps <= (rx_byte == 8'hC3) ? P_S1 : P_S0;
                  end
            P_CMD: if (rx_valid) begin cmd <= rx_byte; cbyte <= rx_byte; cbits <= 4'd8; ps <= P_SEQ; end
            P_SEQ: if (rx_valid) begin seq <= rx_byte; cbyte <= rx_byte; cbits <= 4'd8; ps <= P_LEN; end
            P_LEN: if (rx_valid) begin
                       len <= rx_byte; cbyte <= rx_byte; cbits <= 4'd8; pidx <= 4'd0; cidx <= 2'd0;
                       if (rx_byte > 8'd8) ps <= P_S0;                                  // no command is that long
                       else ps <= (rx_byte == 8'd0) ? P_CRC : P_PAY;
                   end
            P_PAY: if (rx_valid) begin
                       pay[pidx[2:0]] <= rx_byte; cbyte <= rx_byte; cbits <= 4'd8;
                       if (pidx + 1'b1 == len[3:0]) ps <= P_CRC;
                       pidx <= pidx + 1'b1;
                   end
            P_CRC: if (rx_valid) begin
                       rcrc <= {rx_byte, rcrc[31:8]};
                       cidx <= cidx + 1'b1;
                       if (cidx == 2'd3) ps <= P_CHECK;
                   end
            P_CHECK: if (cbits == 4'd0) ps <= ((crc ^ 32'hFFFFFFFF) == rcrc) ? X_DISPATCH : P_S0;   // bad CRC: silence

            // ---- Execute -------------------------------------------------------------------------------------
            X_DISPATCH: begin
                    status <= 8'd0;
                    rlen <= 5'd4;                                                   // cmd|80, seq, len, status
                    snap_wait <= 6'd0;
                    ps <= X_SNAP1;                                                  // every command reads the status first
                end
            X_SNAP1: begin snap <= status_q; snap_wait <= 6'd1; ps <= X_SNAP2; end
            X_SNAP2: if (snap_wait != 6'd0) snap_wait <= snap_wait + 1'b1;          // 63 clocks later...
                     else if (status_q != snap) ps <= X_SNAP1;                       // ...it must not have moved
                     else ps <= X_SET;
            X_SET: begin
                    ps <= X_RESPOND;
                    case (cmd)
                        8'h01: ;                                                    // STATUS: just the block
                        8'h02: if (len != 8'd3 || pay[0] == 8'd0 || pay[0] == 8'd7 || pay[0] > 8'd12) status <= 8'd1;
                               else if ((pay[0] == 8'd6 || pay[0] >= 8'd10) && lisa_on_snap) status <= 8'd2;
                               else begin
                                   web_req  <= {~web_req[15], pay[0][3:0], pay[2][2:0], pay[1]};
                                   wait_cnt <= 25'd0;
                                   ps <= X_WAIT_ACK;
                               end
                        8'h03: if (len != 8'd1) status <= 8'd1;
                               else case (pay[0])
                                   8'd1: begin                                     // save: reg 7 on the write path
                                           web_req  <= {~web_req[15], 4'd7, 11'd0};
                                           wait_cnt <= 25'd0;
                                           ps <= X_WAIT_ACK;
                                       end
                                   8'd2: pwr_cnt <= PRESS_TIME[24:0];
                                   8'd3: rst_cnt <= PRESS_TIME[24:0];
                                   8'd4: nmi_cnt <= PRESS_TIME[24:0];
                                   default: status <= 8'd1;
                               endcase
                        default: status <= 8'd4;
                    endcase
                end
            X_WAIT_ACK: if (ack_s == web_req[15]) ps <= X_RESPOND;
                        else if (wait_cnt == ACK_TIMEOUT[24:0]) begin status <= 8'd3; ps <= X_RESPOND; end
                        else wait_cnt <= wait_cnt + 1'b1;
            X_RESPOND: begin
                    rbuf[0] <= 8'hC3; rbuf[1] <= 8'h3C; rbuf[2] <= 8'h96; rbuf[3] <= 8'h69;
                    rbuf[4] <= cmd | 8'h80; rbuf[5] <= seq; rbuf[7] <= status;
                    if (cmd == 8'h01 && status == 8'd0) begin
                        // status, version, the 11 bytes from HDMI_Interface, the temperature
                        rbuf[6] <= 8'd17;
                        rbuf[8] <= VERSION;
                        for (int i = 0; i < 11; i++) rbuf[9 + i] <= snap[8*i +: 8];
                        rbuf[20] <= temp_raw[7:0];
                        rbuf[21] <= temp_raw[15:8];
                        rbuf[22] <= snap[95:88];                    // status bytes 11-12 (v2)
                        rbuf[23] <= snap[103:96];
                        rlen <= 5'd20;
                    end else begin
                        rbuf[6] <= 8'd1;
                        rlen <= 5'd4;
                    end
                    ridx <= 5'd4;
                    crc  <= 32'hFFFFFFFF;
                    ps   <= T_CRC;
                end

            // ---- Reply -----------------------------------------------------------------------------------------
            T_CRC: if (cbits == 4'd0) begin                                         // CRC over cmd|80 .. payload
                       if (ridx == rlen + 5'd4) begin
                           {rbuf[ridx + 5'd3], rbuf[ridx + 5'd2], rbuf[ridx + 5'd1], rbuf[ridx]} <= crc ^ 32'hFFFFFFFF;
                           guard <= 12'd0;
                           ps <= T_GUARD;
                       end else begin
                           cbyte <= rbuf[ridx]; cbits <= 4'd8; ridx <= ridx + 1'b1;
                       end
                   end
            T_GUARD: if (!sd_s) guard <= 12'd0;                                       // the ESP32 is talking: wait
                     else if (guard == REPLY_GUARD[11:0]) begin ridx <= 5'd0; tx_en <= 1'b1; ps <= T_SEND; end
                     else guard <= guard + 1'b1;
            T_SEND: if (!tx_busy && !tx_start) begin
                        if (ridx == rlen + 5'd8) begin tx_en <= 1'b0; ps <= P_S0; end
                        else begin tx_data <= rbuf[ridx]; tx_start <= 1'b1; ridx <= ridx + 1'b1; ps <= T_WAIT; end
                    end
            T_WAIT: if (tx_busy) ps <= T_SEND;                                        // the byte has started
            default: ps <= P_S0;
        endcase
    end

endmodule
