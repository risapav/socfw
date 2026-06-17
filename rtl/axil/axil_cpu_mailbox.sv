/**
 * @file  axil_cpu_mailbox.sv
 * @brief AXI-Lite CPU mailbox — RX/TX FIFO s registrovym rozhranim a native CPU portami.
 *
 * @details
 *   Bidirectional mailbox medzi XFCP STREAM endpointom a CPU.
 *   RX FIFO (host->CPU, depth=FIFO_DEPTH): XFCP stream data sa zapisuju cez
 *   s_axis port, CPU cita cez RX_POP_DATA register alebo native cpu_rx_* porty.
 *   TX FIFO (CPU->host, depth=FIFO_DEPTH): CPU zapisuje cez TX_PUSH_DATA
 *   register alebo native cpu_tx_* porty, XFCP cita cez m_axis port.
 *
 *   Register mapa (byte offset):
 *   0x00  ID            RO    0x4350554D ("CPUM")
 *   0x04  CTRL          RW    [0]=rx_flush (pulse), [1]=tx_flush (pulse)
 *   0x08  STATUS        RO    [0]=rx_not_empty, [1]=rx_full,
 *                             [2]=tx_not_empty, [3]=tx_full
 *   0x0C  IRQ_EN        RW    reserved
 *   0x10  RX_LEVEL      RO    pocet slov v RX FIFO
 *   0x14  TX_LEVEL      RO    pocet slov v TX FIFO
 *   0x18  RX_POP_DATA   RO*   citanie = pop z RX FIFO;
 *                             [7:0]=data, [8]=tlast, [10]=underflow
 *   0x1C  TX_PUSH_DATA  WO*   zapis = push do TX FIFO;
 *                             [7:0]=data, [8]=tlast
 *
 *   Native CPU porty (priamy pristup k FIFO, CPU pop/push ma prioritu pred AXI-Lite):
 *   cpu_rx_valid_o: RX FIFO obsahuje data (platne ked =1).
 *   cpu_rx_data_o:  {tlast, data[7:0]} aktualneho slova v tom istom cykle ako valid.
 *   cpu_rx_pop_i:   pop strobe (assert len ked cpu_rx_valid_o=1; 1-cyklovy pulse).
 *   cpu_tx_ready_o: TX FIFO ma miesto (platne push iba ked ready=1).
 *   cpu_tx_data_i:  {tlast, data[7:0]} slova na push.
 *   cpu_tx_push_i:  push strobe (assert len ked cpu_tx_ready_o=1; 1-cyklovy pulse).
 *
 * @param FIFO_DEPTH  Hlbka RX a TX FIFO v 9-bit slovach (default 256)
 *
 * Timing: 2-cycle read latency (AR->R). Single-cycle write response.
 * AXI-S stream word: [8]=tlast, [7:0]=data.
 */

`ifndef AXIL_CPU_MAILBOX_SV
`define AXIL_CPU_MAILBOX_SV

`default_nettype none

module axil_cpu_mailbox #(
  parameter int FIFO_DEPTH = 256
)(
  input  wire              clk_i,
  input  wire              rst_ni,

  // AXI-Lite slave (CPU side)
  axi4lite_if.slave        s_axil,

  // AXI-S slave: host->CPU (feeds RX FIFO)
  input  wire [8:0]        s_axis_tdata_i,   // [8]=tlast, [7:0]=data
  input  wire              s_axis_tvalid_i,
  output logic             s_axis_tready_o,

  // AXI-S master: CPU->host (drains TX FIFO)
  output logic [8:0]       m_axis_tdata_o,   // [8]=tlast, [7:0]=data
  output logic             m_axis_tvalid_o,
  input  wire              m_axis_tready_i,

  // Native CPU-side direct FIFO access (CPU pop/push ma prioritu pred AXI-Lite)
  output logic [8:0]       cpu_rx_data_o,    // {tlast, data[7:0]}; platne s cpu_rx_valid_o
  output logic             cpu_rx_valid_o,   // RX FIFO not empty
  input  wire              cpu_rx_pop_i,     // pop strobe; assert len ked valid=1

  input  wire  [8:0]       cpu_tx_data_i,   // {tlast, data[7:0]}
  input  wire              cpu_tx_push_i,    // push strobe; assert len ked ready=1
  output logic             cpu_tx_ready_o    // TX FIFO not full
);

  import axi_pkg::*;

  // ── Register address constants ────────────────────────────────────────────
  localparam logic [31:0] ID_VAL         = 32'h4350554D;
  localparam logic [4:0]  ADDR_ID        = 5'h00;
  localparam logic [4:0]  ADDR_CTRL      = 5'h04;
  localparam logic [4:0]  ADDR_STATUS    = 5'h08;
  localparam logic [4:0]  ADDR_IRQ_EN    = 5'h0C;
  localparam logic [4:0]  ADDR_RX_LEVEL  = 5'h10;
  localparam logic [4:0]  ADDR_TX_LEVEL  = 5'h14;
  localparam logic [4:0]  ADDR_RX_POP   = 5'h18;
  localparam logic [4:0]  ADDR_TX_PUSH  = 5'h1C;

  localparam int LEVEL_W = $clog2(FIFO_DEPTH + 1);

  // ── Stored registers ─────────────────────────────────────────────────────
  logic [31:0] irq_en_q;

  // ── Flush pulses ──────────────────────────────────────────────────────────
  logic rx_flush_w;
  logic tx_flush_w;

  // ── FIFO signals ─────────────────────────────────────────────────────────
  logic [8:0]  rx_r_data_w;
  logic        rx_r_valid_w;
  logic        rx_r_ready_w;
  logic        rx_w_ready_w;

  logic [8:0]  tx_w_data_w;
  logic        tx_w_valid_w;
  logic        tx_w_ready_w;

  // ── Level shadow counters ─────────────────────────────────────────────────
  logic [LEVEL_W-1:0] rx_level_q;
  logic [LEVEL_W-1:0] tx_level_q;

  wire rx_fifo_wr_w = s_axis_tvalid_i && rx_w_ready_w && !rx_flush_w;
  wire rx_fifo_rd_w = rx_r_valid_w    && rx_r_ready_w;
  wire tx_fifo_wr_w = tx_w_valid_w    && tx_w_ready_w && !tx_flush_w;
  wire tx_fifo_rd_w = m_axis_tvalid_o && m_axis_tready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_level_q <= '0;
      tx_level_q <= '0;
    end else begin
      if (rx_flush_w) begin
        rx_level_q <= '0;
      end else begin
        case ({rx_fifo_wr_w, rx_fifo_rd_w})
          2'b10:   rx_level_q <= rx_level_q + 1'b1;
          2'b01:   rx_level_q <= rx_level_q - 1'b1;
          default: rx_level_q <= rx_level_q;
        endcase
      end
      if (tx_flush_w) begin
        tx_level_q <= '0;
      end else begin
        case ({tx_fifo_wr_w, tx_fifo_rd_w})
          2'b10:   tx_level_q <= tx_level_q + 1'b1;
          2'b01:   tx_level_q <= tx_level_q - 1'b1;
          default: tx_level_q <= tx_level_q;
        endcase
      end
    end
  end

  // ── FIFO instances ────────────────────────────────────────────────────────
  xfcp_fifo_reg #(.DATA_WIDTH(9), .DEPTH(FIFO_DEPTH)) u_rx_fifo (
    .clk    (clk_i),
    .rst_n  (rst_ni),
    .flush  (rx_flush_w),
    .w_data (s_axis_tdata_i),
    .w_valid(s_axis_tvalid_i),
    .w_ready(rx_w_ready_w),
    .r_data (rx_r_data_w),
    .r_valid(rx_r_valid_w),
    .r_ready(rx_r_ready_w)
  );

  xfcp_fifo_reg #(.DATA_WIDTH(9), .DEPTH(FIFO_DEPTH)) u_tx_fifo (
    .clk    (clk_i),
    .rst_n  (rst_ni),
    .flush  (tx_flush_w),
    .w_data (tx_w_data_w),
    .w_valid(tx_w_valid_w),
    .w_ready(tx_w_ready_w),
    .r_data (m_axis_tdata_o),
    .r_valid(m_axis_tvalid_o),
    .r_ready(m_axis_tready_i)
  );

  assign s_axis_tready_o = rx_w_ready_w;

  // ── Native CPU port assignments ───────────────────────────────────────────
  assign cpu_rx_data_o  = rx_r_data_w;
  assign cpu_rx_valid_o = rx_r_valid_w;
  assign cpu_tx_ready_o = tx_w_ready_w;

  // ── AXI-Lite read state machine ────────────────────────────────────────────
  // RD_IDLE  → accept AR
  // RD_LATCH → sample rdata mux (pop RX FIFO if ADDR_RX_POP)
  // RD_RESP  → hold rvalid until rready

  typedef enum logic [1:0] {
    RD_IDLE  = 2'b00,
    RD_LATCH = 2'b01,
    RD_RESP  = 2'b10
  } rd_state_e;

  rd_state_e   rd_state_q;
  logic [4:0]  ar_addr_q;

  // RX pop: CPU has priority; AXI-Lite pop blocked when CPU pops simultaneously
  wire axil_rx_pop_w = (rd_state_q == RD_LATCH) && (ar_addr_q == ADDR_RX_POP) && !cpu_rx_pop_i;
  assign rx_r_ready_w = axil_rx_pop_w || cpu_rx_pop_i;

  // Combinatorial rdata mux
  logic [31:0] rdata_mux_w;
  always_comb begin
    rdata_mux_w = 32'h0;
    case (ar_addr_q)
      ADDR_ID:       rdata_mux_w = ID_VAL;
      ADDR_CTRL:     rdata_mux_w = 32'h0;
      ADDR_STATUS:   rdata_mux_w = {28'h0,
                                    !tx_w_ready_w,    // [3] tx_full
                                    m_axis_tvalid_o,  // [2] tx_not_empty
                                    !rx_w_ready_w,    // [1] rx_full
                                    rx_r_valid_w};    // [0] rx_not_empty
      ADDR_IRQ_EN:   rdata_mux_w = irq_en_q;
      ADDR_RX_LEVEL: rdata_mux_w = {{(32-LEVEL_W){1'b0}}, rx_level_q};
      ADDR_TX_LEVEL: rdata_mux_w = {{(32-LEVEL_W){1'b0}}, tx_level_q};
      ADDR_RX_POP:   rdata_mux_w = {21'h0,
                                    !rx_r_valid_w,   // [10] underflow
                                    1'b0,             // [9]  reserved
                                    rx_r_data_w[8],  // [8]  tlast
                                    rx_r_data_w[7:0]};// [7:0] data
      default:       rdata_mux_w = 32'h0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_state_q      <= RD_IDLE;
      ar_addr_q       <= '0;
      s_axil.ARREADY  <= 1'b0;
      s_axil.RDATA    <= '0;
      s_axil.RRESP    <= AXI_RESP_OKAY;
      s_axil.RVALID   <= 1'b0;
    end else begin
      case (rd_state_q)
        RD_IDLE: begin
          s_axil.ARREADY <= 1'b0;
          s_axil.RVALID  <= 1'b0;
          if (s_axil.ARVALID) begin
            ar_addr_q      <= s_axil.ARADDR[4:0];
            s_axil.ARREADY <= 1'b1;
            rd_state_q     <= RD_LATCH;
          end
        end

        RD_LATCH: begin
          s_axil.ARREADY <= 1'b0;
          // rx_r_ready_w fires this cycle for ADDR_RX_POP → pop happens
          s_axil.RDATA   <= rdata_mux_w;
          s_axil.RRESP   <= AXI_RESP_OKAY;
          s_axil.RVALID  <= 1'b1;
          rd_state_q     <= RD_RESP;
        end

        RD_RESP: begin
          if (s_axil.RREADY) begin
            s_axil.RVALID <= 1'b0;
            rd_state_q    <= RD_IDLE;
          end
        end

        default: rd_state_q <= RD_IDLE;
      endcase
    end
  end

  // ── AXI-Lite write state machine ───────────────────────────────────────────
  // WR_IDLE → accept AW
  // WR_DATA → accept W, perform action
  // WR_RESP → assert bvalid until bready

  typedef enum logic [1:0] {
    WR_IDLE = 2'b00,
    WR_DATA = 2'b01,
    WR_RESP = 2'b10
  } wr_state_e;

  wr_state_e  wr_state_q;
  logic [4:0] aw_addr_q;

  // TX push: CPU has priority; AXI-Lite push blocked when CPU pushes simultaneously
  wire axil_tx_push_w = (wr_state_q == WR_DATA) && s_axil.WVALID &&
                        (aw_addr_q == ADDR_TX_PUSH) && !cpu_tx_push_i;
  assign tx_w_valid_w = cpu_tx_push_i || axil_tx_push_w;
  assign tx_w_data_w  = cpu_tx_push_i ? cpu_tx_data_i : s_axil.WDATA[8:0];

  logic rx_flush_q;
  logic tx_flush_q;
  assign rx_flush_w = rx_flush_q;
  assign tx_flush_w = tx_flush_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_state_q      <= WR_IDLE;
      aw_addr_q       <= '0;
      irq_en_q        <= '0;
      rx_flush_q      <= 1'b0;
      tx_flush_q      <= 1'b0;
      s_axil.AWREADY  <= 1'b0;
      s_axil.WREADY   <= 1'b0;
      s_axil.BRESP    <= AXI_RESP_OKAY;
      s_axil.BVALID   <= 1'b0;
    end else begin
      rx_flush_q <= 1'b0;
      tx_flush_q <= 1'b0;

      case (wr_state_q)
        WR_IDLE: begin
          s_axil.AWREADY <= 1'b0;
          s_axil.WREADY  <= 1'b0;
          s_axil.BVALID  <= 1'b0;
          if (s_axil.AWVALID) begin
            aw_addr_q      <= s_axil.AWADDR[4:0];
            s_axil.AWREADY <= 1'b1;
            s_axil.WREADY  <= 1'b1;
            wr_state_q     <= WR_DATA;
          end
        end

        WR_DATA: begin
          s_axil.AWREADY <= 1'b0;
          if (s_axil.WVALID) begin
            s_axil.WREADY   <= 1'b0;
            case (aw_addr_q)
              ADDR_CTRL: begin
                rx_flush_q <= s_axil.WDATA[0];
                tx_flush_q <= s_axil.WDATA[1];
              end
              ADDR_IRQ_EN: irq_en_q <= s_axil.WDATA;
              // TX_PUSH_DATA handled by tx_w_valid_w combinatorial strobe
              default: ;
            endcase
            s_axil.BRESP  <= AXI_RESP_OKAY;
            s_axil.BVALID <= 1'b1;
            wr_state_q    <= WR_RESP;
          end
        end

        WR_RESP: begin
          if (s_axil.BREADY) begin
            s_axil.BVALID <= 1'b0;
            wr_state_q    <= WR_IDLE;
          end
        end

        default: wr_state_q <= WR_IDLE;
      endcase
    end
  end

endmodule

`endif // AXIL_CPU_MAILBOX_SV
