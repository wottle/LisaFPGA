// ---------------------------------------------------------------------------
// NOTE on this file's name: it keeps the old usb_hid_host_rom.v filename so the Vivado project's
// file list needs no editing, but it now holds the DUAL-PORT microcode ROM from the m1nl fork of
// usb_hid_host (https://github.com/m1nl/usb_hid_host, Apache-2.0). One ROM serves both USB ports'
// host cores, one read port each -- exactly as the fork's own usb_hid_host_dual reference design
// does. The old single-port, built-in ROM belonged to the original low-speed-only core.
// Fork commit at import: e492176. Unmodified apart from this comment block.
// ---------------------------------------------------------------------------
`default_nettype none
`timescale 1ns / 1ps
module usb_hid_host_dual_rom #(
  parameter MEMORY_FILE = "usb_hid_host_rom.mem"
) (
  input  wire       clk,

  input  wire [9:0] addra,
  output reg  [3:0] douta,
  input  wire       ena,

  input  wire [9:0] addrb,
  output reg  [3:0] doutb,
  input  wire       enb
);

reg [3:0] mem [0:1023];

initial
  $readmemh(MEMORY_FILE, mem);

always @(posedge clk)
  if (ena)
    douta <= mem[addra];

always @(posedge clk)
  if (enb)
    doutb <= mem[addrb];

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
