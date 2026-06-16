/**
 * @file  xfcp_fifo.sv
 * @brief Synchronous FIFO s fall-through (kombinačným) výstupom.
 *
 * @details
 *   - Štandardná FIFO s plnou/prázdnou detekciou
 *   - r_data je kombinačný výstup (zero-latency read)
 *   - Synchronný flush port namiesto asynchrónneho reset-glitchu
 *   - SIMULATION checky pre overflow/underflow
 *
 * Časovanie:
 *   - Zápis:  w_valid && w_ready → dáta v mem v nasledujúcom takte
 *   - Čítanie: r_valid && r_ready → r_data platné kombinačne (fall-through)
 *              rd_ptr sa posúva v nasledujúcom takte
 *
 * @param DATA_WIDTH  Šírka dátového slova v bitoch
 * @param DEPTH       Hĺbka FIFO (počet slov). Musí byť >= 2.
 */

`ifndef XFCP_FIFO_SV
`define XFCP_FIFO_SV

`default_nettype none

module xfcp_fifo #(
  parameter int DATA_WIDTH = 32,
  parameter int DEPTH      = 16
)(
  input  wire                  clk,
  input  wire                  rst_n,

  // Synchronný flush – vymaže obsah FIFO bez resetu celého modulu.
  // Aktívny v HIGH. Má prednosť pred zápisom/čítaním.
  input  wire                  flush,

  // Write port
  input  wire [DATA_WIDTH-1:0] w_data,
  input  wire                  w_valid,
  output wire                  w_ready,   // 1 = FIFO nie je plná

  // Read port (fall-through / combinational output)
  output wire [DATA_WIDTH-1:0] r_data,    // platné keď r_valid=1
  output wire                  r_valid,   // 1 = FIFO nie je prázdna
  input  wire                  r_ready    // 1 = čitateľ akceptuje dáta
);

  // ── Parametrická ochrana ──────────────────────────────────────
  // synthesis translate_off
  initial begin
    if (DEPTH < 2)
      $fatal(1, "%m: xfcp_fifo DEPTH musí byť >= 2, got %0d", DEPTH);
    if (DATA_WIDTH < 1)
      $fatal(1, "%m: xfcp_fifo DATA_WIDTH musí byť >= 1, got %0d", DATA_WIDTH);
  end
  // synthesis translate_on

  // ── Lokálne konštanty ─────────────────────────────────────────
  // PTR_W: šírka pointera. Pre DEPTH=mocnina 2 pointer prirodzene
  // wrapuje. Pre iné hodnoty DEPTH stačí tiež, pretože inkrementáciu
  // chránime podmienkou (ptr < DEPTH-1 ? ptr+1 : 0).
  localparam int PTR_W   = $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);  // potrebuje 1 bit navyše

  // ── Pamäť ─────────────────────────────────────────────────────
  (* ramstyle = "logic" *)
  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

  // ── Interné registre ──────────────────────────────────────────
  logic [PTR_W-1:0]   wr_ptr_q;
  logic [PTR_W-1:0]   rd_ptr_q;
  logic [COUNT_W-1:0] count_q;

  // ── Kombinačné výstupy ────────────────────────────────────────
  assign w_ready = (count_q < COUNT_W'(DEPTH)) && !flush;
  assign r_valid = (count_q > 0)               && !flush;
  assign r_data  = mem[rd_ptr_q];   // fall-through: platné bez latencie

  // ── Handshake pulzy ───────────────────────────────────────────
  wire do_write = w_valid && w_ready;
  wire do_read  = r_valid && r_ready;

  // ── Pomocná funkcia: bezpečný wrap pointera ───────────────────
  // Správa pre DEPTH ktoré nie sú mocninou 2
  function automatic logic [PTR_W-1:0] ptr_inc(logic [PTR_W-1:0] p);
    return (p == PTR_W'(DEPTH - 1)) ? '0 : p + 1'b1;
  endfunction

  // ── Sekvenčná logika ──────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
      count_q  <= '0;
    end else if (flush) begin
      // Synchronný flush: reset pointerov bez mazania pamäte.
      // Stará dáta v mem zostanú, ale count=0 → r_valid=0 → nedostupné.
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
      count_q  <= '0;
    end else begin

      if (do_write) begin
        mem[wr_ptr_q] <= w_data;
        wr_ptr_q      <= ptr_inc(wr_ptr_q);
      end

      if (do_read)
        rd_ptr_q <= ptr_inc(rd_ptr_q);

      // Počítadlo: unique case pre one-hot pokrytie
      unique case ({do_write, do_read})
        2'b10:   count_q <= count_q + 1'b1;
        2'b01:   count_q <= count_q - 1'b1;
        default: ;  // 2'b00 alebo 2'b11 (simultánny push+pop) → bez zmeny
      endcase

    end
  end

  // ── Simulačné kontroly ────────────────────────────────────────
  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n && !flush) begin
      if (w_valid && !w_ready)
        $error("[%0t] %m: FIFO OVERFLOW! count=%0d DEPTH=%0d",
               $time, count_q, DEPTH);
      // r_ready=1 pri prázdnej FIFO je povolené (konzument môže mať TREADY
      // trvalo HIGH). Skutočný underflow = r_valid=1 ale count=0 (bug vo logike).
      if (r_valid && count_q == '0)
        $error("[%0t] %m: FIFO r_valid=1 ale count=0 – interný bug!",
               $time);
    end
  end
  // synthesis translate_on

endmodule : xfcp_fifo

`endif  // XFCP_FIFO_SV
