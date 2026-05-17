/**
 * @version 1.0.0
 * @date    17.2.2026
 * @author  Pavol Risa
 *
 * @file        axis_fifo_sync.sv
 * @brief       Robustné AXI-Stream FIFO s optional FWFT a debug signálmi
 * @details     Optimalizované pre FPGA Block RAM a vysoké frekvencie.
 *              Parametrizovateľný režim FWFT a výstup počtu prvkov.
 *              Poznámka: FIFO je synchronný; s_axis.TCLK musí byť rovnaký ako m_axis.TCLK.
 */

`ifndef AXIS_FIFO_SYNC_SV
`define AXIS_FIFO_SYNC_SV

`default_nettype none

module axis_fifo_sync #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned FIFO_DEPTH = 128,
    parameter bit          USE_FWFT   = 1     // 1 = FWFT, 0 = klasické FIFO
) (
    axi4s_if.slave  s_axis,
    axi4s_if.master m_axis,
    output logic [31:0] fifo_count  // Počet prvkov vo FIFO (debug)
);

  import axi_pkg::*;

  // ==========================================================================
  // 0. Clock domain sanity check
  // ==========================================================================
  // FIFO je SYNCHRONNÝ; async clocks nie sú podporované
  // synopsys translate_off
  always @(posedge s_axis.TCLK)
    if (s_axis.TCLK !== m_axis.TCLK)
      $fatal("axis_fifo_sync: async clocks not supported");
  // synopsys translate_on

  // ==========================================================================
  // 1. Lokálne parametre a signály
  // ==========================================================================
  localparam int unsigned ADDR_WIDTH = $clog2(FIFO_DEPTH);

  (* ramstyle = "no_rw_check" *) logic [DATA_WIDTH-1:0] mem[FIFO_DEPTH];
/*
  // Pridaj tento blok
  initial begin
    for (int i = 0; i < FIFO_DEPTH; i++) mem[i] = '0;
  end
*/
  logic [ADDR_WIDTH:0] wr_ptr_q, rd_ptr_q; // pointery s wrap bitom
  logic [DATA_WIDTH-1:0] data_out_q;       // registrované výstupné dáta
  logic valid_out_q;                        // valid flag pre FWFT aj non-FWFT

  // Full / Empty indikátory
  wire is_full  = (wr_ptr_q[ADDR_WIDTH-1:0] == rd_ptr_q[ADDR_WIDTH-1:0]) &&
                  (wr_ptr_q[ADDR_WIDTH] != rd_ptr_q[ADDR_WIDTH]);
  wire is_empty = (wr_ptr_q == rd_ptr_q);

  // ==========================================================================
  // 2. FIFO Count (debug)
  // ==========================================================================
  // Logika: rozdiel pointerov = počet prvkov
  assign fifo_count = wr_ptr_q - rd_ptr_q;

  // ==========================================================================
  // 3. AXI-Stream Handshake
  // ==========================================================================
  // TREADY je aktívne keď FIFO nie je full
  assign s_axis.TREADY = !is_full;

  // TVALID + TDATA
  // Ak je USE_FWFT = 1, berieme dáta priamo z pamäte (kombinačne), ak je FIFO prázdne
  // Inak používame registrovaný výstup pre lepší timing.
/*
  assign m_axis.TVALID = (USE_FWFT) ? !is_empty : valid_out_q;
  assign m_axis.TDATA  = (USE_FWFT) ? mem[rd_ptr_q[ADDR_WIDTH-1:0]] : data_out_q;
*/
  // Pridaj bypass logiku pre nulovú latenciu pri prázdnom FIFO
  assign m_axis.TVALID = (USE_FWFT) ? (!is_empty || s_axis.TVALID) : valid_out_q;
  assign m_axis.TDATA  = (USE_FWFT) ? (is_empty ? s_axis.TDATA : mem[rd_ptr_q[ADDR_WIDTH-1:0]]) : data_out_q;

  assign m_axis.TKEEP  = '1;
  assign m_axis.TLAST  = 1'b1;
  assign m_axis.TUSER  = '0;
  assign m_axis.TID    = '0;
  assign m_axis.TDEST  = '0;

  // ==========================================================================
  // 4. Zápis do RAM (slave interface)
  // ==========================================================================
  always_ff @(posedge s_axis.TCLK) begin
    if (s_axis.TVALID && s_axis.TREADY)
      mem[wr_ptr_q[ADDR_WIDTH-1:0]] <= s_axis.TDATA;
  end

  always_ff @(posedge s_axis.TCLK or negedge s_axis.TRESETn) begin
    if (!s_axis.TRESETn)
      wr_ptr_q <= '0;
    else if (s_axis.TVALID && s_axis.TREADY)
      wr_ptr_q <= wr_ptr_q + 1'b1;
  end

  // ==========================================================================
  // 5. Čítanie z RAM (master interface)
  // ==========================================================================
  always_ff @(posedge m_axis.TCLK or negedge m_axis.TRESETn) begin
      if (!m_axis.TRESETn) begin
        rd_ptr_q    <= '0;
        data_out_q  <= '0;
        valid_out_q <= 1'b0;
      end else begin
        if (USE_FWFT) begin
          // V režime FWFT registre nepoužívame, priradíme im defaulty
          data_out_q  <= '0;
          valid_out_q <= 1'b0;
          if (m_axis.TVALID && m_axis.TREADY) begin
            rd_ptr_q <= rd_ptr_q + 1'b1;
          end
        end else begin
          // Pôvodná registrovaná logika pre non-FWFT
          if (!valid_out_q || m_axis.TREADY) begin
            if (!is_empty) begin
              data_out_q  <= mem[rd_ptr_q[ADDR_WIDTH-1:0]];
              rd_ptr_q    <= rd_ptr_q + 1'b1;
              valid_out_q <= 1'b1;
            end else begin
              valid_out_q <= 1'b0;
            end
          end
        end
      end
    end

  // ==========================================================================
  // 6. Assertions / sanity check
  // ==========================================================================
  // FIFO_DEPTH musí byť mocnina 2 pre korektnú pointer logiku
  // synopsys translate_off
  initial begin
    if ((FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0)
      $fatal(1, "axis_fifo_sync: FIFO_DEPTH (%0d) musi byt mocnina 2!", FIFO_DEPTH);
  end
  // synopsys translate_on

endmodule

`endif // AXIS_FIFO_SYNC_SV
