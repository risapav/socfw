/**
 * @file xfcp_id_rom.sv
 * @brief ROM modul poskytujúci identifikačné údaje o XFCP bridge.
 * @details Obsahuje informácie o šírke zberníc a identifikačný reťazec.
 */

`ifndef XFCP_ID_ROM_SV
`define XFCP_ID_ROM_SV

`default_nettype none

module xfcp_id_rom #(
  parameter logic [15:0] XFCP_ID_TYPE     = 16'h0001,
  parameter int          XFCP_ID_STR_LEN  = 16,
  parameter logic [127:0] XFCP_ID_STR     = "Hybrid AXIL",
  parameter int          AXI_ADDR_WIDTH   = 32,
  parameter int          AXI_DATA_WIDTH   = 32,
  parameter int          COUNT_WIDTH      = 16
)(
  input  wire        clk,
  input  wire        rst_n,

  input  wire        start,
  output logic [7:0] data,
  output logic       valid,
  input  wire        ready,
  output logic       last
);

  // --- Lokalné výpočty ---
  localparam int WORD_SIZE    = AXI_DATA_WIDTH / 8;
  localparam int ROM_SIZE     = 10 + XFCP_ID_STR_LEN;

  // Pamäť ROM
  (* romstyle = "logic" *) logic [7:0] rom [ROM_SIZE];

  // --- Inicializácia ROM ---
  // Použitie generovacieho bloku alebo initial bloku je pre ROM v FPGA korektné.
  initial begin : rom_init
    // Verzia a Typ (Big Endian formát pre XFCP)
    rom[0] = 8'h80; // Verzia protokolu 0 s príznakom ROM
    rom[1] = XFCP_ID_TYPE[7:0];

    // Parametre zbernice
    rom[2] = 8'(AXI_ADDR_WIDTH);
    rom[3] = 0; // Padding
    rom[4] = 8'(AXI_DATA_WIDTH);
    rom[5] = 0; // Padding
    rom[6] = 8'(WORD_SIZE);
    rom[7] = 0; // Padding
    rom[8] = 8'(COUNT_WIDTH);
    rom[9] = 0; // Padding

    // Identifikačný reťazec
    for (int i = 0; i < XFCP_ID_STR_LEN; i++) begin
      rom[10+i] = XFCP_ID_STR[8*(XFCP_ID_STR_LEN-1-i) +: 8];
    end
  end

  // --- Registre a FSM ---
  typedef enum logic { ID_IDLE, ID_STREAM } state_e;
  state_e state_q, state_n;

  logic [$clog2(ROM_SIZE)-1:0] ptr_q, ptr_n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ID_IDLE;
      ptr_q   <= '0;
    end else begin
      state_q <= state_n;
      ptr_q   <= ptr_n;
    end
  end

  // --- Kombinačná logika ---
  always_comb begin
    state_n = state_q;
    ptr_n   = ptr_q;
    valid   = 1'b0;
    data    = rom[ptr_q];
    last    = 1'b0;

    case (state_q)
      ID_IDLE: begin
        ptr_n = '0;
        if (start) state_n = ID_STREAM;
      end

      ID_STREAM: begin
        valid = 1'b1;
        last  = (ptr_q == (ROM_SIZE - 1));

        if (ready) begin
          if (last) begin
            state_n = ID_IDLE;
          end else begin
            ptr_n = ptr_q + 1'b1;
          end
        end
      end

      default: state_n = ID_IDLE;
    endcase
  end

endmodule

`endif // XFCP_ID_ROM_SV
