/**
 * @file  axifull_sram.sv
 * @brief AXI4-Full slave -- synchronna SRAM (M9K bloky, 4 byte-lane).
 *
 * @details
 *   AXI4 slave pre testovanie MEM backendu.
 *   Podporuje INCR burst, single outstanding.
 *
 *   RAM inference: 4x byte-lane (* ramstyle = "M9K" *) s bezpodmienecnym
 *   registrovanym citanim (M9K output register). Cesta rd_addr_q -> rd_data_q
 *   ide cez M9K interni output register, nie cez kombinacny mux.
 *
 *   Citanie: 1-cyklova latencia.
 *     Cyklus N   : rd_addr_q je platna adresa (RD_DATA state)
 *     Cyklus N+1 : rd_data_q = mem[rd_addr_q] (M9K output register)
 *                  rd_valid_q = 1 (RD_WAIT state)
 *
 *   Obmedzenia:
 *     - DATA_WIDTH = 32 bit
 *     - ADDR_WIDTH = 32 bit (bajty; DEPTH = pocet 32-bit slov)
 *     - WSTRB plne implementovany (byte enable)
 *     - Ignoruje AWID/ARID/AWPROT/ARPROT
 *
 * @param DEPTH       Pocet 32-bit slov v pamati (default 256 = 1 KiB).
 * @param ADDR_WIDTH  Sirka adresy (default 32).
 * @param DATA_WIDTH  Sirka dat (default 32).
 */

`ifndef AXIFULL_SRAM_SV
`define AXIFULL_SRAM_SV

`default_nettype none

module axifull_sram #(
  parameter int DEPTH      = 256,
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
)(
  input  wire clk,
  input  wire rst_n,

  // AXI4 Write Address Channel
  input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
  input  logic [7:0]            s_axi_awlen,
  input  logic [2:0]            s_axi_awsize,
  input  logic [1:0]            s_axi_awburst,
  input  logic                  s_axi_awvalid,
  output logic                  s_axi_awready,

  // AXI4 Write Data Channel
  input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
  input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
  input  logic                    s_axi_wlast,
  input  logic                    s_axi_wvalid,
  output logic                    s_axi_wready,

  // AXI4 Write Response Channel
  output logic [1:0] s_axi_bresp,
  output logic       s_axi_bvalid,
  input  logic       s_axi_bready,

  // AXI4 Read Address Channel
  input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
  input  logic [7:0]            s_axi_arlen,
  input  logic [2:0]            s_axi_arsize,
  input  logic [1:0]            s_axi_arburst,
  input  logic                  s_axi_arvalid,
  output logic                  s_axi_arready,

  // AXI4 Read Data Channel
  output logic [DATA_WIDTH-1:0] s_axi_rdata,
  output logic [1:0]            s_axi_rresp,
  output logic                  s_axi_rlast,
  output logic                  s_axi_rvalid,
  input  logic                  s_axi_rready
);

  localparam int WORD_BITS = $clog2(DEPTH);

  // ── SRAM: 4 byte-lane M9K arrays ─────────────────────────────────────────
  (* ramstyle = "M9K" *) logic [7:0] mem0 [0:DEPTH-1];  // byte 0
  (* ramstyle = "M9K" *) logic [7:0] mem1 [0:DEPTH-1];  // byte 1
  (* ramstyle = "M9K" *) logic [7:0] mem2 [0:DEPTH-1];  // byte 2
  (* ramstyle = "M9K" *) logic [7:0] mem3 [0:DEPTH-1];  // byte 3

  // ── Write FSM ────────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    WR_IDLE, WR_DATA, WR_RESP
  } wr_state_e;

  wr_state_e             wr_state_q;
  logic [ADDR_WIDTH-1:0] wr_addr_q;
  logic [7:0]            wr_beat_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_state_q <= WR_IDLE;
      wr_addr_q  <= '0;
      wr_beat_q  <= '0;
    end else begin
      case (wr_state_q)
        WR_IDLE: begin
          if (s_axi_awvalid && s_axi_awready) begin
            wr_addr_q  <= s_axi_awaddr;
            wr_beat_q  <= s_axi_awlen;
            wr_state_q <= WR_DATA;
          end
        end
        WR_DATA: begin
          if (s_axi_wvalid && s_axi_wready) begin
            wr_addr_q <= wr_addr_q + 4;
            if (wr_beat_q == '0 || s_axi_wlast)
              wr_state_q <= WR_RESP;
            else
              wr_beat_q <= wr_beat_q - 1'b1;
          end
        end
        WR_RESP: begin
          if (s_axi_bvalid && s_axi_bready)
            wr_state_q <= WR_IDLE;
        end
        default: wr_state_q <= WR_IDLE;
      endcase
    end
  end

  // Dedicated write port — byte-enable per lane (M9K inference)
  wire wr_en_w = (wr_state_q == WR_DATA) && s_axi_wvalid;
  wire [WORD_BITS-1:0] wr_waddr_w = wr_addr_q[WORD_BITS+1:2];

  always_ff @(posedge clk) begin
    if (wr_en_w) begin
      if (s_axi_wstrb[0]) mem0[wr_waddr_w] <= s_axi_wdata[ 7: 0];
      if (s_axi_wstrb[1]) mem1[wr_waddr_w] <= s_axi_wdata[15: 8];
      if (s_axi_wstrb[2]) mem2[wr_waddr_w] <= s_axi_wdata[23:16];
      if (s_axi_wstrb[3]) mem3[wr_waddr_w] <= s_axi_wdata[31:24];
    end
  end

  assign s_axi_awready = (wr_state_q == WR_IDLE);
  assign s_axi_wready  = (wr_state_q == WR_DATA);
  assign s_axi_bvalid  = (wr_state_q == WR_RESP);
  assign s_axi_bresp   = 2'b00;

  // ── Read FSM ─────────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    RD_IDLE, RD_DATA, RD_WAIT
  } rd_state_e;

  rd_state_e             rd_state_q;
  logic [ADDR_WIDTH-1:0] rd_addr_q;
  logic [7:0]            rd_beat_q;
  logic [7:0]            rd_total_q;
  logic [DATA_WIDTH-1:0] rd_data_q;
  logic                  rd_last_q;
  logic                  rd_valid_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state_q <= RD_IDLE;
      rd_addr_q  <= '0;
      rd_beat_q  <= '0;
      rd_total_q <= '0;
      rd_last_q  <= 1'b0;
      rd_valid_q <= 1'b0;
    end else begin
      case (rd_state_q)
        RD_IDLE: begin
          rd_valid_q <= 1'b0;
          if (s_axi_arvalid && s_axi_arready) begin
            rd_addr_q  <= s_axi_araddr;
            rd_total_q <= s_axi_arlen;
            rd_beat_q  <= '0;
            rd_state_q <= RD_DATA;
          end
        end

        RD_DATA: begin
          // rd_data_q is driven by the dedicated M9K always_ff below.
          // One clock after entering RD_DATA, rd_addr_q is stable and
          // M9K registered output will appear in rd_data_q next cycle.
          rd_last_q  <= (rd_beat_q == rd_total_q);
          rd_valid_q <= 1'b1;
          rd_state_q <= RD_WAIT;
        end

        RD_WAIT: begin
          if (s_axi_rvalid && s_axi_rready) begin
            if (rd_last_q) begin
              rd_valid_q <= 1'b0;
              rd_state_q <= RD_IDLE;
            end else begin
              rd_beat_q  <= rd_beat_q + 1'b1;
              rd_addr_q  <= rd_addr_q + 4;
              rd_state_q <= RD_DATA;
              rd_valid_q <= 1'b0;
            end
          end
        end

        default: rd_state_q <= RD_IDLE;
      endcase
    end
  end

  // Dedicated read port — bezpodmienecne registrovane citanie (M9K output reg)
  // rd_addr_q je platna 1 cyklus pred tym, ako rd_valid_q ide na 1.
  wire [WORD_BITS-1:0] rd_waddr_w = rd_addr_q[WORD_BITS+1:2];

  always_ff @(posedge clk) begin
    rd_data_q <= {mem3[rd_waddr_w], mem2[rd_waddr_w],
                  mem1[rd_waddr_w], mem0[rd_waddr_w]};
  end

  assign s_axi_arready = (rd_state_q == RD_IDLE);
  assign s_axi_rdata   = rd_data_q;
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rlast   = rd_last_q;
  assign s_axi_rvalid  = rd_valid_q;

endmodule : axifull_sram

`endif  // AXIFULL_SRAM_SV
