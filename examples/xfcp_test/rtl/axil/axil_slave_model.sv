`ifndef AXIL_SLAVE_MODEL_SV
`define AXIL_SLAVE_MODEL_SV

`default_nettype none

module axil_slave_model #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned MEM_DEPTH  = 1024
)(
  input  wire           clk,
  input  wire           rstn,
  axi4lite_if.slave     s_axil
);
  import axi_pkg::*;

  localparam int STRB_W    = DATA_WIDTH / 8;
  localparam int WORD_BITS = $clog2(STRB_W);

  // ── Pamäť (štandardné pole, žiadne asociatívne) ──────────────
  logic [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

  // ── Pomocné word-indexy (kombinačne) ─────────────────────────
  logic [31:0] widx, ridx;
  assign widx = 32'(s_axil.AWADDR) >> WORD_BITS;
  assign ridx = 32'(s_axil.ARADDR) >> WORD_BITS;

  // ── Kombinačné čítanie — vždy aktuálna hodnota pamäte ────────
  logic [DATA_WIDTH-1:0] rdata_comb;
  assign rdata_comb = (ridx < MEM_DEPTH) ? mem[ridx] : 32'hBAAD_F00D;

  // ==========================================================================
  // WRITE PATH
  // ==========================================================================
  logic                  aw_pend_q, w_pend_q, b_valid_q;
  logic [ADDR_WIDTH-1:0] awaddr_q;
  logic [DATA_WIDTH-1:0] wdata_q;
  logic [STRB_W-1:0]     wstrb_q;
  logic [31:0]           waddr_idx_q;

  assign s_axil.AWREADY = !aw_pend_q;
  assign s_axil.WREADY  = !w_pend_q;
  assign s_axil.BVALID  = b_valid_q;
  assign s_axil.BRESP   = AXI_RESP_OKAY;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      aw_pend_q   <= 1'b0;
      w_pend_q    <= 1'b0;
      b_valid_q   <= 1'b0;
      awaddr_q    <= '0;
      wdata_q     <= '0;
      wstrb_q     <= '0;
      waddr_idx_q <= '0;
      // Inicializácia pamäte v resete
      for (int i = 0; i < MEM_DEPTH; i++) mem[i] <= '0;
    end else begin

      // AW zachytenie
      if (s_axil.AWVALID && s_axil.AWREADY) begin
        awaddr_q    <= s_axil.AWADDR;
        waddr_idx_q <= widx;
        aw_pend_q   <= 1'b1;
      end

      // W zachytenie
      if (s_axil.WVALID && s_axil.WREADY) begin
        wdata_q  <= s_axil.WDATA;
        wstrb_q  <= s_axil.WSTRB;
        w_pend_q <= 1'b1;
      end

      // Zápis do pamäte + B odpoveď
      if (aw_pend_q && w_pend_q && !b_valid_q) begin
        if (waddr_idx_q < MEM_DEPTH) begin
          for (int b = 0; b < STRB_W; b++)
            if (wstrb_q[b]) mem[waddr_idx_q][b*8 +: 8] <= wdata_q[b*8 +: 8];
        end
        aw_pend_q <= 1'b0;
        w_pend_q  <= 1'b0;
        b_valid_q <= 1'b1;
      end

      // B handshake
      if (b_valid_q && s_axil.BREADY)
        b_valid_q <= 1'b0;

    end
  end

  // ==========================================================================
  // READ PATH
  // ==========================================================================
  logic                  r_valid_q;
  logic [DATA_WIDTH-1:0] rdata_q;

  assign s_axil.ARREADY = !r_valid_q;
  assign s_axil.RVALID  = r_valid_q;
  assign s_axil.RDATA   = rdata_q;
  assign s_axil.RRESP   = AXI_RESP_OKAY;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      r_valid_q <= 1'b0;
      rdata_q   <= '0;
    end else begin
      if (s_axil.ARVALID && s_axil.ARREADY) begin
        rdata_q   <= rdata_comb;   // kombinačný zdroj = aktuálna pamäť
        r_valid_q <= 1'b1;
      end
      if (r_valid_q && s_axil.RREADY)
        r_valid_q <= 1'b0;
    end
  end

  // ==========================================================================
  // DEBUG
  // ==========================================================================
  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rstn) begin
      if (aw_pend_q && w_pend_q && !b_valid_q)
        $display("[%0t ns] SLAVE WR: addr=0x%08h data=0x%08h idx=%0d",
                 $time, awaddr_q, wdata_q, waddr_idx_q);
      if (s_axil.ARVALID && s_axil.ARREADY)
        $display("[%0t ns] SLAVE RD: addr=0x%08h data=0x%08h idx=%0d",
                 $time, s_axil.ARADDR, rdata_comb, ridx);
      if (b_valid_q && !s_axil.BREADY)
        $warning("[%0t ns] SLAVE: BVALID high but BREADY low!", $time);
    end
  end
  // synthesis translate_on

endmodule
`endif
