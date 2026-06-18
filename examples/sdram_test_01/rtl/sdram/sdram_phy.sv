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
 * PIPELINE LATENCIA (od read_en_in po dq_i_valid):
 *   read_en_in → clk_sh reg(1) → valid_pipe_sh[CAS_LATENCY+1:0] → capture → clk reg(1)
 *   Celková latencia: CAS_LATENCY + 2 clk cyklov
 *   read_engine PIPE_LEN = CAS_LATENCY + 2
 *
 * PLL KONFIGURÁCIA (Quartus IP Catalog → ALTPLL):
 *   c0: 100 MHz, phase = 0°    → clk (systémový)
 *   c1: 100 MHz, phase = 90°   → clk_sh (sdram_clk forwarding)
 *   SDC: create_generated_clock pre oba výstupy
 */

`ifndef SDRAM_PHY_SV
`define SDRAM_PHY_SV

`default_nettype none
import sdram_pkg::*;

module sdram_phy #(
  parameter int DATA_WIDTH      = 16,
  parameter int ROW_ADDR_WIDTH  = 13,
  parameter int BANK_ADDR_WIDTH = 2,
  parameter int CAS_LATENCY     = 3,
  parameter bit USE_ALTIOBUF    = 0   // 0=inferovaný tristate, 1=altiobuf primitív
)(
  input  wire clk,
  input  wire clk_sh,
  input  wire rstn,

  input  wire phy_cmd_e                  phy_cmd,
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
  // DDR output: datain_h=1, datain_l=0 → výstup je 1 v prvej polovici,
  // 0 v druhej → efektívne forwarded clock so správnym duty cycle.
  // Quartus timing analyzer vidí pin ako clock output a správne constraintuje.
  //
  // Pre simuláciu: ALTDDIO_OUT nie je dostupný v Questa bez Altera lib.
  // Preto synthesis translate_off blok poskytuje simulačný náhradník.
  // --------------------------------------------------------------------------
  // synthesis translate_off
  assign sdram_clk = clk_sh;
  // synthesis translate_on

  // synthesis translate_off
  // Simulačný blok — pri syntéze je nahradený ALTDDIO_OUT nižšie
  // (Questa nepoužíva primitívy, assign vyššie funguje pre sim)
  // synthesis translate_on

  generate
    // synthesis translate_off
    // Quartus synthesis ignoruje tento blok a používa ALTDDIO_OUT dole
    // synthesis translate_on
  endgenerate

`ifndef SYNTHESIS
  // Simulácia: assign je dostačujúci (definovaný vyššie)
`else
  // Syntéza: ALTDDIO_OUT pre správny clock forwarding
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
  // Command register
  // --------------------------------------------------------------------------
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
  // CDC: read_en clk → clk_sh (1 register)
  // clk a clk_sh majú rovnakú frekvenciu, len fázový posun 90°.
  // Metastabilita nehrozí — 1 register je dostatočný.
  // SDC: set_false_path -from [get_clocks clk] -to [get_clocks clk_sh]
  // --------------------------------------------------------------------------
  logic read_en_sh;
  always_ff @(posedge clk_sh or negedge rstn) begin
    if (!rstn) read_en_sh <= 1'b0;
    else       read_en_sh <= read_en_in;
  end

  // --------------------------------------------------------------------------
  // CAS Latency Pipeline (clk_sh doména)
  // valid_pipe_sh: CAS_LATENCY+2 stupňov
  // Vydanie po CAS_LATENCY+2 clk_sh cykloch od read_en_sh
  // --------------------------------------------------------------------------
  logic [CAS_LATENCY+1:0] valid_pipe_sh;
  logic [DATA_WIDTH-1:0]  dq_capture_sh;
  logic                   dq_valid_sh;

  always_ff @(posedge clk_sh or negedge rstn) begin
    if (!rstn) begin
      valid_pipe_sh <= '0;
      dq_capture_sh <= '0;
      dq_valid_sh   <= 1'b0;
    end else begin
      valid_pipe_sh <= {valid_pipe_sh[CAS_LATENCY:0], read_en_sh};
      dq_valid_sh   <= valid_pipe_sh[CAS_LATENCY+1];
      if (valid_pipe_sh[CAS_LATENCY+1])
        dq_capture_sh <= sdram_dq;  // Inferovaný tristate alebo altiobuf výstup
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
