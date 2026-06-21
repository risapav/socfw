/**
 * @file sdram_phy.sv
 * @brief SDR SDRAM PHY — Quartus 25.1 syntetizovateľná verzia.
 *
 * OPRAVY PRE SYNTÉZU (v170):
 *  [F3] sdram_clk: priame assign clk_sh nahradené ALTDDIO_OUT primitívom.
 *       Quartus vyžaduje DDR output buffer pre forwarded clock pin.
 *       Bez neho: "Clock is not properly constrained" a timing violations.
 *
 *  [F4] sdram_dq tristate: Quartus inferuje IOBUF automaticky z
 *       assign sdram_dq = dq_oe ? dq_o : 'z
 *       Explicitný altiobuf je dostupný cez USE_ALTIOBUF parameter
 *       (USE_ALTIOBUF=0 = inferovaný tristate, USE_ALTIOBUF=1 = primitív).
 *
 * PIPELINE LATENCIA (od READ cmd po dq_i_valid, v CLK125_SH cykloch):
 *   read_det (kombinacny, z NBA sdram_cs_n) → valid_pipe_sh capture na pipe[READ_IDX]
 *   → dq_capture_sh (CLK125_SH) → dq_i (CLK reg)
 *   READ_IDX = CAS_LATENCY + READ_CAPTURE_SHIFT (default: CL-1 = N+4 capture).
 *   Celkova latencia dq_i_valid: CAS_LATENCY + 2 CLK cyklov (zachovane pre SHIFT=-1).
 *   read_engine PIPE_LEN = CAS_LATENCY + 2
 *
 * PLL KONFIGURÁCIA (Quartus IP Catalog → ALTPLL):
 *   c0: 125 MHz, phase = 0°    → clk (systémový)
 *   c1: 125 MHz, phase = 90°   → clk_sh (sdram_clk forwarding)
 *   SDC: create_generated_clock pre oba výstupy
 */

`ifndef SDRAM_PHY_SV
`define SDRAM_PHY_SV

`default_nettype none

`include "sdram_build_cfg.svh"

import sdram_pkg::*;

module sdram_phy #(
  parameter int DATA_WIDTH      = 16,
  parameter int ROW_ADDR_WIDTH  = 13,
  parameter int BANK_ADDR_WIDTH = 2,
  parameter int CAS_LATENCY          = 3,
  parameter int READ_CAPTURE_SHIFT   = `SDRAM_BUILD_READ_CAPTURE_SHIFT,
  parameter bit CMD_REG_ON_CLK_SH    = `SDRAM_BUILD_CMD_REG_ON_CLK_SH,
  parameter bit USE_ALTIOBUF         = 0
)(
  input  wire clk,
  input  wire clk_sh,
  input  wire rstn,

  input  wire [3:0]                      phy_cmd,  // phy_cmd_e
  input  wire [ROW_ADDR_WIDTH-1:0]       addr_in,
  input  wire [BANK_ADDR_WIDTH-1:0]      ba_in,
  input  wire                            read_en_in,

  input  wire [DATA_WIDTH-1:0]           dq_o,
  input  wire                            dq_oe,

  output logic [DATA_WIDTH-1:0]          dq_i,
  output logic                           dq_i_valid,
  output logic                           phy_wready,

  output logic [ROW_ADDR_WIDTH-1:0]      sdram_addr,
  output logic [BANK_ADDR_WIDTH-1:0]     sdram_ba,
  output logic                           sdram_ras_n,
  output logic                           sdram_cas_n,
  output logic                           sdram_we_n,
  output logic                           sdram_cs_n,
  inout  wire  [DATA_WIDTH-1:0]          sdram_dq,
  output wire                            sdram_clk,   // wire, nie logic — DDR primitív
  output logic                           sdram_cke
);

  assign sdram_cke = 1'b1;

  // --------------------------------------------------------------------------
  // [F3] SDRAM Clock Output — ALTDDIO_OUT
  //
  // DDR output: datain_h=1, datain_l=0 → forwarded clock, duty cycle 50%.
  // Quartus timing analyzer vidí pin ako clock output.
  //
  // Simulácia: +define+SIM aktivuje priamy assign (Questa bez Altera lib).
  // Syntéza:   ALTDDIO_OUT primitív (Quartus 25.1 Lite, Cyclone IV E).
  // --------------------------------------------------------------------------
`ifdef SIM
  assign sdram_clk = clk_sh;
`else
  altddio_out #(
    .extend_oe_disable      ("OFF"),
    .intended_device_family ("Cyclone IV E"),
    .invert_output          ("OFF"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_out"),
    .oe_reg                 ("UNREGISTERED"),
    .power_up_high          ("OFF"),
    .width                  (1)
  ) u_sdram_clk_ddr (
    .datain_h   (1'b1),
    .datain_l   (1'b0),
    .outclock   (clk_sh),
    .dataout    (sdram_clk),
    .aclr       (1'b0),
    .aset       (1'b0),
    .oe         (1'b1),
    .oe_out     (),
    .outclocken (1'b1),
    .sclr       (1'b0),
    .sset       (1'b0)
  );
`endif

  // --------------------------------------------------------------------------
  // Command register — clocked by clk_sh (CMD_REG_ON_CLK_SH=1) or clk (=0).
  // CMD_REG_ON_CLK_SH=1: CMD FF on CLK125_SH (+90deg), SDRAM_CLK same phase.
  //   STA: CLK125_SH -> IO has IO skew (-4.5ns on Cyclone IV) -> may violate slow corner.
  // CMD_REG_ON_CLK_SH=0: CMD FF on CLK125 (0deg), SDRAM_CLK from CLK125_SH (+90deg).
  //   Classic board-level setup: CMD launches at 0deg, SDRAM samples at 90deg = +2ns later.
  //   STA: CLK125 -> IO has better skew -> closed at slow 85C.
  // read_det fires 1 clk_sh cycle after CMD captured in clk_sh domain.
  // --------------------------------------------------------------------------
  generate
    if (CMD_REG_ON_CLK_SH) begin : g_cmd_clksh
      always_ff @(posedge clk_sh or negedge rstn) begin
        if (!rstn) begin
          {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= 4'b1111;
          sdram_addr <= '0;
          sdram_ba   <= '0;
        end else begin
          {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= phy_cmd;
          sdram_addr <= addr_in;
          sdram_ba   <= ba_in;
        end
      end
    end else begin : g_cmd_clk
      always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
          {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= 4'b1111;
          sdram_addr <= '0;
          sdram_ba   <= '0;
        end else begin
          {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= phy_cmd;
          sdram_addr <= addr_in;
          sdram_ba   <= ba_in;
        end
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // [F4] DQ Tristate
  //
  // USE_ALTIOBUF=0: Quartus inferuje IOBUF automaticky — funguje pre väčšinu
  //   prípadov. Jednoduchšie, ale menej kontroly nad IO štandardom.
  //
  // USE_ALTIOBUF=1: Explicitný altiobuf primitív — odporúčané pre produkciu.
  //   Umožňuje nastaviť IO štandard (3.3V LVTTL/LVCMOS) a slew rate priamo
  //   v RTL namiesto v Quartus Pin Planner.
  // --------------------------------------------------------------------------
  generate
    if (!USE_ALTIOBUF) begin : g_tristate_infer
      // Inferovaný tristate — Quartus vytvorí IOBUF automaticky
      logic [DATA_WIDTH-1:0] dq_in_w;
      assign sdram_dq = dq_oe ? dq_o : 'z;
      assign dq_in_w  = sdram_dq;

      // Registrovaný vstup (vzorkovanie v clk_sh doméne — viď pipeline nižšie)
      // dq_in_w je priamo napojený na pipeline
    end else begin : g_altiobuf
      // Explicitný altiobuf — nastaviť io_standard podľa PCB (typicky "3.3-V LVTTL")
      altiobuf #(
        .io_standard      ("3.3-V LVTTL"),
        .number_of_channels (DATA_WIDTH),
        .open_drain_output  ("NO"),
        .operation_mode     ("BIDIR_SINGLE_OUTPUT"),
        .output_current_strength ("MAXIMUM CURRENT")
      ) u_dq_buf (
        .dataio  (sdram_dq),
        .oe      ({DATA_WIDTH{dq_oe}}),
        .datain  (dq_o),
        .dataout (/* dq_in — pozri poznámku */)
        // Poznámka: altiobuf.dataout je kombinačný výstup (pred clk_sh registrom)
        // Napoj na vstup CAS pipeline nižšie ak USE_ALTIOBUF=1
      );
    end
  endgenerate

  // --------------------------------------------------------------------------
  // READ detection v clk_sh domene — z registrovanych CMD vystupov PHY.
  //
  // DOVOD: read_en_in (z CLK125 schedulera) ma kratsi kombinacny path ako
  //   phy_cmd. Obidva su z rovnakeho CLK125 cyklu, ale phy_cmd sa zachyti
  //   v CLK125_SH o 1 cyklus neskor (Tcomb_cmd > Tcomb_re). Pouzitie
  //   read_en_in by spustilo pipeline 1 CLK125_SH cyklus priskoro ->
  //   capture pred DQ valid oknom.
  //
  //   Riesenie: read_det z uz-registrovanych sdram_cs_n/ras_n/cas_n/we_n
  //   (CLK125_SH FF). Tie sa aktualizuju v rovnakom cykle ako CMD register ->
  //   pipeline je vzdy synchronizovana s CMD, bez ohluadu na Tcomb_cmd.
  //
  // Casovanie (T_cmd = CLK125_SH cyklus zachytenia CMD_RD, 125 MHz, CL=3):
  //   T_cmd:    CMD register zachyti CMD_RD; sdram_cs_n/... -> NBA
  //   T_cmd+8:  read_det PRE-EDGE=1; pipeline bit[0] <- 1
  //   T_cmd+16: bit[1] <- 1
  //   T_cmd+24: bit[2] <- 1
  //   T_cmd+32: bit[3] PRE-EDGE=0 -> no capture; bit[3] <- 1
  //   T_cmd+40: bit[3] PRE-EDGE=1 -> CAPTURE
  //
  //   SDRAM vidi RD CMD pri SDRAM_CLK T_cmd+8.
  //   DQ valid: T_cmd+32 + tAC(5ns) = T_cmd+37 ns.
  //   DQ valid do: T_cmd+40 + tOH(3ns) = T_cmd+43 ns.
  //   DQ Hi-Z do: T_cmd+40 + tHZ(5ns) = T_cmd+45 ns.
  //   Capture pri T_cmd+40: setup = 3 ns > 0. OK.
  // --------------------------------------------------------------------------
  wire read_det = (!sdram_cs_n && sdram_ras_n && !sdram_cas_n && sdram_we_n);

  localparam int READ_IDX = CAS_LATENCY + READ_CAPTURE_SHIFT;

  // synthesis translate_off
  initial begin
    if (READ_IDX < 0 || READ_IDX > CAS_LATENCY + 1)
      $fatal(1, "sdram_phy: READ_IDX=%0d out of range [0..%0d]", READ_IDX, CAS_LATENCY + 1);
  end
  // synthesis translate_on

  logic [CAS_LATENCY+1:0] valid_pipe_sh;
  logic [DATA_WIDTH-1:0] dq_capture_sh;
  logic                  dq_valid_sh;

  always_ff @(posedge clk_sh or negedge rstn) begin
    if (!rstn) begin
      valid_pipe_sh <= '0;
      dq_capture_sh <= '0;
      dq_valid_sh   <= 1'b0;
    end else begin
      valid_pipe_sh <= {valid_pipe_sh[CAS_LATENCY:0], read_det};
      dq_valid_sh   <= valid_pipe_sh[READ_IDX];
      if (valid_pipe_sh[READ_IDX])
        dq_capture_sh <= sdram_dq;
    end
  end

  // --------------------------------------------------------------------------
  // Synchronizácia dát späť do clk domény (1 register)
  // SDC: set_false_path -from [get_clocks clk_sh] -to [get_clocks clk]
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      dq_i       <= '0;
      dq_i_valid <= 1'b0;
    end else begin
      dq_i       <= dq_capture_sh;
      dq_i_valid <= dq_valid_sh;
    end
  end

  assign phy_wready = 1'b1;

endmodule

`default_nettype wire
`endif // SDRAM_PHY_SV
