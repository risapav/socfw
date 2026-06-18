/**
 * @file refresh_manager.sv
 * @brief SDRAM Refresh Generator s kreditným systémom
 *
 * @details
 * Tento modul generuje pravidelný požiadavok na Refresh (refresh_req) pre SDRAM.
 * Používa kreditný systém:
 *   • každých REFRESH_INTERVAL cyklov sa priradí nový kredit
 *   • scheduler si kredit "vezme" pomocou refresh_grant
 *
 * Tento prístup umožňuje:
 *   • bezpečné dodržanie tREFI
 *   • toleranciu krátkodobého zahltenia scheduleru
 *
 * Parametre:
 *   • REFRESH_INTERVAL     – počet taktov medzi kreditmi
 *   • MAX_REFRESH_CREDITS  – maximálny počet kumulovaných refreshov
 */

`ifndef REFRESH_MANAGER_SV
`define REFRESH_MANAGER_SV

`default_nettype none

module refresh_manager #(
  parameter int REFRESH_INTERVAL    = 780,  // tREFI v taktoch
  parameter int MAX_REFRESH_CREDITS = 8
)(
  input  wire clk,
  input  wire rstn,

  output logic refresh_req,   // signál pre scheduler
  input  wire refresh_grant   // grant od scheduleru (spotreba kreditu)
);

  // =====================================================
  // Šírka timeru a kreditov (dynamická)
  // =====================================================
  localparam TIMER_W  = $clog2(REFRESH_INTERVAL);
  localparam CREDIT_W = $clog2(MAX_REFRESH_CREDITS+1);

  // =====================================================
  // Interné registre
  // =====================================================
  logic [TIMER_W:0]  timer;           // periodický časovač
  logic [CREDIT_W:0] refresh_credit;  // kumulované kredity

  // =====================================================
  // TIMER – generuje nový kredit každých REFRESH_INTERVAL cyklov
  // =====================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn)
      timer <= 0;
    else if (timer == REFRESH_INTERVAL-1)
      timer <= 0;
    else
      timer <= timer + 1;
  end

  // =====================================================
  // CREDIT GENERATION a SPOTREBA
  // =====================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn)
      refresh_credit <= 0;
    else begin
      // GENEROVANIE KREDITU
      if (timer == REFRESH_INTERVAL-1) begin
        if (refresh_credit < MAX_REFRESH_CREDITS)
          refresh_credit <= refresh_credit + 1;
      end

      // SPOTREBA KREDITU
      if (refresh_grant && refresh_credit != 0)
        refresh_credit <= refresh_credit - 1;
    end
  end

  // =====================================================
  // REFRESH REQUEST
  // =====================================================
  assign refresh_req = (refresh_credit != 0);

endmodule

`endif // REFRESH_MANAGER_SV
