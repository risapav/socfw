`ifndef DATA_ISLAND_FORMATTER_SV
`define DATA_ISLAND_FORMATTER_SV

`default_nettype none

import hdmi_pkg::*;

// HDMI data island formatter.
//
// Converts an HDMI packet (3 header bytes + up to 28 payload bytes) into
// 32 symbol periods of TERC4 nibbles for three TMDS channels, following
// the HDMI 1.3 data island bit layout.
//
// BCH ECC (x^8+x^4+x^3+x^2+1, init 0xFF) is computed combinatorially and
// folded into the bit streams before serialization.
//
// Channel assignment per symbol period p (0..31):
//   ch0 = { parity, header_bit[p], vsync, hsync }
//   ch1 = { sp1[2p+1], sp1[2p], sp0[2p+1], sp0[2p] }
//   ch2 = { sp3[2p+1], sp3[2p], sp2[2p+1], sp2[2p] }
//
// where parity = XOR of ch0[2], ch1[3:0], ch2[3:0] for the same period.
//
// Packet payload is split into 4 subpackets of 7 bytes each (SP0=PB0-6,
// SP1=PB7-13, SP2=PB14-20, SP3=PB21-27).  Unused bytes must be 0.
//
// Usage:
//   Assert start_i for one clock when hdmi_period_scheduler outputs
//   packet_start_o (at preamble entry).  Assert advance_i each clock
//   during the 32-cycle payload phase (packet_pop_o from the scheduler).
//   TERC4 nibble outputs are combinational and valid throughout.
module data_island_formatter (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic start_i,    // pulse: latch packet and reset counter
  input  logic advance_i,  // pulse: advance to next symbol (once per payload period)

  input  logic hsync_i,    // current HSYNC value (passed to ch0[0])
  input  logic vsync_i,    // current VSYNC value (passed to ch0[1])

  // Packet header bytes HB0-HB2
  input  logic [7:0] hb [0:2],
  // Packet payload bytes PB0-PB27 (unused bytes must be 0)
  input  logic [7:0] pb [0:27],

  // TERC4 nibble outputs (connect to three terc4_encoder instances)
  output logic [3:0] ch0_o,
  output logic [3:0] ch1_o,
  output logic [3:0] ch2_o,

  output logic active_o,   // 1 while symbol counter is running (0..31)
  output logic done_o      // pulse on the last symbol period (p=31)
);

  // ── BCH ECC (combinational, from current inputs) ──────────────────────────
  // Computed from the raw hb/pb inputs so the result is ready on start_i.
  wire [7:0] bch_hdr;
  wire [7:0] bch_sp [0:3];

  hdmi_bch_ecc #(.DATA_BITS(24)) u_bch_hdr (
    .data_i ({hb[2], hb[1], hb[0]}),
    .ecc_o  (bch_hdr)
  );

  genvar k;
  generate
    for (k = 0; k < 4; k++) begin : gen_bch_sp
      hdmi_bch_ecc #(.DATA_BITS(56)) u_bch_sp (
        .data_i ({pb[7*k+6], pb[7*k+5], pb[7*k+4],
                  pb[7*k+3], pb[7*k+2], pb[7*k+1], pb[7*k+0]}),
        .ecc_o  (bch_sp[k])
      );
    end
  endgenerate

  // ── Bit streams (header=32b, each subpacket=64b, LSB-first) ──────────────
  // header_bits[p]        = bit p of the serial header stream
  // sp_bits[k][2p+1:2p]  = 2 bits of subpacket k for symbol period p
  wire [31:0] hdr_bits = {bch_hdr, hb[2], hb[1], hb[0]};

  wire [63:0] sp_bits [0:3];
  generate
    for (k = 0; k < 4; k++) begin : gen_sp_bits
      assign sp_bits[k] = {bch_sp[k],
                           pb[7*k+6], pb[7*k+5], pb[7*k+4],
                           pb[7*k+3], pb[7*k+2], pb[7*k+1], pb[7*k+0]};
    end
  endgenerate

  // ── Shift registers (loaded on start_i, shifted right by 1/2 on advance_i)
  // Latch from combinational inputs so ECC is captured at the moment the
  // packet is committed (same cycle as start_i).
  logic [31:0] hdr_sr;
  logic [63:0] sp_sr [0:3];

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      hdr_sr   <= '0;
      sp_sr[0] <= '0;  sp_sr[1] <= '0;
      sp_sr[2] <= '0;  sp_sr[3] <= '0;
    end else if (start_i) begin
      hdr_sr   <= hdr_bits;
      sp_sr[0] <= sp_bits[0];  sp_sr[1] <= sp_bits[1];
      sp_sr[2] <= sp_bits[2];  sp_sr[3] <= sp_bits[3];
    end else if (advance_i) begin
      hdr_sr   <= {1'b0,  hdr_sr[31:1]};
      sp_sr[0] <= {2'b00, sp_sr[0][63:2]};
      sp_sr[1] <= {2'b00, sp_sr[1][63:2]};
      sp_sr[2] <= {2'b00, sp_sr[2][63:2]};
      sp_sr[3] <= {2'b00, sp_sr[3][63:2]};
    end
  end

  // ── Symbol counter ────────────────────────────────────────────────────────
  logic [4:0] sym_cnt;
  logic       active;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      active  <= 1'b0;
      sym_cnt <= '0;
    end else if (start_i) begin
      active  <= 1'b1;
      sym_cnt <= '0;
    end else if (active && advance_i) begin
      if (sym_cnt == 5'd31)
        active <= 1'b0;
      else
        sym_cnt <= sym_cnt + 1'b1;
    end
  end

  assign active_o = active;
  assign done_o   = active && (sym_cnt == 5'd31) && advance_i;

  // ── Nibble assembly (combinational from shift register LSBs) ──────────────
  // Output is always driven; the period scheduler ensures we're only in the
  // DATA_PAYLOAD phase when advance_i fires and the channel mux is selecting data.
  wire        hdr_bit  = hdr_sr[0];
  wire [3:0]  ch1_data = {sp_sr[1][1:0], sp_sr[0][1:0]};
  wire [3:0]  ch2_data = {sp_sr[3][1:0], sp_sr[2][1:0]};
  // Parity = XOR of all 9 bits in the same TERC4 symbol (HDMI spec Table 5-11):
  // HB_n, CTL1=VSYNC, CTL0=HSYNC, and the 8 subpacket bits on ch1/ch2.
  wire        parity   = hdr_bit ^ vsync_i ^ hsync_i
                         ^ ch1_data[3] ^ ch1_data[2] ^ ch1_data[1] ^ ch1_data[0]
                         ^ ch2_data[3] ^ ch2_data[2] ^ ch2_data[1] ^ ch2_data[0];

  assign ch1_o = ch1_data;
  assign ch2_o = ch2_data;
  assign ch0_o = {parity, hdr_bit, vsync_i, hsync_i};

endmodule

`endif // DATA_ISLAND_FORMATTER_SV
