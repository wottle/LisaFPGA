// ---------------------------------------------------------------------------------------------
// usb_softcpu -- PicoRV32 plus its firmware memory and MMIO, the core of the soft-CPU USB host.
// See docs/usb_softcpu_host_design.md.
//
// Runs entirely on usbclk_core (60 MHz). Memory map:
//   0x0000_0000 - 0x0000_7FFF   32 KB RAM, code + data, initialised from FIRMWARE ($readmemh, 32-bit words)
//   0x1000_0000                 W  debug word (dbg_word output)
//   0x1000_0004                 R  free-running microsecond counter
//   0x1000_0008                 W  console byte (simulation only: printed with $write)
//   0x1000_0010                 W  keyboard keys 0-3 (key_0 in [7:0])
//   0x1000_0014                 W  [7:0] key_4, [15:8] key_5, [23:16] modifiers; writing it emits the report
//   0x1000_0018                 W  mouse: [2:0] buttons, [15:8] dx, [23:16] dy; writing it emits the report
//   0x1000_1000 - 0x1000_10FF   usb_sie, port 0 (registers: see usb_sie.sv)
//   0x1000_2000 - 0x1000_20FF   usb_sie, port 1
// ---------------------------------------------------------------------------------------------
module usb_softcpu #(
    parameter FIRMWARE = "usb_host_fw.mem",
    parameter CLK_MHZ  = 60
) (
    input  logic        clk,
    input  logic        reset,           // active high, synchronous to clk
    // USB pins, one bit per port (IOBUFs are in top.sv)
    input  logic [1:0]  usb_dp_i,
    input  logic [1:0]  usb_dm_i,
    output logic [1:0]  usb_dp_o,
    output logic [1:0]  usb_dm_o,
    output logic [1:0]  usb_oe,
    // Reports for the Lisa side, as the old core produced them: data plus a one-cycle pulse
    output logic        kbd_report,
    output logic [55:0] kbd_data,        // {modifiers, key_5 .. key_0}
    output logic        mouse_report,
    output logic [18:0] mouse_data,      // {buttons[2:0], dx, dy}
    output logic [31:0] dbg_word
);
    localparam RAM_WORDS = 8192;

    logic        mem_valid, mem_instr, mem_ready;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic [3:0]  mem_wstrb;

    picorv32 #(
        .ENABLE_COUNTERS      (0),
        .ENABLE_COUNTERS64    (0),
        .ENABLE_REGS_DUALPORT (1),
        .BARREL_SHIFTER       (1),
        .COMPRESSED_ISA       (1),
        .ENABLE_MUL           (0),
        .ENABLE_DIV           (0),
        .ENABLE_IRQ           (0),
        .CATCH_MISALIGN       (1),
        .CATCH_ILLINSN        (1),
        .PROGADDR_RESET       (32'h0000_0000),
        .STACKADDR            (32'h0000_8000)
    ) cpu (
        .clk       (clk),
        .resetn    (!reset),
        .trap      (),
        .mem_valid (mem_valid),
        .mem_instr (mem_instr),
        .mem_ready (mem_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata),
        .mem_la_read (), .mem_la_write (), .mem_la_addr (), .mem_la_wdata (), .mem_la_wstrb (),
        .pcpi_valid (), .pcpi_insn (), .pcpi_rs1 (), .pcpi_rs2 (),
        .pcpi_wr (1'b0), .pcpi_rd (32'd0), .pcpi_wait (1'b0), .pcpi_ready (1'b0),
        .irq (32'd0), .eoi (),
        .trace_valid (), .trace_data ()
    );

    // ---- RAM: one read/write port, registered read, so every access completes in one wait state ----
    logic [31:0] ram [0:RAM_WORDS-1];
    initial begin
        for (int i = 0; i < RAM_WORDS; i++) ram[i] = 32'd0;
        $readmemh(FIRMWARE, ram);
    end

    wire        sel_ram  = mem_addr[31:28] == 4'h0;
    wire        sel_mmio = mem_addr[31:28] == 4'h1;
    wire [12:0] ram_idx  = mem_addr[14:2];
    logic [31:0] ram_q;

    always_ff @(posedge clk) begin
        if (mem_valid && !mem_ready && sel_ram) begin
            if (mem_wstrb[0]) ram[ram_idx][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wstrb[1]) ram[ram_idx][15: 8] <= mem_wdata[15: 8];
            if (mem_wstrb[2]) ram[ram_idx][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) ram[ram_idx][31:24] <= mem_wdata[31:24];
            ram_q <= ram[ram_idx];
        end
    end

    // ---- microsecond timer ----
    logic [$clog2(CLK_MHZ)-1:0] us_div;
    logic [31:0]                us_count;
    always_ff @(posedge clk) begin
        if (reset) begin
            us_div <= '0; us_count <= '0;
        end else if (us_div == CLK_MHZ - 1) begin
            us_div <= '0; us_count <= us_count + 1;
        end else
            us_div <= us_div + 1;
    end

    // ---- USB packet engines ----
    wire        sel_sie0 = sel_mmio && mem_addr[15:12] == 4'h1;
    wire        sel_sie1 = sel_mmio && mem_addr[15:12] == 4'h2;
    wire        bus_wr   = mem_valid && !mem_ready && |mem_wstrb;
    logic [31:0] sie_q [2];
    for (genvar p = 0; p < 2; p++) begin : sie
        usb_sie #(.CLK_MHZ(CLK_MHZ)) port (
            .clk (clk), .reset (reset),
            .bus_we (bus_wr && (p == 0 ? sel_sie0 : sel_sie1)), .bus_addr (mem_addr[7:0]),
            .bus_wdata (mem_wdata), .bus_wstrb (mem_wstrb), .bus_rdata (sie_q[p]),
            .dp_i (usb_dp_i[p]), .dm_i (usb_dm_i[p]), .dp_o (usb_dp_o[p]), .dm_o (usb_dm_o[p]), .oe (usb_oe[p]));
    end

    // ---- MMIO ----
    logic [31:0] mmio_q;
    always_ff @(posedge clk) begin
        kbd_report   <= 1'b0;
        mouse_report <= 1'b0;
        if (reset) begin
            dbg_word <= '0; kbd_data <= '0; mouse_data <= '0;
        end else if (bus_wr && sel_mmio && mem_addr[15:12] == 4'h0) begin
            case (mem_addr[7:0])
                8'h00: dbg_word <= mem_wdata;
                8'h10: kbd_data[31:0] <= mem_wdata;
                8'h14: begin kbd_data[55:32] <= mem_wdata[23:0]; kbd_report <= 1'b1; end
                8'h18: begin mouse_data <= {mem_wdata[2:0], mem_wdata[15:8], mem_wdata[23:16]}; mouse_report <= 1'b1; end
                // synthesis translate_off
                8'h08: $write("%c", mem_wdata[7:0]);
                // synthesis translate_on
                default: ;
            endcase
        end
        case (mem_addr[7:0])
            8'h00:   mmio_q <= dbg_word;
            8'h04:   mmio_q <= us_count;
            default: mmio_q <= 32'd0;
        endcase
    end

    // ---- handshake: ready one cycle after valid; rdata muxed from whichever unit was addressed ----
    logic       sel_ram_q;
    logic [1:0] sel_sie_q;
    always_ff @(posedge clk) begin
        if (reset) mem_ready <= 1'b0;
        else       mem_ready <= mem_valid && !mem_ready;
        sel_ram_q <= sel_ram;
        sel_sie_q <= {sel_sie1, sel_sie0};
    end
    assign mem_rdata = sel_ram_q ? ram_q : sel_sie_q[0] ? sie_q[0] : sel_sie_q[1] ? sie_q[1] : mmio_q;
endmodule
