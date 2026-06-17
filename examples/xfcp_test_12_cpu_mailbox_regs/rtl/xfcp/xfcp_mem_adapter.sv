/**
 * @file  xfcp_mem_adapter.sv
 * @brief XFCP MEM_READ/MEM_WRITE adapter -- AXI4-Full master, single outstanding.
 *
 * @details
 *   Implementuje MEM_READ (0x30) a MEM_WRITE (0x31) opcodes nad AXI4-Full.
 *
 *   Obmedzenia (v1.0):
 *     - Single outstanding transakcia (busy tracker v xfcp_fabric_endpoint)
 *     - INCR burst only (AWBURST/ARBURST = 2'b01)
 *     - DATA_WIDTH = 32 bit
 *     - MAX_BYTES = 256 B (max AWLEN/ARLEN = 63, burst 64 beats)
 *     - COUNT musi byt nenulovy nasobok 4 (parser garantuje)
 *     - Timeout watchdog (TIMEOUT_CYCLES) -> XFCP_ST_TIMEOUT
 *
 *   Status mapovanie:
 *     AXI OKAY    -> XFCP_ST_OK
 *     AXI SLVERR  -> XFCP_ST_AXI_SLVERR
 *     AXI DECERR  -> XFCP_ST_AXI_DECERR
 *     timeout     -> XFCP_ST_TIMEOUT
 *
 *   FSM (MEM_READ):
 *     ST_IDLE -> ST_AR -> ST_R -> ST_DONE_PLS -> ST_DATA -> ST_IDLE
 *
 *   FSM (MEM_WRITE):
 *     ST_IDLE -> ST_AW_W -> [ST_AW_ONLY | ST_W_ONLY] -> ST_B -> ST_DONE_PLS -> ST_IDLE
 *
 * @param TIMEOUT_CYCLES  Pocet taktov pred TIMEOUT (default 1024).
 * @param MAX_BYTES       Max pocet bajtov na jeden prenos (default 256, <= 256).
 * @param ADDR_WIDTH      Sirka adresy AXI (default 32).
 * @param DATA_WIDTH      Sirka dat AXI (default 32, = 4 bajty/beat).
 */

`ifndef XFCP_MEM_ADAPTER_SV
`define XFCP_MEM_ADAPTER_SV

`default_nettype none

import xfcp_pkg::*;

module xfcp_mem_adapter #(
  parameter int TIMEOUT_CYCLES = 1024,
  parameter int MAX_BYTES      = 256,
  parameter int ADDR_WIDTH     = 32,
  parameter int DATA_WIDTH     = 32
)(
  input  wire clk,
  input  wire rst_n,

  // Request interface (od xfcp_fabric_endpoint)
  input  logic          mem_req_valid_i,
  output logic          mem_req_ready_o,
  input  xfcp_req_hdr_t mem_req_hdr_i,

  // Wdata channel (od xfcp_fabric_endpoint, pre MEM_WRITE)
  input  logic [31:0]   mem_wdata_i,
  input  logic          mem_wdata_valid_i,
  output logic          mem_wdata_ready_o,

  // Rdata channel (do xfcp_fabric_endpoint -> packetizer, pre MEM_READ)
  output logic [31:0]   mem_rdata_o,
  output logic          mem_rdata_valid_o,
  input  logic          mem_rdata_ready_i,

  // Done signal -> xfcp_fabric_endpoint
  output logic          mem_resp_done_o,
  output logic [7:0]    mem_resp_status_o,

  // AXI4-Full master
  output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
  output logic [7:0]            m_axi_awlen,    // burst length - 1
  output logic [2:0]            m_axi_awsize,   // 3'b010 = 4 bytes
  output logic [1:0]            m_axi_awburst,  // 2'b01 = INCR
  output logic                  m_axi_awvalid,
  input  logic                  m_axi_awready,

  output logic [DATA_WIDTH-1:0]   m_axi_wdata,
  output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
  output logic                    m_axi_wlast,
  output logic                    m_axi_wvalid,
  input  logic                    m_axi_wready,

  input  logic [1:0]  m_axi_bresp,
  input  logic        m_axi_bvalid,
  output logic        m_axi_bready,

  output logic [ADDR_WIDTH-1:0] m_axi_araddr,
  output logic [7:0]            m_axi_arlen,
  output logic [2:0]            m_axi_arsize,
  output logic [1:0]            m_axi_arburst,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,

  input  logic [DATA_WIDTH-1:0] m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rlast,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready
);

  // synthesis translate_off
  initial begin
    if (MAX_BYTES < 4 || MAX_BYTES > 256 || (MAX_BYTES % 4) != 0)
      $fatal(1, "%m: MAX_BYTES musi byt nasobok 4 v rozsahu 4-256, got %0d", MAX_BYTES);
    if (DATA_WIDTH != 32)
      $fatal(1, "%m: DATA_WIDTH musi byt 32, got %0d", DATA_WIDTH);
  end
  // synthesis translate_on

  localparam int BEATS_MAX  = MAX_BYTES / 4;  // max burst beats (64)

  // ── FSM ──────────────────────────────────────────────────────────────────
  typedef enum logic [2:0] {
    ST_IDLE     = 3'd0,  // caka na request
    ST_AR       = 3'd1,  // READ: caka na AR handshake
    ST_R        = 3'd2,  // READ: prijima R beaty
    ST_AW_W     = 3'd3,  // WRITE: caka na AW a W simultanne
    ST_B        = 3'd4,  // WRITE: caka na B response
    ST_DONE_PLS = 3'd5,  // 1-cyklovy done pulse
    ST_DATA     = 3'd6   // READ: streamuje rdata do packetizera
  } state_e;

  state_e    state_q;
  logic      is_read_q;   // 1 = MEM_READ, 0 = MEM_WRITE
  logic [7:0]  beat_cnt_q;  // pocitadlo beat (pre WLAST a DONE)
  logic [7:0]  beat_total_q; // celkovy pocet beatov (count/4 - 1 -> AWLEN)
  logic [ADDR_WIDTH-1:0] addr_q;
  logic [7:0]  status_q;

  // timeout watchdog
  localparam int TO_W = $clog2(TIMEOUT_CYCLES + 1);
  logic [TO_W-1:0] to_cnt_q;
  wire             timeout_w = (to_cnt_q >= TO_W'(TIMEOUT_CYCLES));

  // ── Read data capture FIFO ───────────────────────────────────────────────
  // xfcp_fifo_reg: registrovany vystup eliminuje kombinacnu cestu
  // RAM_address -> rdata_r (Quartus Warning 276020 pass-through bypass).
  // DATA_WIDTH+1 = 32 data + 1 rlast; DEPTH = BEATS_MAX (pokryva plny burst).
  logic                rfifo_w_ready_w;
  logic [DATA_WIDTH:0] rfifo_r_data_w;
  logic                rfifo_r_valid_w;
  wire                 rfifo_r_ready_w = (state_q == ST_DATA) && mem_rdata_ready_i;

  xfcp_fifo_reg #(
    .DATA_WIDTH(DATA_WIDTH + 1),
    .DEPTH     (BEATS_MAX)
  ) u_rdata_fifo (
    .clk    (clk),
    .rst_n  (rst_n),
    .flush  (1'b0),
    .w_data ({m_axi_rlast, m_axi_rdata}),
    .w_valid(m_axi_rvalid && m_axi_rready),
    .w_ready(rfifo_w_ready_w),
    .r_data (rfifo_r_data_w),
    .r_valid(rfifo_r_valid_w),
    .r_ready(rfifo_r_ready_w)
  );

  // ── Mainny FSM ───────────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q      <= ST_IDLE;
      is_read_q    <= 1'b0;
      beat_cnt_q   <= '0;
      beat_total_q <= '0;
      addr_q       <= '0;
      status_q     <= '0;
      to_cnt_q     <= '0;
    end else begin
      case (state_q)

        ST_IDLE: begin
          if (mem_req_valid_i) begin
            addr_q       <= mem_req_hdr_i.addr;
            beat_total_q <= 8'(mem_req_hdr_i.count[9:2] - 1'b1);
            beat_cnt_q   <= '0;
            is_read_q    <= (mem_req_hdr_i.opcode == xfcp_pkg::XFCP_OP_MEM_READ);
            status_q     <= '0;
            to_cnt_q     <= '0;
            state_q      <= (mem_req_hdr_i.opcode == xfcp_pkg::XFCP_OP_MEM_READ)
                            ? ST_AR : ST_AW_W;
          end
        end

        ST_AR: begin
          if (timeout_w) begin
            status_q <= 8'(XFCP_ST_TIMEOUT);
            state_q  <= ST_DONE_PLS;
          end else begin
            to_cnt_q <= to_cnt_q + 1'b1;
            if (m_axi_arvalid && m_axi_arready) begin
              to_cnt_q <= '0;
              state_q  <= ST_R;
            end
          end
        end

        ST_R: begin
          if (timeout_w) begin
            status_q <= 8'(XFCP_ST_TIMEOUT);
            state_q  <= ST_DONE_PLS;
          end else begin
            to_cnt_q <= to_cnt_q + 1'b1;
            if (m_axi_rvalid && m_axi_rready) begin
              to_cnt_q <= '0;
              if (m_axi_rresp != 2'b00 && status_q == '0)
                status_q <= (m_axi_rresp == 2'b10)
                            ? 8'(XFCP_ST_AXI_SLVERR)
                            : 8'(XFCP_ST_AXI_DECERR);
              if (m_axi_rlast)
                state_q <= ST_DONE_PLS;
            end
          end
        end

        ST_AW_W: begin
          if (timeout_w) begin
            status_q <= 8'(XFCP_ST_TIMEOUT);
            state_q  <= ST_DONE_PLS;
          end else begin
            if (m_axi_wvalid && m_axi_wready) begin
              to_cnt_q <= '0;
              if (beat_cnt_q == beat_total_q)
                state_q <= ST_B;
              else
                beat_cnt_q <= beat_cnt_q + 1'b1;
            end else if (mem_wdata_valid_i) begin
              // wdata je pripravena ale AXI W este nedobehol — cakame na slave
              to_cnt_q <= to_cnt_q + 1'b1;
            end else begin
              // wdata este neprisla od upstream parsera — neni to chyba AXI slave
              to_cnt_q <= '0;
            end
          end
        end

        ST_B: begin
          if (timeout_w) begin
            status_q <= 8'(XFCP_ST_TIMEOUT);
            state_q  <= ST_DONE_PLS;
          end else begin
            to_cnt_q <= to_cnt_q + 1'b1;
            if (m_axi_bvalid && m_axi_bready) begin
              if (m_axi_bresp != 2'b00)
                status_q <= (m_axi_bresp == 2'b10)
                            ? 8'(XFCP_ST_AXI_SLVERR)
                            : 8'(XFCP_ST_AXI_DECERR);
              state_q <= ST_DONE_PLS;
            end
          end
        end

        ST_DONE_PLS: begin
          state_q <= is_read_q ? ST_DATA : ST_IDLE;
        end

        ST_DATA: begin
          // Skoncime po poslednom beate (rlast bit v rfifo_r_data_w[DATA_WIDTH])
          if (rfifo_r_valid_w && mem_rdata_ready_i && rfifo_r_data_w[DATA_WIDTH])
            state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  // ── AXI AR channel ───────────────────────────────────────────────────────
  assign m_axi_araddr  = addr_q;
  assign m_axi_arlen   = beat_total_q;
  assign m_axi_arsize  = 3'b010;   // 4 bytes per beat
  assign m_axi_arburst = 2'b01;    // INCR
  assign m_axi_arvalid = (state_q == ST_AR) && !timeout_w;

  // ── AXI R channel ────────────────────────────────────────────────────────
  assign m_axi_rready  = (state_q == ST_R) && rfifo_w_ready_w && !timeout_w;

  // ── AXI AW channel ───────────────────────────────────────────────────────
  assign m_axi_awaddr  = addr_q;
  assign m_axi_awlen   = beat_total_q;
  assign m_axi_awsize  = 3'b010;
  assign m_axi_awburst = 2'b01;
  // AW fires simultaneously with first W beat (simplifcation: AW+W concurrent)
  assign m_axi_awvalid = (state_q == ST_AW_W) && (beat_cnt_q == '0)
                         && mem_wdata_valid_i && !timeout_w;

  // ── AXI W channel ────────────────────────────────────────────────────────
  assign m_axi_wdata   = mem_wdata_i;
  assign m_axi_wstrb   = {(DATA_WIDTH/8){1'b1}};
  assign m_axi_wlast   = (beat_cnt_q == beat_total_q);
  assign m_axi_wvalid  = (state_q == ST_AW_W) && mem_wdata_valid_i && !timeout_w;

  // ── AXI B channel ────────────────────────────────────────────────────────
  assign m_axi_bready  = (state_q == ST_B) && !timeout_w;

  // ── Request interface ─────────────────────────────────────────────────────
  assign mem_req_ready_o  = (state_q == ST_IDLE);

  // ── Wdata interface ───────────────────────────────────────────────────────
  assign mem_wdata_ready_o = (state_q == ST_AW_W) && m_axi_wready && !timeout_w;

  // ── Done + status ─────────────────────────────────────────────────────────
  assign mem_resp_done_o   = (state_q == ST_DONE_PLS);
  assign mem_resp_status_o = status_q;

  // ── Rdata interface (READ) ────────────────────────────────────────────────
  assign mem_rdata_valid_o = (state_q == ST_DATA) && rfifo_r_valid_w;
  assign mem_rdata_o       = rfifo_r_data_w[DATA_WIDTH-1:0];

  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (mem_req_valid_i && mem_req_ready_o)
        $display("[%0t] %m: REQ op=0x%02h seq=0x%02h addr=0x%08h count=%0d",
                 $time, 8'(mem_req_hdr_i.opcode), mem_req_hdr_i.seq,
                 mem_req_hdr_i.addr, mem_req_hdr_i.count);
      if (state_q == ST_DONE_PLS)
        $display("[%0t] %m: DONE is_read=%0b status=0x%02h",
                 $time, is_read_q, status_q);
      if (timeout_w && state_q != ST_IDLE && state_q != ST_DONE_PLS && state_q != ST_DATA)
        $warning("[%0t] %m: TIMEOUT v stave %0d", $time, 3'(state_q));
    end
  end
  // synthesis translate_on

endmodule : xfcp_mem_adapter

`endif  // XFCP_MEM_ADAPTER_SV
