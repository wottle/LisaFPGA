`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 12/15/2025 05:49:45 PM
// Design Name: 
// Module Name: usb_keyboard_interface
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


module usb_keyboard_interface(
    input logic usbclk,
    input logic usbrst,
    input logic [7:0] key_modifiers_in,
    input logic [47:0] keys_in, // All six keycodes of the boot report, {key_5 .. key_0}
    input logic report,
    input logic KBD_in,
    output logic KBD_out
    );

    // First, let's synchronize KBD_in to the usbclk domain to avoid metastability issues
    (* ASYNC_REG = "TRUE" *) logic KBD_in_int, KBD_in_sync;
    always_ff @(posedge usbclk) begin
        KBD_in_int <= KBD_in;
        KBD_in_sync <= KBD_in_int;
    end

    // The latched versions of the key modifiers and all six keycodes
    logic [7:0] key_modifiers;
    logic [7:0] keys [6];

    // Latch the key modifiers and keycodes on the rising edge of report
    // A report whose first keycode is 0x01 (ErrorRollOver) means the keyboard has more keys down than it can
    // report, and every keycode slot holds 0x01. It says nothing about which keys are actually held, so it is
    // ignored outright -- treating it as "no keys" would release everything the user is holding.
    always_ff @(posedge usbclk, negedge usbrst) begin
        // On reset, clear all the latched values
        if (!usbrst) begin
            key_modifiers <= 8'b0;
            for (int i = 0; i < 6; i++) keys[i] <= 8'b0;
        end else if (report && keys_in[7:0] != 8'h01) begin
            // If report is asserted, latch the key states
            key_modifiers <= key_modifiers_in;
            for (int i = 0; i < 6; i++) keys[i] <= keys_in[8*i +: 8];
        end
    end

    // We've got the key states latched now, so let's output them in the format the Lisa expects
    // This is the trickier part
    // The Lisa's keyboard protocol is as follows:
    // Both KBD_in and KBD_out are active-low signals
    // When KBD_in goes low for about 20us (which happens about every 1ms), the Lisa is requesting a key state update
    // The keyboard is expected to respond about 20us later if it has any key updates to send, if not it just leaves KBD_out high
    // If it does have something to report, it responds (20us after KBD_in goes low) by sending out a 16us long start bit (KBD_out low)
    // The start bit is followed by 8 data bits representing the keycode
    // All bits are transmitted inverted (0 = high, 1 = low) and they all take time 16us, except D7 which is 30us long
    // They're sent in the order D4, D5, D6, D7, D0, D1, D2, D3 (weirdly)
    // After the last bit, KBD_out goes high again
    // Another case: immediately after the system is reset, the keyboard is expected to send an ID code to the Lisa
    // First we send an 0x80 keyboard ID and then an 0xBF to identify it as a US keyboard layout
    // Same format as above, and we still wait for 20us sync pulses before sending each byte
    // The Lisa can also request a reset at any time by pulling KBD_in low for at least 5ms
    // We translate USB keyboard keycodes to Lisa keycodes using a lookup table

    typedef enum logic [6:0] {
        IDLE,
        WAIT_FOR_HIGH,
        WAIT_TO_SEND,
        SEND_START_BIT,
        SEND_D4,
        SEND_D5,
        SEND_D6,
        SEND_D7,
        SEND_D0,
        SEND_D1,
        SEND_D2,
        SEND_D3,
        FINISHED,
        KBD_RESET
    } kbd_state_t;

    kbd_state_t kbd_state;

    logic [25:0] kbd_in_pulse_counter; // Counts how long KBD_in has been low
    logic [9:0] kbd_bit_timer; // Timer for sending bits (16us or 30us)

    // The keycode in Lisa format to send
    logic [7:0] lisa_keycode;

    // And a lookup table to convert USB HID keycodes to Lisa keycodes
    // I'm not going to pretend that I wrote this myself; it sounded like a lot of work so I asked ChatGPT to generate it for me
    // USB HID usage (0x00–0x7F) -> Apple Lisa keycode
    logic [7:0] lisa_keycode_hid [0:127];
    initial begin
        integer i;
        for (i = 0; i < 128; i++)
            lisa_keycode_hid[i] = 8'h00;

        // ----------------------------------------------------------------
        // Letters (HID 0x04–0x1D)
        // ----------------------------------------------------------------
        lisa_keycode_hid[8'h04] = 8'h70; // A
        lisa_keycode_hid[8'h05] = 8'h6E; // B
        lisa_keycode_hid[8'h06] = 8'h6D; // C
        lisa_keycode_hid[8'h07] = 8'h7B; // D
        lisa_keycode_hid[8'h08] = 8'h60; // E
        lisa_keycode_hid[8'h09] = 8'h69; // F
        lisa_keycode_hid[8'h0A] = 8'h6A; // G
        lisa_keycode_hid[8'h0B] = 8'h6B; // H
        lisa_keycode_hid[8'h0C] = 8'h53; // I
        lisa_keycode_hid[8'h0D] = 8'h54; // J
        lisa_keycode_hid[8'h0E] = 8'h55; // K
        lisa_keycode_hid[8'h0F] = 8'h59; // L
        lisa_keycode_hid[8'h10] = 8'h58; // M
        lisa_keycode_hid[8'h11] = 8'h6F; // N
        lisa_keycode_hid[8'h12] = 8'h5F; // O
        lisa_keycode_hid[8'h13] = 8'h44; // P
        lisa_keycode_hid[8'h14] = 8'h75; // Q
        lisa_keycode_hid[8'h15] = 8'h65; // R
        lisa_keycode_hid[8'h16] = 8'h76; // S
        lisa_keycode_hid[8'h17] = 8'h66; // T
        lisa_keycode_hid[8'h18] = 8'h52; // U
        lisa_keycode_hid[8'h19] = 8'h6C; // V
        lisa_keycode_hid[8'h1A] = 8'h77; // W
        lisa_keycode_hid[8'h1B] = 8'h7A; // X
        lisa_keycode_hid[8'h1C] = 8'h67; // Y
        lisa_keycode_hid[8'h1D] = 8'h79; // Z

        // ----------------------------------------------------------------
        // Number row
        // ----------------------------------------------------------------
        lisa_keycode_hid[8'h1E] = 8'h74; // 1 !
        lisa_keycode_hid[8'h1F] = 8'h71; // 2 @
        lisa_keycode_hid[8'h20] = 8'h72; // 3 #
        lisa_keycode_hid[8'h21] = 8'h73; // 4 $
        lisa_keycode_hid[8'h22] = 8'h64; // 5 %
        lisa_keycode_hid[8'h23] = 8'h61; // 6 ^
        lisa_keycode_hid[8'h24] = 8'h62; // 7 &
        lisa_keycode_hid[8'h25] = 8'h63; // 8 *
        lisa_keycode_hid[8'h26] = 8'h50; // 9 (
        lisa_keycode_hid[8'h27] = 8'h51; // 0 )

        // ----------------------------------------------------------------
        // Punctuation / symbols
        // ----------------------------------------------------------------
        lisa_keycode_hid[8'h28] = 8'h48; // Enter (main Return)
        lisa_keycode_hid[8'h29] = 8'h68; // Esc -> ` ~ (Esc in LisaTerminal)
        lisa_keycode_hid[8'h2A] = 8'h45; // Backspace
        lisa_keycode_hid[8'h2B] = 8'h78; // Tab
        lisa_keycode_hid[8'h2C] = 8'h5C; // Space
        lisa_keycode_hid[8'h39] = 8'h7D; // Caps Lock

        lisa_keycode_hid[8'h2D] = 8'h40; // - _
        lisa_keycode_hid[8'h2E] = 8'h41; // = +
        lisa_keycode_hid[8'h2F] = 8'h56; // [ {
        lisa_keycode_hid[8'h30] = 8'h57; // ] }
        lisa_keycode_hid[8'h31] = 8'h42; // \ | (ANSI backslash)
        lisa_keycode_hid[8'h32] = 8'h42; // \ | (ISO backslash)
        lisa_keycode_hid[8'h33] = 8'h5A; // ; :
        lisa_keycode_hid[8'h34] = 8'h5B; // ' "
        lisa_keycode_hid[8'h35] = 8'h68; // ` ~
        lisa_keycode_hid[8'h36] = 8'h5D; // , <
        lisa_keycode_hid[8'h37] = 8'h5E; // . >
        lisa_keycode_hid[8'h38] = 8'h4C; // / ?
        lisa_keycode_hid[8'h64] = 8'h43; // < > (ISO 102nd key)
        lisa_keycode_hid[8'h65] = 8'h46; // Menu -> third Enter key

        // ------------------------------------------------------------
        // Keypad operators
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h54] = 8'h27; // KP /
        lisa_keycode_hid[8'h55] = 8'h23; // KP *
        lisa_keycode_hid[8'h56] = 8'h21; // KP -
        lisa_keycode_hid[8'h57] = 8'h22; // KP +
        lisa_keycode_hid[8'h63] = 8'h2C; // KP .
        lisa_keycode_hid[8'h67] = 8'h2B; // KP = (Mac USB kbd) -> KP , (Lisa kbd)

        // ------------------------------------------------------------
        // Keypad digits
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h59] = 8'h4D; // KP 1
        lisa_keycode_hid[8'h5A] = 8'h2D; // KP 2
        lisa_keycode_hid[8'h5B] = 8'h2E; // KP 3
        lisa_keycode_hid[8'h5C] = 8'h28; // KP 4
        lisa_keycode_hid[8'h5D] = 8'h29; // KP 5
        lisa_keycode_hid[8'h5E] = 8'h2A; // KP 6
        lisa_keycode_hid[8'h5F] = 8'h24; // KP 7
        lisa_keycode_hid[8'h60] = 8'h25; // KP 8
        lisa_keycode_hid[8'h61] = 8'h26; // KP 9
        lisa_keycode_hid[8'h62] = 8'h49; // KP 0

        // ------------------------------------------------------------
        // Keypad Enter
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h58] = 8'h2F; // KP Enter -> Lisa Numpad Enter
        lisa_keycode_hid[8'h53] = 8'h20; // KP NumLock/Clear -> Lisa Clear

        // ------------------------------------------------------------
        // Arrow keys mapped to keypad
        // Apple Lisa and very early Macintosh used KP / , + * as arrow keys.
        // Arrow legends appear on these keys on Lisa and pre-ADB Mac keyboards.
        // KP 2 4 6 8 as arrow keys was exclusively an IBM PC thing.
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h52] = 8'h27; // Up    -> KP / (Up in LisaTerminal)
        lisa_keycode_hid[8'h50] = 8'h22; // Left  -> KP + (Left in LisaTerminal)
        lisa_keycode_hid[8'h4F] = 8'h23; // Right -> KP * (Right in LisaTerminal)
        lisa_keycode_hid[8'h51] = 8'h2B; // Down  -> KP , (Down in LisaTerminal)

        // ------------------------------------------------------------
        // Nav cluster mapping from LisaKeys keyboard adapter
        // (https://github.com/RebeccaRGB/lisakeys)
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h49] = 8'h46; // Ins  -> third Enter key
        lisa_keycode_hid[8'h4A] = 8'h68; // Home -> ` ~
        lisa_keycode_hid[8'h4B] = 8'h42; // PgUp -> \ |
        lisa_keycode_hid[8'h4C] = 8'h45; // Del  -> Backspace
        lisa_keycode_hid[8'h4D] = 8'h43; // End  -> < >
        lisa_keycode_hid[8'h4E] = 8'h2B; // PgDn -> KP ,
    end


    // A state counter that's set when we start a reset sequence
    // In which case we send 0x80 first, then 0xBF
    logic [1:0] kbd_reset_sequence;

    // Another difference we need to account for:
    // The USB keyboard sends a keycode as long as the key is held down and then sends 0 when it's released
    // The Lisa keyboard protocol expects key press and key release to be separate events
    // So we need to detect which keys have appeared in or vanished from the report and send a press or release for each
    // A USB boot report carries up to six keycodes at once, in no particular order, and a key that stays held
    // can move between slots from one report to the next. So we compare SETS, not slots: prev_keys is the set
    // of keys the Lisa has been told are down, and we send events one at a time until it matches the report.
    // (Tracking only the first slot breaks on rollover -- pressing the next key before releasing the last
    // produced no release at all, and the second key of an overlap was simply never sent. Full-speed
    // keyboards poll every 1ms instead of 10ms, so they see far more overlaps and lost far more keys.)
    logic [7:0] prev_keys [6];
    logic [7:0] prev_key_modifiers;

    // The key currently being sent, and which prev_keys slot it is leaving or entering
    logic [7:0] event_key;
    logic [2:0] event_slot;

    // Diff the report against prev_keys. Codes below 0x04 are not keys (0x00 empty, 0x01-0x03 error codes)
    logic [5:0] key_released;   // prev_keys[i] is down as far as the Lisa knows, but no longer in the report
    logic [5:0] key_pressed;    // keys[i] is in the report, but the Lisa hasn't been told about it yet
    logic [5:0] slot_free;      // prev_keys[i] is empty and can take a newly pressed key
    always_comb begin
        for (int i = 0; i < 6; i++) begin
            key_released[i] = (prev_keys[i] >= 8'h04);
            key_pressed[i]  = (keys[i] >= 8'h04);
            slot_free[i]    = (prev_keys[i] == 8'h00);
            for (int j = 0; j < 6; j++) begin
                if (prev_keys[i] == keys[j]) key_released[i] = 1'b0;
                if (keys[i] == prev_keys[j]) key_pressed[i]  = 1'b0;
            end
        end
    end

    // Lowest-numbered slot in each of those masks
    logic [2:0] release_idx, press_idx, free_idx;
    always_comb begin
        release_idx = 3'd0;
        press_idx = 3'd0;
        free_idx = 3'd0;
        for (int i = 5; i >= 0; i--) begin
            if (key_released[i]) release_idx = 3'(i);
            if (key_pressed[i])  press_idx   = 3'(i);
            if (slot_free[i])    free_idx    = 3'(i);
        end
    end

    // An enum for the states of each modifier key
    typedef enum logic [1:0] {
        DOWN = 0,
        UP = 1
    } modifier_state_t;

    // Now create some signals for storing the previous states of said keys: shift (left/right are same), left/right option, and apple key
    modifier_state_t prev_shift_state, prev_left_option_state, prev_right_option_state, prev_apple_state;
    // This signal keeps track of the caps lock state
    logic caps_lock_state;

    // A flag to indicate the first run of any of the modifier key handlers
    logic first_run;

    // Bit masks for the modifier keys
    localparam logic [7:0] SHIFT_MASK = 8'h22; // Left and right shift
    localparam logic [7:0] LEFT_OPTION_MASK = 8'h01; // Left option (mapped to the left control key)
    localparam logic [7:0] RIGHT_OPTION_MASK = 8'h10; // Right option (mapped to the right control key)
    localparam logic [7:0] APPLE_MASK = 8'h44; // Left Apple (mapped to left and right alt keys)

    typedef enum logic [6:0] {
        WAIT,
        HANDLE_SHIFT,
        HANDLE_LEFT_OPTION,
        HANDLE_RIGHT_OPTION,
        HANDLE_APPLE,
        HANDLE_REGULAR_SCAN,
        HANDLE_REGULAR_DOWN,
        HANDLE_REGULAR_UP
    } decoder_state_t;

    decoder_state_t decoder_state;

    // Boolean flag to say whether or not keycode was actually sent
    logic sent_keycode;

    always_ff @(posedge usbclk, negedge usbrst) begin
        if (!usbrst) begin
            for (int i = 0; i < 6; i++) prev_keys[i] <= 8'd0;
            prev_key_modifiers <= 8'd0;
            event_key <= 8'd0;
            event_slot <= 3'd0;
            caps_lock_state <= 1'b0;
            lisa_keycode <= 8'd0;
            kbd_reset_sequence <= 2'd0;
            prev_shift_state <= UP;
            prev_left_option_state <= UP;
            prev_right_option_state <= UP;
            prev_apple_state <= UP;
            decoder_state <= WAIT;
            sent_keycode <= 1'b1;
            first_run <= 1'b1;
        end else begin
            if (kbd_state == KBD_RESET || kbd_reset_sequence != 2'd0) begin
                // If we end up here, we need to reset the keyboard interface
                if (kbd_reset_sequence == 2'd0) begin
                    // If we're in step 0, start the reset sequence by sending 0x80 to the Lisa
                    lisa_keycode <= 8'h80;
                    kbd_reset_sequence <= 2'd1; // And move to step 1
                end else if (kbd_reset_sequence == 2'd1 && kbd_state == FINISHED) begin
                    // Next, send 0xBF, being sure to wait for the state machine to finish sending the first byte
                    lisa_keycode <= 8'hBF;
                    kbd_reset_sequence <= 2'd2; // And move to step 2
                end else if (kbd_reset_sequence == 2'd2 && kbd_state == FINISHED) begin
                    // After sending both bytes, clear lisa_keycode to indicate no key to send
                    lisa_keycode <= 8'd0;
                    // And clear the reset sequence counter
                    kbd_reset_sequence <= 2'd0;
                end
                // Also, clear prev_keys and prev_key_modifiers to avoid spurious key events after reset
                for (int i = 0; i < 6; i++) prev_keys[i] <= 8'd0;
                prev_key_modifiers <= 8'd0;
            end else begin
                // Otherwise, handle key events as normal, which we do with a state machine
                case (decoder_state)
                    WAIT: begin
                        // In the idle state, we just wait until we see a change in the held keys or the modifiers
                        if (key_released != 6'd0 || key_pressed != 6'd0 || key_modifiers != prev_key_modifiers) begin
                            // And then we move to HANDLE_SHIFT to start processing modifier keys
                            first_run <= 1'b1; // Set the first run flag
                            sent_keycode <= 1'b1; // Set the flag so we don't automatically fall through the shift handler
                            prev_key_modifiers <= key_modifiers; // Update prev_key_modifiers to the new modifier value
                            decoder_state <= HANDLE_SHIFT;
                        end
                    end
                    HANDLE_SHIFT: begin
                        first_run <= 1'b0; // Clear the first run flag
                        // Check the shift key state
                        if (((key_modifiers & SHIFT_MASK) != 8'd0) && (prev_shift_state == UP)) begin
                            // If we end up here, then the shift key has just been pressed
                            lisa_keycode <= 8'h7E | 8'b10000000; // So send out the Lisa Shift keycode with bit 7 set
                            prev_shift_state <= DOWN;
                            sent_keycode <= 1'b1; // Set the flag to say we sent something
                        end else if (((key_modifiers & SHIFT_MASK) == 8'd0) && (prev_shift_state == DOWN)) begin
                            // Here's where we go if the shift key has just been released
                            lisa_keycode <= 8'h7E & 8'b01111111; // Send the keycode again with bit 7 cleared
                            prev_shift_state <= UP;
                            sent_keycode <= 1'b1; // Set the flag to say we sent something
                        end else if (first_run) begin
                            sent_keycode <= 1'b0; // No change in shift key state, so nothing sent
                        end
                        if (kbd_state == FINISHED || !sent_keycode) begin
                            // Wait until after we've sent the keycode before moving to the next state
                            // Or just go straight to the next state if we didn't send anything
                            first_run <= 1'b1; // Set the first run flag again
                            sent_keycode <= 1'b1; // Set the flag so we don't automatically fall through next time
                            lisa_keycode <= 8'd0; // Clear lisa_keycode to indicate no key to send
                            decoder_state <= HANDLE_LEFT_OPTION;
                        end
                    end
                    HANDLE_LEFT_OPTION: begin
                        first_run <= 1'b0; // Clear the first run flag
                        // Check the left option key state
                        if (((key_modifiers & LEFT_OPTION_MASK) != 8'd0) && (prev_left_option_state == UP)) begin
                            // Left option key pressed
                            lisa_keycode <= 8'h7C | 8'b10000000; // Lisa Left Option keycode with bit 7 set
                            prev_left_option_state <= DOWN;
                            sent_keycode <= 1'b1; // Set the flag to say we sent something
                        end else if (((key_modifiers & LEFT_OPTION_MASK) == 8'd0) && (prev_left_option_state == DOWN)) begin
                            // Left option key released
                            lisa_keycode <= 8'h7C & 8'b01111111; // Lisa Left Option keycode with bit 7 cleared
                            prev_left_option_state <= UP;
                            sent_keycode <= 1'b1; // Set the flag to say we sent something
                        end else if (first_run) begin
                            sent_keycode <= 1'b0; // No change in left option key state, so nothing sent
                        end
                        if (kbd_state == FINISHED || !sent_keycode) begin
                            sent_keycode <= 1'b1; // Set the flag so we don't automatically fall through next time
                            first_run <= 1'b1; // Set the first run flag again
                            lisa_keycode <= 8'd0; // Clear lisa_keycode to indicate no key to send
                            decoder_state <= HANDLE_RIGHT_OPTION;
                        end
                    end
                    HANDLE_RIGHT_OPTION: begin
                        first_run <= 1'b0; // Clear the first run flag
                        // Check the right option key state
                        if (((key_modifiers & RIGHT_OPTION_MASK) != 8'd0) && (prev_right_option_state == UP)) begin
                            // Right option key pressed
                            lisa_keycode <= 8'h4E | 8'b10000000; // Lisa Right Option keycode with bit 7 set
                            prev_right_option_state <= DOWN;
                            sent_keycode <= 1'b1; // Set the flag to say we sent something
                        end else if (((key_modifiers & RIGHT_OPTION_MASK) == 8'd0) && (prev_right_option_state == DOWN)) begin
                            // Right option key released
                            lisa_keycode <= 8'h4E & 8'b01111111; // Lisa Right Option keycode with bit 7 cleared
                            prev_right_option_state <= UP;
                            sent_keycode <= 1'b1; // Set the flag to say we sent something
                        end else if (first_run) begin
                            sent_keycode <= 1'b0; // No change in right option key state, so nothing sent
                        end
                        if (kbd_state == FINISHED || !sent_keycode) begin
                            sent_keycode <= 1'b1; // Set the flag so we don't automatically fall through next time
                            first_run <= 1'b1; // Set the first run flag again
                            lisa_keycode <= 8'd0; // Clear lisa_keycode to indicate no key to send
                            decoder_state <= HANDLE_APPLE;
                        end
                    end
                    HANDLE_APPLE: begin
                        first_run <= 1'b0; // Clear the first run flag
                        // Check the Apple key state
                        if (((key_modifiers & APPLE_MASK) != 8'd0) && (prev_apple_state == UP)) begin
                            // Apple key pressed
                            lisa_keycode <= 8'h7F | 8'b10000000; // Lisa Apple keycode with bit 7 set
                            prev_apple_state <= DOWN;
                            sent_keycode <= 1'b1; // Set the flag to say we sent something
                        end else if (((key_modifiers & APPLE_MASK) == 8'd0) && (prev_apple_state == DOWN)) begin
                            // Apple key released
                            lisa_keycode <= 8'h7F & 8'b01111111; // Lisa Apple keycode with bit 7 cleared
                            prev_apple_state <= UP;
                            sent_keycode <= 1'b1; // Set the flag to say we sent something
                        end else if (first_run) begin
                            sent_keycode <= 1'b0; // No change in Apple key state, so nothing sent
                        end
                        if (kbd_state == FINISHED || !sent_keycode) begin
                            first_run <= 1'b1; // Set the first run flag again
                            sent_keycode <= 1'b1; // Set the flag so we don't automatically fall through next time
                            lisa_keycode <= 8'd0; // Clear lisa_keycode to indicate no key to send
                            // We're finally done with modifier keys, so move to handling regular keys
                            decoder_state <= HANDLE_REGULAR_SCAN;
                        end
                    end
                    HANDLE_REGULAR_SCAN: begin
                        // Pick the next regular key event, one at a time, until prev_keys matches the report
                        // Releases go first: that frees prev_keys slots for the presses, and it is the order a
                        // real typist's rollover happens in anyway (the earlier key goes up as the next goes down)
                        // The diff is re-evaluated against the live report on every pass, so a report that lands
                        // mid-sequence is simply folded in rather than lost
                        first_run <= 1'b1;
                        sent_keycode <= 1'b1;
                        if (key_released != 6'd0) begin
                            event_key <= prev_keys[release_idx];
                            event_slot <= release_idx;
                            decoder_state <= HANDLE_REGULAR_UP;
                        end else if (key_pressed != 6'd0) begin
                            // A free slot always exists here: once every release has been sent, prev_keys holds
                            // only keys that are still in the report, and the report has a key prev_keys lacks
                            event_key <= keys[press_idx];
                            event_slot <= free_idx;
                            decoder_state <= HANDLE_REGULAR_DOWN;
                        end else begin
                            // Nothing left to send (or only the modifiers changed), so go back and wait for the next event
                            decoder_state <= WAIT;
                        end
                    end
                    HANDLE_REGULAR_DOWN: begin
                        first_run <= 1'b0; // Clear the first run flag
                        // Handle regular key down event
                        if (event_key == 8'h39) begin
                            // Caps Lock key pressed, toggle the caps_lock_state
                            if (first_run) begin
                                // Make sure we only toggle it once per key press though
                                caps_lock_state <= ~caps_lock_state;
                            end
                            // Bit 7 must follow the NEW caps lock state (down = caps on). On the first cycle the toggle
                            // above hasn't landed yet, so the new state is ~caps_lock_state; on every cycle after, it's
                            // caps_lock_state itself. (Using ~caps_lock_state throughout sent the opposite state.)
                            lisa_keycode <= lisa_keycode_hid[event_key] | {(first_run ? ~caps_lock_state : caps_lock_state), 7'b0000000};
                        end else begin
                            // For other keys, just set lisa_keycode normally
                            lisa_keycode <= lisa_keycode_hid[event_key] | 8'b10000000; // Set bit 7 to indicate key press
                            if (lisa_keycode_hid[event_key] != 8'd0) begin
                                // Only say that we sent something if lisa_keycode is valid; some keys may not have a mapping
                                sent_keycode <= 1'b1; // Set the flag to say we sent something
                            end else begin
                                sent_keycode <= 1'b0; // No valid keycode to send
                            end
                        end
                        // Once the keycode has been sent, record the key as down and look for the next event
                        // (unmapped keys are recorded too, so they don't get "pressed" again on every report)
                        if (kbd_state == FINISHED || !sent_keycode) begin
                            first_run <= 1'b1; // Set the first run flag again
                            sent_keycode <= 1'b1; // Set the flag so we don't automatically fall through next time
                            prev_keys[event_slot] <= event_key;
                            lisa_keycode <= 8'd0; // Clear lisa_keycode to indicate no key to send
                            decoder_state <= HANDLE_REGULAR_SCAN;
                        end
                    end
                    HANDLE_REGULAR_UP: begin
                        // Handle a regular key up event for event_key
                        if (event_key != 8'h39) begin
                            // Only send release codes for non-Caps Lock keys
                            // For Caps Lock, we only care about the press event to toggle the state
                            lisa_keycode <= lisa_keycode_hid[event_key] & 8'b01111111; // Clear bit 7 to indicate key release (should already be clear)
                            if (lisa_keycode_hid[event_key] != 8'd0) begin
                                // Only say that we sent something if lisa_keycode is valid; some keys may not have a mapping
                                sent_keycode <= 1'b1; // Set the flag to say we sent something
                            end else begin
                                sent_keycode <= 1'b0; // No valid keycode to send
                            end
                        end else begin
                            sent_keycode <= 1'b0; // No valid keycode to send for Caps Lock release
                        end
                        // Once the release has been sent, clear the key's slot and look for the next event
                        if (kbd_state == FINISHED || !sent_keycode) begin
                            sent_keycode <= 1'b1; // Set the flag so we don't automatically fall through next time
                            prev_keys[event_slot] <= 8'd0;
                            lisa_keycode <= 8'd0; // Clear lisa_keycode to indicate no key to send
                            decoder_state <= HANDLE_REGULAR_SCAN;
                        end
                    end
                    default: begin
                        decoder_state <= WAIT;
                    end
                endcase
            end
        end
    end

    always_ff @(posedge usbclk, negedge usbrst) begin
        if (!usbrst) begin
            kbd_state <= KBD_RESET;
            KBD_out <= 1'b1; // Release KBD_out
            kbd_in_pulse_counter <= 26'd0;
            kbd_bit_timer <= 10'd0;
        end else begin
            case (kbd_state)
                IDLE: begin
                    KBD_out <= 1'b1; // Release KBD_out
                    // In the idle state, wait for KBD_in to go low
                    if (!KBD_in_sync) begin
                        // When it does, go to the WAIT_FOR_HIGH state
                        kbd_state <= WAIT_FOR_HIGH;
                        // And start counting how long KBD_in is low
                        kbd_in_pulse_counter <= 26'd1;
                    end
                end
                WAIT_FOR_HIGH: begin
                    // We're waiting for KBD_in to go high again to see what the Lisa wants
                    kbd_in_pulse_counter <= kbd_in_pulse_counter + 1;
                    if (KBD_in_sync) begin
                        // KBD_in went high again, check how long it was low for
                        if (kbd_in_pulse_counter >= 26'd55000) begin
                            // KBD_in was low for about 5ms or more, Lisa is requesting a reset
                            kbd_state <= KBD_RESET;
                        end else if (kbd_in_pulse_counter >= 26'd200) begin
                            // KBD_in was low for at about 20us, Lisa wants a key update
                            if (lisa_keycode != 8'd0) begin
                                // We've got a key to report, so prepare to send it
                                kbd_state <= WAIT_TO_SEND;
                            end else begin
                                // No key to report, go back to idle
                                kbd_state <= IDLE;
                            end
                        end else begin
                            // KBD_in was low for an invalid time, go back to idle
                            kbd_state <= IDLE;
                        end
                        kbd_in_pulse_counter <= 26'd0;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                WAIT_TO_SEND: begin
                    // Wait for 40us (480 clock cycles at 12MHz) before sending
                    // Nope, just kidding, after some testing we actually want to wait for 21.545-ish us or 258 clocks
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd258) begin
                        // Time to send the start bit
                        kbd_state <= SEND_START_BIT;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_START_BIT: begin
                    // Send the start bit (KBD_out low for 16us)
                    // We'll actually do 15.7us to be slightly closer to what I've observed with an actual Apple keyboard
                    KBD_out <= 1'b0;
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        // Move to sending D4 once we've waited 16us
                        kbd_state <= SEND_D4;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D4: begin
                    // Send the inversion of bit D4 of the Lisa keycode
                    KBD_out <= ~lisa_keycode[4];
                    // And then wait 15.7us before going onto the next bit
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D5;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                // Repeat for D5 and D6
                SEND_D5: begin
                    KBD_out <= ~lisa_keycode[5];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D6;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D6: begin
                    KBD_out <= ~lisa_keycode[6];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D7;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D7: begin
                    // D7 is a little different; it's held low for 30us instead of 15.7us
                    // And we're actually going to do 30.745us to match the real keyboard again
                    KBD_out <= ~lisa_keycode[7];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd369) begin
                        kbd_state <= SEND_D0;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                // And then we're back to 15.7us for D0-D3
                SEND_D0: begin
                    KBD_out <= ~lisa_keycode[0];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D1;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D1: begin
                    KBD_out <= ~lisa_keycode[1];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D2;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D2: begin
                    KBD_out <= ~lisa_keycode[2];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D3;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D3: begin
                    KBD_out <= ~lisa_keycode[3];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        // Finished sending all bits, so go to FINISHED state
                        kbd_state <= FINISHED;
                        KBD_out <= 1'b1; // Release KBD_out
                    end
                end
                FINISHED: begin
                    // The only point of this state is to tell the decoder state machine when we're done sending a keycode
                    // So we just go back to idle here
                    kbd_state <= IDLE;
                end
                KBD_RESET: begin
                    // Just go back to idle after we enter this state
                    // We only need to be in it for 1 cycle so that the always_ff that loads the keycode can see it and act accordingly
                    kbd_state <= IDLE;
                end
                default: begin
                    kbd_state <= IDLE;
                end
            endcase
        end
    end

endmodule