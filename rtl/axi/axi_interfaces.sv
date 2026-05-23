/**
 * @file        axi_interfaces.sv
 * @brief       Definície AXI rozhraní (AXI4, AXI4-Lite, AXI4-Stream) pre použitie v SoC dizajne.
 * @details     Tento súbor obsahuje deklarácie troch rozhraní AXI štandardu:
 * - `axi4lite_if`: jednoduché register-based rozhranie bez burst prenosov
 * - `axi4_if`: plné AXI rozhranie s podporou burst prenosov, ID a out-of-order komunikácie
 * - `axi4s_if`: prúdové rozhranie bez adresácie, vhodné na vysokorýchlostný prenos dát
 *
 * Každé rozhranie obsahuje `modport` definície pre `master` a `slave`, ktoré
 * uľahčujú správne použitie a smerovanie signálov v dizajne.
 *
 * @param[in]   ADDR_WIDTH    Šírka adresy (v bitoch)
 * @param[in]   DATA_WIDTH    Šírka dátovej zbernice (v bitoch)
 * @param[in]   ID_WIDTH      Šírka identifikátora transakcie (len AXI4/AXI4-Stream)
 * @param[in]   LEN_WIDTH     Šírka poľa dĺžky burst prenosu (AXI4)
 * @param[in]   STRB_WIDTH    Šírka byte-masky (WSTRB, TKEEP)
 * @param[in]   USER_WIDTH    Šírka TUSER signálu (AXI4-Stream)
 * @param[in]   DEST_WIDTH    Šírka TDEST signálu (AXI4-Stream)
 *
 * @input       ACLK          Hodinový signál (všetky rozhrania)
 * @input       ARESETn       Asynchrónny reset, aktívny v nule
 *
 * @example
 * // Použitie v module:
 * module my_axi_peripheral (
 * input  logic clk,
 * input  logic rstn,
 * ...
 * );
 * import axi_pkg::*;
 * axi4lite_if #(.ADDR_WIDTH(16), .DATA_WIDTH(32)) axi_if (
 * .ACLK(clk),
 * .ARESETn(rstn)
 * );
 *
 * // Prístup k modportom:
 * assign axi_if.AWADDR = ...;
 * ...
 * endmodule
 */

`ifndef AXI_INTERFACES_SV
`define AXI_INTERFACES_SV

`default_nettype none

import axi_pkg::*;  // import package pred interface

//================================================================
// AXI4-Lite Interface
// Zjednodušená adresná zbernica pre prístup k registrom.
// Nepodporuje burst prenosy (viacnásobné prenosy na jednu adresu).
//================================================================

// AXI4-Lite supports only single-beat transactions (AWLEN/ARSIZE not present)
interface axi4lite_if #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 32,
    // Šírka WSTRB sa automaticky odvodzuje z DATA_WIDTH.
    // Každý bit v WSTRB zodpovedá jednému bajtu v WDATA.
    parameter int unsigned STRB_WIDTH = DATA_WIDTH / 8
    // NOTE: DATA_WIDTH must be a multiple of 8 to support WSTRB correctly
) (
    // NOTE: ACLK and ARESETn are provided for structural consistency.
    // The interface itself contains no sequential logic.
    input wire ACLK,    // Globálny hodinový signál
    input wire ARESETn  // Globálny asynchrónny reset, aktívny v nule
);

  // synthesis translate_off
  initial begin
    if (DATA_WIDTH % 8 != 0) $error("AXI4LITE DATA_WIDTH must be a multiple of 8");
  end
  // synthesis translate_on

  // --- Write Address Channel (AW) ---
  logic      [ADDR_WIDTH-1:0] AWADDR;  // Adresa pre zápis
  logic      [           2:0] AWPROT;  // Typ ochrany (napr. privilegovaný, bezpečný prístup)
  logic                       AWVALID;  // Master signalizuje platnú adresu a riadiace signály
  logic                       AWREADY;  // Slave signalizuje pripravenosť prijať adresu

  // --- Write Data Channel (W) ---
  logic      [DATA_WIDTH-1:0] WDATA;  // Zapisované dáta
  logic      [STRB_WIDTH-1:0] WSTRB;  // Maska bajtov (určuje, ktoré bajty v WDATA sú platné)
  logic                       WVALID;  // Master signalizuje platné dáta
  logic                       WREADY;  // Slave signalizuje pripravenosť prijať dáta

  // --- Write Response Channel (B) ---
  axi_resp_t                  BRESP;  // Odpoveď na zápis (OKAY, EXOKAY, SLVERR, DECERR)
  logic                       BVALID;  // Slave signalizuje platnú odpoveď
  logic                       BREADY;  // Master signalizuje pripravenosť prijať odpoveď

  // --- Read Address Channel (AR) ---
  logic      [ADDR_WIDTH-1:0] ARADDR;  // Adresa pre čítanie
  logic      [           2:0] ARPROT;
  logic                       ARVALID;  // Master signalizuje platnú adresu
  logic                       ARREADY;  // Slave signalizuje pripravenosť prijať adresu

  // --- Read Data Channel (R) ---
  logic      [DATA_WIDTH-1:0] RDATA;  // Čítané dáta
  axi_resp_t                  RRESP;  // Odpoveď na čítanie (status operácie)
  logic                       RVALID;  // Slave signalizuje platné dáta a odpoveď
  logic                       RREADY;  // Master signalizuje pripravenosť prijať dáta


  // Ak chceš použiť hodiny a reset priamo v interface
  modport master(
      input ACLK, ARESETn,
      output AWVALID, AWADDR, AWPROT, WVALID, WDATA, WSTRB, BREADY, ARVALID, ARADDR, ARPROT, RREADY,
      input AWREADY, WREADY, BVALID, BRESP, ARREADY, RVALID, RDATA, RRESP
  );

  // Modport definuje smer signálov z pohľadu Slave zariadenia
  modport slave(
      input ACLK, ARESETn,
      input AWVALID, AWADDR, AWPROT, WVALID, WDATA, WSTRB, BREADY, ARVALID, ARADDR, ARPROT, RREADY,
      output AWREADY, WREADY, BVALID, BRESP, ARREADY, RVALID, RDATA, RRESP
  );

endinterface


//================================================================
// AXI4-Full Interface
// Kompletná adresná zbernica s podporou burst prenosov,
// ID transakcií a out-of-order spracovania.
//================================================================

// NOTE: AWCACHE, AWPROT, AWLOCK omitted intentionally (simple AXI subset)
interface axi4_if #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned ID_WIDTH   = 4,
    parameter int unsigned LEN_WIDTH  = 8,
    // Šírka WSTRB sa automaticky odvodzuje z DATA_WIDTH.
    // Každý bit v WSTRB zodpovedá jednému bajtu v WDATA.
    parameter int unsigned STRB_WIDTH = DATA_WIDTH / 8
    // NOTE: DATA_WIDTH must be a multiple of 8 to support WSTRB correctly
) (
    input wire ACLK,
    input wire ARESETn
);

  // synthesis translate_off
  initial begin
    if (DATA_WIDTH % 8 != 0) $error("AXI4 DATA_WIDTH must be a multiple of 8");
  end
  // synthesis translate_on

  // --- Write Address Channel ---
  logic       [  ID_WIDTH-1:0] AWID;
  logic       [ADDR_WIDTH-1:0] AWADDR;
  logic       [ LEN_WIDTH-1:0] AWLEN;  // Dĺžka burstu (počet prenosov - 1). OPRAVENÉ
  axi_size_t                   AWSIZE;  // Veľkosť jedného prenosu (napr. 2^AWSIZE bajtov)
  axi_burst_t                  AWBURST;  // Typ burstu (FIXED, INCR, WRAP)
  logic                        AWVALID;
  logic                        AWREADY;

  // --- Write Data Channel ---
  logic       [DATA_WIDTH-1:0] WDATA;
  logic       [STRB_WIDTH-1:0] WSTRB;
  logic                        WLAST;  // Signalizuje posledný prenos v burst zápise
  logic                        WVALID;
  logic                        WREADY;

  // --- Write Response Channel ---
  logic       [  ID_WIDTH-1:0] BID;  // ID transakcie, na ktorú sa odpovedá
  axi_resp_t                   BRESP;
  logic                        BVALID;
  logic                        BREADY;

  // --- Read Address Channel ---
  logic       [  ID_WIDTH-1:0] ARID;
  logic       [ADDR_WIDTH-1:0] ARADDR;
  logic       [ LEN_WIDTH-1:0] ARLEN;  // Dĺžka burstu (počet prenosov - 1). OPRAVENÉ
  axi_size_t                   ARSIZE;
  axi_burst_t                  ARBURST;
  logic                        ARVALID;
  logic                        ARREADY;

  // --- Read Data Channel ---
  logic       [  ID_WIDTH-1:0] RID;
  logic       [DATA_WIDTH-1:0] RDATA;
  axi_resp_t                   RRESP;
  logic                        RLAST;  // Signalizuje posledný prenos v burst čítaní
  logic                        RVALID;
  logic                        RREADY;


  modport master(
      input ACLK, ARESETn,
      output AWID, AWADDR, AWLEN, AWSIZE, AWBURST, AWVALID,
               WDATA, WSTRB, WLAST, WVALID,
               BREADY,
               ARID, ARADDR, ARLEN, ARSIZE, ARBURST, ARVALID,
               RREADY,
      input AWREADY, WREADY, BID, BRESP, BVALID, ARREADY, RID, RDATA, RRESP, RLAST, RVALID
  );

  modport slave(
      input ACLK, ARESETn,
      input  AWID, AWADDR, AWLEN, AWSIZE, AWBURST, AWVALID,
               WDATA, WSTRB, WLAST, WVALID,
               BREADY,
               ARID, ARADDR, ARLEN, ARSIZE, ARBURST, ARVALID,
               RREADY,
      output AWREADY, WREADY, BID, BRESP, BVALID, ARREADY, RID, RDATA, RRESP, RLAST, RVALID
  );

endinterface


//================================================================
// AXI4-Stream Interface
// Neadresovaná, dátovo-orientovaná prúdová zbernica.
// Používa jednoduchý valid/ready handshake pre riadenie toku.
//================================================================
// Pomôcka pre prácu so štruktúrou z axi_pkg
// V module stačí:
// axi4s_payload_t p;
// assign p = {if.TLAST, if.TKEEP, if.TUSER, if.TDATA};
// NOTE: TKEEP is valid only when DATA_WIDTH >= 8
interface axi4s_if #(
    parameter int unsigned DATA_WIDTH = AXI_TDATA_WIDTH,
    parameter int unsigned USER_WIDTH = AXI_TUSER_WIDTH,
    parameter int unsigned KEEP_WIDTH = AXI_TKEEP_WIDTH,
    parameter int unsigned ID_WIDTH = 1,  // Quartus-safe
    parameter int unsigned DEST_WIDTH = 1
    // NOTE: ID_WIDTH and DEST_WIDTH must be >= 1 (Quartus does not support zero-width vectors)
) (
    input wire TCLK,
    input wire TRESETn
);

  // synthesis translate_off
  initial begin
    if (DATA_WIDTH % 8 != 0) $error("AXI4S DATA_WIDTH must be a multiple of 8");
  end
  // synthesis translate_on

  // Optional helper view for payload-based designs
  // axi4s_payload_t payload;
  // assign payload = '{TLAST, TKEEP, TUSER, TDATA};
  // NOTE: Field order must match axi4s_payload_t definition in axi_pkg

  // Hlavné signály pre riadenie toku a dáta
  logic                  TVALID;  // Master signalizuje platné dáta
  logic                  TREADY;  // Slave signalizuje pripravenosť prijať dáta
  logic [DATA_WIDTH-1:0] TDATA;  // Dátový payload

  // Voliteľné signály
  logic [KEEP_WIDTH-1:0] TKEEP;  // Maska bajtov, podobná WSTRB
  logic                  TLAST;  // Signalizuje posledné dáta v pakete/rámci
  logic [USER_WIDTH-1:0] TUSER;  // Používateľom definovaný postranný signál
  logic [  ID_WIDTH-1:0] TID;  // Identifikátor prúdu
  logic [DEST_WIDTH-1:0] TDEST;  // Cieľový identifikátor pre routing

  // Ak chceš použiť hodiny a reset priamo v interface
  modport master(
      input TCLK, TRESETn,
      output TVALID, TDATA, TLAST, TKEEP, TUSER, TID, TDEST,
      input TREADY
  );

  modport slave(
      input TCLK, TRESETn,
      input TVALID, TDATA, TLAST, TKEEP, TUSER, TID, TDEST,
      output TREADY
  );

endinterface

// ================================================================
// Notes:
// - Interfaces contain no sequential logic.
// - Clock/reset are provided for structural and tooling consistency.
// - All protocol semantics must be implemented by connected modules.
// ================================================================

`endif  // AXI_INTERFACES_SV
