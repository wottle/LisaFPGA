// ---------------------------------------------------------------------------------------------
// usb_softcpu -- PicoRV32 plus its firmware memory and MMIO, the core of the soft-CPU USB host.
// See docs/usb_softcpu_host_design.md.
//
// Runs entirely on usbclk_core (60 MHz). Memory map:
//   0x0000_0000 - 0x0000_7FFF   32 KB RAM, code + data, initialised from FIRMWARE ($readmemh, 32-bit words)
//   0x1000_0000                 W  debug word (dbg_word output)
//   0x1000_0004                 R  free-running microsecond counter
//   0x1000_0008                 W  console byte (simulation only: printed with $write)
// ---------------------------------------------------------------------------------------------
module usb_softcpu #(
    parameter FIRMWARE = "usb_host_fw.mem",
    parameter CLK_MHZ  = 60
) (
    input  logic        clk,
    input  logic        reset,           // active high, synchronous to clk
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

    // ---- MMIO ----
    logic [31:0] mmio_q;
    always_ff @(posedge clk) begin
        if (reset) dbg_word <= '0;
        else if (mem_valid && !mem_ready && sel_mmio && |mem_wstrb) begin
            case (mem_addr[7:0])
                8'h00: dbg_word <= mem_wdata;
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
    logic sel_ram_q;
    always_ff @(posedge clk) begin
        if (reset) mem_ready <= 1'b0;
        else       mem_ready <= mem_valid && !mem_ready;
        sel_ram_q <= sel_ram;
    end
    assign mem_rdata = sel_ram_q ? ram_q : mmio_q;
endmodule
