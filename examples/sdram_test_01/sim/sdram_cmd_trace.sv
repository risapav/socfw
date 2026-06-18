`default_nettype none

/**
 * @file sdram_cmd_trace.sv
 * @brief SDRAM Trace Modul – formátovaný log transakcií s detekciou chýb.
 *
 * @details
 *  Monitoruje SDRAM zbernicu a vypisuje farebný log každého príkazu.
 *  Zobrazuje deltu taktov, parametre príkazu a maticový stav bánk.
 *
 * OPRAVY voči pôvodnej verzii:
 *  [FIX-1] Row Hit detekcia: pri RD/WR sa addr nesie COL adresu, nie ROW.
 *          Pôvodný kód porovnával open_row[ba] == addr (vždy false → MISS).
 *          Oprava: ERR: MISS sa hlási len keď banka je CLOSED pri RD/WR.
 *          Pre skutočnú row-level detekciu pozri poznámku pri cmd_wr/cmd_rd.
 *  [FIX-2] PRE / PRE_ALL: odstránené dvojité NBA na bank_open v jednom bloku.
 *  [FIX-3] rstn port pridaný do port listu (bol v deklarácii ale chýbal
 *          v inštancii TB – spôsobovalo Z na porte a nefunkčný reset).
 *
 * @param ROW_WIDTH  Šírka riadkovej adresy (default 13)
 * @param COL_WIDTH  Šírka stĺpcovej adresy (default 10)
 * @param BANKS      Počet bánk (default 4)
 */
module sdram_cmd_trace #(
  parameter int ROW_WIDTH = 13,
  parameter int COL_WIDTH = 10,
  parameter int BANKS     = 4
)(
  input wire clk,
  input wire rstn,           // [FIX-3] Musí byť zapojený v TB!
  input wire [ROW_WIDTH-1:0] addr,
  input wire [1:0]           ba,
  input wire                 ras_n,
  input wire                 cas_n,
  input wire                 we_n,
  input wire                 cs_n
);

  // -------------------------------------------------------------------------
  // JEDEC Dekódovanie príkazov (SDR SDRAM command truth table)
  // -------------------------------------------------------------------------
  wire cmd_mrs = (!cs_n && !ras_n && !cas_n && !we_n);
  wire cmd_ref = (!cs_n && !ras_n && !cas_n &&  we_n);
  wire cmd_pre = (!cs_n && !ras_n &&  cas_n && !we_n);
  wire cmd_act = (!cs_n && !ras_n &&  cas_n &&  we_n);
  wire cmd_wr  = (!cs_n &&  ras_n && !cas_n && !we_n);
  wire cmd_rd  = (!cs_n &&  ras_n && !cas_n &&  we_n);
  wire cmd_nop = ( cs_n || (ras_n && cas_n && we_n));

  // -------------------------------------------------------------------------
  // Interný stav – zrkadlo bank_machine pre potreby tracera
  // -------------------------------------------------------------------------
  logic [BANKS-1:0]      bank_open;
  logic [ROW_WIDTH-1:0]  open_row [BANKS];   // Riadok otvorený ACT príkazom
  longint                last_cmd_tick;
  longint                current_tick;

  // -------------------------------------------------------------------------
  // ANSI farebné kódy pre terminálový výstup
  // -------------------------------------------------------------------------
  localparam string C_RST    = "\033[0m";
  localparam string C_BRIGHT = "\033[1m";
  localparam string C_CYAN   = "\033[36m";
  localparam string C_RED    = "\033[31m";
  localparam string C_GRN    = "\033[32m";

  // -------------------------------------------------------------------------
  // Funkcia: generovanie riadku so stavom všetkých bánk
  // -------------------------------------------------------------------------
  function automatic string get_bank_matrix();
    string s;
    s = "[ ";
    for (int i = 0; i < BANKS; i++) begin
      if (bank_open[i])
        s = {s, $sformatf("B%0d: %sOPEN (Row:%04h)%s", i, C_GRN, open_row[i], C_RST)};
      else
        s = {s, $sformatf("B%0d: %sIDLE%s", i, C_CYAN, C_RST)};
      if (i < BANKS-1) s = {s, " | "};
    end
    s = {s, " ]"};
    return s;
  endfunction

  // -------------------------------------------------------------------------
  // Hlavná monitorovacia logika
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      bank_open     <= '0;
      current_tick  <= 0;
      last_cmd_tick <= 0;
      for (int i = 0; i < BANKS; i++) open_row[i] <= '0;

    end else begin
      current_tick <= current_tick + 1;

      if (!cmd_nop) begin
        // Lokálne premenné pre formátovanie
        string cmd_name;
        string params;
        automatic string  hit_str  = "";
        automatic longint delta    = current_tick - last_cmd_tick;

        case (1'b1)

          // ------------------------------------------------------------------
          // Mode Register Set
          // ------------------------------------------------------------------
          cmd_mrs: begin
            cmd_name = "MRS";
            params   = $sformatf("Mode=%04h", addr);
          end

          // ------------------------------------------------------------------
          // Auto Refresh
          // ------------------------------------------------------------------
          cmd_ref: begin
            cmd_name = "REF";
            params   = "All Banks";
          end

          // ------------------------------------------------------------------
          // Precharge (single banka alebo PRE_ALL)
          // [FIX-2] Oddelené vetvy – žiadne dvojité NBA na bank_open
          // ------------------------------------------------------------------
          cmd_pre: begin
            if (addr[10]) begin
              // PRE_ALL: A10=1 podľa JEDEC
              cmd_name  = "PRE_ALL";
              params    = "---";
              bank_open <= '0;
            end else begin
              // PRE single banka
              cmd_name      = $sformatf("PRE");
              params        = $sformatf("B%0d", ba);
              bank_open[ba] <= 1'b0;
            end
          end

          // ------------------------------------------------------------------
          // Activate
          // ------------------------------------------------------------------
          cmd_act: begin
            cmd_name      = "ACT";
            params        = $sformatf("B%0d Row:%04h", ba, addr);
            bank_open[ba] <= 1'b1;
            open_row[ba]  <= addr;   // Uloženie otvoreného riadku
          end

          // ------------------------------------------------------------------
          // Write / Read
          // [FIX-1] addr pri RD/WR = COL adresa, NIE ROW adresa.
          //         Pôvodné porovnanie (open_row[ba] == addr) bolo vždy false
          //         pretože open_row má ROW_WIDTH bitov a addr nesie col index.
          //
          //         Správna detekcia chýb:
          //           ERR: CLOSED – banka vôbec nie je otvorená
          //           (HIT)       – banka je otvorená (row garantuje scheduler)
          //
          //         Ak chceš skutočnú row-level detekciu v traceri, potrebuješ
          //         extra vstupný port s expected_row (z bank_machine alebo
          //         z príkazu latched_cmd schedulera).
          // ------------------------------------------------------------------
          cmd_wr, cmd_rd: begin
            cmd_name = cmd_wr ? "WR" : "RD";
            params   = $sformatf("B%0d Col:%03h", ba, addr[COL_WIDTH-1:0]);

            if (!bank_open[ba]) begin
              // Kritická chyba: RD/WR na zatvorenú banku
              hit_str = $sformatf(" %s(ERR: CLOSED)%s", C_RED, C_RST);
            end else begin
              // Banka je otvorená – scheduler zodpovedá za správnosť riadku
              hit_str = $sformatf(" %s(OK)%s", C_GRN, C_RST);
            end
          end

          default: begin
            cmd_name = "UNK";
            params   = "???";
          end

        endcase

        // Formátovaný výstup: timestamp | príkaz | delta | params | banky
        $display("[%0t ns] %s%-7s%s (Δ:%4d) | %-26s | %s",
                 $time, C_BRIGHT, cmd_name, C_RST,
                 delta,
                 {params, hit_str},
                 get_bank_matrix());

        last_cmd_tick <= current_tick;
      end
    end
  end

endmodule

`default_nettype wire
