/**
 * @file        ethernet_alinx_top.sv
 * @brief       Alternatívny top-level modul pre testovanie Ethernet/UDP.
 * @details     Modul zabezpečuje inicializáciu statických dát (textový reťazec
 * "HELLO ALINX AX516") do pamäte a následne ich odosielanie cez UDP protokol.
 * Pôvodne určený pre vývojové dosky rady ALINX. Obsahuje fyzické prepojenia
 * na PHY čip (MDC/MDIO) a GMII dátové linky.
 */

`ifndef ETHERNET_ALINX_TOP_SV
`define ETHERNET_ALINX_TOP_SV

`default_nettype none

module ethernet_alinx_top (
  input  wire        rst_ni,
  input  wire        clk_i,        // Hlavné hodiny (fpga_gclk)

  // Fyzické PHY ovládanie
  output logic       eth_rst_no,
  output logic       eth_mdc_o,
  inout  wire        eth_mdio_io,

  // GMII/MII rozhranie
  input  wire        eth_rx_clk_i,
  input  wire        eth_rx_dv_i,
  input  wire        eth_rx_er_i,
  input  wire  [7:0] eth_rx_data_i,

  input  wire        eth_tx_clk_i,
  output logic       eth_gtx_clk_o,
  output logic       eth_tx_en_o,
  output logic       eth_tx_er_o,
  output logic [7:0] eth_tx_data_o
);

  // Generovanie TX hodín z RX pre synchrónny loopback
  assign eth_gtx_clk_o = eth_rx_clk_i;
  assign eth_rst_no    = 1'b1;

  // Interné prepojovacie signály pre RAM a UDP
  logic [31:0] ram_wr_data_w;
  logic [31:0] ram_rd_data_w;
  logic [8:0]  ram_wr_addr_w;
  logic [8:0]  ram_rd_addr_w;

  logic [3:0]  tx_state_w;
  logic [3:0]  rx_state_w;
  logic [15:0] rx_total_length_w;
  logic [15:0] tx_total_length_w;
  logic [15:0] rx_data_length_w;
  logic [15:0] tx_data_length_w;

  logic        data_receive_w;
  logic        ram_wr_finish_q;

  logic [31:0] udp_data_q [4:0];
  logic        ram_wren_q;
  logic [8:0]  ram_addr_q;
  logic [31:0] ram_data_q;
  logic [4:0]  init_idx_q;

  logic        data_o_valid_w;
  logic        wea_w;
  logic [8:0]  addra_w;
  logic [31:0] dina_w;

  // Logika dĺžky paketu: Ak sme niečo prijali, vraciame echo s rovnakou dĺžkou.
  // Ak nie, odosielame statický string s dĺžkou 28 B (Data) / 48 B (Celý IP paket).
  assign tx_data_length_w  = data_receive_w ? rx_data_length_w  : 16'd28;
  assign tx_total_length_w = data_receive_w ? rx_total_length_w : 16'd48;

  // Multiplexor pre zápis do RAM (1. inicializácia textom, 2. príjem dát zo siete)
  assign wea_w   = ram_wr_finish_q ? data_o_valid_w : ram_wren_q;
  assign addra_w = ram_wr_finish_q ? ram_wr_addr_w  : ram_addr_q;
  assign dina_w  = ram_wr_finish_q ? ram_wr_data_w  : ram_data_q;

  // ==========================================================================
  // Inštanciácia UDP jadra (naše refaktorované udp.sv)
  // ==========================================================================
  udp u_udp (
    .rst_ni             (rst_ni),
    .clk_i             (eth_rx_clk_i),
    .rx_data_i         (eth_rx_data_i),
    .rx_dv_i           (eth_rx_dv_i),
    .tx_en_o           (eth_tx_en_o),
    .tx_data_o         (eth_tx_data_o),
    .tx_er_o           (eth_tx_er_o),

    .data_o_valid_o    (data_o_valid_w),
    .ram_wr_data_o     (ram_wr_data_w),
    .rx_total_length_o (rx_total_length_w),
    .rx_state_o        (rx_state_w),
    .rx_data_length_o  (rx_data_length_w),
    .ram_wr_addr_o     (ram_wr_addr_w),

    .ram_rd_data_i     (ram_rd_data_w),
    .tx_state_o        (tx_state_w),
    .tx_data_length_i  (tx_data_length_w),
    .tx_total_length_i (tx_total_length_w),
    .ram_rd_addr_o     (ram_rd_addr_w),
    .data_receive_o    (data_receive_w)
  );

  // ==========================================================================
  // Inštanciácia Dual-Port RAM (DPRAM z Quartus IP alebo inferred RTL)
  // ==========================================================================
  ram u_ram (
    .clka      (eth_rx_clk_i),
    .wea       (wea_w),
    .addra     (addra_w),
    .dina      (dina_w),
    .clkb      (eth_rx_clk_i),
    .addrb     (ram_rd_addr_w),
    .doutb     (ram_rd_data_w)
  );

  // ==========================================================================
  // Inicializácia statických dát (HELLO ALINX AX516 \n\r)
  // ==========================================================================
  always_comb begin
    udp_data_q[0] = {8'd72, 8'd69, 8'd76, 8'd76}; // H E L L
    udp_data_q[1] = {8'd79, 8'd32, 8'd65, 8'd76}; // O [space] A L
    udp_data_q[2] = {8'd73, 8'd78, 8'd88, 8'd32}; // I N X [space]
    udp_data_q[3] = {8'd65, 8'd88, 8'd53, 8'd49}; // A X 5 1
    udp_data_q[4] = {8'd54, 8'd32, 8'd10, 8'd13}; // 6 [space] \n \r
  end

  // ==========================================================================
  // FSM pre zápis inicializačných dát do RAM pri spustení
  // Zápis sa vykonáva na padavú hranu pre bezpečnejší timing pred prenosom
  // ==========================================================================
  always_ff @(negedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ram_wr_finish_q <= 1'b0;
      ram_addr_q      <= 9'd0;
      ram_data_q      <= 32'd0;
      init_idx_q      <= 5'd0;
      ram_wren_q      <= 1'b0;
    end else begin
      if (init_idx_q == 5'd5) begin
        // Koniec inicializácie
        ram_wr_finish_q <= 1'b1;
        ram_wren_q      <= 1'b0;
      end else begin
        // Zapisovanie slov do pamäte
        ram_wren_q <= 1'b1;
        ram_addr_q <= ram_addr_q + 1'b1;
        ram_data_q <= udp_data_q[init_idx_q];
        init_idx_q <= init_idx_q + 1'b1;
      end
    end
  end

endmodule

`endif // ETHERNET_ALINX_TOP_SV
