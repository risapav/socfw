/**
 * @file sdram_model_pro.sv
 * @brief Profesionálny SDR SDRAM behavioral model pre simuláciu
 *
 * Vlastnosti:
 *  - JEDEC timing checky (tRCD, tRP, tRAS, tWR, tRFC)
 *  - CAS latency pipeline (presne CL cyklov)
 *  - bank-interleaved memory addressing
 *  - associative memory (žiadny limit veľkosti, žiadny aliasing)
 *  - kompatibilné s Questa / Verilator
 *
 * OPRAVA [vlog-60]:
 *  Associative array zápis musí byť blokovacie priradenie (=),
 *  nie NBA (<=). Questa nepodporuje NBA na asociatívne polia.
 */

`timescale 1ns/1ps
// synthesis translate_off
// Tento modul je VÝLUČNE pre simuláciu — NIKDY ho nesyntézuj!
// Neobsahuje sa v rtl filelist, len v sim filelist.
`default_nettype none

module sdram_model_pro #(

  parameter DATA_WIDTH = 16,
  parameter ROW_WIDTH  = 13,
  parameter COL_WIDTH  = 9,
  parameter BANKS      = 4,

  // timing (clock cycles)
  parameter tRCD = 2,
  parameter tRP  = 2,
  parameter tRAS = 4,
  parameter tWR  = 2,
  parameter tRFC = 7,

  parameter CL   = 3

)(
  input  wire                  clk,
  input  wire                  rst,

  input  wire [ROW_WIDTH-1:0]  addr,
  input  wire [1:0]            ba,

  input  wire                  ras_n,
  input  wire                  cas_n,
  input  wire                  we_n,
  input  wire                  cs_n,

  inout  wire [DATA_WIDTH-1:0] dq
);

  // ================================================================
  // MEMORY STORAGE (associative — žiadny aliasing, žiadna fixná veľkosť)
  // ================================================================

  logic [DATA_WIDTH-1:0] mem [int];

  // ================================================================
  // ADDRESS MAPPING
  // Každá (ba, row, col) kombinacia má unikátny kľúč
  // ================================================================

  function automatic int mem_addr(
    input logic [1:0]            ba,
    input logic [ROW_WIDTH-1:0]  row,
    input logic [COL_WIDTH-1:0]  col
  );
    return int'(ba)  * (1 << ROW_WIDTH) * (1 << COL_WIDTH)
         + int'(row) * (1 << COL_WIDTH)
         + int'(col);
  endfunction

  // ================================================================
  // BANK STATE
  // ================================================================

  typedef struct packed {
    logic open;
    logic [ROW_WIDTH-1:0] row;
    int rcd_timer;
    int ras_timer;
    int rp_timer;
    int wr_timer;
  } bank_state_t;

  bank_state_t bank [BANKS];
  int          rfc_timer;

  // ================================================================
  // DQ BUS
  // ================================================================

  logic [DATA_WIDTH-1:0] dq_out;
  logic                  dq_drive;

  assign dq = dq_drive ? dq_out : 'z;

  // ================================================================
  // CAS LATENCY PIPELINE
  // CL+1 stupňov → výstup z cas_pipe[CL] = CL cyklov latencie
  // ================================================================

  typedef struct packed {
    logic                  valid;
    logic [DATA_WIDTH-1:0] data;
  } cas_stage_t;

  cas_stage_t cas_pipe [CL+1];

  // ================================================================
  // COMMAND DECODER
  // ================================================================

  wire cmd_active = (!cs_n && !ras_n &&  cas_n &&  we_n);
  wire cmd_pre    = (!cs_n && !ras_n &&  cas_n && !we_n);
  wire cmd_read   = (!cs_n &&  ras_n && !cas_n &&  we_n);
  wire cmd_write  = (!cs_n &&  ras_n && !cas_n && !we_n);
  wire cmd_ref    = (!cs_n && !ras_n && !cas_n &&  we_n);

  // ================================================================
  // MAIN LOGIC
  // ================================================================

  always_ff @(posedge clk) begin

    int mem_index;

    if (rst) begin

      dq_drive  <= 0;
      rfc_timer <= 0;

      for (int b = 0; b < BANKS; b++) begin
        bank[b].open      <= 0;
        bank[b].rcd_timer <= 0;
        bank[b].ras_timer <= 0;
        bank[b].rp_timer  <= 0;
        bank[b].wr_timer  <= 0;
      end

      for (int i = 0; i <= CL; i++) begin
        cas_pipe[i].valid <= 0;
        cas_pipe[i].data  <= 0;
      end

    end else begin

      dq_drive <= 0;

      // ------------------------------------------------------------
      // Timer decrement
      // ------------------------------------------------------------

      if (rfc_timer > 0) rfc_timer--;

      for (int b = 0; b < BANKS; b++) begin
        if (bank[b].rcd_timer > 0) bank[b].rcd_timer--;
        if (bank[b].ras_timer > 0) bank[b].ras_timer--;
        if (bank[b].rp_timer  > 0) bank[b].rp_timer--;
        if (bank[b].wr_timer  > 0) bank[b].wr_timer--;
      end

      // ------------------------------------------------------------
      // CAS pipeline shift
      // ------------------------------------------------------------

      for (int i = CL; i > 0; i--)
        cas_pipe[i] <= cas_pipe[i-1];

      cas_pipe[0].valid <= 0;

      // Výstup posledného stupňa
      if (cas_pipe[CL].valid) begin
        dq_out   <= cas_pipe[CL].data;
        dq_drive <= 1;
      end

      // ------------------------------------------------------------
      // Command execution
      // ------------------------------------------------------------

      if (!cs_n) begin

        // ACTIVE
        if (cmd_active) begin
          if (rfc_timer > 0)       $error("[SDRAM] ACTIVE during tRFC");
          if (bank[ba].open)       $error("[SDRAM] ACTIVE on open bank B%0d", ba);
          if (bank[ba].rp_timer>0) $error("[SDRAM] tRP violation B%0d", ba);

          bank[ba].open      <= 1;
          bank[ba].row       <= addr;
          bank[ba].rcd_timer <= tRCD;
          bank[ba].ras_timer <= tRAS;
        end

        // PRECHARGE
        if (cmd_pre) begin
          if (addr[10]) begin
            for (int b = 0; b < BANKS; b++) begin
              if (bank[b].open) begin
                if (bank[b].ras_timer > 0) $error("[SDRAM] tRAS violation PRE_ALL");
                if (bank[b].wr_timer  > 0) $error("[SDRAM] tWR  violation PRE_ALL");
                bank[b].open     <= 0;
                bank[b].rp_timer <= tRP;
              end
            end
          end else begin
            if (!bank[ba].open) $warning("[SDRAM] PRE on closed bank B%0d", ba);
            bank[ba].open     <= 0;
            bank[ba].rp_timer <= tRP;
          end
        end

        // REFRESH
        if (cmd_ref) begin
          for (int b = 0; b < BANKS; b++)
            if (bank[b].open) $error("[SDRAM] REFRESH with open bank B%0d", b);
          rfc_timer <= tRFC;
        end

        // READ / WRITE
        if (cmd_read || cmd_write) begin
          if (!bank[ba].open)      $error("[SDRAM] RD/WR on closed bank B%0d", ba);
          if (bank[ba].rcd_timer>0)$error("[SDRAM] tRCD violation B%0d", ba);


          mem_index = mem_addr(ba, bank[ba].row, addr[COL_WIDTH-1:0]);

          if (cmd_read) begin
            cas_pipe[0].valid <= 1;
            cas_pipe[0].data  <= mem[mem_index];
          end else begin
            // [vlog-60] Blokovacie priradenie pre associative array
            mem[mem_index]     = dq;
            bank[ba].wr_timer <= tWR;
          end

          // Auto-precharge (A10)
          if (addr[10]) begin
            bank[ba].open     <= 0;
            bank[ba].rp_timer <= tRP;
          end
        end

      end
    end
  end

endmodule
// synthesis translate_on
