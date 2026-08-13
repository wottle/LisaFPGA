`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// settings_flash -- persists a small settings block in the FPGA's own configuration
// SPI flash (Winbond W25Q128JV, 16MB), so image-alignment tuning survives power cycles.
//
// *** SAFETY: this writes to the flash the FPGA boots from. ***
// The settings block lives at SETTINGS_ADDR = 0xC00000 (12MB in), about 8MB clear of the
// ~3.65MB bitstream at address 0. Erase touches a single 4KB sector and only ever happens on
// an explicit save request from the menu -- nothing here writes on its own. If it ever did go
// wrong, recovery is a JTAG reflash of the bitstream.
//
// Access method: after configuration the flash's CS/MOSI/MISO land on ordinary bank-14 I/O
// (FCS_B=L13, D00_MOSI=K17, D01_DIN=K18 on this part), but CCLK is NOT a user pin -- it can
// only be driven through the STARTUPE2 primitive's USRCCLKO port, which is the whole reason
// that primitive is instantiated here. Single-bit SPI throughout: quad only matters for fast
// configuration, and we are moving 16 bytes.
//
// Clocking: runs off the stable 125MHz sysclk, deliberately NOT the pixel clock, whose
// frequency changes with video mode. SCK is sysclk/8 (~15.6MHz), well inside the 50MHz limit
// for the plain 0x03 READ command.
//////////////////////////////////////////////////////////////////////////////////

module settings_flash #(
    parameter logic [23:0] SETTINGS_ADDR = 24'hC00000
) (
    input  logic        clk,          // 125MHz sysclk -- must be stable, not the muxed pixel clock
    input  logic        rst,          // active high

    input  logic        do_load,      // pulse: read the block from flash
    input  logic        do_save,      // pulse: erase the sector and write settings_in
    output logic        busy,
    output logic        load_done,    // pulses when a load finishes (check load_valid)
    output logic        load_valid,   // magic and checksum both matched

    input  logic [79:0] settings_in,  // 10 payload bytes, byte 0 in the low 8 bits
    output logic [79:0] settings_out,
    output logic [23:0] jedec_id,    // 0xEF4018 on a healthy W25Q128JV -- proof the SPI link works
    // Live diagnostic word, shown on screen: {3'b0, state, last rx byte, flags}. Lets us see where the
    // sequencer actually is, which the JEDEC readout could not -- a stuck machine still displays its last
    // latched ID and looks identical to a working one.
    output logic [23:0] dbg_word,

    // Flash pins. SCK is driven through STARTUPE2 inside this module, so it is not a port.
    output logic        flash_cs_n,
    output logic        flash_mosi,
    input  logic        flash_miso
);

    // ---------------------------------------------------------------------------------------
    // Block layout, 16 bytes:
    //   0..3   magic 'L','F','P','G'
    //   4..13  payload (settings_in / settings_out)
    //   14..15 checksum, a plain 16-bit sum of bytes 0..13
    // Anything that doesn't match falls back to defaults, so a blank (0xFF) or corrupted
    // sector behaves exactly like a board that has never been saved to.
    // ---------------------------------------------------------------------------------------
    localparam logic [7:0] MAGIC0 = "L", MAGIC1 = "F", MAGIC2 = "P", MAGIC3 = "G";

    // W25Q128JV command set (single-bit)
    localparam logic [7:0] CMD_READ  = 8'h03;
    localparam logic [7:0] CMD_WREN  = 8'h06;
    localparam logic [7:0] CMD_PP    = 8'h02; // page program
    localparam logic [7:0] CMD_ERASE = 8'h20; // 4KB sector erase
    localparam logic [7:0] CMD_RDSR1 = 8'h05; // read status register 1 (bit 0 = BUSY)
    localparam logic [7:0] CMD_RDID  = 8'h9F; // read JEDEC ID (manufacturer + type + capacity)

    // --- SCK generation: sysclk/8, plus the SPI mode-0 shift points derived from it ----------
    logic [2:0] clkdiv;
    logic sck_r, sck_rise, sck_fall;
    always_ff @(posedge clk) begin
        if (rst) clkdiv <= 3'd0;
        else     clkdiv <= clkdiv + 3'd1;
    end
    assign sck_rise = (clkdiv == 3'd4); // sample MISO here
    assign sck_fall = (clkdiv == 3'd0); // change MOSI here

    // --- byte-level shift engine -------------------------------------------------------------
    logic       xfer_start;
    logic [7:0] tx_byte, rx_byte, shift_tx, shift_rx;
    logic [3:0] bit_cnt;
    logic       xfer_active, xfer_done;

    always_ff @(posedge clk) begin
        if (rst) begin
            xfer_active <= 1'b0;
            xfer_done   <= 1'b0;
            sck_r       <= 1'b0;
            bit_cnt     <= 4'd0;
            flash_mosi  <= 1'b0;
        end else begin
            xfer_done <= 1'b0;
            if (xfer_start && !xfer_active) begin
                xfer_active <= 1'b1;
                shift_tx    <= {tx_byte[6:0], 1'b0};
                flash_mosi  <= tx_byte[7];   // MSB first, presented before the first rising edge
                bit_cnt     <= 4'd0;
            end else if (xfer_active) begin
                if (sck_rise) begin
                    sck_r    <= 1'b1;
                    shift_rx <= {shift_rx[6:0], flash_miso};
                    bit_cnt  <= bit_cnt + 4'd1;
                end else if (sck_fall) begin
                    sck_r <= 1'b0;
                    if (bit_cnt == 4'd8) begin
                        xfer_active <= 1'b0;
                        xfer_done   <= 1'b1;
                        rx_byte     <= shift_rx;
                    end else begin
                        flash_mosi <= shift_tx[7];
                        shift_tx   <= {shift_tx[6:0], 1'b0};
                    end
                end
            end else begin
                sck_r <= 1'b0;
            end
        end
    end

    // CCLK is not available as ordinary I/O; STARTUPE2 is the only route to it.
    // EOS (End Of Startup) matters: until it asserts, the startup sequencer still owns the config pins
    // and USRCCLKO does not reach CCLK. Issuing a command before then talks to nothing, which is exactly
    // what a single power-up read did -- one failed attempt, then it never tried again.
    logic eos;
    STARTUPE2 #(
        .PROG_USR("FALSE"),
        .SIM_CCLK_FREQ(0.0)
    ) startupe2_inst (
        .CFGCLK(), .CFGMCLK(), .EOS(eos), .PREQ(),
        .CLK(1'b0), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b0), .PACK(1'b0),
        .USRCCLKO(sck_r), .USRCCLKTS(1'b0),
        .USRDONEO(1'b1), .USRDONETS(1'b1)
    );

    // --- the 16 bytes we would write, with checksum, built combinationally --------------------
    logic [127:0] blk_tx;
    logic [15:0]  csum_tx;
    always_comb begin
        csum_tx = 16'(MAGIC0) + 16'(MAGIC1) + 16'(MAGIC2) + 16'(MAGIC3);
        for (int i = 0; i < 10; i++) csum_tx = csum_tx + 16'(settings_in[i*8 +: 8]);
        blk_tx = {csum_tx, settings_in, MAGIC3, MAGIC2, MAGIC1, MAGIC0};
    end

    // --- checksum over what we read back ------------------------------------------------------
    logic [127:0] blk;
    logic [15:0]  csum_rx;
    always_comb begin
        csum_rx = 16'd0;
        for (int i = 0; i < 14; i++) csum_rx = csum_rx + 16'(blk[i*8 +: 8]);
    end

    // --- command sequencer ---------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE,
        S_ID_CMD, S_ID_D0, S_ID_D1, S_ID_D2,
        S_LD_CMD, S_LD_A2b, S_LD_A2, S_LD_A1, S_LD_A0, S_LD_DATA, S_LD_CHECK,
        S_ER_WREN, S_ER_CMD, S_ER_A2, S_ER_A1, S_ER_A0, S_ER_END,
        S_PP_WREN, S_PP_CMD, S_PP_A2, S_PP_A1, S_PP_A0, S_PP_AL, S_PP_DATA, S_DESEL,
        S_POLL_CMD, S_POLL_RD, S_POLL_END
    } state_t;
    state_t state, ret_state, desel_next;
    assign dbg_word = {3'b000, 5'(state), rx_byte, 6'b000000, do_save, busy};
    logic [5:0] cs_dly;

    // Retry timer. Rather than reading once at power-up (which raced STARTUPE2 releasing CCLK and then
    // never tried again), wait for EOS plus a settling delay, then re-read every ~34ms. That keeps the
    // JEDEC ID display live, and means a transient failure at startup self-corrects instead of latching.
    logic [21:0] retry_cnt = 22'd0;
    logic auto_load;
    assign auto_load = eos && (retry_cnt == 22'h3FFFFF);

    // 5 bits, not 4: the page-program phase has to count to 16 to know it has sent every byte
    logic [4:0] byte_idx;

    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            load_done  <= 1'b0;
            load_valid <= 1'b0;
            flash_cs_n <= 1'b1;
            xfer_start <= 1'b0;
        end else begin
            retry_cnt <= retry_cnt + 22'd1;
            load_done  <= 1'b0;
            xfer_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    flash_cs_n <= 1'b1;
                    busy       <= 1'b0;
                    if (do_load || auto_load) begin
                        busy <= 1'b1; flash_cs_n <= 1'b0;
                        tx_byte <= CMD_RDID; xfer_start <= 1'b1; state <= S_ID_CMD;
                    end else if (do_save) begin
                        busy <= 1'b1; flash_cs_n <= 1'b0;
                        tx_byte <= CMD_WREN; xfer_start <= 1'b1; state <= S_ER_WREN;
                    end
                end

                // ---- LOAD: 0x03 + 24-bit address, then 16 bytes clocked in ----
                // ---- Read JEDEC ID first: a healthy W25Q128JV answers EF 40 18, which is proof the
                // ---- SPI link works. A dead MISO gives 000000 or FFFFFF instead. Runs ahead of every
                // ---- load so the menu always has a fresh answer to show.
                S_ID_CMD: if (xfer_done) begin tx_byte <= 8'h00; xfer_start <= 1'b1; state <= S_ID_D0; end
                S_ID_D0:  if (xfer_done) begin jedec_id[23:16] <= rx_byte; tx_byte <= 8'h00; xfer_start <= 1'b1; state <= S_ID_D1; end
                S_ID_D1:  if (xfer_done) begin jedec_id[15:8]  <= rx_byte; tx_byte <= 8'h00; xfer_start <= 1'b1; state <= S_ID_D2; end
                S_ID_D2:  if (xfer_done) begin
                    jedec_id[7:0] <= rx_byte;
                    flash_cs_n <= 1'b1;          // ID read ends here; the block read starts a new CS cycle
                    state <= S_LD_CMD;
                end
                // The block read proper. CS is re-asserted here because the ID read above released it.
                S_LD_CMD: begin flash_cs_n <= 1'b0; tx_byte <= CMD_READ; xfer_start <= 1'b1; state <= S_LD_A2b; end
                S_LD_A2b: if (xfer_done) begin tx_byte <= SETTINGS_ADDR[23:16]; xfer_start <= 1'b1; state <= S_LD_A2; end
                S_LD_A2:  if (xfer_done) begin tx_byte <= SETTINGS_ADDR[15:8];  xfer_start <= 1'b1; state <= S_LD_A1; end
                S_LD_A1:  if (xfer_done) begin tx_byte <= SETTINGS_ADDR[7:0];   xfer_start <= 1'b1; state <= S_LD_A0; end
                S_LD_A0:  if (xfer_done) begin byte_idx <= 5'd0; tx_byte <= 8'h00; xfer_start <= 1'b1; state <= S_LD_DATA; end
                S_LD_DATA: if (xfer_done) begin
                    blk[byte_idx[3:0]*8 +: 8] <= rx_byte;
                    if (byte_idx == 5'd15) begin
                        flash_cs_n <= 1'b1; state <= S_LD_CHECK;
                    end else begin
                        byte_idx <= byte_idx + 5'd1; tx_byte <= 8'h00; xfer_start <= 1'b1;
                    end
                end
                S_LD_CHECK: begin
                    load_valid   <= (blk[31:0] == {MAGIC3, MAGIC2, MAGIC1, MAGIC0}) && (csum_rx == blk[127:112]);
                    settings_out <= blk[111:32];
                    load_done    <= 1'b1;
                    state        <= S_IDLE;
                end

                // ---- SAVE step 1: write-enable, then erase the 4KB sector, then wait ----
                // Every command is committed by CS RISING, and the flash needs a real deselect gap
                // (tSHSL, tens of ns) before the next one -- hence S_DESEL rather than just toggling
                // CS for a single cycle. Getting this wrong is silent: the flash simply discards the
                // command and nothing is erased or written.
                S_ER_WREN: if (xfer_done) begin desel_next <= S_ER_CMD; cs_dly <= 6'd32; state <= S_DESEL; end
                S_ER_CMD: begin flash_cs_n <= 1'b0; tx_byte <= CMD_ERASE; xfer_start <= 1'b1; state <= S_ER_A2; end
                S_ER_A2: if (xfer_done) begin tx_byte <= SETTINGS_ADDR[23:16]; xfer_start <= 1'b1; state <= S_ER_A1; end
                S_ER_A1: if (xfer_done) begin tx_byte <= SETTINGS_ADDR[15:8];  xfer_start <= 1'b1; state <= S_ER_A0; end
                S_ER_A0: if (xfer_done) begin tx_byte <= SETTINGS_ADDR[7:0];   xfer_start <= 1'b1; state <= S_ER_END; end
                // Waits for the LAST address byte to finish before deselecting. Without this state the
                // erase command was still in flight when the status poll began, and CS never rose at all.
                S_ER_END: if (xfer_done) begin
                    ret_state <= S_PP_WREN; desel_next <= S_POLL_CMD; cs_dly <= 6'd32; state <= S_DESEL;
                end

                // ---- SAVE step 2: write-enable again, then page-program the 16 bytes ----
                S_PP_WREN: begin flash_cs_n <= 1'b0; tx_byte <= CMD_WREN; xfer_start <= 1'b1; state <= S_PP_CMD; end
                S_PP_CMD: if (xfer_done) begin desel_next <= S_PP_A2; cs_dly <= 6'd32; state <= S_DESEL; end
                S_PP_A2: begin flash_cs_n <= 1'b0; tx_byte <= CMD_PP; xfer_start <= 1'b1; state <= S_PP_A1; end
                S_PP_A1: if (xfer_done) begin tx_byte <= SETTINGS_ADDR[23:16]; xfer_start <= 1'b1; state <= S_PP_A0; end
                S_PP_A0: if (xfer_done) begin tx_byte <= SETTINGS_ADDR[15:8];  xfer_start <= 1'b1; state <= S_PP_AL; end
                S_PP_AL: if (xfer_done) begin
                    tx_byte <= SETTINGS_ADDR[7:0]; xfer_start <= 1'b1; byte_idx <= 5'd0; state <= S_PP_DATA;
                end
                S_PP_DATA: if (xfer_done) begin
                    if (byte_idx == 5'd16) begin
                        ret_state <= S_IDLE; desel_next <= S_POLL_CMD; cs_dly <= 6'd32; state <= S_DESEL;
                    end else begin
                        tx_byte <= blk_tx[byte_idx[3:0]*8 +: 8];
                        xfer_start <= 1'b1;
                        byte_idx <= byte_idx + 5'd1;
                    end
                end

                // ---- deselect with a dwell, then continue where desel_next says ----
                S_DESEL: begin
                    flash_cs_n <= 1'b1;
                    if (cs_dly == 6'd0) state <= desel_next;
                    else cs_dly <= cs_dly - 6'd1;
                end

                // ---- shared BUSY poll: read status register 1 until bit 0 clears ----
                S_POLL_CMD: begin flash_cs_n <= 1'b0; tx_byte <= CMD_RDSR1; xfer_start <= 1'b1; state <= S_POLL_RD; end
                S_POLL_RD:  if (xfer_done) begin tx_byte <= 8'h00; xfer_start <= 1'b1; state <= S_POLL_END; end
                S_POLL_END: if (xfer_done) begin
                    // Deselect properly between polls too -- the status read is a command like any other
                    desel_next <= rx_byte[0] ? S_POLL_CMD : ret_state;  // bit 0 set = still busy
                    cs_dly     <= 6'd32;
                    state      <= S_DESEL;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
