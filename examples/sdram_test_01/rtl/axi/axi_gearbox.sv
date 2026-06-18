/**
 * @file axi_gearbox.sv
 * @brief Spoločný gearbox modul pre 32-bit AXI → 2x 16-bit SDRAM príkazy.
 *
 * Funkcia:
 *  Každý 32-bit AXI beat (write alebo read) sa rozloží na dva 16-bit SDRAM
 *  príkazy: fáza 0 (col) a fáza 1 (col+1). Modul spravuje AW/AR channel
 *  handshake, burst počítadlo a generuje sdram_cmd_t pre cmd_fifo.
 *
 * Parametre:
 *  ID_WIDTH   — šírka AXI ID
 *  WRITE_MODE — 1 = write engine (čaká na s_valid pred GS_PHASE0)
 *               0 = read frontend (ide do GS_PHASE0 okamžite z aw_active)
 *
 * Rozdiely medzi write a read módom:
 *  Write: GS_IDLE čaká na s_valid (s_axi_wvalid) aby latchol dáta
 *         Exponuje s_ready (s_axi_wready) — aktívne v GS_IDLE
 *         Exponuje data_out, data_phase pre write_engine data FIFO
 *  Read:  GS_IDLE prechádza do GS_PHASE0 okamžite keď aw_active
 *         s_ready nie je potrebný (AR channel má vlastný ready)
 *         data_out/data_phase nepoužívané
 *
 * Použitie:
 *  write_engine:  axi_gearbox #(.WRITE_MODE(1)) i_gb (...)
 *  axi_frontend:  axi_gearbox #(.WRITE_MODE(0)) i_gb (...)
 */

`ifndef AXI_GEARBOX_SV
`define AXI_GEARBOX_SV

`default_nettype none

import sdram_pkg::*;

module axi_gearbox #(
  parameter int ID_WIDTH   = AXI_ID_WIDTH,
  parameter bit WRITE_MODE = 1  // 1=write, 0=read
)(
  input  wire  clk,
  input  wire  rstn,

  // ==========================================================================
  // AXI Address Channel (AW pre write, AR pre read — rovnaké signály)
  // ==========================================================================
  input  wire [31:0]           s_addr,     // awaddr / araddr
  input  wire [7:0]            s_len,      // awlen  / arlen
  input  wire [ID_WIDTH-1:0]   s_id,       // awid   / arid
  input  wire                  s_avalid,   // awvalid / arvalid
  output logic                 s_aready,   // awready / arready

  // ==========================================================================
  // Write data channel (len WRITE_MODE=1, inak ignorované)
  // ==========================================================================
  input  wire [AXI_DATA_WIDTH-1:0] s_data,   // wdata
  input  wire                      s_wlast,  // wlast
  input  wire                      s_valid,  // wvalid
  output logic                     s_ready,  // wready (aktívne v GS_IDLE)

  // ==========================================================================
  // Command output → cmd_fifo
  // ==========================================================================
  output sdram_cmd_t  m_cmd,
  output logic        m_valid,
  input  wire         m_ready,

  // ==========================================================================
  // Gearbox status — pre rodičovský modul
  // ==========================================================================
  output logic        phase1_done,   // pulz: GS_PHASE1 && m_ready (beat hotový)
  output logic        is_phase1,     // 1 keď sme v GS_PHASE1
  output logic        is_idle,       // 1 keď sme v GS_IDLE

  // ==========================================================================
  // Write data výstup (len WRITE_MODE=1)
  // Rodičovský modul (write_engine) používa tieto signály pre data FIFO push
  // ==========================================================================
  output logic [AXI_DATA_WIDTH-1:0] data_latch_out,  // latchnuté wdata
  output logic                      last_latch_out    // latchnutý wlast
);

  // ==========================================================================
  // Typedef — pred AW channel blokom (Questa vlog-2730)
  // ==========================================================================
  typedef enum logic [1:0] {
    GS_IDLE,
    GS_PHASE0,
    GS_PHASE1
  } gear_state_e;

  gear_state_e gear_state;

  // ==========================================================================
  // AW/AR channel — burst tracking
  // ==========================================================================
  logic        aw_active;
  logic [8:0]  aw_burst_cnt;   // 9-bit: write používa cnt-1, read používa cnt
  logic [31:0] aw_addr_reg;
  logic [ID_WIDTH-1:0] aw_id_reg;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      aw_active    <= 1'b0;
      aw_burst_cnt <= '0;
      aw_addr_reg  <= '0;
      aw_id_reg    <= '0;
      s_aready     <= 1'b1;
    end else begin
      if (s_avalid && s_aready) begin
        aw_active    <= 1'b1;
        // Write: burst_cnt = len+1 (počet beatov)
        // Read:  burst_cnt = len   (dekrementuje inak)
        aw_burst_cnt <= WRITE_MODE ? ({1'b0, s_len} + 9'd1) : {1'b0, s_len};
        aw_addr_reg  <= s_addr;
        aw_id_reg    <= s_id;
        s_aready     <= 1'b0;
      end else if (aw_active && gear_state == GS_PHASE1 && m_ready) begin
        aw_addr_reg <= aw_addr_reg + 32'd4;
        if (WRITE_MODE) begin
          // Write: dekrementuj od len+1 → 0
          if (aw_burst_cnt == 9'd1) begin
            aw_active <= 1'b0;
            s_aready  <= 1'b1;
          end
          aw_burst_cnt <= aw_burst_cnt - 9'd1;
        end else begin
          // Read: dekrementuj od len → 0
          if (aw_burst_cnt == 8'd0) begin
            aw_active <= 1'b0;
            s_aready  <= 1'b1;
          end else
            aw_burst_cnt <= aw_burst_cnt - 9'd1;
        end
      end
    end
  end

  // ==========================================================================
  // Gearbox FSM — latch adresy a dát pri prechode GS_IDLE→GS_PHASE0
  // ==========================================================================
  logic [31:0]  addr_latch;
  logic [8:0]   beat_cnt_latch;
  logic [AXI_DATA_WIDTH-1:0] data_latch;
  logic         last_latch;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      gear_state     <= GS_IDLE;
      addr_latch     <= '0;
      beat_cnt_latch <= '0;
      data_latch     <= '0;
      last_latch     <= 1'b0;
    end else begin
      case (gear_state)

        GS_IDLE: begin
          // Write: čaká na wvalid aby latchol dáta
          // Read:  ide okamžite keď aw_active
          if (aw_active && (!WRITE_MODE || s_valid)) begin
            addr_latch     <= aw_addr_reg;
            beat_cnt_latch <= aw_burst_cnt;
            if (WRITE_MODE) begin
              data_latch <= s_data;
              last_latch <= s_wlast;
            end
            gear_state <= GS_PHASE0;
          end
        end

        GS_PHASE0: if (m_ready) gear_state <= GS_PHASE1;
        GS_PHASE1: if (m_ready) gear_state <= GS_IDLE;

      endcase
    end
  end

  // ==========================================================================
  // Výstupy
  // ==========================================================================

  // wready — aktívne len v GS_IDLE (write mode)
  assign s_ready = WRITE_MODE ? (aw_active && (gear_state == GS_IDLE)) : 1'b0;

  assign m_valid    = (gear_state == GS_PHASE0 || gear_state == GS_PHASE1);
  assign phase1_done = (gear_state == GS_PHASE1) && m_ready;
  assign is_phase1   = (gear_state == GS_PHASE1);
  assign is_idle     = (gear_state == GS_IDLE);

  // Write data pre rodičovský modul
  assign data_latch_out = data_latch;
  assign last_latch_out = last_latch;

  // sdram_cmd_t output
  always_comb begin
    m_cmd           = '0;
    m_cmd.write_en  = logic'(WRITE_MODE);
    m_cmd.id        = aw_id_reg;
    m_cmd.burst_len = 8'd0;
    m_cmd.addr.bank = addr_latch[BANK_BIT_HIGH:BANK_BIT_LOW];
    m_cmd.addr.row  = addr_latch[ROW_BIT_HIGH:ROW_BIT_LOW];
    m_cmd.addr.col  = addr_latch[COL_BIT_HIGH:COL_BIT_LOW]
                    + COL_ADDR_WIDTH'(gear_state == GS_PHASE1);
    m_cmd.last      = WRITE_MODE
                      ? (last_latch && (gear_state == GS_PHASE1))
                      : ((gear_state == GS_PHASE1) && (aw_burst_cnt == '0));
  end

endmodule
`endif
