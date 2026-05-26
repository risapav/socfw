/**
 * @file        ethernet_test.sv
 * @brief       Top-level modul pre testovanie Ethernet/UDP stacku.
 * @details     Modul zabezpecuje inicializaciu statickych dat (textovy retazec)
 * do pamate a nasledne ich cyklicke odosielanie cez UDP protokol do siete.
 * Implementuje fyzicke prepojenia na GMII rozhranie.
 */

`ifndef ETHERNET_TEST_SV
`define ETHERNET_TEST_SV

`default_nettype none

module ethernet_test (
  input  wire        rst_ni,

  // Fyzicke PHY ovladanie
  output logic       eth_rst_no, // Reset pre PHY (Aktivny nizky)
  output logic       eth_mdc_o,  // MDIO Clock pre PHY
  inout  wire        eth_mdio_io,

  // GMII/MII rozhranie
  input  wire        eth_rx_clk_i,  // 125Mhz ethernet gmii rx clock
  input  wire        eth_rx_clk_0_i,// 125Mhz ethernet gmii rx clock
  input  wire        eth_rx_dv_i,
  input  wire        eth_rx_er_i,
  input  wire  [7:0] eth_rx_data_i,

  input  wire        eth_tx_clk_i,  //25Mhz ethernet gmii tx clock
  output logic       eth_gtx_clk_o, //25Mhz ethernet gmii tx clock
  output logic       eth_tx_en_o,
  output logic       eth_tx_er_o,
  output logic [7:0] eth_tx_data_o
);

  // GTX clock: FPGA forwarded zo ETH_RX_CLK (125 MHz)
  assign eth_gtx_clk_o = eth_rx_clk_i;

  // MDIO: neaktivny rezim (PHY konfiguracia cez strap piny dosky)
  assign eth_mdc_o   = 1'b0;
  assign eth_mdio_io = 1'bz;

  // PHY reset extender: 2^21 / 125 MHz = 16.8 ms hold time
  logic [20:0] phy_rst_cnt_q;
  logic        phy_rst_done_q;

  always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phy_rst_cnt_q  <= '0;
      phy_rst_done_q <= 1'b0;
    end else if (!phy_rst_done_q) begin
      phy_rst_cnt_q <= phy_rst_cnt_q + 1'b1;
      if (&phy_rst_cnt_q)
        phy_rst_done_q <= 1'b1;
    end
  end

  assign eth_rst_no = phy_rst_done_q;

  // Interné spojovacie signály
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

  // Ak sme prijali paket, pouzivame jeho dlzku pre echo. Ak nie, staticka dlzka pre test text.
  assign tx_data_length_w  = data_receive_w ? rx_data_length_w  : 16'd28;
  assign tx_total_length_w = data_receive_w ? rx_total_length_w : 16'd48;

  // Mux pre zapis do pamate (najskor inicializacia, potom data z UDP payloadu)
  assign wea_w   = ram_wr_finish_q ? data_o_valid_w : ram_wren_q;
  assign addra_w = ram_wr_finish_q ? ram_wr_addr_w  : ram_addr_q;
  assign dina_w  = ram_wr_finish_q ? ram_wr_data_w  : ram_data_q;

  // ==========================================================================
  // UDP Modul (Refaktorovany instancny nazov podla slovenskeho standardu)
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
  // Dual-Port RAM pre ukladanie prijatych/vysielanych paketov
  // (Predpokladame existenciu refaktorovaneho modulu 'ram')
  // ==========================================================================
   ram u_ram (
    .clk_wr_i   (eth_rx_clk_i),
    .we_i      (wea_w),
    .addr_wr_i (addra_w),
    .data_i    (dina_w),
    .clk_rd_i   (eth_rx_clk_i),
    .addr_rd_i (ram_rd_addr_w),
    .data_o     (ram_rd_data_w)
  );

  // ==========================================================================
  // Staticke data ("HELLO QM TECH BOARD") na inicializaciu pamate pre test
  // ==========================================================================
  always_comb begin
    udp_data_q[0] = {8'd72, 8'd69, 8'd76, 8'd76}; // 'H' 'E' 'L' 'L'
    udp_data_q[1] = {8'd79, 8'd32, 8'd81, 8'd77}; // 'O' ' ' 'Q' 'M'
    udp_data_q[2] = {8'd84, 8'd69, 8'd67, 8'd72}; // 'T' 'E' 'C' 'H'
    udp_data_q[3] = {8'd32, 8'd66, 8'd79, 8'd65}; // ' ' 'B' 'O' 'A'
    udp_data_q[4] = {8'd82, 8'd68, 8'd10, 8'd13}; // 'R' 'D' '\n' '\r'
  end

  // Inicializacny automat do pamate pri starte (padava hrana gmii rx clocku)
  always_ff @(negedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ram_wr_finish_q <= 1'b0;
      ram_addr_q      <= 9'd0;
      ram_data_q      <= 32'd0;
      init_idx_q      <= 5'd0;
      ram_wren_q      <= 1'b0;
    end else begin
      if (init_idx_q == 5'd5) begin
        ram_wr_finish_q <= 1'b1;
        ram_wren_q      <= 1'b0;
      end else begin
        ram_wren_q <= 1'b1;
        ram_addr_q <= ram_addr_q + 1'b1;
        ram_data_q <= udp_data_q[init_idx_q];
        init_idx_q <= init_idx_q + 1'b1;
      end
    end
  end

endmodule


`endif // ETHERNET_TEST_SV
