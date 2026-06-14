/**
 * @file  xfcp_fifo_reg.sv
 * @brief Synchronous FIFO s registrovanym M9K vystupom (DEPTH >= 2).
 *
 * @details
 *   Na rozdiel od xfcp_fifo (fall-through) tento modul drzi r_data v
 *   registrovanom vystupnom buffri (out_reg_q, inferovany ako M9K output reg).
 *   Kriticka cesta:
 *
 *     rd_ptr_q (FF) -> M9K adresa -> M9K output reg -> out_reg_q : 2-4 ns
 *
 *   namiesto xfcp_fifo:
 *
 *     rd_ptr_q (FF) -> kombinacny mux -> r_data (wire) : az 8-9 ns pre DEPTH=256
 *
 *   Protokol r_valid/r_ready je rovnaky ako xfcp_fifo.
 *   r_data je platne ked r_valid=1 a ostava stabilne az do r_ready=1.
 *
 *   Latencia: 2 cykly od prvej citary do platneho r_valid (write-to-read, empty FIFO).
 *   Pre loopback / batch prenos (write a read sa neprekryvaju) toto nie je problem.
 *
 *   do_prefetch podmienka obsahuje !prefetch_q: zabranuje dvojitemu posunutiu
 *   rd_ptr v po sebe iducich cykloch, kym out_valid_q este nebol nastaveny.
 *   out_reg_q sa aktualizuje JEDINE ked do_prefetch=1 (M9K output register enable),
 *   cim sa zabrani prepisu platnych dat pri necitajucom receiveri.
 *
 * @param DATA_WIDTH  Sirka datoveho slova.
 * @param DEPTH       Hlbka FIFO (pocet slov v pamati; celkova kapacita = DEPTH).
 */

`ifndef XFCP_FIFO_REG_SV
`define XFCP_FIFO_REG_SV

`default_nettype none

module xfcp_fifo_reg #(
  parameter int DATA_WIDTH = 32,
  parameter int DEPTH      = 64
)(
  input  wire                  clk,
  input  wire                  rst_n,
  input  wire                  flush,

  // Write port
  input  wire [DATA_WIDTH-1:0] w_data,
  input  wire                  w_valid,
  output wire                  w_ready,

  // Read port (registered output, 1-cycle M9K latency)
  output logic [DATA_WIDTH-1:0] r_data,
  output logic                  r_valid,
  input  wire                   r_ready
);

  // synthesis translate_off
  initial begin
    if (DEPTH < 2)
      $fatal(1, "%m: xfcp_fifo_reg DEPTH musi byt >= 2, got %0d", DEPTH);
  end
  // synthesis translate_on

  localparam int PTR_W   = $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);

  // ── Pamat (M9K) ──────────────────────────────────────────────
  (* ramstyle = "M9K" *)
  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

  // ── Pointre a pocitadlo ───────────────────────────────────────
  logic [PTR_W-1:0]   wr_ptr_q;
  logic [PTR_W-1:0]   rd_ptr_q;    // adresa pre M9K read (posunie sa pri do_prefetch)
  logic [COUNT_W-1:0] count_q;     // pocet poloziek v pamati (nie v out_reg)

  // ── Vystupny buffer ───────────────────────────────────────────
  logic [DATA_WIDTH-1:0] out_reg_q;   // M9K registered output (platne ked out_valid_q=1)
  logic                  out_valid_q; // out_reg_q obsahuje platne data pre consumer
  logic                  prefetch_q;  // minuly cyklus bolo vydane M9K citanie

  // ── Pomocna funkcia: bezpecny wrap ───────────────────────────
  function automatic logic [PTR_W-1:0] ptr_inc(logic [PTR_W-1:0] p);
    return (p == PTR_W'(DEPTH - 1)) ? '0 : p + 1'b1;
  endfunction

  // ── Handshake signaly ─────────────────────────────────────────
  wire do_write = w_valid && w_ready;
  wire do_consume = out_valid_q && r_ready;

  // do_prefetch: vydaj M9K citanie na aktualny rd_ptr_q.
  // !prefetch_q: zabrani dvojitemu posunutiu rd_ptr ked out_valid_q este nie je 1
  //              (M9K ma 1-cyklovu latenciu, out_valid_q sa nastavi az nasledujuci cyklus).
  wire do_prefetch = (count_q > 0) && (!out_valid_q || do_consume) && !flush && !prefetch_q;

  assign w_ready = (count_q < COUNT_W'(DEPTH)) && !flush;

  // ── Zapisova logika ───────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr_q <= '0;
    end else if (flush) begin
      wr_ptr_q <= '0;
    end else if (do_write) begin
      mem[wr_ptr_q] <= w_data;
      wr_ptr_q      <= ptr_inc(wr_ptr_q);
    end
  end

  // ── M9K citanie: output register enable ──────────────────────
  // out_reg_q <= mem[rd_ptr_q] sa spusti JEDINE ked do_prefetch=1.
  // Quartus inferuje M9K s output register enable z tohto vzoru.
  // rd_ptr_q este nebol inkrementovany v tomto cykle (NB semantika),
  // takze M9K cita AKTUALNU hlavu fronty.
  always_ff @(posedge clk) begin
    if (do_prefetch)
      out_reg_q <= mem[rd_ptr_q];
  end

  // ── Riadenie rd_ptr a count ───────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_ptr_q   <= '0;
      count_q    <= '0;
      prefetch_q <= 1'b0;
    end else if (flush) begin
      rd_ptr_q   <= '0;
      count_q    <= '0;
      prefetch_q <= 1'b0;
    end else begin
      prefetch_q <= do_prefetch;

      if (do_prefetch)
        rd_ptr_q <= ptr_inc(rd_ptr_q);

      unique case ({do_write, do_prefetch})
        2'b10:   count_q <= count_q + 1'b1;
        2'b01:   count_q <= count_q - 1'b1;
        default: ;
      endcase
    end
  end

  // ── Vystupny buffer validity ──────────────────────────────────
  // flush is synchronous -- must be separated from async !rst_n to satisfy Quartus.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid_q <= 1'b0;
    end else begin
      if (flush)
        out_valid_q <= 1'b0;
      else if (prefetch_q)
        out_valid_q <= 1'b1;
      else if (do_consume)
        out_valid_q <= 1'b0;
    end
  end

  assign r_data  = out_reg_q;
  assign r_valid = out_valid_q;

  // ── Simulacne kontroly ────────────────────────────────────────
  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n && !flush) begin
      if (w_valid && !w_ready)
        $error("[%0t] %m: FIFO OVERFLOW! count=%0d DEPTH=%0d",
               $time, count_q, DEPTH);
    end
  end
  // synthesis translate_on

endmodule : xfcp_fifo_reg

`endif  // XFCP_FIFO_REG_SV
