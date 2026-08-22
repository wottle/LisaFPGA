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
    parameter bit OUTPUT_1024X768 = 1'b0,
    // Horizontal placement of the image inside the 1080p frame: 0 = centre (default), 1 = flush left, 2 = flush right.
    // Only affects the 1080p modes; 1024x768 has its own always-centred borders. See top.sv.
    parameter bit [1:0] HALIGN_1080P = 2'd0,
    // TEMPORARY DEBUG AID -- live tuning of the 1080p horizontal offset via the ESFloppy buttons, with an on-screen
    // readout. Costs nothing when 0 (the parameter constant-folds the whole thing away). See top.sv.
    parameter bit ALIGNMENT_TUNING_MODE = 1'b0
) (
    // Settings loaded from the config flash. settings_loaded is a level (sysclk domain) that goes high
    // once the read finished; settings_data is stable from then on, so a simple level sync is enough CDC.
    input logic        settings_loaded,
    input logic        settings_valid,
    input logic [79:0] settings_data,
    input logic [23:0] jedec_id,           // flash JEDEC ID, shown when no saved block exists
    input logic        settings_save_done, // level from the sysclk side: the write finished
    output logic [79:0] settings_save_data = 80'd0, // snapshot taken when SAVE is picked, stable while saving
    output logic        settings_save_req = 1'b0,  // level: raised on SAVE, dropped once done

    // ESFloppy control buttons, active low. Only read when ALIGNMENT_TUNING_MODE is set; ignored otherwise.
    input logic btn_left,
    input logic btn_ok,
    input logic btn_right,
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
    // ------------------------------------------------------------------------------------------------------
    // Three-way runtime mode selection: 1080p30, 1080p60, 1024x768
    // ------------------------------------------------------------------------------------------------------
    // video_mode is the single source of truth for which mode is live:
    //   2'd0 = 1080p30 (74.25MHz pixel)   2'd1 = 1080p60 (148.5MHz)   2'd2 = 1024x768 (65MHz)
    // It powers up following the FRAMERATE jumper (so a board nobody touches behaves exactly like a stock one:
    // jumper picks 30 or 60), and stays following it until the menu's RESOLUTION item is used, after which the
    // menu owns it. Seeding happens on the first frame tick rather than at elaboration because the jumper is a
    // runtime input; the ~33ms of 1080p30 before that is far shorter than any display takes to sync, so it is
    // invisible in practice.
    //
    // OUTPUT_1024X768 no longer gates the CLOCK choice -- all three clocks are always generated. It now only
    // says whether mode 2 is *reachable*: with it clear, sel_1024 is a constant 0, so the second mux stage and
    // the whole 1024x768 scaling path fold away as dead code and you get a lean stock build.
    logic [1:0] video_mode = 2'd0;
    logic mode_user_set = 1'b0;   // Set once the menu picks a mode, after which the jumper stops driving it
    logic sel_60, sel_1024;
    assign sel_60   = (video_mode == 2'd1);
    assign sel_1024 = OUTPUT_1024X768 && (video_mode == 2'd2);

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

    // Cascaded BUFGMUXes: stage A picks between the two 1080p rates, stage B swaps in 1024x768 instead.
    // The selects are registers in the clk_pixel domain, i.e. clocked by the very clock they are switching --
    // a deliberate circular dependency that is safe because BUFGMUX switching is glitchless and the clock keeps
    // running (only its rate changes), so the register holds its value across the switch. This was already true
    // of the single-stage version and is confirmed working on hardware.
    logic clk_pixel_a, clk_pixel_x5_a;
    BUFGMUX bufgmux_clk_pixel_a (
        .I0(clk_pixel_1080p30),
        .I1(clk_pixel_1080p60),
        .S(sel_60),
        .O(clk_pixel_a)
    );
    BUFGMUX bufgmux_clk_pixel (
        .I0(clk_pixel_a),
        .I1(clk_pixel_1024x768),
        .S(sel_1024),
        .O(clk_pixel)
    );
    BUFGMUX bufgmux_clk_pixel_x5_a (
        .I0(clk_pixel_x5_1080p30),
        .I1(clk_pixel_x5_1080p60),
        .S(sel_60),
        .O(clk_pixel_x5_a)
    );
    BUFGMUX bufgmux_clk_pixel_x5 (
        .I0(clk_pixel_x5_a),
        .I1(clk_pixel_x5_1024x768),
        .S(sel_1024),
        .O(clk_pixel_x5)
    );

    // Frame timing in hdmi.sv is derived entirely from this, so it must track video_mode exactly.
    logic [6:0] video_id_code;
    always_ff @(posedge clk_pixel) begin
        case (video_mode)
            2'd0:     video_id_code <= 7'd34; // 1080p30
            2'd1:     video_id_code <= 7'd16; // 1080p60
            default: video_id_code <= 7'd0;  // 1024x768 -- VESA DMT has no CEA code, so "no data"
        endcase
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
    // With three runtime modes there is no fixed reference that works for all of them, so the counter runs off
    // the actual muxed clk_pixel and picks its threshold from video_mode.
    //
    // The counter runs 0..threshold inclusive, so a half period is (threshold + 1) clocks and the full divide is
    // 2*(threshold + 1). Hence threshold = round(f_pixel / 96000) - 1:
    //   1080p30   74.25MHz -> 773.4  -> 772   (full divide 1546, the value the stock design always used)
    //   1080p60  148.50MHz -> 1546.9 -> 1546  (full divide 3094)
    //   1024x768  65.00MHz -> 677.1  -> 676   (full divide 1354)
    // NOTE the -1: an earlier version of this file used 677 for 1024x768 on the reasoning that
    // 65000000/(2*48000) = 677.08 rounds to 677, which forgot that the counter spends threshold+1 cycles per
    // half period. That gave 678 cycles and a ~0.15% pitch error -- inaudible, but wrong; 676 is correct and
    // matches the XDC's -divide_by 1354.
    logic [11:0] audio_clk_threshold;
    always_ff @(posedge clk_pixel) begin
        case (video_mode)
            2'd0:    audio_clk_threshold <= 12'd772;  // 1080p30
            2'd1:    audio_clk_threshold <= 12'd1546; // 1080p60
            default: audio_clk_threshold <= 12'd676;  // 1024x768
        endcase
    end
    always_ff @(posedge clk_pixel, negedge _reset_hdmi) begin
        if (!_reset_hdmi) begin
            counter <= 12'd0;
            clk_audio_unbuffered <= 1'b0;
        end else begin
            if (counter >= audio_clk_threshold) begin
                counter <= 12'd0;
                clk_audio_unbuffered <= ~clk_audio_unbuffered;
            end else begin
                counter <= counter + 1'd1;
            end
        end
    end

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
    // Horizontal start offset of the image within the 1080p frame, derived from HALIGN_1080P. The H ROM image is
    // 1440 wide (720*2) and the 3A ROM image is 1216 (608*2), both inside a 1920-wide frame, so there are 480 and
    // 704 spare pixels respectively to place. Centre splits that evenly (the original hardcoded 240 and 352);
    // left puts it all on the right, and right puts it all on the left.
    localparam int H_ROM_1080P_WIDTH  = 1440;
    localparam int A3_ROM_1080P_WIDTH = 1216;
    localparam int H_ROM_1080P_X = (HALIGN_1080P == 2'd1) ? 0 :
                                   (HALIGN_1080P == 2'd2) ? (1920 - H_ROM_1080P_WIDTH) :
                                                            ((1920 - H_ROM_1080P_WIDTH) / 2);
    localparam int A3_ROM_1080P_X = (HALIGN_1080P == 2'd1) ? 0 :
                                    (HALIGN_1080P == 2'd2) ? (1920 - A3_ROM_1080P_WIDTH) :
                                                             ((1920 - A3_ROM_1080P_WIDTH) / 2);

    // ------------------------------------------------------------------------------------------------------
    // TEMPORARY: live image-alignment tuning via the ESFloppy buttons (ALIGNMENT_TUNING_MODE)
    // ------------------------------------------------------------------------------------------------------
    // Buttons are sampled once per frame, which doubles as a ~16ms debounce -- no separate debounce counter
    // needed. Holding a button therefore repeats at the frame rate (60/sec), so a full 480px sweep takes about
    // 8 seconds on the fine step and 1 second on the coarse one.
    //   LEFT / RIGHT : move the image along the currently selected axis
    //   OK           : cycles X-fine -> X-coarse -> Y-fine -> Y-coarse -> back
    // Four registers: horizontal and vertical, each held separately per output mode, so flipping the jumper
    // never destroys a value tuned in the other mode.
    logic [10:0] h_offset_1080p, h_offset_1024, v_offset_1080p, v_offset_1024;
    logic coarse_step = 1'b0;      // 0 = 1px per frame, 1 = 8px per frame
    logic axis_y = 1'b0;           // 0 = adjusting X, 1 = adjusting Y
    logic tuning_init_done = 1'b0;
    logic settings_valid_q = 1'b0;  // latched copy of settings_valid for the menu readout

    // Everything stays dormant until summoned: hold OK for ~5 seconds to open the on-screen menu. Until then the
    // buttons do nothing here (they still pass through to the ESP32 as always) and nothing is drawn, so the board
    // behaves exactly like a stock build. Counting frames avoids a separate timer, but the frame rate varies by
    // mode, so the target does too: 60Hz for 1024x768 and 1080p60, 30Hz for the 1080p30 position.
    //   OK held ~5s   : open / close the menu
    //   OK short press: activate the highlighted menu item, or (menu closed, adjust on) cycle axis and step size
    //   LEFT / RIGHT  : move the menu highlight, or (menu closed, adjust on) move the image
    logic tuning_active = 1'b0;    // "ADJUST IMAGE" -- readout visible and LEFT/RIGHT move the picture
    logic menu_active = 1'b0;
    logic [2:0] menu_sel = 3'd0;
    logic ok_long_fired = 1'b0;    // Set once the long press fires, so holding on doesn't toggle repeatedly
    logic [8:0] ok_frames = 9'd0;
    logic ok_pressed, prev_left, prev_right;
    logic [8:0] long_press_target;
    assign ok_pressed = (btn_sync[1] == 1'b0); // Buttons are active low
    assign long_press_target = (video_mode == 2'd0) ? 9'd90 : 9'd180; // ~3s: 1080p30 is 30Hz, the other two are 60Hz

    // Runtime overrides for things that are otherwise jumper-only. Each is a toggle XORed onto the real input,
    // so the physical jumper still works and the menu just flips whatever it currently says.
    logic scanlines_override = 1'b0;
    logic contrast_override_menu = 1'b0;
    logic scanlines_eff, contrast_eff;
    assign scanlines_eff = scanlines ^ scanlines_override;
    assign contrast_eff  = cont_override ^ contrast_override_menu;

    // Spare space is (frame size - image size), and differs by mode AND ROM type:
    //   1080p    H ROM : 1440x1092 in 1920x1080 -> 480 horiz, 0 vert (already cropped, nothing to move)
    //   1080p    3A    : 1216x862  in 1920x1080 -> 704 horiz, 218 vert
    //   1024x768 H ROM : 960x728   in 1024x768  -> 64 horiz,  40 vert
    //   1024x768 3A    : 608x432   in 1024x768  -> 416 horiz, 336 vert
    logic in_1024_mode, in_1024_mode_q;
    logic [10:0] h_limit, v_limit, active_limit, active_value;
    assign in_1024_mode = sel_1024; // Already OUTPUT_1024X768 && (video_mode == 2), declared up with the clock muxes
    assign h_limit = in_1024_mode ? ((CPU_ROM_SEL == 1'b0) ? 11'd64 : 11'd416)
                                  : ((CPU_ROM_SEL == 1'b0) ? 11'd480 : 11'd704);
    assign v_limit = in_1024_mode ? ((CPU_ROM_SEL == 1'b0) ? 11'd40 : 11'd336)
                                  : ((CPU_ROM_SEL == 1'b0) ? 11'd0  : 11'd218);
    assign active_limit = axis_y ? v_limit : h_limit;
    assign active_value = axis_y ? (in_1024_mode ? v_offset_1024 : v_offset_1080p)
                                 : (in_1024_mode ? h_offset_1024 : h_offset_1080p);

    // settings_loaded comes from the sysclk domain; sync it before the init logic below uses it.
    // Only the level needs crossing -- settings_data is written once, long before this goes high,
    // and never changes afterwards, so it is stable by construction and needs no synchroniser.
    (* ASYNC_REG = "TRUE" *) logic settings_loaded_int, settings_loaded_sync;
    (* ASYNC_REG = "TRUE" *) logic settings_save_done_int, settings_save_done_sync;
    // Pure synchronisers only. settings_save_req and settings_valid_q are deliberately NOT touched here:
    // they are also written by the menu block below, and driving one register from two always_ff blocks
    // is multiple-drivers -- illegal, and Vivado resolves it silently rather than erroring, which is what
    // made the save request never behave. All of their logic lives in the one block below.
    always_ff @(posedge clk_pixel) begin
        settings_loaded_int  <= settings_loaded;
        settings_loaded_sync <= settings_loaded_int;
        settings_save_done_int  <= settings_save_done;
        settings_save_done_sync <= settings_save_done_int;
    end

    (* ASYNC_REG = "TRUE" *) logic [2:0] btn_int, btn_sync;
    logic prev_cy_zero, frame_tick;
    // Feedback for a repeat save. settings_valid_q is sticky -- it means "a valid block exists in flash" --
    // so once the first save lands the row reads SAVED forever and a second save produces no visible change,
    // even though it really did write. This counter forces the row to show SAVING for a minimum number of
    // frames so every press gives feedback. The write itself is far shorter than that (a 4KB sector erase is
    // ~45ms), so without the hold the transition would flicker past in two or three frames.
    logic [5:0] save_disp_cnt = 6'd0;
    logic save_active;
    assign save_active = settings_save_req || (save_disp_cnt != 6'd0);
    logic [10:0] step_amount, next_value;
    assign step_amount = coarse_step ? 11'd8 : 11'd1;
    // What the selected register becomes after this frame's button state, saturating at both ends
    always_comb begin
        next_value = active_value;
        if (btn_sync[2] == 1'b0) begin          // LEFT: towards 0 (image moves left / up)
            next_value = (active_value > step_amount) ? (active_value - step_amount) : 11'd0;
        end else if (btn_sync[0] == 1'b0) begin // RIGHT: towards the limit (image moves right / down)
            next_value = ((active_value + step_amount) < active_limit) ? (active_value + step_amount) : active_limit;
        end
    end

    always_ff @(posedge clk_pixel) begin
        // Buttons come from the "user pressing things" domain, so synchronize before use
        btn_int  <= {btn_left, btn_ok, btn_right};
        btn_sync <= btn_int;

        // One pulse per frame, on the first line
        prev_cy_zero <= (cy == 0);
        frame_tick <= (cy == 0) && !prev_cy_zero;

        in_1024_mode_q <= in_1024_mode;

        // Save completion: drop the request and mark the block present, so the menu row switches to
        // SAVED. Lives in THIS block (not the synchroniser above) so these registers have a single driver.
        if (settings_save_done_sync && settings_save_req) begin
            settings_save_req <= 1'b0;
            settings_valid_q  <= 1'b1;
        end

        // video_mode follows the FRAMERATE jumper until the menu's RESOLUTION item is used, after which the
        // menu owns it. This is what makes an untouched board behave exactly like a stock one. Note this runs
        // whether or not ALIGNMENT_TUNING_MODE is set -- the jumper must work even in a build with no menu.
        if (frame_tick && !mode_user_set) begin
            video_mode <= framerate_sel_sync_pixel ? 2'd1 : 2'd0;
        end

        if (ALIGNMENT_TUNING_MODE && frame_tick) begin
            // Runs before the button handling below, so a fresh SEL press re-arms the counter rather than
            // having its reload immediately decremented in the same frame.
            if (save_disp_cnt != 6'd0) save_disp_cnt <= save_disp_cnt - 1'b1;

            // Hold off initialising until the flash read has finished, so a saved block wins over the
            // compile-time defaults rather than being briefly overwritten by them. If the block is
            // missing or its checksum failed, settings_valid is low and we fall back to defaults --
            // which are the centred positions, since with persistence there is no reason to bake an
            // alignment into the bitstream any more.
            if (!tuning_init_done && settings_loaded_sync) begin
                tuning_init_done <= 1'b1;
                if (settings_valid) begin
                    h_offset_1080p <= settings_data[10:0];
                    v_offset_1080p <= settings_data[26:16];
                    h_offset_1024  <= settings_data[42:32];
                    v_offset_1024  <= settings_data[58:48];
                    settings_valid_q       <= 1'b1;
                    scanlines_override     <= settings_data[64];
                    contrast_override_menu <= settings_data[65];
                    // A saved resolution takes over from the jumper, so a board wired to a 1024x768
                    // panel comes up in the right mode from cold without touching the menu
                    if (settings_data[68]) begin
                        video_mode    <= settings_data[67:66];
                        mode_user_set <= 1'b1;
                    end
                end else begin
                    // CPU_ROM_SEL is a runtime jumper, so these are seeded here rather than at elaboration
                    h_offset_1080p <= (CPU_ROM_SEL == 1'b0) ? H_ROM_1080P_X[10:0] : A3_ROM_1080P_X[10:0];
                    v_offset_1080p <= (CPU_ROM_SEL == 1'b0) ? 11'd0  : 11'd108;
                    h_offset_1024  <= (CPU_ROM_SEL == 1'b0) ? 11'd32 : 11'd208;
                    v_offset_1024  <= (CPU_ROM_SEL == 1'b0) ? 11'd20 : 11'd168;
                end
            end else begin
                prev_left  <= btn_sync[2];
                prev_right <= btn_sync[0];

                // OK: long hold toggles the menu, short press acts on release (so a long hold doesn't also
                // fire the short-press action on its way past)
                if (ok_pressed) begin
                    if (!ok_long_fired) begin
                        if (ok_frames >= long_press_target) begin
                            menu_active <= ~menu_active;
                            menu_sel <= 3'd0;
                            ok_long_fired <= 1'b1; // Wait for a release before this can fire again
                        end else begin
                            ok_frames <= ok_frames + 1'b1;
                        end
                    end
                end else begin
                    if (ok_frames != 9'd0 && !ok_long_fired) begin
                        if (menu_active) begin
                            // Activate the highlighted item
                            case (menu_sel)
                                // RESOLUTION: cycle 1080p30 -> 1080p60 -> 1024x768 -> back. Mode 2 is skipped
                                // when OUTPUT_1024X768 is clear, since that build has no 1024x768 clock.
                                3'd0: begin
                                    mode_user_set <= 1'b1;
                                    if (video_mode == 2'd0)      video_mode <= 2'd1;
                                    else if (video_mode == 2'd1) video_mode <= OUTPUT_1024X768 ? 2'd2 : 2'd0;
                                    else                         video_mode <= 2'd0;
                                end
                                3'd1: tuning_active <= ~tuning_active;                     // ADJUST IMAGE
                                3'd2: scanlines_override <= ~scanlines_override;           // SCANLINES
                                3'd3: contrast_override_menu <= ~contrast_override_menu;   // MAX CONTRAST
                                3'd4: begin
                                    // SETTINGS: snapshot the current values and ask the sysclk side to write
                                    // them. Latching here rather than driving the bus straight from the live
                                    // registers keeps it stable for the whole erase+program, which takes
                                    // milliseconds -- far longer than a button press.
                                    settings_save_data <= {
                                        {11'b0, 1'b1, video_mode, contrast_override_menu, scanlines_override},
                                        {5'b0, v_offset_1024},
                                        {5'b0, h_offset_1024},
                                        {5'b0, v_offset_1080p},
                                        {5'b0, h_offset_1080p}
                                    };
                                    settings_save_req <= 1'b1;
                                    save_disp_cnt     <= 6'd30;  // ~0.5s at 60Hz, ~1s at 30Hz
                                end
                                default: menu_active <= 1'b0;                              // EXIT
                            endcase
                        end else if (tuning_active) begin
                            // Menu closed and the adjust tool up: cycle axis then step size
                            {axis_y, coarse_step} <= {axis_y, coarse_step} + 2'd1;
                        end
                    end
                    ok_frames <= 9'd0;
                    ok_long_fired <= 1'b0;
                end

                if (menu_active) begin
                    // LEFT/RIGHT move the highlight, on press edges only so the list doesn't race past
                    if (btn_sync[2] == 1'b0 && prev_left == 1'b1) begin
                        menu_sel <= (menu_sel == 3'd0) ? 3'd5 : menu_sel - 1'b1;
                    end else if (btn_sync[0] == 1'b0 && prev_right == 1'b1) begin
                        menu_sel <= (menu_sel == 3'd5) ? 3'd0 : menu_sel + 1'b1;
                    end
                end else if (tuning_active) begin
                    // Write the (possibly unchanged) value back to whichever register is selected
                    if (axis_y) begin
                        if (in_1024_mode) v_offset_1024  <= next_value;
                        else              v_offset_1080p <= next_value;
                    end else begin
                        if (in_1024_mode) h_offset_1024  <= next_value;
                        else              h_offset_1080p <= next_value;
                    end
                end
            end
        end
        // If the jumper moved, re-clamp in case the new mode has less room than the stored value
        if (ALIGNMENT_TUNING_MODE && (in_1024_mode != in_1024_mode_q)) begin
            if (in_1024_mode) begin
                if (h_offset_1024 > h_limit) h_offset_1024 <= h_limit;
                if (v_offset_1024 > v_limit) v_offset_1024 <= v_limit;
            end else begin
                if (h_offset_1080p > h_limit) h_offset_1080p <= h_limit;
                if (v_offset_1080p > v_limit) v_offset_1080p <= v_limit;
            end
        end
    end

    // What the video path actually uses: the live register while tuning, otherwise the elaboration-time constant.
    // The 1024x768 constants (32/20 for the H ROM image, 208/168 for the 3A 1:1 stopgap) are its normal centred
    // borders; 108 is the 3A ROM's normal vertical border at 1080p. 1080p H ROM has no vertical offset at all --
    // its 1092-row image is already taller than the 1080-row frame, so there is nothing to slide.
    logic [10:0] h_rom_x_active, a3_rom_x_active, x1024_h_active, x1024_a3_active;
    logic [10:0] a3_rom_y_active, y1024_h_active, y1024_a3_active;
    assign h_rom_x_active   = ALIGNMENT_TUNING_MODE ? h_offset_1080p : H_ROM_1080P_X[10:0];
    assign a3_rom_x_active  = ALIGNMENT_TUNING_MODE ? h_offset_1080p : A3_ROM_1080P_X[10:0];
    assign a3_rom_y_active  = ALIGNMENT_TUNING_MODE ? v_offset_1080p : 11'd108;
    assign x1024_h_active   = ALIGNMENT_TUNING_MODE ? h_offset_1024  : 11'd32;
    assign x1024_a3_active  = ALIGNMENT_TUNING_MODE ? h_offset_1024  : 11'd208;
    assign y1024_h_active   = ALIGNMENT_TUNING_MODE ? v_offset_1024  : 11'd20;
    assign y1024_a3_active  = ALIGNMENT_TUNING_MODE ? v_offset_1024  : 11'd168;

    // Precompute the far edges of each active area. These only change when an offset changes -- at most once per
    // frame, and only while tuning -- so registering them is free, and it keeps an adder out of the per-pixel
    // comparison feeding the rgb register. Same 148.5MHz reasoning as the shade registers further down.
    logic [11:0] h_rom_x_end, a3_rom_x_end, x1024_h_end, x1024_a3_end;
    logic [10:0] a3_rom_y_end, y1024_h_end, y1024_a3_end;
    always_ff @(posedge clk_pixel) begin
        h_rom_x_end  <= h_rom_x_active  + H_ROM_1080P_WIDTH;
        a3_rom_x_end <= a3_rom_x_active + A3_ROM_1080P_WIDTH;
        a3_rom_y_end <= a3_rom_y_active + 11'd862;
        x1024_h_end  <= x1024_h_active  + 12'd960;
        y1024_h_end  <= y1024_h_active  + 11'd728;
        x1024_a3_end <= x1024_a3_active + 12'd608;
        y1024_a3_end <= y1024_a3_active + 11'd432;
    end

    // Compensate for the video pipeline's latency. Everything below computes a pixel from cx, but that pixel
    // doesn't reach the screen until several clocks later, by which time hdmi.sv has moved on to a later column
    // -- so without correction the image lands to the RIGHT of where the active-area test nominally puts it.
    // Invisible on a centred image, but at offset 0 it leaves a bar down the left edge.
    //
    // Counting stages: lisa_x(+1), word_index(+2), stage3(+1), pixel_word(+1), pixel_level(+1) = 6, then our own
    // rgb register = 7, then hdmi.sv's `video_data <= rgb` = 8. Against that, hdmi.sv derives the screen position
    // it is painting from `mode`/`hsync`, which are 2 registers behind cx. So the correction is 8 - 2 = 6.
    //
    // *** The wrap matters as much as the value. *** cx_adj MUST fold back to 0 at the end of a line: without
    // that, cx_adj never takes the values 0..LAT-1, so for the first few columns of every line the active-area
    // test is still looking at the tail of the PREVIOUS line (way outside the image) and paints border there.
    // That produces a left-edge bar that gets WIDER, not narrower, if you raise PIPELINE_LAT -- which is exactly
    // what a first attempt without this wrap did. If a thin bar remains at offset 0, raise this by a pixel or
    // two; if the leftmost source columns are clipped instead, lower it.
    // PIPELINE_LAT is 7 rather than 6 because cx_adj is REGISTERED below, which adds one more stage
    // between cx and the pixel data. See the note on that register for why it is worth a stage.
    localparam int PIPELINE_LAT = 7;
    logic [12:0] cx_plus_lat;
    logic [11:0] cx_adj_comb, cx_adj;
    assign cx_plus_lat = cx + PIPELINE_LAT;
    assign cx_adj_comb = (cx_plus_lat >= frame_width) ? 12'(cx_plus_lat - frame_width) : 12'(cx_plus_lat);
    // Registered on purpose. Combinationally, cx -> add -> compare -> wrap-subtract -> offset-subtract
    // -> shift was 11 logic levels and 5 carry chains in a single clock, which missed 148.5MHz by 37ps.
    // Splitting it here puts the add/compare/wrap in one clock and the offset subtract in the next.
    // Everything downstream already keys off cx_adj, and the extra stage is absorbed by PIPELINE_LAT
    // going 6 -> 7, so the image lands in exactly the same place.
    always_ff @(posedge clk_pixel) begin
        cx_adj <= cx_adj_comb;
    end

    // lisa_x is the primary source column; lisa_x_b is the secondary one that gets blended in, and blend_en says
    // whether to actually blend. Outside the 1024x768 H ROM path the scale is a clean integer, so there's nothing to
    // blend: lisa_x_b just tracks lisa_x and blend_en stays low, which makes the blend stage below a no-op
    always_ff @(posedge clk_pixel) begin
        if (in_1024_mode) begin
            if (CPU_ROM_SEL == 1'b0) begin
                // H ROMs: 960x728 image (720*4/3 x 364*2) centered in 1024x768, with 32px left/right and 20px top/bottom borders
                lisa_y <= (cy - y1024_h_active) >> 1; // Exact 2x line-doubling, gives us Lisa pixel y coordinate 0-363
                lisa_x <= hscale_lut_a[cx_adj - x1024_h_active]; // Exact 4/3 scale via LUT, gives us Lisa pixel x coordinate 0-719
                lisa_x_b <= hscale_lut_b[cx_adj - x1024_h_active];
                blend_en <= hscale_blend[cx_adj - x1024_h_active];
            end else begin
                // 3A ROMs stopgap: simple centered 1:1 (608x432 centered in 1024x768 gives 208px left/right, 168px top/bottom borders)
                lisa_x <= cx_adj - x1024_a3_active;
                lisa_x_b <= cx_adj - x1024_a3_active;
                blend_en <= 1'b0;
                lisa_y <= cy - y1024_a3_active;
            end
        end else begin
            if (CPU_ROM_SEL == 1'b0) begin
                // If we have H ROMs, then each Lisa pixel is 2x3 HDMI pixels
                lisa_x <= (cx_adj - h_rom_x_active) >> 1; // Remove the horizontal start offset and divide by 2, gives us Lisa pixel x coordinate 0-719
                lisa_x_b <= (cx_adj - h_rom_x_active) >> 1;
                blend_en <= 1'b0;
                lisa_y <= div3_lut[cy]; // Divide by 3 using our LUT, gives us Lisa pixel y coordinate 0-363
            end else begin
                // If we have 3A ROMs, then each Lisa pixel is 2x2 HDMI pixels
                lisa_x <= (cx_adj - a3_rom_x_active) >> 1; // Remove the horizontal start offset and divide by 2, gives us Lisa pixel x coordinate 0-607
                lisa_x_b <= (cx_adj - a3_rom_x_active) >> 1;
                blend_en <= 1'b0;
                lisa_y <= (cy - a3_rom_y_active) >> 1; // Remove the vertical start offset and divide by 2, gives us Lisa pixel y coordinate 0-431 (or really 0-430 since last line is cut off)
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
        if (scanlines_eff) begin
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
        cx1 <= cx_adj; // Must be the same adjusted coordinate the pixel data was computed from, so the
                       // active-area test below lines up with the image it is gating
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
        if (contrast_eff) begin
            CONT_int <= 6'h00; // If cont_override is high, max out the contrast all the time
        end else begin
            CONT_int <= CONT; // Otherwise, use the CONT value from the Lisa
        end
        CONT_sync <= CONT_int;
    end

    // ------------------------------------------------------------------------------------------------------
    // TEMPORARY: on-screen menu and alignment readout (only drawn when ALIGNMENT_TUNING_MODE is set)
    // ------------------------------------------------------------------------------------------------------
    // Shared 8x8 font, 64 glyph slots: 0-9 = digits, 10 = space, 11 = colon, 12-37 = A-Z, rest blank.
    // One byte per row, MSB = leftmost pixel. Held as one 64-bit literal per glyph and unpacked at elaboration.
    function automatic logic [63:0] glyph_bits(input int g);
        case (g)
            0:  glyph_bits = 64'h3C66666666663C00; //  0
            1:  glyph_bits = 64'h1838181818187E00; //  1
            2:  glyph_bits = 64'h3C66060C18307E00; //  2
            3:  glyph_bits = 64'h3C66061C06663C00; //  3
            4:  glyph_bits = 64'h0C1C3C6C7E0C0C00; //  4
            5:  glyph_bits = 64'h7E607C0606663C00; //  5
            6:  glyph_bits = 64'h1C30607C66663C00; //  6
            7:  glyph_bits = 64'h7E060C1830303000; //  7
            8:  glyph_bits = 64'h3C66663C66663C00; //  8
            9:  glyph_bits = 64'h3C66663E060C3800; //  9
            11: glyph_bits = 64'h0018180018180000; //  :
            12: glyph_bits = 64'h183C66667E666600; //  A
            13: glyph_bits = 64'h7C66667C66667C00; //  B
            14: glyph_bits = 64'h3C66606060663C00; //  C
            15: glyph_bits = 64'h786C6666666C7800; //  D
            16: glyph_bits = 64'h7E60607C60607E00; //  E
            17: glyph_bits = 64'h7E60607C60606000; //  F
            18: glyph_bits = 64'h3C66606E66663E00; //  G
            19: glyph_bits = 64'h6666667E66666600; //  H
            20: glyph_bits = 64'h3C18181818183C00; //  I
            21: glyph_bits = 64'h1E0C0C0C0C6C3800; //  J
            22: glyph_bits = 64'h666C7870786C6600; //  K
            23: glyph_bits = 64'h6060606060607E00; //  L
            24: glyph_bits = 64'h63777F6B63636300; //  M
            25: glyph_bits = 64'h66767E7E6E666600; //  N
            26: glyph_bits = 64'h3C66666666663C00; //  O
            27: glyph_bits = 64'h7C66667C60606000; //  P
            28: glyph_bits = 64'h3C6666666E3C0600; //  Q
            29: glyph_bits = 64'h7C66667C786C6600; //  R
            30: glyph_bits = 64'h3C66603C06663C00; //  S
            31: glyph_bits = 64'h7E18181818181800; //  T
            32: glyph_bits = 64'h6666666666663C00; //  U
            33: glyph_bits = 64'h66666666663C1800; //  V
            34: glyph_bits = 64'h6363636B7F776300; //  W
            35: glyph_bits = 64'h66663C183C666600; //  X
            36: glyph_bits = 64'h66663C1818181800; //  Y
            37: glyph_bits = 64'h7E060C1830607E00; //  Z
            default: glyph_bits = 64'h0000000000000000; // space and unused slots
        endcase
    endfunction

    // Turns an ASCII character into a glyph slot, so the menu text below can stay readable in the source
    function automatic logic [5:0] ascii_glyph(input logic [7:0] c);
        if (c >= "0" && c <= "9")      ascii_glyph = 6'(c - "0");
        else if (c >= "A" && c <= "Z") ascii_glyph = 6'(c - "A") + 6'd12;
        else if (c == ":")             ascii_glyph = 6'd11;
        else                           ascii_glyph = 6'd10; // space
    endfunction

    // Menu rows: a 16-character label followed by an 8-character value field
    function automatic logic [127:0] menu_label(input int i);
        case (i)
            0: menu_label = "RESOLUTION      ";
            1: menu_label = "ADJUST IMAGE    ";
            2: menu_label = "SCANLINES       ";
            3: menu_label = "MAX CONTRAST    ";
            4: menu_label = "SAVE SETTINGS   ";
            default: menu_label = "EXIT            ";
        endcase
    endfunction
    function automatic logic [63:0] menu_value(input int i);
        case (i)
            1: menu_value = " 1080P30";
            2: menu_value = "1024X768";
            3: menu_value = "      ON";
            4: menu_value = "     OFF";
            5: menu_value = " 1080P60"; // Only reachable in a stock (OUTPUT_1024X768 = 0) build
            6: menu_value = "   SAVED"; // A valid settings block was found in flash
            7: menu_value = " DEFAULT"; // Blank or bad checksum -- compile-time defaults in use
            8: menu_value = "  SAVING"; // Transient, held briefly so a repeat save is visible
            default: menu_value = "        ";
        endcase
    endfunction

    (* rom_style = "distributed" *) logic [7:0] font_rom   [0:511];
    (* rom_style = "distributed" *) logic [5:0] label_rom  [0:95];  // 6 rows x 16 chars
    (* rom_style = "distributed" *) logic [5:0] value_rom  [0:127]; // 16 slots x 8 chars (9 used)
    logic [63:0] glyph_tmp;
    logic [127:0] label_tmp;
    logic [63:0] value_tmp;
    initial begin
        for (int g = 0; g < 64; g = g + 1) begin
            glyph_tmp = glyph_bits(g);
            for (int r = 0; r < 8; r = r + 1) font_rom[g*8 + r] = glyph_tmp[8*(7-r) +: 8];
        end
        for (int i = 0; i < 6; i = i + 1) begin
            label_tmp = menu_label(i);
            for (int j = 0; j < 16; j = j + 1) label_rom[i*16 + j] = ascii_glyph(label_tmp[8*(15-j) +: 8]);
        end
        // Value strings: blank, 1080P30, 1024X768, ON, OFF, 1080P60, SAVED, DEFAULT, SAVING.
        // Fill all 16 slots (menu_value's default is blank) so no index can read an uninitialised entry.
        for (int i = 0; i < 16; i = i + 1) begin
            value_tmp = menu_value(i);
            for (int j = 0; j < 8; j = j + 1) value_rom[i*8 + j] = ascii_glyph(value_tmp[8*(7-j) +: 8]);
        end
    end

    // Binary -> decimal digits by lookup; cheaper than a divider and the offset only ever reaches 704
    (* rom_style = "distributed" *) logic [3:0] dec_hundreds [0:1023];
    (* rom_style = "distributed" *) logic [3:0] dec_tens     [0:1023];
    (* rom_style = "distributed" *) logic [3:0] dec_units    [0:1023];
    initial begin
        for (int d = 0; d < 1024; d = d + 1) begin
            dec_hundreds[d] = (d / 100) % 10;
            dec_tens[d]     = (d / 10) % 10;
            dec_units[d]    = d % 10;
        end
    end

    // --- Alignment readout: 5 chars in the top-left corner, "X240C" style, at 4x scale (32x32 per char) ---
    localparam int OVL_X = 16;
    localparam int OVL_Y = 16;
    logic overlay_on, overlay_pixel;
    logic [11:0] ovl_dx;
    logic [10:0] ovl_dy;
    logic [5:0] ovl_glyph;
    assign ovl_dx = cx5 - OVL_X;
    assign ovl_dy = cy5 - OVL_Y;
    // Decimal digits are REGISTERED, not looked up per pixel: active_value changes at most once per frame, but
    // chaining its mux -> three 1024-entry decimal ROMs -> character mux -> 512-entry font ROM -> bit select in
    // a single cycle was 12 logic levels and blew the 6.737ns budget at 148.5MHz (it fit easily at 65MHz). This
    // leaves only the small character mux and the font lookup in the per-pixel path.
    logic [3:0] dec_h_q, dec_t_q, dec_u_q;
    always_ff @(posedge clk_pixel) begin
        dec_h_q <= dec_hundreds[active_value[9:0]];
        dec_t_q <= dec_tens[active_value[9:0]];
        dec_u_q <= dec_units[active_value[9:0]];
    end
    always_comb begin
        case (ovl_dx[7:5]) // Which of the five characters we're inside
            3'd0: ovl_glyph = axis_y ? 6'd36 : 6'd35;                    // Y or X
            3'd1: ovl_glyph = 6'(dec_h_q);
            3'd2: ovl_glyph = 6'(dec_t_q);
            3'd3: ovl_glyph = 6'(dec_u_q);
            default: ovl_glyph = coarse_step ? 6'd14 : 6'd17;            // C or F
        endcase
    end
    always_ff @(posedge clk_pixel) begin
        overlay_on <= ALIGNMENT_TUNING_MODE && tuning_active && !menu_active &&
                      (cx5 >= OVL_X) && (cx5 < OVL_X + 160) &&
                      (cy5 >= OVL_Y) && (cy5 < OVL_Y + 32);
        // ovl_dx[4:2] / ovl_dy[4:2] are the column/row within the 8x8 glyph at 4x scale
        overlay_pixel <= font_rom[{ovl_glyph, ovl_dy[4:2]}][7 - ovl_dx[4:2]];
    end

    // --- Menu: 24 chars x 5 rows at 2x scale => 384x80, centred for whichever mode is live ---
    localparam int MENU_W = 384;
    localparam int MENU_H = 96;  // 6 rows at 16px
    logic [11:0] menu_x;
    logic [10:0] menu_y;
    assign menu_x = in_1024_mode ? 12'd320 : 12'd768;
    assign menu_y = in_1024_mode ? 11'd336 : 11'd492;  // (768-96)/2 and (1080-96)/2

    logic menu_on, menu_pixel, menu_highlight;
    logic [11:0] mdx;
    logic [10:0] mdy;
    logic [2:0] m_row;
    logic [3:0] m_vid;
    // Registered copy, used for the value-string ROM lookup. m_vid depends ONLY on m_row, which comes
    // from mdy and is therefore constant for a whole scan line -- so delaying it by one pixel clock is
    // visually free: it settles one pixel into the line, and the menu box does not start until x=320
    // (1024x768) or x=768 (1080p). What it buys is breaking the
    //   video_mode -> m_vid -> value_rom -> m_glyph -> font_rom -> menu_pixel
    // chain, which is 12 logic levels and was marginal at 1080p60's 6.737ns (WNS -0.019).
    logic [3:0] m_vid_q;
    logic [4:0] m_col;
    logic [5:0] m_glyph;
    logic [3:0] hex_nib;
    logic [2:0] hex_idx;
    assign mdx = cx5 - menu_x;
    assign mdy = cy5 - menu_y;
    assign m_row = mdy[6:4]; // 16px per row at 2x scale
    assign m_col = mdx[8:4]; // 16px per character, 0..23
    always_comb begin
        // Which value string this row shows, from the live state of whatever that row controls
        case (m_row)
            // What the second mode actually IS depends on the build, so name it accordingly rather than
            // assuming 1024x768: a stock build's second position is 1080p60
            3'd0: m_vid = (video_mode == 2'd0) ? 4'd1 : (video_mode == 2'd1) ? 4'd5 : 4'd2; // 1080P30 / 1080P60 / 1024X768
            3'd1: m_vid = tuning_active ? 4'd3 : 4'd4; // ON / OFF
            3'd2: m_vid = scanlines_eff ? 4'd3 : 4'd4;
            3'd3: m_vid = contrast_eff  ? 4'd3 : 4'd4;
            // SAVING wins over both, so a repeat save on an already-saved board still shows something happening
            3'd4: m_vid = save_active ? 4'd8 : (settings_valid_q ? 4'd6 : 4'd7);
            default: m_vid = 4'd0;                        // EXIT has no value
        endcase
        // Columns 0-15 are the label, 16-23 the value (m_col[2:0] conveniently gives 0-7 there).
        // The SETTINGS row is special when nothing is saved: instead of a fixed string it shows the
        // flash's JEDEC ID as hex, which is the quickest way to tell a working SPI link (EF4018 on a
        // W25Q128JV) from a dead one (000000 or FFFFFF). Two leading spaces, then six nibbles.
        // Value columns 2..7 map to nibbles 5..0 (MSB first); clamped so the columns showing spaces
        // don't index past the end of the 24-bit ID
        hex_idx = (m_col[2:0] >= 3'd2) ? (3'd7 - m_col[2:0]) : 3'd0;
        hex_nib = jedec_id[hex_idx*4 +: 4];
        if (m_col < 5'd16) begin
            m_glyph = label_rom[{m_row, m_col[3:0]}];
        end else if (m_row == 3'd4 && !settings_valid_q && !save_active) begin
            if (m_col[2:0] < 3'd2) m_glyph = 6'd10;                       // leading spaces
            else if (hex_nib < 4'd10) m_glyph = 6'(hex_nib);              // 0-9
            else m_glyph = 6'd12 + 6'(hex_nib) - 6'd10;                   // A-F
        end else begin
            m_glyph = value_rom[{m_vid_q, m_col[2:0]}];
        end
    end
    always_ff @(posedge clk_pixel) begin
        m_vid_q <= m_vid;
        menu_on <= ALIGNMENT_TUNING_MODE && menu_active &&
                   (cx5 >= menu_x) && (cx5 < menu_x + MENU_W) &&
                   (cy5 >= menu_y) && (cy5 < menu_y + MENU_H);
        menu_highlight <= (m_row == menu_sel);
        menu_pixel <= font_rom[{m_glyph, mdy[3:1]}][7 - mdx[3:1]];
    end


    // Turn the pixel intensity level into an actual 8-bit grey value, scaled by the current contrast setting.
    // Levels 0 and 3 are exactly the black/white the design has always produced; levels 1 and 2 are the
    // intermediate greys used by the 1024x768 horizontal anti-aliasing (they never occur in other modes).
    // Multiplying by 85/256 and 171/256 is a cheap stand-in for dividing by 3 (255*85/256 = 84.7, 255/3 = 85)
    // These are REGISTERED rather than combinational on purpose. They depend only on CONT_sync, which changes
    // at most about once per frame, so pipelining them costs nothing functionally -- but it takes a subtract
    // and two multiplies out of the path feeding the rgb register, leaving just a 4:1 mux. That matters if this
    // ever has to run at 148.5MHz (1080p60) rather than 65MHz, where the combinational version was the most
    // likely thing to fail timing.
    logic [7:0] white_level;
    logic [15:0] shade_third, shade_two_thirds;
    logic [7:0] white_q, shade_1of3, shade_2of3, pixel_shade;
    assign white_level = {(6'h3f - CONT_sync), 2'b00};
    assign shade_third = white_level * 16'd85;
    assign shade_two_thirds = white_level * 16'd171;
    always_ff @(posedge clk_pixel) begin
        white_q    <= white_level;
        shade_1of3 <= shade_third[15:8];
        shade_2of3 <= shade_two_thirds[15:8];
    end
    always_comb begin
        case (pixel_level)
            2'd0: pixel_shade = 8'h00;
            2'd1: pixel_shade = shade_1of3;
            2'd2: pixel_shade = shade_2of3;
            default: pixel_shade = white_q;
        endcase
    end

    // Now generate the RGB value
    always @(posedge clk_pixel) begin
        // The menu and tuning readout paint over everything else, so they stay visible wherever the image ends up
        if (menu_on) begin
            // Highlighted row is drawn inverted so the selection is obvious
            rgb <= menu_highlight ? (menu_pixel ? 24'h000000 : 24'hFFFF00)
                                  : (menu_pixel ? 24'hFFFF00 : 24'h000000);
        end else if (overlay_on) begin
            rgb <= overlay_pixel ? 24'hFFFF00 : 24'h000000; // Yellow on black, hard to miss
        // Check our output mode and the ROM revision; the active area of the frame depends on both
        end else if (in_1024_mode) begin
            if (CPU_ROM_SEL == 1'b0) begin
                // H ROM active area in 1024x768 mode: 960x728 starting at (x1024_h_active, y1024_h_active), normally (32,20)
                if (cx6 >= x1024_h_active && cx6 < x1024_h_end &&
                    cy6 >= y1024_h_active && cy6 < y1024_h_end) begin
                    rgb <= blank_video_sync ? 24'h000000 : {pixel_shade, pixel_shade, pixel_shade};
                end else begin
                    rgb <= 24'h202020;
                end
            end else begin
                // 3A ROM stopgap active area in 1024x768 mode: 608x432 starting at (x1024_a3_active, y1024_a3_active), normally (208,168)
                if (cx6 >= x1024_a3_active && cx6 < x1024_a3_end &&
                    cy6 >= y1024_a3_active && cy6 < y1024_a3_end) begin
                    rgb <= blank_video_sync ? 24'h000000 : {pixel_shade, pixel_shade, pixel_shade};
                end else begin
                    rgb <= 24'h202020;
                end
            end
        end else begin
            if (CPU_ROM_SEL == 1'b0) begin
                // H ROM active area: 1440x1092 starting at h_rom_x_active (240 when centred, 0 left, 480 right)
                if (cx6 >= h_rom_x_active && cx6 < h_rom_x_end && cy6 < 1092) begin
                    // Figure out if the pixel is black or white, taking CONT into account
                    // No need to worry about INVID since it's already handled on the CPU board
                    // If the Lisa is off (blank_video), force black output
                    rgb <= blank_video_sync ? 24'h000000 : {pixel_shade, pixel_shade, pixel_shade};
                end else begin
                    // If we're outside the active area, output a dark gray border
                    rgb <= 24'h202020;
                end
            end else begin
                // 3A ROM active area: 1216 wide starting at a3_rom_x_active (352 when centred, 0 left, 704 right),
                // vertically starting at a3_rom_y_active (108 normally), 862 rows tall -- 862 rather than 864
                // because the VSROM only ever draws about an eighth of the final row, so we skip it entirely
                if (cx6 >= a3_rom_x_active && cx6 < a3_rom_x_end &&
                    cy6 >= a3_rom_y_active && cy6 < a3_rom_y_end) begin
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
        .cy(cy),
        .frame_width(frame_width) // Needed so the pipeline-latency compensation can wrap at the end of a line
    );

endmodule
