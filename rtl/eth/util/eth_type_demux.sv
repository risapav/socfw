/**
 * @file eth_type_demux.sv
 * @brief EtherType-based 1→2 AXI-Stream demultiplexer.
 * @param ETH_TYPE_0  EtherType routed to output port 0 (default: ARP  0x0806).
 * @param ETH_TYPE_1  EtherType routed to output port 1 (default: IPv4 0x0800).
 * @details Consumes eth_rx_mac's early header notification (m_hdr_valid_o) to
 *   decide routing before the first payload byte arrives.  Frames whose
 *   EtherType does not match ETH_TYPE_0 or ETH_TYPE_1, and frames where
 *   mac_ok=0, are silently dropped (no output tvalid).
 *
 *   No backpressure on the input stream (eth_rx_mac does not support it).
 *   Downstream ports must be ready or use axis_fifo buffers; overflow is silent.
 *
 *   Timing:
 *     Cycle T  : s_hdr_valid_i fires (combinatorial from eth_rx_mac).
 *     Cycle T+1: route_q latched.
 *     Cycle T+6: first payload byte on s_axis_* → routed to selected port.
 *     (5-cycle margin from the FCS window filling in eth_rx_mac.)
 *
 *   Header forwarding (m0/m1_hdr_valid) is combinatorial from s_hdr_valid_i.
 */
`ifndef ETH_TYPE_DEMUX_SV
`define ETH_TYPE_DEMUX_SV

`default_nettype none

module eth_type_demux #(
  parameter logic [15:0] ETH_TYPE_0 = 16'h0806,  // ARP
  parameter logic [15:0] ETH_TYPE_1 = 16'h0800   // IPv4
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // ---- Early header from eth_rx_mac ----
  input  wire logic        s_hdr_valid_i,    // 1-cycle combinatorial pulse
  input  wire logic [47:0] s_hdr_dst_mac_i,
  input  wire logic [47:0] s_hdr_src_mac_i,
  input  wire logic [15:0] s_hdr_eth_type_i,
  input  wire logic        s_hdr_mac_ok_i,   // 0 = frame failed MAC filter → drop

  // ---- Input payload stream (no backpressure) ----
  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  input  wire logic        s_axis_tlast,
  input  wire logic        s_axis_tuser,  // 1 = error (bad FCS / runt)

  // ---- Output port 0 (e.g. ARP) ----
  output      logic [7:0]  m0_axis_tdata,
  output      logic        m0_axis_tvalid,
  output      logic        m0_axis_tlast,
  output      logic        m0_axis_tuser,
  output      logic        m0_hdr_valid,   // combinatorial, same cycle as s_hdr_valid_i
  output      logic [47:0] m0_hdr_dst_mac,
  output      logic [47:0] m0_hdr_src_mac,

  // ---- Output port 1 (e.g. IPv4) ----
  output      logic [7:0]  m1_axis_tdata,
  output      logic        m1_axis_tvalid,
  output      logic        m1_axis_tlast,
  output      logic        m1_axis_tuser,
  output      logic        m1_hdr_valid,
  output      logic [47:0] m1_hdr_dst_mac,
  output      logic [47:0] m1_hdr_src_mac,

  // ---- Diagnostics ----
  output      logic [15:0] stat_routed_0,  // frames routed to port 0
  output      logic [15:0] stat_routed_1,  // frames routed to port 1
  output      logic [15:0] stat_dropped    // frames dropped (unknown type or mac_ok=0)
);

  // -------------------------------------------------------------------------
  // Route register: latched at s_hdr_valid_i, cleared at tlast.
  // 2'b00 = drop, 2'b01 = port0, 2'b10 = port1
  // -------------------------------------------------------------------------
  logic [1:0]  route_q;
  logic [15:0] cnt_p0_q;
  logic [15:0] cnt_p1_q;
  logic [15:0] cnt_drop_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      route_q    <= 2'b00;
      cnt_p0_q   <= '0;
      cnt_p1_q   <= '0;
      cnt_drop_q <= '0;
    end else begin
      if (s_hdr_valid_i) begin
        if (s_hdr_mac_ok_i && (s_hdr_eth_type_i == ETH_TYPE_0)) begin
          route_q  <= 2'b01;
          cnt_p0_q <= cnt_p0_q + 16'd1;
        end else if (s_hdr_mac_ok_i && (s_hdr_eth_type_i == ETH_TYPE_1)) begin
          route_q  <= 2'b10;
          cnt_p1_q <= cnt_p1_q + 16'd1;
        end else begin
          route_q    <= 2'b00;
          cnt_drop_q <= cnt_drop_q + 16'd1;
        end
      end else if (s_axis_tvalid && s_axis_tlast) begin
        route_q <= 2'b00;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Payload routing (combinatorial)
  // -------------------------------------------------------------------------
  always_comb begin
    m0_axis_tdata  = s_axis_tdata;
    m0_axis_tvalid = s_axis_tvalid && (route_q == 2'b01);
    m0_axis_tlast  = s_axis_tlast;
    m0_axis_tuser  = s_axis_tuser;

    m1_axis_tdata  = s_axis_tdata;
    m1_axis_tvalid = s_axis_tvalid && (route_q == 2'b10);
    m1_axis_tlast  = s_axis_tlast;
    m1_axis_tuser  = s_axis_tuser;
  end

  // -------------------------------------------------------------------------
  // Header forwarding (combinatorial — same cycle as s_hdr_valid_i)
  // -------------------------------------------------------------------------
  always_comb begin
    m0_hdr_valid   = s_hdr_valid_i && s_hdr_mac_ok_i && (s_hdr_eth_type_i == ETH_TYPE_0);
    m0_hdr_dst_mac = s_hdr_dst_mac_i;
    m0_hdr_src_mac = s_hdr_src_mac_i;

    m1_hdr_valid   = s_hdr_valid_i && s_hdr_mac_ok_i && (s_hdr_eth_type_i == ETH_TYPE_1);
    m1_hdr_dst_mac = s_hdr_dst_mac_i;
    m1_hdr_src_mac = s_hdr_src_mac_i;
  end

  // -------------------------------------------------------------------------
  // Statistics outputs
  // -------------------------------------------------------------------------
  assign stat_routed_0 = cnt_p0_q;
  assign stat_routed_1 = cnt_p1_q;
  assign stat_dropped  = cnt_drop_q;

endmodule

`endif // ETH_TYPE_DEMUX_SV
