`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/20/2025 01:23:33 AM
// Design Name: 
// Module Name: HDMI_Interface
// Project Name: 
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


module HDMI_Interface #(
    // 0 = stock 1080p30/60 (default), 1 = fixed 1024x768@60Hz VESA output. See top.sv for the single high-level switch.
    parameter bit OUTPUT_1024X768 = 1'b0
) (
    input logic sysclk,
    input logic _reset,
    input logic DOTCK,
    input logic framerate_sel, // 0 for 1080p30, 1 for 1080p60
    input logic VA_overflow, // Replaces VSYNC; active high during vertical blanking
    input logic _clr_vid_clk, // Replaces _HSYNC; active low during horizontal blanking
    input logic VID,
    input logic [5:0] CONT,
    input logic cont_override, // When high, force the contrast to be maxed out all the time; added at the request of Adrian
    input logic TONE,
    input logic [2:0] VC,
    input logic CPU_ROM_SEL,
    input logic blank_video, // When high, force the video output to black
    input logic scanlines, // When high, put scanlines on the video output to make it look cool
    output logic tmds_clock,
    output logic [2:0] tmds
    );

    logic clk_pixel, clk_pixel_1080p30, clk_pixel_1080p60;
    logic clk_pixel_x5, clk_pixel_x5_1080p30, clk_pixel_x5_1080p60;
    logic clk_pixel_1024x768, clk_pixel_x5_1024x768;
    logic clk_feedback_in, clk_feedback_out;
    logic clk_feedback_in_1024x768, clk_feedback_out_1024x768;
    logic clk_audio_unbuffered, clk_audio;

    // Instantiate the MMCM for our stock 1080p30/1080p60 pixel clocks and their 5x pixel clocks
    // It always generates both framerates simultaneously regardless of OUTPUT_1024X768 -- this way,
    // flipping OUTPUT_1024X768 (see top.sv) never requires regenerating this IP; just flip the parameter and rebuild
    hdmi_clock_divider hdmi_clock_generator (
        .sysclk(sysclk),
        .clk_pixel_x5_1080p60(clk_pixel_x5_1080p60),
        .clk_pixel_x5_1080p30(clk_pixel_x5_1080p30),
        .clk_pixel_1080p60(clk_pixel_1080p60),
        .clk_pixel_1080p30(clk_pixel_1080p30),
        .clkfb_in(clk_feedback_in),
        .clkfb_out(clk_feedback_out)
    );
    // Give it a feedback path through a BUFG
    BUFG hdmi_clk_feedback (
        .I(clk_feedback_out),
        .O(clk_feedback_in)
    );

    // The 1024x768 pixel clock and its 5x TMDS clock need a SEPARATE MMCM, not just two more taps on
    // the IP above: hdmi_clock_divider's VCO is tuned to be a clean multiple of 74.25MHz (for the
    // 1080p clocks), and 65MHz doesn't share a clean common multiple with that -- dividing the same
    // VCO down for 65/325MHz landed ~3.8%/14.2% off nominal, and worse, the ratio between those two
    // came out to 5.5, not the exact 5 that TMDS/OSERDES2 serialization requires. A dedicated MMCM
    // with its own VCO, unconstrained by the 1080p outputs, can hit both frequencies (and their exact
    // 5x ratio) cleanly. Like hdmi_clock_divider above, this always generates its clocks regardless of
    // OUTPUT_1024X768. See tools/vivado_scripts/add_1024x768_clocks.tcl for how this IP is created.
    hdmi_clock_divider_1024x768 hdmi_clock_generator_1024x768 (
        .sysclk(sysclk),
        .clk_pixel_1024x768(clk_pixel_1024x768),
        .clk_pixel_x5_1024x768(clk_pixel_x5_1024x768),
        .clkfb_in(clk_feedback_in_1024x768),
        .clkfb_out(clk_feedback_out_1024x768)
    );
    // Give it its own feedback path through a BUFG, same as the IP above
    BUFG hdmi_clk_feedback_1024x768 (
        .I(clk_feedback_out_1024x768),
        .O(clk_feedback_in_1024x768)
    );

    // The jumper's "first" position (framerate_sel = 0) always selects 1080p30. The "second" position
    // (framerate_sel = 1) selects 1080p60 in a stock build, or the fixed 1024x768@60Hz mode when OUTPUT_1024X768
    // is set -- this way, an OUTPUT_1024X768 build can still fall back to a working 1080p30 picture by flipping
    // the jumper, e.g. if you need to plug into a 1080p-only display temporarily.
    logic clk_pixel_second_position, clk_pixel_x5_second_position;
    assign clk_pixel_second_position = OUTPUT_1024X768 ? clk_pixel_1024x768 : clk_pixel_1080p60;
    assign clk_pixel_x5_second_position = OUTPUT_1024X768 ? clk_pixel_x5_1024x768 : clk_pixel_x5_1080p60;

    // Next, we need to synchronize our framerate selector signal into the pixel clock and pixel clock x5 domains so we can feed it to other parts of our design
    (* ASYNC_REG = "TRUE" *) logic framerate_sel_int_pixel, framerate_sel_sync_pixel;
    (* ASYNC_REG = "TRUE" *) logic framerate_sel_int_pixel_x5, framerate_sel_sync_pixel_x5;
    always_ff @(posedge clk_pixel) begin
        framerate_sel_int_pixel <= framerate_sel;
        framerate_sel_sync_pixel <= framerate_sel_int_pixel;
    end
    always_ff @(posedge clk_pixel_x5) begin
        framerate_sel_int_pixel_x5 <= framerate_sel;
        framerate_sel_sync_pixel_x5 <= framerate_sel_int_pixel_x5;
    end
    // Now instantiate two BUFGMUXes to mux the pixel clocks and the x5 pixel clocks
    // DON'T use the synchronized framerate_sel here since they depend on the output of the BUFGMUX in the first place
    BUFGMUX bufgmux_clk_pixel (
        .I0(clk_pixel_1080p30),
        .I1(clk_pixel_second_position),
        .S(framerate_sel),
        .O(clk_pixel)
    );
    BUFGMUX bufgmux_clk_pixel_x5 (
        .I0(clk_pixel_x5_1080p30),
        .I1(clk_pixel_x5_second_position),
        .S(framerate_sel),
        .O(clk_pixel_x5)
    );

    // Pick the video ID code sent to the HDMI interface based on the (synchronized) framerate select signal:
    // 1080p30 in the jumper's first position, or 1080p60 / 1024x768 (whichever OUTPUT_1024X768 says the second
    // position means) in the second. hdmi.sv itself derives all of its frame timing from this value.
    logic [6:0] video_id_code;
    always_ff @(posedge clk_pixel) begin
        if (framerate_sel_sync_pixel == 1'b0) begin
            video_id_code <= 7'd34; // Code 34 for 1080p30
        end else begin
            video_id_code <= OUTPUT_1024X768 ? 7'd0 : 7'd16; // 0 = "no data" (1024x768 VESA DMT has no CEA code), or code 16 for 1080p60
        end
    end

    // Synchronise the reset signal (from the DOTCK domain) to the HDMI pixel clock domain
    // Otherwise we have tons of metastability issues`
    (* ASYNC_REG = "TRUE" *) logic _reset_hdmi_int, _reset_hdmi;
    // We use a two-stage synchronizer here
    always_ff @(posedge clk_pixel) begin
        _reset_hdmi_int <= _reset;
        _reset_hdmi <= _reset_hdmi_int;
    end

    // We need to synchronize blank_video too; it's the ON signal, which is in the COPCK_2x domain
    (* ASYNC_REG = "TRUE" *) logic blank_video_int, blank_video_sync;
    always_ff @(posedge clk_pixel) begin
        blank_video_int <= blank_video;
        blank_video_sync <= blank_video_int;
    end

    // Now generate the audio clock by dividing the pixel clock down to 48KHz using a counter
    // We can't use an MMCM because they can only go down to 6MHz or so
    logic [11:0] counter;
    // In a stock build, 1080p30 (74.25MHz) and 1080p60 (148.5MHz) share a clean 2x ratio, so we can just clock
    // this off the fixed 1080p30 reference and use a single threshold regardless of which framerate is selected
    // (that's the whole reason for doing it this way, per the original comment below).
    // But 1080p30 (74.25MHz) and 1024x768 (65MHz) DON'T share a clean ratio, so an OUTPUT_1024X768 build can't use
    // that shortcut: it has to actually track which mode is live (via framerate_sel_sync_pixel) and adjust the
    // threshold to match, clocked off the real muxed clk_pixel instead of a fixed reference.
    generate
        if (!OUTPUT_1024X768) begin : gen_audio_clk_stock
            // Clock this off the 1080p30 clock; this way we don't have to worry about the threshold changing when we shift between 1080p30 and 1080p60
            always_ff @(posedge clk_pixel_1080p30, negedge _reset_hdmi) begin
                if (!_reset_hdmi) begin
                    counter <= 12'd0;
                    clk_audio_unbuffered <= 1'b0;
                end else begin
                    if (counter == 12'd772) begin // Toggle threshold for 48KHz audio is 74250000 / (2 * 48000) = 772-ish
                        counter <= 12'd0;
                        clk_audio_unbuffered <= ~clk_audio_unbuffered;
                    end else begin
                        counter <= counter + 1'd1;
                    end
                end
            end
        end else begin : gen_audio_clk_1024x768_fallback
            logic [11:0] audio_clk_threshold;
            always_ff @(posedge clk_pixel) begin
                // 772-ish for 1080p30 (74.25MHz); 677 for 1024x768, which locks to an exact 65.000MHz (see
                // hdmi_clock_divider_1024x768's achieved MMCM_CLKOUT0_DIVIDE_F/MMCM_CLKFBOUT_MULT_F/MMCM_DIVCLK_DIVIDE),
                // so 65000000/(2*48000) = 677.08 rounds to 677, not 676. See the two generated-clock constraints in the
                // XDC for where these numbers come from (the XDC's divide_by 1354 = 2*677 already assumed this value).
                audio_clk_threshold <= (framerate_sel_sync_pixel == 1'b0) ? 12'd772 : 12'd677;
            end
            always_ff @(posedge clk_pixel, negedge _reset_hdmi) begin
                if (!_reset_hdmi) begin
                    counter <= 12'd0;
                    clk_audio_unbuffered <= 1'b0;
                end else begin
                    if (counter == audio_clk_threshold) begin
                        counter <= 12'd0;
                        clk_audio_unbuffered <= ~clk_audio_unbuffered;
                    end else begin
                        counter <= counter + 1'd1;
                    end
                end
            end
        end
    endgenerate

    // But clk_audio_unbuffered is a clock, and it's not on a clock net right now, which causes clock skew if we use it as-is
    // This isn't a theoretical problem; the audio actually gets garbled sometimes between synthesis runs if we don't fix the skew
    // So we need to get it on a real clock net there, which we can do with a BUFG
    BUFG buf_audio (
        .I(clk_audio_unbuffered),
        .O(clk_audio)
    );

    logic [15:0] audio_sample_word;

    // Now let's do the audio sample generation
    // We take our input audio square wave on TONE and volume on VC (3 bits)
    // And then we convert it to two 16-bit audio samples (stereo)
    // Both channels will be the same since the Lisa is mono
    // We need to convert the square wave to a PCM value, and scale it linearly based on VC
    // VC = 000 = mute, VC = 111 = max volume
    // So when TONE is high, output max_volume, when TONE is low, output 0
    // max_volume = (VC / 7) * 65535
    // So final output = TONE ? max_volume : 0
    // Before we do any of that though, synchronize both VC and TONE to the audio clock domain to avoid metastability issues
    (* ASYNC_REG = "TRUE" *) logic TONE_int, TONE_sync;
    (* ASYNC_REG = "TRUE" *) logic [2:0] VC_int, VC_sync;
    always_ff @(posedge clk_audio) begin
        TONE_int <= TONE;
        TONE_sync <= TONE_int;
        VC_int <= VC;
        VC_sync <= VC_int;
    end

    // LOS's volume levels are 0 for off (duh), 3 for Soft, 4, 5, and 6 for the in between levels, and 7 for Loud
    // But then after you select it, it remaps it to 1-5 from the 3-7, not sure why, maybe it maps it back when a sound actually plays
    // MacWorks Plus uses 0 for volume slider levels 0 and 1, 1 for volume slider levels 2 and 3, 2 for volume slider levels 4 and 5, and 3 for volume slider levels 6 and 7
    // MWP never goes above 3 oddly enough
    logic [15:0] max_volume;
    assign max_volume = (VC_sync == 3'd0) ? 16'd0 :
                        (VC_sync == 3'd1) ? 16'd9362 :
                        (VC_sync == 3'd2) ? 16'd18724 :
                        (VC_sync == 3'd3) ? 16'd28086 :
                        (VC_sync == 3'd4) ? 16'd37448 :
                        (VC_sync == 3'd5) ? 16'd46810 :
                        (VC_sync == 3'd6) ? 16'd56172 :
                                       16'd65535;
    always_ff @(posedge clk_audio) begin
        audio_sample_word <= TONE_sync ? max_volume : 0; //-max_volume;
    end

    logic [23:0] rgb = 24'd0;
    logic [11:0] cx;
    logic [10:0] cy;

    // We'll use the full vertical resolution (actually a little more), and less of the horizontal resolution
    // The Lisa is 720x364, so we'll center that in 1920x1080, but each Lisa pixel is 3 pixels high and 2 pixels wide
    // So we'll actually use 1440x1092 (720*2 x 364*3) centered in 1920x1080
    // This gives us a border of 240 pixels on the left and right, and we'll just crop 12 pixels off the bottom
    // (All of the above is for stock 1080p mode. When OUTPUT_1024X768 is set, we instead scale/center the image
    // into a 1024x768 frame; see the lisa_x/lisa_y and active-area generation logic further down for those details)
    // The Lisa framebuffer is a 32K 1 bit per pixel bitmap
    (* ram_style = "block" *)
    // The framebuffer needs to be 32760 bytes (720*364/8) for the H ROMs
    // And it needs to be 32832 bytes (608*432/8) for the 3A ROMs
    // But we'll make it even bigger (33000 bytes) to account for the fact that the 3A ROMs capture an extra few bytes at the end of the frame
    logic [7:0] lisa_framebuffer [0:32999];
    logic [9:0] lisa_x;
    logic [9:0] lisa_x_b; // Secondary source column for the 1024x768 horizontal blend (see hscale_lut_b)
    logic blend_en;       // High when this output pixel straddles two source columns and needs mixing
    logic [9:0] lisa_y;
    logic [15:0] word_index;
    logic [15:0] word_index_b; // Framebuffer address of the secondary (blended) source pixel
    logic [2:0] bit_index;
    logic [2:0] bit_index_b;
    // Intensity of the current output pixel in thirds: 0 = black, 3 = full white, 1/2 = the blended greys that the
    // 1024x768 horizontal anti-aliasing produces. Outside that mode only 0 and 3 ever occur
    logic [1:0] pixel_level;
    logic [15:0] byte_counter;
    logic [2:0] bit_counter;
    logic [7:0] current_byte;
    logic [3:0] end_line_overlap_counter;
    logic [3:0] start_line_overlap_counter;
    logic [1:0] hsync_delay_counter;
    logic prev_clr_vid_clk;
    logic [3:0] hsync_delay_counter_threshold;
    logic [3:0] start_line_overlap_counter_threshold;
    logic [3:0] end_line_overlap_counter_threshold;
    always_ff @(negedge DOTCK) begin
        // First, check the state of CPU_ROM_SEL and set the frame bounds accordingly
        if (CPU_ROM_SEL == 1'b0) begin
            // H ROMs; set the start and end line overlap counters for H ROM timing, as well as the start-of-frame hsync delay counter
            // Wait 2 lines after VSYNC is over before starting to capture lines
            // We really shouldn't be waiting at all here, but 364*3=1092 which is a bit bigger than 1080
            // This means 4 lines will get cut off the bottom of the frame, so to better center it, we wait 2 lines before starting to capture
            // This way, we lose 2 lines at the top and 2 lines at the bottom instead of all 4 at the bottom
            hsync_delay_counter_threshold <= 2'd2;
            start_line_overlap_counter_threshold <= 4'd9; // Wait 9 DOTCKs after HSYNC is over before starting to capture pixels
            end_line_overlap_counter_threshold <= 4'd9; // Keep capturing pixels for 9 DOTCKs after HSYNC starts
        end else begin
            // 3A ROMs; set the start and end line overlap counters for 3A ROM timing, and the the hsync delay counter is zero
            // No delay after VSYNC is over before starting to capture lines; 432*2=864 which fits within 1080 just fine
            hsync_delay_counter_threshold <= 2'd0;
            start_line_overlap_counter_threshold <= 4'd9; // Wait 9 DOTCKs after HSYNC is over before starting to capture pixels
            end_line_overlap_counter_threshold <= 4'd9; // Keep capturing pixels for 9 DOTCKs after HSYNC starts
        end
        prev_clr_vid_clk <= _clr_vid_clk;
        if (!_reset) begin
            bit_counter <= 0;
            byte_counter <= 0;
            current_byte <= 8'd0;
            start_line_overlap_counter <= 0;
            end_line_overlap_counter <= 0;
            hsync_delay_counter <= 0;
        end else begin
            if (VA_overflow == 1'b1) begin
                bit_counter <= 0;
                byte_counter <= 0;
                current_byte <= 8'd0;
                hsync_delay_counter <= 0;
                start_line_overlap_counter <= 0;
                end_line_overlap_counter <= 0;
            end else if ((_clr_vid_clk == 1'b1 || end_line_overlap_counter != end_line_overlap_counter_threshold) && hsync_delay_counter == hsync_delay_counter_threshold) begin
                if (_clr_vid_clk == 1'b0 && end_line_overlap_counter != end_line_overlap_counter_threshold) begin
                    end_line_overlap_counter <= end_line_overlap_counter + 1;
                end else if (_clr_vid_clk == 1'b1) begin
                    end_line_overlap_counter <= 4'd0;
                end
                if (start_line_overlap_counter != start_line_overlap_counter_threshold) begin
                    if (_clr_vid_clk == 1'b1) begin
                        start_line_overlap_counter <= start_line_overlap_counter + 1;
                    end
                end else begin
                    if (bit_counter == 3'd7) begin
                        lisa_framebuffer[byte_counter] <= {VID, current_byte[7:1]};
                        byte_counter <= byte_counter + 1;
                        bit_counter <= 0;
                        current_byte <= 8'd0;
                    end else begin
                        current_byte <= {VID, current_byte[7:1]};
                        bit_counter <= bit_counter + 1;
                    end
                end
            end else begin
                start_line_overlap_counter <= 4'd0;
                if (hsync_delay_counter != hsync_delay_counter_threshold && prev_clr_vid_clk && !_clr_vid_clk) begin
                    hsync_delay_counter <= hsync_delay_counter + 1;
                end
                if (bit_counter == 3'd7) begin
                    lisa_framebuffer[byte_counter] <= {VID, current_byte[7:1]};
                    byte_counter <= byte_counter + 1;
                    bit_counter <= 0;
                    current_byte <= 8'd0;
                end
            end
        end
    end

    // Now that we have the Lisa's display neatly in our framebuffer, we need to read it out and display it in 1080p HDMI

    // The way we do this will differ a bit depending on whether we're using H ROMs or 3A ROMs
    // The H ROMs capture a 720x364 image, where each Lisa pixel is 2 HDMI pixels wide and 3 HDMI pixels high
    // The 3A ROMs capture a 608x432 image, where each Lisa pixel is 2 HDMI pixels wide and 2 HDMI pixels high
    // To get things properly centered on the display, the H image will start at (240,0) and end at (1680,1092) in HDMI coordinates
    // And the 3A image will start at (352, 108) and end at (1568, 972) in HDMI coordinates
    // Interestingly enough, the final row (431) of the 3A image seems like it only gets partially drawn
    // The VSROM draws about an 1/8th of it and then goes straight into VSYNC, so it's like it doesn't even exist
    // Because of that, we'll actually only draw 431 rows of the 3A image, not the full 432, meaning it's actually 608x431
    // And thus it ends at (1568, 970) instead of (1568, 972)

    // I used to do all this in an always_comb block, but it wouldn't meet timing, so now I've pipelined it into a few stages

    // Before we do any of that though, we need to make a LUT for division by 3
    // Hardware dividers take tons of hardware resources and are too slow to meet timing at 148.5MHz, so a LUT is the solution
    (* rom_style = "distributed" *) logic [9:0] div3_lut [0:1079];

    initial begin
        integer i;
        for (i = 0; i <= 1079; i = i + 1) begin
            div3_lut[i] = i / 3;
        end
    end

    // We also need LUTs for mod 2 and mod 3 operations so that we can insert scanlines (blank lines) every 2 or 3 lines, depending on ROM type
     (* rom_style = "distributed" *) logic [1:0] mod2_lut [0:1079];
     (* rom_style = "distributed" *) logic [1:0] mod3_lut [0:1079];
     initial begin
         integer j;
         for (j = 0; j <= 1079; j = j + 1) begin
             mod2_lut[j] = j % 2;
             mod3_lut[j] = j % 3;
         end
     end

    // For the 1024x768 output mode, horizontal scaling of the H ROM image (720 -> 960) isn't a power-of-2 shift or a
    // simple division, so we use the same LUT trick: precompute, at elaboration time, which source Lisa column each
    // of the 960 active output columns maps to. This produces an exact repeating 4-output/3-source-pixel pattern
    // (960 = 240*4, 720 = 240*3, so it divides evenly with zero drift across the whole line)
    //
    // A plain nearest-neighbour 4/3 scale draws one out of every three source columns twice and the other two once,
    // which makes vertical strokes in text visibly alternate between 1px and 2px wide -- confirmed on hardware, and
    // the reason for the anti-aliasing below. Instead of picking a single source pixel, each output pixel is treated
    // as covering exactly 0.75 of a source pixel and takes an area-weighted blend of the (at most two) source pixels
    // it overlaps. Working through one group of 4 outputs over source pixels s0,s1,s2:
    //     out0 covers [0.00,0.75) -> all s0                    -> pure
    //     out1 covers [0.75,1.50) -> 0.25 of s0 + 0.50 of s1   -> 1/3 s0 + 2/3 s1
    //     out2 covers [1.50,2.25) -> 0.50 of s1 + 0.25 of s2   -> 2/3 s1 + 1/3 s2
    //     out3 covers [2.25,3.00) -> all s2                    -> pure
    // Conveniently every blended case is the same 2/3 + 1/3 split, so we only need a "primary" column, a "secondary"
    // column and a single blend flag. Every stroke then renders at equal visual weight, at the cost of soft grey edge
    // pixels instead of hard black/white ones (this is the ONLY place the output stops being strict nearest-neighbour;
    // 1080p and the 3A path are untouched and stay perfectly sharp integer scales)
    (* rom_style = "distributed" *) logic [9:0] hscale_lut_a [0:959]; // Primary (2/3 weight, or the whole pixel)
    (* rom_style = "distributed" *) logic [9:0] hscale_lut_b [0:959]; // Secondary (1/3 weight; == primary when pure)
    (* rom_style = "distributed" *) logic       hscale_blend [0:959]; // 1 = mix the two, 0 = primary only
    initial begin
        integer n, grp, pos;
        for (n = 0; n <= 959; n = n + 1) begin
            grp = n >> 2;
            pos = n[1:0];
            case (pos)
                0: begin // Entirely inside s0
                    hscale_lut_a[n] = grp * 3 + 0;
                    hscale_lut_b[n] = grp * 3 + 0;
                    hscale_blend[n] = 1'b0;
                end
                1: begin // Mostly s1, spilling back into s0
                    hscale_lut_a[n] = grp * 3 + 1;
                    hscale_lut_b[n] = grp * 3 + 0;
                    hscale_blend[n] = 1'b1;
                end
                2: begin // Mostly s1, spilling forward into s2
                    hscale_lut_a[n] = grp * 3 + 1;
                    hscale_lut_b[n] = grp * 3 + 2;
                    hscale_blend[n] = 1'b1;
                end
                default: begin // Entirely inside s2
                    hscale_lut_a[n] = grp * 3 + 2;
                    hscale_lut_b[n] = grp * 3 + 2;
                    hscale_blend[n] = 1'b0;
                end
            endcase
        end
    end

    // First up, we compute the Lisa pixel coordinates from the HDMI pixel coordinates
    // In 1080p mode (either framerate, in a stock build; or the jumper's 1080p30 position, in an OUTPUT_1024X768
    // build), each Lisa pixel is 2x3 (H ROMs) or 2x2 (3A ROMs) HDMI pixels
    // In 1024x768 mode (only reachable in an OUTPUT_1024X768 build, jumper in its second position), H ROMs use
    // an exact 4/3 horizontal LUT scale + 2x vertical line-doubling (see hscale_lut above); 3A ROMs get a simple
    // centered 1:1 stopgap (proper 3A scaling for 1024x768 is a follow-on, not implemented here)
    // lisa_x is the primary source column; lisa_x_b is the secondary one that gets blended in, and blend_en says
    // whether to actually blend. Outside the 1024x768 H ROM path the scale is a clean integer, so there's nothing to
    // blend: lisa_x_b just tracks lisa_x and blend_en stays low, which makes the blend stage below a no-op
    always_ff @(posedge clk_pixel) begin
        if (OUTPUT_1024X768 && framerate_sel_sync_pixel) begin
            if (CPU_ROM_SEL == 1'b0) begin
                // H ROMs: 960x728 image (720*4/3 x 364*2) centered in 1024x768, with 32px left/right and 20px top/bottom borders
                lisa_y <= (cy - 20) >> 1; // Exact 2x line-doubling, gives us Lisa pixel y coordinate 0-363
                lisa_x <= hscale_lut_a[cx - 32]; // Exact 4/3 scale via LUT, gives us Lisa pixel x coordinate 0-719
                lisa_x_b <= hscale_lut_b[cx - 32];
                blend_en <= hscale_blend[cx - 32];
            end else begin
                // 3A ROMs stopgap: simple centered 1:1 (608x432 centered in 1024x768 gives 208px left/right, 168px top/bottom borders)
                lisa_x <= cx - 208;
                lisa_x_b <= cx - 208;
                blend_en <= 1'b0;
                lisa_y <= cy - 168;
            end
        end else begin
            if (CPU_ROM_SEL == 1'b0) begin
                // If we have H ROMs, then each Lisa pixel is 2x3 HDMI pixels
                lisa_x <= (cx - 240) >> 1; // Remove the start offset of 240 HDMI pixels and divide by 2, gives us Lisa pixel x coordinate 0-719
                lisa_x_b <= (cx - 240) >> 1;
                blend_en <= 1'b0;
                lisa_y <= div3_lut[cy]; // Divide by 3 using our LUT, gives us Lisa pixel y coordinate 0-363
            end else begin
                // If we have 3A ROMs, then each Lisa pixel is 2x2 HDMI pixels
                lisa_x <= (cx - 352) >> 1; // Remove the start offset of 352 HDMI pixels and divide by 2, gives us Lisa pixel x coordinate 0-607
                lisa_x_b <= (cx - 352) >> 1;
                blend_en <= 1'b0;
                lisa_y <= (cy - 108) >> 1; // Remove the start offset of 108 HDMI pixels and divide by 2, gives us Lisa pixel y coordinate 0-431 (or really 0-430 since last line is cut off)
            end
        end
    end


    // Next, we use the Lisa pixel coordinates to compute our bit index into the framebuffer
    // Which we then use to determine which word and bit within that word we need to read from the framebuffer
    // Make sure to use a DSP for the multiplications here to help with timing
    // The secondary (blended) source pixel sits on the SAME row as the primary, so it reuses the expensive
    // lisa_y multiply and only needs its own column offset and bit index
    (* use_dsp = "yes" *) logic [15:0] word_index_int;
    logic [15:0] lisa_x_shifted, lisa_x_b_shifted;
    logic [2:0] bit_index_int, bit_index_b_int;
    logic blend_en_stage2, blend_en_pipe;
    always_ff @(posedge clk_pixel) begin
        if (CPU_ROM_SEL == 1'b0) begin
            // H ROMs
            // The easy-to-understand way to do this is:
            // word_index <= (lisa_y * 720 + lisa_x) >> 3; // Combine the x and y and divide by 8 to get word (byte) index
            // bit_index  <= (lisa_y * 720 + lisa_x) & 7; // Modulo 8 to get bit index within the byte
            // But this is pretty expensive (huge multiplier for lisa_y * 720) and fails timing at 1080p60, so we'll simplify it a bit
            // 720 / 8 = 90, so we can do:
            word_index_int <= lisa_y * 90; // Go ahead and do the >> 3 for 720 to get 90, combine with lisa_y to get word (byte) index of the column
            lisa_x_shifted <= lisa_x >> 3; // Also do the division by 8 for lisa_x here too
            lisa_x_b_shifted <= lisa_x_b >> 3;
            // We'll add in the row's lisa_x >> 3 in the next stage of the pipeline
            bit_index_int <= lisa_x[2:0]; // The lower 3 bits of lisa_x give us the bit index within the byte, no multiplication needed
            bit_index_b_int <= lisa_x_b[2:0];
        end else begin
            // 3A ROMs
            // Same deal for the 3A ROM version; this is the easy-to-understand way:
            // word_index <= (lisa_y * 608 + lisa_x) >> 3; // Combine the x and y and divide by 8 to get word (byte) index
            // bit_index  <= (lisa_y * 608 + lisa_x) & 7; // Modulo 8 to get bit index within the byte
            // But 608 / 8 = 76, so we can do:
            word_index_int <= lisa_y * 76; // Combine the y * 76 and x / 8 to get word (byte) index of the column
            lisa_x_shifted <= lisa_x >> 3; // Divide lisa_x by 8 here too
            lisa_x_b_shifted <= lisa_x_b >> 3;
            bit_index_int <= lisa_x[2:0]; // The lower 3 bits of lisa_x give us the bit index within the byte without any multiplication
            bit_index_b_int <= lisa_x_b[2:0];
        end
        blend_en_stage2 <= blend_en;
        // Now in the next pipeline stage, add lisa_x_shifted to the intermediate word index to account for how far we are into the line
        word_index <= word_index_int + lisa_x_shifted;
        word_index_b <= word_index_int + lisa_x_b_shifted;
        // The bit index was already done in the previous stage, so just pass it along
        bit_index <= bit_index_int;
        bit_index_b <= bit_index_b_int;
        blend_en_pipe <= blend_en_stage2;
    end

    // Two reads of the framebuffer per output pixel (primary + secondary). Both are reads of the same array from the
    // same clock domain, so Vivado just replicates the underlying block RAM -- the framebuffer is ~33KB, so this
    // costs a handful of extra BRAMs out of the 135 available on this part
    logic [7:0] pixel_word, pixel_word_b;

    // Pipeline the read address for better timing
    logic [15:0] word_index_stage3, word_index_stage4;
    logic [15:0] word_index_b_stage3;
    logic [2:0] bit_index_stage3, bit_index_stage4;
    logic [2:0] bit_index_b_stage3, bit_index_b_stage4;
    logic blend_en_stage3, blend_en_stage4;
    logic in_scanline_stage4, in_scanline_stage5;

    always_ff @(posedge clk_pixel) begin
        // In the third stage, we just pass the values along
        word_index_stage3 <= word_index;
        word_index_b_stage3 <= word_index_b;
        bit_index_stage3 <= bit_index;
        bit_index_b_stage3 <= bit_index_b;
        blend_en_stage3 <= blend_en_pipe;

        // In the fourth stage, we read the pixel words from the framebuffer
        word_index_stage4 <= word_index_stage3;
        bit_index_stage4 <= bit_index_stage3;
        bit_index_b_stage4 <= bit_index_b_stage3;
        blend_en_stage4 <= blend_en_stage3;
        pixel_word <= lisa_framebuffer[word_index_stage3];
        pixel_word_b <= lisa_framebuffer[word_index_b_stage3];
        // Also, if scanlines are on, figure out if we're in a scanline or not in this stage and set a flag accordingly
        if (scanlines) begin
            if (CPU_ROM_SEL == 1'b0) begin
                // For the H ROMs, we want a scanline every 3 lines, so check if mod3_lut[cy] == 2 (the last line in each 3 line group)
                in_scanline_stage4 <= (mod3_lut[cy] == 2);
            end else begin
                // For the 3A ROMs, we want a scanline every 2 lines, so check if mod2_lut[cy] == 1 (the last line in each 2 line group)
                in_scanline_stage4 <= (mod2_lut[cy] == 1);
            end
        end else begin
            in_scanline_stage4 <= 1'b0;
        end
        in_scanline_stage5 <= in_scanline_stage4;

        // And finally, in the fifth stage, we extract the pixel bits and turn them into an intensity level, but
        // override it to black if we're in a scanline. pixel_level is 0..3 in thirds:
        //   not blending -> primary only, so 0 (black) or 3 (full white), exactly as before
        //   blending     -> 2/3 primary + 1/3 secondary, giving the two intermediate greys
        if (in_scanline_stage5) begin
            pixel_level <= 2'd0;
        end else if (blend_en_stage4) begin
            pixel_level <= (pixel_word[bit_index_stage4] ? 2'd2 : 2'd0) +
                           (pixel_word_b[bit_index_b_stage4] ? 2'd1 : 2'd0);
        end else begin
            pixel_level <= pixel_word[bit_index_stage4] ? 2'd3 : 2'd0;
        end
    end

    // Now we can finally generate the RGB output based on the pixel value
    // But we need to delay cx and cy by 5 clock cycles to match the pixel signal
    logic [11:0] cx1, cx2, cx3, cx4, cx5, cx6;
    logic [10:0] cy1, cy2, cy3, cy4, cy5, cy6;
    always_ff @(posedge clk_pixel) begin
        cx1 <= cx;
        cx2 <= cx1;
        cx3 <= cx2;
        cx4 <= cx3;
        cx5 <= cx4;
        cx6 <= cx5;
        cy1 <= cy;
        cy2 <= cy1;
        cy3 <= cy2;
        cy4 <= cy3;
        cy5 <= cy4;
        cy6 <= cy5;
    end

    // Note: The "brightest" I've seen anything be able to go on the Lisa is an 0x11 on the CONT value (MacWorks Plus)
    // So maybe make 0x11 full white and scale down from there, just so things are brighter on HDMI?
    // Unless I find some other OS that goes brighter of course!

    // We need to synchronize CONT to the pixel clock domain before we can use it to adjust the brightness of the output
    (* ASYNC_REG = "TRUE" *) logic [5:0] CONT_int, CONT_sync;
    always_ff @(posedge clk_pixel) begin
        // An interesting quirk here though: we need to either pipe through CONT or a maxed-out contrast depending on cont_override
        if (cont_override) begin
            CONT_int <= 6'h00; // If cont_override is high, max out the contrast all the time
        end else begin
            CONT_int <= CONT; // Otherwise, use the CONT value from the Lisa
        end
        CONT_sync <= CONT_int;
    end

    // Turn the pixel intensity level into an actual 8-bit grey value, scaled by the current contrast setting.
    // Levels 0 and 3 are exactly the black/white the design has always produced; levels 1 and 2 are the
    // intermediate greys used by the 1024x768 horizontal anti-aliasing (they never occur in other modes).
    // Multiplying by 85/256 and 171/256 is a cheap stand-in for dividing by 3 (255*85/256 = 84.7, 255/3 = 85)
    logic [7:0] white_level;
    logic [15:0] shade_third, shade_two_thirds;
    logic [7:0] pixel_shade;
    assign white_level = {(6'h3f - CONT_sync), 2'b00};
    assign shade_third = white_level * 16'd85;
    assign shade_two_thirds = white_level * 16'd171;
    always_comb begin
        case (pixel_level)
            2'd0: pixel_shade = 8'h00;
            2'd1: pixel_shade = shade_third[15:8];
            2'd2: pixel_shade = shade_two_thirds[15:8];
            default: pixel_shade = white_level;
        endcase
    end

    // Now generate the RGB value
    always @(posedge clk_pixel) begin
        // Check our output mode and the ROM revision; the active area of the frame depends on both
        if (OUTPUT_1024X768 && framerate_sel_sync_pixel) begin
            if (CPU_ROM_SEL == 1'b0) begin
                // H ROM active area in 1024x768 mode: (32,20) to (992,748)
                if (cx6 >= 32 && cx6 < 992 && cy6 >= 20 && cy6 < 748) begin
                    rgb <= blank_video_sync ? 24'h000000 : {pixel_shade, pixel_shade, pixel_shade};
                end else begin
                    rgb <= 24'h202020;
                end
            end else begin
                // 3A ROM stopgap active area in 1024x768 mode: (208,168) to (816,600)
                if (cx6 >= 208 && cx6 < 816 && cy6 >= 168 && cy6 < 600) begin
                    rgb <= blank_video_sync ? 24'h000000 : {pixel_shade, pixel_shade, pixel_shade};
                end else begin
                    rgb <= 24'h202020;
                end
            end
        end else begin
            if (CPU_ROM_SEL == 1'b0) begin
                // H ROM active area: (240,0) to (1680,1092)
                if (cx6 >= 240 && cx6 < 1680 && cy6 < 1092) begin
                    // Figure out if the pixel is black or white, taking CONT into account
                    // No need to worry about INVID since it's already handled on the CPU board
                    // If the Lisa is off (blank_video), force black output
                    rgb <= blank_video_sync ? 24'h000000 : {pixel_shade, pixel_shade, pixel_shade};
                end else begin
                    // If we're outside the active area, output a dark gray border
                    rgb <= 24'h202020;
                end
            end else begin
                // 3A ROM active area: (352,108) to (1568,972) or really (1568,970) because of the missing last line
                if (cx6 >= 352 && cx6 < 1568 && cy6 >= 108 && cy6 < 970) begin
                    // Figure out if the pixel is black or white, taking CONT into account
                    // No need to worry about INVID since it's already handled on the CPU board
                    // If the Lisa is off (blank_video), force black output
                    rgb <= blank_video_sync ? 24'h000000 : {pixel_shade, pixel_shade, pixel_shade};
                end else begin
                    rgb <= 24'h202020;
                end
            end
        end
    end

    // hdmi.sv derives its own frame timing from video_id_code (34 = 1080p30, 16 = 1080p60, 0 = 1024x768 VESA DMT)
    hdmi #(.VIDEO_REFRESH_RATE(60.0), .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16)) hdmi(
        .video_id_code(video_id_code),
        .clk_pixel_x5(clk_pixel_x5), // Input clocks
        .clk_pixel(clk_pixel),
        .clk_audio(clk_audio),
        //.reset(~_reset_hdmi), // Reset signal, active high
        .rgb(rgb), // RGB pixel value
        .audio_sample_word({audio_sample_word, audio_sample_word}), // Audio samples (stereo)
        .tmds(tmds), // outputs to HDMI port
        .tmds_clock(tmds_clock),
        .cx(cx), // x and y coordinates of current pixel
        .cy(cy)
    );

endmodule