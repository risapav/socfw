/**
 * @file  axifull_sram.sv
 * @brief Jednoduchy AXI4-Full slave -- synchronna SRAM (M9K bloky).
 *
 * @details
 *   Implementuje AXI4 slave pre testovanie MEM backendu.
 *   Podporuje INCR burst, single data channel.
 *
 *   Obmedzenia:
 *     - DATA_WIDTH = 32 bit
 *     - ADDR_WIDTH = 32 bit (adresuje bajty; DEPTH je pocet 32-bit slov)
 *     - Single outstanding (resp. pipelined AXI s 1-cycle latency)
 *     - Ignoruje AWID/ARID (vracia ID=0)
 *     - Ignoruje AWPROT/ARPROT
 *     - WSTRB plne implementovany (byte enable)
 *
 * @param DEPTH       Pocet 32-bit slov v pamati (default 256 = 1KB).
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

  // ── SRAM ─────────────────────────────────────────────────────────────────
  logic [DATA_WIDTH-1:0] mem_q [0:DEPTH-1];

  // ── Write FSM ────────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    WR_IDLE, WR_DATA, WR_RESP
  } wr_state_e;

  wr_state_e         wr_state_q;
  logic [ADDR_WIDTH-1:0] wr_addr_q;
  logic [7:0]            wr_beat_q;   // beats remaining

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_state_q  <= WR_IDLE;
      wr_addr_q   <= '0;
      wr_beat_q   <= '0;
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
            // byte-enable write
            for (int b = 0; b < DATA_WIDTH/8; b++) begin
              if (s_axi_wstrb[b])
                mem_q[wr_addr_q[WORD_BITS+1:2]][b*8+:8] <= s_axi_wdata[b*8+:8];
            end
            wr_addr_q <= wr_addr_q + 4;
            if (wr_beat_q == '0 || s_axi_wlast) begin
              wr_state_q <= WR_RESP;
            end else begin
              wr_beat_q <= wr_beat_q - 1'b1;
            end
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

  assign s_axi_awready = (wr_state_q == WR_IDLE);
  assign s_axi_wready  = (wr_state_q == WR_DATA);
  assign s_axi_bvalid  = (wr_state_q == WR_RESP);
  assign s_axi_bresp   = 2'b00;  // OKAY

  // ── Read FSM ─────────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    RD_IDLE, RD_DATA, RD_WAIT
  } rd_state_e;

  rd_state_e         rd_state_q;
  logic [ADDR_WIDTH-1:0] rd_addr_q;
  logic [7:0]            rd_beat_q;
  logic [7:0]            rd_total_q;
  logic [DATA_WIDTH-1:0] rd_data_q;
  logic                  rd_last_q;
  logic                  rd_valid_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state_q  <= RD_IDLE;
      rd_addr_q   <= '0;
      rd_beat_q   <= '0;
      rd_total_q  <= '0;
      rd_data_q   <= '0;
      rd_last_q   <= 1'b0;
      rd_valid_q  <= 1'b0;
    end else begin
      case (rd_state_q)
        RD_IDLE: begin
          if (s_axi_arvalid && s_axi_arready) begin
            rd_addr_q  <= s_axi_araddr;
            rd_total_q <= s_axi_arlen;
            rd_beat_q  <= '0;
            rd_state_q <= RD_DATA;
          end
          rd_valid_q <= 1'b0;
        end

        RD_DATA: begin
          // latch data from SRAM (1-cycle latency)
          rd_data_q  <= mem_q[rd_addr_q[WORD_BITS+1:2]];
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

  assign s_axi_arready = (rd_state_q == RD_IDLE);
  assign s_axi_rdata   = rd_data_q;
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rlast   = rd_last_q;
  assign s_axi_rvalid  = rd_valid_q;

endmodule : axifull_sram

`endif  // AXIFULL_SRAM_SV
