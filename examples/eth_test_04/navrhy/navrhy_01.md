# eth_test_04 — navrhy_01

Architektúra postavená na prevode GMII na AXI-Stream, použití FIFO pamäte a následnom prevode späť na GMII pre účely loopbacku je vynikajúci, štandardizovaný a vysoko flexibilný prístup. Oddelenie MAC vrstvy od transportu pomocou AXI-Stream ti neskôr obrovsky uľahčí napájanie ďalších modulov (napríklad analyzátorov paketov alebo DMA).

Pre prvotný loopback test som pripravil tri moduly a jeden jednoduchý synchrónny FIFO buffer. Kód je napísaný striktne podľa tvojich SystemVerilog štandardov, pripravený pre Intel Quartus Prime a overiteľný vo Verilatore.

Budeme sa striktne držať štandardu IEEE 802.3 , vybudujeme si kompletné portfolio modulova a vyriešime všetky vrstvy komunikácie. Kontrolovať simuláciou budeme každý navrhnutý modul , debugovať budeme pomocou led v J11, J10  a onboard LED, prípadne použijeme uart.

Tu sú potrebné súbory:

### 1. Modul RX MAC (`gmii_rx_mac.sv`)

Tento modul prevádza prijímané dáta do AXI-Stream zbernice. Využíva posun o jeden hodinový takt, aby dokázal korektne vygenerovať signál `m_axis_tlast` presne na poslednom platnom bajte rámca (čo vyžaduje AXI-Stream štandard). Status register počíta prijaté rámce a chybové stavy.

```systemverilog
/**
 * @file gmii_rx_mac.sv
 * @brief GMII to AXI-Stream RX MAC wrapper with diagnostic status.
 * @param DATA_WIDTH Width of the datapath.
 * @details Captures GMII signals, converts to AXIS, and tracks diagnostics.
 */
`default_nettype none
`ifndef GMII_RX_MAC_SV
`define GMII_RX_MAC_SV

module gmii_rx_mac #(
  parameter int DATA_WIDTH = 8
)(
  input  wire logic                  rx_clk,
  input  wire logic                  arstn,
  input  wire logic                  gmii_rx_dv,
  input  wire logic                  gmii_rx_er,
  input  wire logic [DATA_WIDTH-1:0] gmii_rxd,
  output      logic [DATA_WIDTH-1:0] m_axis_tdata,
  output      logic                  m_axis_tvalid,
  output      logic                  m_axis_tlast,
  output      logic                  m_axis_tuser,
  output      logic [31:0]           status_reg
);

  logic [DATA_WIDTH-1:0] rxd_q;
  logic                  rx_dv_q;
  logic                  rx_er_q;
  logic [15:0]           frame_count;
  logic [15:0]           error_count;

  always_ff @(posedge rx_clk or negedge arstn) begin
    if (!arstn) begin
      rxd_q         <= '0;
      rx_dv_q       <= 1'b0;
      rx_er_q       <= 1'b0;
      m_axis_tdata  <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_axis_tuser  <= 1'b0;
      frame_count   <= '0;
      error_count   <= '0;
      status_reg    <= '0;
    end else begin
      // Delay incoming signals to detect falling edge for tlast
      rxd_q   <= gmii_rxd;
      rx_dv_q <= gmii_rx_dv;
      rx_er_q <= gmii_rx_er;

      m_axis_tdata  <= rxd_q;
      m_axis_tvalid <= rx_dv_q;
      m_axis_tuser  <= rx_er_q;

      // tlast is asserted when current is valid but incoming next is not
      m_axis_tlast  <= rx_dv_q & (~gmii_rx_dv);

      // Diagnostic counters
      if (rx_dv_q & (~gmii_rx_dv)) begin
        frame_count <= frame_count + 16'd1;
      end
      if (rx_dv_q & rx_er_q) begin
        error_count <= error_count + 16'd1;
      end

      status_reg <= {error_count, frame_count};
    end
  end

endmodule
`endif


```

### 2. Modul AXI-Stream FIFO (`axis_fifo.sv`)

Pre zjednodušenie prvého testu (ak predpokladáme zdieľané hodiny) využijeme základné synchrónne FIFO postavené na poli štruktúr.

```systemverilog
/**
 * @file axis_fifo.sv
 * @brief Simple Synchronous AXI-Stream FIFO.
 * @param DATA_WIDTH Width of the datapath.
 * @param DEPTH_LOG2 Log2 of the FIFO depth.
 * @details Stores AXI-Stream transactions for loopback bridging.
 */
`default_nettype none
`ifndef AXIS_FIFO_SV
`define AXIS_FIFO_SV

module axis_fifo #(
  parameter int DATA_WIDTH = 8,
  parameter int DEPTH_LOG2 = 4
)(
  input  wire logic                  clk,
  input  wire logic                  arstn,
  input  wire logic [DATA_WIDTH-1:0] s_axis_tdata,
  input  wire logic                  s_axis_tvalid,
  input  wire logic                  s_axis_tlast,
  input  wire logic                  s_axis_tuser,
  output      logic                  s_axis_tready,
  output      logic [DATA_WIDTH-1:0] m_axis_tdata,
  output      logic                  m_axis_tvalid,
  output      logic                  m_axis_tlast,
  output      logic                  m_axis_tuser,
  input  wire logic                  m_axis_tready
);

  localparam int DEPTH = 1 << DEPTH_LOG2;

  typedef struct packed {
    logic [DATA_WIDTH-1:0] tdata;
    logic                  tlast;
    logic                  tuser;
  } axis_data_t;

  axis_data_t mem [DEPTH-1:0];
  logic [DEPTH_LOG2:0] wr_ptr;
  logic [DEPTH_LOG2:0] rd_ptr;

  logic full;
  logic empty;

  always_comb begin
    full  = (wr_ptr[DEPTH_LOG2] != rd_ptr[DEPTH_LOG2]) &&
            (wr_ptr[DEPTH_LOG2-1:0] == rd_ptr[DEPTH_LOG2-1:0]);
    empty = (wr_ptr == rd_ptr);

    s_axis_tready = ~full;
    m_axis_tvalid = ~empty;
  end

  assign m_axis_tdata = mem[rd_ptr[DEPTH_LOG2-1:0]].tdata;
  assign m_axis_tlast = mem[rd_ptr[DEPTH_LOG2-1:0]].tlast;
  assign m_axis_tuser = mem[rd_ptr[DEPTH_LOG2-1:0]].tuser;

  always_ff @(posedge clk or negedge arstn) begin
    if (!arstn) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else begin
      if (s_axis_tvalid & s_axis_tready) begin
        mem[wr_ptr[DEPTH_LOG2-1:0]] <= '{
          tdata: s_axis_tdata,
          tlast: s_axis_tlast,
          tuser: s_axis_tuser
        };
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (m_axis_tvalid & m_axis_tready) begin
        rd_ptr <= rd_ptr + 1'b1;
      end
    end
  end

endmodule
`endif


```

### 3. Modul TX MAC (`gmii_tx_mac.sv`)

Korektne spracuje AXI-Stream dáta a obnoví signály `tx_en` a `tx_er`. Keďže ide o priamy priechod dát, `tvalid` priamo determinuje `tx_en`.

```systemverilog
/**
 * @file gmii_tx_mac.sv
 * @brief AXI-Stream to GMII TX MAC wrapper with diagnostic status.
 * @param DATA_WIDTH Width of the datapath.
 * @details Converts AXIS to GMII transmit signals.
 */
`default_nettype none
`ifndef GMII_TX_MAC_SV
`define GMII_TX_MAC_SV

module gmii_tx_mac #(
  parameter int DATA_WIDTH = 8
)(
  input  wire logic                  tx_clk,
  input  wire logic                  arstn,
  input  wire logic [DATA_WIDTH-1:0] s_axis_tdata,
  input  wire logic                  s_axis_tvalid,
  input  wire logic                  s_axis_tlast,
  input  wire logic                  s_axis_tuser,
  output      logic                  s_axis_tready,
  output      logic                  gmii_tx_en,
  output      logic                  gmii_tx_er,
  output      logic [DATA_WIDTH-1:0] gmii_txd,
  output      logic [31:0]           status_reg
);

  logic [15:0] tx_frame_count;

  // Always ready to accept data in this simple loopback test
  assign s_axis_tready = 1'b1;

  always_ff @(posedge tx_clk or negedge arstn) begin
    if (!arstn) begin
      gmii_tx_en     <= 1'b0;
      gmii_tx_er     <= 1'b0;
      gmii_txd       <= '0;
      tx_frame_count <= '0;
      status_reg     <= '0;
    end else begin
      gmii_tx_en <= s_axis_tvalid;
      gmii_tx_er <= s_axis_tuser;
      gmii_txd   <= s_axis_tdata;

      // Count fully transmitted frames
      if (s_axis_tvalid & s_axis_tlast) begin
        tx_frame_count <= tx_frame_count + 16'd1;
      end

      status_reg <= {16'd0, tx_frame_count};
    end
  end

endmodule
`endif


```

### 4. Top Modul Loopbacku (`gmii_loopback_top.sv`)

Tento modul inštancuje všetky komponenty a zabezpečuje prepojenie. Pre tento základný test predpokladáme zjednotené hodiny `clk` pre TX aj RX stranu.

```systemverilog
/**
 * @file gmii_loopback_top.sv
 * @brief Top level GMII loopback design.
 * @details Connects RX MAC -> FIFO -> TX MAC for testing.
 */
`default_nettype none
`ifndef GMII_LOOPBACK_TOP_SV
`define GMII_LOOPBACK_TOP_SV

module gmii_loopback_top (
  input  wire logic        clk,
  input  wire logic        arstn,

  input  wire logic        gmii_rx_dv,
  input  wire logic        gmii_rx_er,
  input  wire logic [7:0]  gmii_rxd,

  output      logic        gmii_tx_en,
  output      logic        gmii_tx_er,
  output      logic [7:0]  gmii_txd,

  output      logic [31:0] rx_status_reg,
  output      logic [31:0] tx_status_reg
);

  logic [7:0] rx_axis_tdata;
  logic       rx_axis_tvalid;
  logic       rx_axis_tlast;
  logic       rx_axis_tuser;

  logic [7:0] tx_axis_tdata;
  logic       tx_axis_tvalid;
  logic       tx_axis_tlast;
  logic       tx_axis_tuser;
  logic       tx_axis_tready;

  gmii_rx_mac #(
    .DATA_WIDTH ( 8 )
  ) u_gmii_rx_mac (
    .rx_clk        ( clk            ),
    .arstn         ( arstn          ),
    .gmii_rx_dv    ( gmii_rx_dv     ),
    .gmii_rx_er    ( gmii_rx_er     ),
    .gmii_rxd      ( gmii_rxd       ),
    .m_axis_tdata  ( rx_axis_tdata  ),
    .m_axis_tvalid ( rx_axis_tvalid ),
    .m_axis_tlast  ( rx_axis_tlast  ),
    .m_axis_tuser  ( rx_axis_tuser  ),
    .status_reg    ( rx_status_reg  )
  );

  axis_fifo #(
    .DATA_WIDTH ( 8 ),
    .DEPTH_LOG2 ( 4 )
  ) u_axis_fifo (
    .clk           ( clk            ),
    .arstn         ( arstn          ),
    .s_axis_tdata  ( rx_axis_tdata  ),
    .s_axis_tvalid ( rx_axis_tvalid ),
    .s_axis_tlast  ( rx_axis_tlast  ),
    .s_axis_tuser  ( rx_axis_tuser  ),
    .s_axis_tready (                ), // RX wrapper ignores backpressure
    .m_axis_tdata  ( tx_axis_tdata  ),
    .m_axis_tvalid ( tx_axis_tvalid ),
    .m_axis_tlast  ( tx_axis_tlast  ),
    .m_axis_tuser  ( tx_axis_tuser  ),
    .m_axis_tready ( tx_axis_tready )
  );

  gmii_tx_mac #(
    .DATA_WIDTH ( 8 )
  ) u_gmii_tx_mac (
    .tx_clk        ( clk            ),
    .arstn         ( arstn          ),
    .s_axis_tdata  ( tx_axis_tdata  ),
    .s_axis_tvalid ( tx_axis_tvalid ),
    .s_axis_tlast  ( tx_axis_tlast  ),
    .s_axis_tuser  ( tx_axis_tuser  ),
    .s_axis_tready ( tx_axis_tready ),
    .gmii_tx_en    ( gmii_tx_en     ),
    .gmii_tx_er    ( gmii_tx_er     ),
    .gmii_txd      ( gmii_txd       ),
    .status_reg    ( tx_status_reg  )
  );

endmodule
`endif


```

*(Poznámka: Pri ukladaní nezabudni, že tvoje pravidlá vyžadujú jeden prázdny riadok na konci každého súboru, ktorý je tu reprezentovaný samotným uzavretím bloku kódu).*
