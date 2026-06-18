/**
 * @file sdram_init.sv
 * @brief Inicializačný FSM pre SDR SDRAM.
 * @details Vykonáva: 200us Delay → PRE_ALL → 8x REF → MRS
 *
 * OPRAVY:
 *  [FIX-A10] PRE_ALL: pôvodný kód mal 13'b0010000000000 = bit[11]=1,
 *            ale JEDEC vyžaduje A10=1 pre Precharge All.
 *            Bit 10 = 13'h0400. Pôvodná hodnota aktivovala bit 11
 *            čo je undefined/reserved → model mohol ignorovať PRE_ALL.
 *
 *  [FIX-MRS] MODE_REG: explicitne zostavený z konštánt sdram_pkg
 *            namiesto hardcoded binary literálu. Zaručuje konzistenciu
 *            s CAS_LATENCY parametrom.
 *
 * MODE REGISTER (JEDEC SDR):
 *   bits [12:10] = 000  Reserved
 *   bit  [9]     = 0    Write Burst Mode (0=programmed, 1=single)
 *   bits [8:7]   = 00   Operating Mode (00=standard)
 *   bits [6:4]   = CAS  CAS Latency (011=3)
 *   bit  [3]     = 0    Burst Type (0=Sequential)
 *   bits [2:0]   = 000  Burst Length (000=1)
 */

`ifndef SDRAM_INIT_SV
`define SDRAM_INIT_SV
`default_nettype none

import sdram_pkg::*;

module sdram_init #(
  parameter int T_MRD_CYCLES       = 2,
  parameter int INIT_200US_CYCLES  = 20000,
  parameter int NUM_REFRESH        = 8
)(
  input  wire      clk,
  input  wire      rstn,
  output phy_cmd_e init_cmd,
  output logic [ROW_ADDR_WIDTH-1:0] init_addr,
  output logic     init_done,
  output logic     init_busy
);

  // --------------------------------------------------------------------------
  // Mode Register – zostavený z parametrov sdram_pkg
  // --------------------------------------------------------------------------
  localparam logic [ROW_ADDR_WIDTH-1:0] MODE_REG = ROW_ADDR_WIDTH'(
    (CAS_LATENCY[2:0] << 4)   // bits[6:4] = CAS Latency
  );
  // Burst Length=1 (000), Sequential (bit3=0), CAS=3 (011), Standard mode (00)
  // = 13'b000_0_00_011_0_000 = 13'h0030

  // --------------------------------------------------------------------------
  // FSM
  // --------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ST_RESET,
    ST_WAIT_200US,
    ST_PRECHARGE,
    ST_TRP_WAIT,
    ST_REFRESH,
    ST_TRFC_WAIT,
    ST_MRS,
    ST_TMRD_WAIT,
    ST_DONE
  } state_e;

  state_e       state;
  logic [15:0]  timer;
  logic [3:0]   refresh_cnt;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state       <= ST_RESET;
      timer       <= 16'(INIT_200US_CYCLES);
      refresh_cnt <= '0;
      init_done   <= 1'b0;
      init_busy   <= 1'b1;
      init_cmd    <= CMD_NOP;
      init_addr   <= '0;
    end else begin
      // Default: NOP každý cyklus kde stav nevydáva príkaz
      init_cmd  <= CMD_NOP;
      init_addr <= '0;

      case (state)

        ST_RESET: begin
          timer <= 16'(INIT_200US_CYCLES);
          state <= ST_WAIT_200US;
        end

        ST_WAIT_200US: begin
          if (timer == 0)
            state <= ST_PRECHARGE;
          else
            timer <= timer - 1;
        end

        ST_PRECHARGE: begin
          init_cmd  <= CMD_PRE;
          // [FIX-A10] A10=1 pre PRE_ALL: bit[10] = 13'h0400
          // Pôvodné 13'b0010000000000 = 0x0800 = bit[11] → CHYBA
          init_addr <= 13'h0400;
          timer     <= 16'(T_RP_CYCLES);
          state     <= ST_TRP_WAIT;
        end

        ST_TRP_WAIT: begin
          if (timer == 0)
            state <= ST_REFRESH;
          else
            timer <= timer - 1;
        end

        ST_REFRESH: begin
          init_cmd    <= CMD_REF;
          timer       <= 16'(T_RFC_CYCLES);
          refresh_cnt <= refresh_cnt + 1;
          state       <= ST_TRFC_WAIT;
        end

        ST_TRFC_WAIT: begin
          if (timer == 0)
            state <= (refresh_cnt >= 4'(NUM_REFRESH)) ? ST_MRS : ST_REFRESH;
          else
            timer <= timer - 1;
        end

        ST_MRS: begin
          init_cmd  <= CMD_MRS;
          init_addr <= MODE_REG;
          timer     <= 16'(T_MRD_CYCLES);
          state     <= ST_TMRD_WAIT;
        end

        ST_TMRD_WAIT: begin
          if (timer == 0)
            state <= ST_DONE;
          else
            timer <= timer - 1;
        end

        ST_DONE: begin
          init_done <= 1'b1;
          init_busy <= 1'b0;
          // Terminálny stav – ostávame tu navždy
        end

        default: state <= ST_RESET;

      endcase
    end
  end

endmodule

`endif // SDRAM_INIT_SV
