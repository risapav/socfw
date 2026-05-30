kód pre inšpiráciu:

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: HdlForBeginners
// Engineer:
//
// Create Date: 13.11.2021 13:55:40
// Design Name:
// Module Name: packet_gen
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////

import ethernet_header_pkg::*;

module packet_gen
  #(
    parameter SOURCE_MAC = 48'he86a64e7e830,
    parameter DEST_MAC = 48'h080027fbdd65,
    parameter MII_WIDTH = 2,
    parameter PACKET_PAYLOAD_WORDS = 64,
    parameter WORD_BYTES = 4

    )
   (
    input                        clk,
    input                        rst,

    input [WORD_BYTES*8-1:0]     s_axis_tdata,
    input                        s_axis_tvalid,
    input                        s_axis_tlast,
    output                       s_axis_tready,


    output logic                 tx_en,
    output logic [MII_WIDTH-1:0] txd
    );


   localparam PACKET_PAYLOAD_BYTES = PACKET_PAYLOAD_WORDS*WORD_BYTES;

   // create a first
   logic                         s_axis_tfirst;


   always_ff @(posedge clk)
     begin
	    if(rst) begin
           s_axis_tfirst <= 1;

	    end
	    else begin
           if (s_axis_tvalid && s_axis_tready) begin
              if (s_axis_tlast) begin
                 // After tlast pulse, drive first high
                 s_axis_tfirst <= 1;

              end
              else begin
                 // otherwise, drive it low on valid and ready
                 s_axis_tfirst <= 0;

              end
           end
	    end
     end


   // header and state buffers
   ethernet_header header;
   logic [$bits(ethernet_header)-1 : 0] header_buffer;
   logic [WORD_BYTES*8-1:0]             data_buffer;
   logic [7*8-1:0]                      preamble_buffer;
   logic [1*8-1:0]                      sfd_buffer;
   logic [4*8-1:0]                      fcs;
   logic [4*8-1:0]                      fcs_buffer;

   // Number of bytes transferred in each stage
   localparam HEADER_BYTES = $bits(ethernet_header)/8;
   localparam DATA_BYTES = PACKET_PAYLOAD_BYTES;
   localparam WAIT_BYTES = 12;
   localparam SFD_BYTES = 1;
   localparam PREAMBLE_BYTES = 7;
   localparam FCS_BYTES = 4;

   // RMII interface is MII_WIDTH bits wide, so divide by MII_WIDTH to get the correct
   // number of iterations per each stage
   localparam HEADER_LENGTH = HEADER_BYTES*8/MII_WIDTH;
   localparam WAIT_LENGTH = WAIT_BYTES*8/MII_WIDTH;
   localparam SFD_LENGTH = SFD_BYTES*8/MII_WIDTH;
   localparam PREAMBLE_LENGTH = PREAMBLE_BYTES*8/MII_WIDTH;
   localparam FCS_LENGTH = FCS_BYTES*8/MII_WIDTH;
   localparam DATA_LENGTH = DATA_BYTES*8/MII_WIDTH;
   localparam DATA_COUNTER_BITS = $clog2(WORD_BYTES*8/MII_WIDTH);



   // State machine
   typedef enum                         {IDLE, PREAMBLE, SFD, HEADER, DATA, FCS, WAIT}  state_type;

   state_type current_state = IDLE;
   state_type next_state    = IDLE;

   // Data fifo
   logic                                fifo_full;
   logic                                fifo_empty;
   logic [11:0]                         fifo_count;
   logic [WORD_BYTES*8-1:0]             fifo_out;
   logic                                fifo_rd_en;
   logic                                fifo_wr_en;
   logic                                packet_start_valid;
   logic                                packet_valid;
   logic                                fifo_has_space;

   localparam FIFO_DEPTH = 2048;

   assign fifo_has_space = (fifo_count < FIFO_DEPTH-PACKET_PAYLOAD_BYTES ) ? 1 : 0;

   // Packet start is only valid when
   // First beat of axi stream and
   // Axis Stream is valid and
   // Axis Stream is ready and
   // Space in FIFO
   // This indicates that this packet has space to go into the fifo
   // Otherwise, it is skipped
   assign packet_start_valid = s_axis_tvalid && s_axis_tready && s_axis_tfirst && fifo_has_space;

   // create packet_valid flag
   always_ff @(posedge clk)
     begin
	    if(rst) begin
           packet_valid <= 0;

	    end
	    else begin
           // If the start of this packet is valid
           if (packet_start_valid) begin
              // The entire packet is valid
              packet_valid <= 1;

           end

           // If this is the end of a valid packet
           if (packet_valid && s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
              // End of valid packet
              packet_valid <= 0;
           end
	    end
     end

   // only write a valid packet
   assign fifo_wr_en = s_axis_tvalid & s_axis_tready & (packet_start_valid || packet_valid);

   // ready if fifo has space
   assign s_axis_tready = (fifo_has_space & s_axis_tfirst) | packet_valid;

   // Get header
   eth_header_gen
     #(
       .SOURCE_MAC(SOURCE_MAC),
       .DEST_MAC(DEST_MAC),
       .PACKET_PAYLOAD_BYTES(PACKET_PAYLOAD_BYTES)
       )
   eth_header_gen
     (
      .output_header(header)

      );

   data_fifo data_fifo_i
     (
      .clk(clk),
      .srst(rst),
      .din(s_axis_tdata),
      .wr_en(fifo_wr_en),
      .rd_en(fifo_rd_en),
      .dout(fifo_out),
      .full(fifo_full),
      .empty(fifo_empty),
      .data_count(fifo_count)
      );


   // count the time spent in each state
   logic [31:0]                         state_counter;

   always @(posedge clk)
     begin
	    if(rst) begin
           state_counter  <= '0;

	    end
	    else begin
           if (current_state != next_state) begin
              state_counter  <= '0;

           end
           else begin
              // otherwise increment counter and shift buffer
              state_counter <= state_counter  + 'd1;
           end
	    end
     end

   // 3 process state machine
   // 1) decide which state to go into next
   always @(*)
     begin
        case (current_state)
          IDLE   :
            begin
               // If there's enough data in fifo
               if (fifo_count >= PACKET_PAYLOAD_WORDS) begin
                  next_state = PREAMBLE;

               end
               else begin
                  next_state = current_state;

               end
            end
          PREAMBLE:
            begin
               if (state_counter == PREAMBLE_LENGTH-1) begin
                  next_state = SFD;
               end
               else begin
                  next_state = current_state;

               end
            end
          SFD:
            begin
               if (state_counter == SFD_LENGTH-1) begin
                  next_state = HEADER;
               end
               else begin
                  next_state = current_state;

               end
            end
          HEADER  :
            begin
               if (state_counter == HEADER_LENGTH-1) begin
                  next_state = DATA;
               end
               else begin
                  next_state = current_state;

               end
            end
          DATA  :
            begin
               if (state_counter == DATA_LENGTH-1) begin
                  next_state = FCS;
               end
               else begin
                  next_state = current_state;

               end
            end
          FCS  :
            begin
               if (state_counter == FCS_LENGTH-1) begin
                  next_state = WAIT;
               end
               else begin
                  next_state = current_state;

               end
            end
          WAIT   :
            begin
               if (state_counter == WAIT_LENGTH-1) begin
                  next_state = IDLE;
               end
               else begin
                  next_state = current_state;

               end
            end
          default:
            next_state = current_state;
        endcase
     end

   //2) register into that state
   always @(posedge clk)
     begin
	    if(rst) begin
           current_state <= IDLE;
	    end
	    else begin
           current_state <= next_state;
	    end

     end


   // state dependant variables
   logic [MII_WIDTH-1:0]                          tx_data;
   logic                                          tx_valid;
   logic                                          fcs_en;
   logic                                          fcs_rst;

   //3) drive output according to state
   always @(*)
     begin
        case (current_state)
          IDLE   :
            begin
               tx_valid = 0;
               tx_data  = 0;
               fcs_en   = 0;
               fcs_rst   = 1;

            end
          PREAMBLE  :
            begin
               tx_valid = 1;
               tx_data  = preamble_buffer[MII_WIDTH-1:0];
               fcs_en   = 0;
               fcs_rst   = 0;

            end
          SFD  :
            begin
               tx_valid = 1;
               tx_data  = sfd_buffer[MII_WIDTH-1:0];
               fcs_en   = 0;
               fcs_rst   = 0;
            end
          HEADER  :
            begin
               tx_valid = 1;
               tx_data  = header_buffer[MII_WIDTH-1:0];
               fcs_en   = 1;
               fcs_rst   = 0;

            end
          DATA  :
            begin
               tx_valid = 1;
               tx_data  = data_buffer[MII_WIDTH-1:0];
               fcs_en   = 1;
               fcs_rst   = 0;

            end
          FCS:
            begin
               tx_valid = 1;
               tx_data  = fcs_buffer[MII_WIDTH-1:0];
               fcs_en   = 0;
               fcs_rst  = 0;

            end
          WAIT   :
            begin
               tx_valid = 0;
               tx_data  = 0;
               fcs_en   = 0;
               fcs_rst  = 0;

            end
          default:
            begin
               tx_valid = 0;
               tx_data  = 0;
               fcs_en   = 0;
               fcs_rst  = 0;

            end
        endcase
     end

   logic [DATA_COUNTER_BITS-1:0] data_ones;
   assign data_ones = '1;

   // populate and shift buffers according to state
   always_ff@(posedge clk) begin
      if (rst == 1) begin
         header_buffer   <= 0;
         preamble_buffer <= 0;
         fifo_rd_en      <= 0;

      end
      else begin
         fifo_rd_en      <= 0;

         // buffer loading
         if (current_state == IDLE) begin
            header_buffer   <= header;
            preamble_buffer <= 56'h55555555555555;
            sfd_buffer      <= 8'hd5;
         end
         // and fcs when it's available
         if (next_state == FCS && current_state != FCS) begin
            fcs_buffer <= fcs;
         end
         // and fcs when it's available
         if (next_state == DATA && current_state != DATA) begin
            data_buffer <= fifo_out;
            fifo_rd_en  <= 1;

         end

         // shift buffers during those states
         if (current_state == HEADER) begin
            header_buffer <= header_buffer >> MII_WIDTH;
         end
         if (current_state == PREAMBLE) begin
            preamble_buffer <= preamble_buffer >> MII_WIDTH;
         end
         if (current_state == SFD) begin
            sfd_buffer <= sfd_buffer >> MII_WIDTH;
         end
         if (current_state == DATA && next_state == DATA ) begin
            if (state_counter[DATA_COUNTER_BITS-1:0] == data_ones) begin
               data_buffer <= fifo_out;
               fifo_rd_en  <= 1;

            end
            else begin
               data_buffer <= data_buffer >> MII_WIDTH;
            end
         end
         if (current_state == FCS) begin
            fcs_buffer <= fcs_buffer >> MII_WIDTH;
         end
      end
   end

   // crc generator
   crc_gen crc_gen_i
     (
      .clk(clk),
      .rst(rst || fcs_rst),

      .data_in(tx_data),
      .crc_en(fcs_en),
      .crc_out(fcs)

      );

   // Register outputs
   //drive tx interfaces

   always @(posedge clk)

     begin
	    if(rst) begin
           tx_en <= 0;

	    end
	    else begin
           tx_en <= tx_valid;
           txd   <= tx_data;

	    end

     end

endmodule


Tento priložený kód je **TX packet generátor pre MII/RMII-štýl výstup**, nie priamo GMII knižničný blok pre náš RTL8211EG projekt. Dá sa z neho prevziať viacero dobrých princípov, ale **neodporúčam ho prebrať priamo** do `eth_test_03`.

Najväčšia hodnota kódu je v štruktúre TX FSM:

```text
IDLE -> PREAMBLE -> SFD -> HEADER -> DATA -> FCS -> WAIT
```

Presne takúto kostru má mať aj náš `gmii_tx_mac`, len s 8-bitovým GMII výstupom a lepším stream/packet handshakom. V priloženom kóde je šírka výstupu parametrizovaná cez `MII_WIDTH`, defaultne `2`, a dĺžky stavov sa počítajú ako počet bitových krokov podľa `MII_WIDTH`; to je typické pre RMII/MII serializer, nie pre GMII byte-per-clock MAC.

## Čo sa dá použiť

### 1. Stavová štruktúra TX MAC

Toto je najviac použiteľná časť. Kód jasne oddeľuje:

```text
preamble
SFD
Ethernet header
payload data
FCS
inter-frame gap / WAIT
```

V našom `gmii_tx_mac.sv` by som ponechal rovnakú ideu:

```systemverilog
typedef enum logic [2:0] {
  ST_IDLE,
  ST_PREAMBLE,
  ST_SFD,
  ST_ETH_HEADER,
  ST_PAYLOAD,
  ST_PADDING,
  ST_FCS,
  ST_IFG
} tx_state_e;
```

Rozdiel: v našom GMII variante sa neposúva o `MII_WIDTH` bitov, ale vysiela sa **jeden bajt za takt**:

```text
Preamble: 7 taktov
SFD:      1 takt
Header:   14 taktov
Payload:  payload_len taktov
Padding:  podľa potreby
FCS:      4 takty
IFG:      12 taktov
```

### 2. Oddelenie CRC enable od preambuly/SFD/FCS

Priložený kód správne počíta CRC iba v stavoch `HEADER` a `DATA`, nie počas preambuly, SFD, FCS ani WAIT. Vždy nastavuje `fcs_en=1` len pri `HEADER` a `DATA`, a pri preambule/SFD/FCS/WAIT je `fcs_en=0`.

Toto presne treba zachovať v `gmii_tx_mac`:

```text
CRC sa počíta cez:
  Ethernet header
  payload
  padding

CRC sa nepočíta cez:
  preamble
  SFD
  samotný FCS
  IFG
```

V našom prípade však ešte treba pridať padding do CRC. Priložený kód padding vôbec nerieši.

### 3. IFG / WAIT stav

Kód má `WAIT_BYTES = 12`, teda 12 bajtov inter-frame gapu. To je dobrý princíp a má zostať aj v našom `gmii_tx_mac`.

Pre GMII je to jednoduché:

```systemverilog
if (ifg_cnt_q == 4'd11)
  state_d = ST_IDLE;
```

a počas IFG:

```systemverilog
gmii_tx_en_o = 1'b0;
gmii_txd_o   = 8'h00;
```

### 4. Myšlienka packet admission control

Kód sleduje začiatok AXI-stream packetu cez `s_axis_tfirst` a rozhodne, či má FIFO dosť miesta. Ak áno, nastaví `packet_valid`, inak packet zahodí ešte na vstupe.

Toto je dobrá myšlienka pre robustnú knižnicu:

```text
Ak FIFO nemá miesto na celý packet, nezačni prijímať packet napoly.
```

Do `eth_test_03` by som ju prevzal ako samostatný modul, nie priamo do GMII MAC:

```text
axis_packet_gate.sv
```

Úloha:

```text
- sleduje tfirst/tlast
- pred začiatkom packetu overí miesto vo FIFO
- buď prijme celý packet, alebo celý packet zahodí
- nikdy neprijme polovicu packetu
```

---

## Čo by som nepreberal priamo

### 1. Nie je to GMII TX MAC

Priložený modul má výstup:

```systemverilog
output logic [MII_WIDTH-1:0] txd
```

a default `MII_WIDTH = 2`. Dĺžky stavov sa počítajú ako:

```systemverilog
HEADER_LENGTH   = HEADER_BYTES*8/MII_WIDTH;
PREAMBLE_LENGTH = PREAMBLE_BYTES*8/MII_WIDTH;
FCS_LENGTH      = FCS_BYTES*8/MII_WIDTH;
```

To je serializer pre 2-bit/4-bit MII/RMII štýl, nie pre náš 8-bit GMII.

Pre náš RTL8211EG v GMII režime má `gmii_tx_mac` výstupy:

```systemverilog
output logic [7:0] gmii_txd_o,
output logic       gmii_tx_en_o,
output logic       gmii_tx_er_o
```

a všetko ide po bajtoch.

### 2. Fixná dĺžka payloadu

Modul predpokladá fixný packet:

```systemverilog
parameter PACKET_PAYLOAD_WORDS = 64
parameter WORD_BYTES = 4
localparam PACKET_PAYLOAD_BYTES = PACKET_PAYLOAD_WORDS*WORD_BYTES
```

FSM potom čaká presne na `DATA_LENGTH`.

Pre náš UDP echo stack to nestačí. Potrebujeme variabilnú dĺžku:

```text
payload_len_i
tlast
padding = max(0, 60 - (14 + payload_len_i))
```

Takže v `gmii_tx_mac` nesmie byť pevné `DATA_LENGTH`, ale počítanie podľa metadata alebo `tlast`.

### 3. FIFO priestor sa počíta v nesprávnych jednotkách

Kód má:

```systemverilog
fifo_count < FIFO_DEPTH - PACKET_PAYLOAD_BYTES
```

Ale `fifo_count` je počet položiek FIFO, zatiaľ čo `PACKET_PAYLOAD_BYTES` je počet bajtov. FIFO vstup má šírku `WORD_BYTES*8`, teda počet položiek je počet slov, nie bajtov.

Správne by malo byť:

```systemverilog
localparam int PACKET_PAYLOAD_WORDS = ...;
fifo_has_space = fifo_count <= FIFO_DEPTH - PACKET_PAYLOAD_WORDS;
```

alebo všeobecne:

```systemverilog
packet_words_needed = ceil(payload_bytes / WORD_BYTES);
```

Tento bug by som v našej knižnici nechcel preniesť.

### 4. FIFO nestráži skutočné packet boundaries

Kód používa `s_axis_tfirst`, `s_axis_tlast` a `packet_valid`, ale samotné FIFO ukladá iba `tdata`, nie `tlast` ani `tkeep`.

Pre fixný payload to stačí. Pre naše UDP payloady nie. V knižnici má byť stream FIFO minimálne:

```text
tdata
tlast
tkeep alebo byte-valid, ak bude šírka > 8
tuser/error
```

Pre 8-bit stream stačí:

```systemverilog
typedef struct packed {
  logic [7:0] data;
  logic       last;
  logic       user;
} axis8_word_t;
```

### 5. Nepodporuje padding

Kód ide:

```text
HEADER -> DATA -> FCS
```

bez `PADDING`.

Pre náš projekt je padding povinný. Práve krátky payload typu `"HELLO"` musí mať 13 nulových bajtov paddingu:

```text
14 Ethernet + 20 IPv4 + 8 UDP + 5 payload = 47
60 - 47 = 13 padding bytes
```

V našom `gmii_tx_mac` musí byť stav:

```text
ST_PADDING
```

a padding sa musí započítať do CRC.

### 6. CRC generátor nemusí sedieť na Ethernet GMII

Priložený kód používa externý `crc_gen`, do ktorého posiela `tx_data` široký `MII_WIDTH` bitov.

Pre náš GMII stack chcem výhradne bajtový Ethernet CRC:

```systemverilog
crc32_eth.sv
```

s overením:

```text
"123456789" -> 0xCBF43926
frame+FCS residue -> 0xDEBB20E3
```

Nedával by som do knižnice CRC s parametrickou šírkou `2/4/8`, kým nemáme spoľahlivo hotový 8-bit GMII variant.

### 7. Header cez packed struct a shiftovanie je riziko endianity

Kód používa:

```systemverilog
ethernet_header header;
logic [$bits(ethernet_header)-1:0] header_buffer;
header_buffer <= header;
header_buffer <= header_buffer >> MII_WIDTH;
```



Toto je elegantné, ale nebezpečné pre endianitu. V našom projekte by som ostal pri explicitnom `eth_header_builder`:

```systemverilog
byte 0  = dst_mac[47:40]
byte 1  = dst_mac[39:32]
...
byte 12 = ethertype[15:8]
byte 13 = ethertype[7:0]
```

Je to nudnejšie, ale oveľa bezpečnejšie.

---

## Ako by som využil tento kód v `eth_test_03`

Neprevzal by som ho ako modul `packet_gen`, ale rozdelil by som jeho idey do troch našich modulov:

## A. `gmii_tx_mac.sv`

Použiť FSM princíp:

```text
IDLE
PREAMBLE
SFD
ETH_HEADER
PAYLOAD
PADDING
FCS
IFG
```

Ale implementovať 8-bit GMII, nie `MII_WIDTH`.

Rozhranie:

```systemverilog
module gmii_tx_mac #(
  parameter int MIN_FRAME_NO_FCS = 60
)(
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        tx_start_i,
  output logic        tx_busy_o,
  output logic        tx_done_o,

  input  logic [47:0] tx_dst_mac_i,
  input  logic [47:0] tx_src_mac_i,
  input  logic [15:0] tx_ethertype_i,
  input  logic [15:0] tx_payload_len_i,

  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,

  output logic [7:0]  gmii_txd_o,
  output logic        gmii_tx_en_o,
  output logic        gmii_tx_er_o
);
```

## B. `axis_packet_gate.sv`

Z priloženého kódu prebrať myšlienku `packet_start_valid` a `packet_valid`.

Úloha:

```text
Na začiatku packetu rozhodni, či ho prijmeš.
Ak FIFO nemá miesto, zahoď celý packet.
```

Rozhranie:

```systemverilog
module axis_packet_gate #(
  parameter int MAX_PACKET_BYTES = 1522
)(
  input  logic       clk_i,
  input  logic       rst_ni,

  input  logic [15:0] fifo_free_bytes_i,

  input  logic [7:0] s_axis_tdata,
  input  logic       s_axis_tvalid,
  output logic       s_axis_tready,
  input  logic       s_axis_tlast,

  output logic [7:0] m_axis_tdata,
  output logic       m_axis_tvalid,
  input  logic       m_axis_tready,
  output logic       m_axis_tlast,

  output logic       drop_packet_o
);
```

## C. `axis_packet_fifo.sv`

Namiesto `data_fifo` iba na `tdata` by som spravil FIFO, ktoré nesie aj `tlast`:

```systemverilog
module axis_packet_fifo #(
  parameter int DEPTH = 2048
)(
  input  logic       clk_i,
  input  logic       rst_ni,

  input  logic [7:0] s_axis_tdata,
  input  logic       s_axis_tvalid,
  output logic       s_axis_tready,
  input  logic       s_axis_tlast,

  output logic [7:0] m_axis_tdata,
  output logic       m_axis_tvalid,
  input  logic       m_axis_tready,
  output logic       m_axis_tlast,

  output logic [$clog2(DEPTH+1)-1:0] count_o
);
```

---

## Konkrétne odporúčania pre náš `gmii_tx_mac`

Z priloženého kódu by som ponechal princíp, ale implementoval ho takto:

```text
ST_IDLE:
  čaká na tx_start_i
  pripraví padding_len
  crc_clear = 1

ST_PREAMBLE:
  7x 0x55
  crc_en = 0

ST_SFD:
  1x 0xD5
  crc_en = 0

ST_ETH_HEADER:
  14 bajtov z eth_header_builder
  crc_en = 1

ST_PAYLOAD:
  odoberá s_axis bajty iba pri valid && ready
  crc_en = 1 iba pri skutočne odoslanom bajte

ST_PADDING:
  vysiela 0x00
  crc_en = 1

ST_FCS:
  vysiela ~crc_state little-endian
  crc_en = 0

ST_IFG:
  TXEN = 0 minimálne 12 cyklov
```

Dôležité vnútorné počítadlá:

```systemverilog
logic [15:0] frame_cnt_q;    // Ethernet header + payload + padding, bez FCS
logic [15:0] payload_cnt_q;
logic [15:0] pad_cnt_q;
logic [1:0]  fcs_cnt_q;
logic [3:0]  ifg_cnt_q;
logic [2:0]  preamble_cnt_q;
logic [3:0]  header_idx_q;
```

Nepoužíval by som jeden `state_counter` na všetko, ako v priloženom kóde. Pri GMII je čitateľnejšie mať samostatné počítadlá.

---

## Aké testy z toho vyplývajú

Pre inšpiráciu z `packet_gen` by som pridal tieto testy do `eth_test_03`:

```text
tb_gmii_tx_mac_min_frame
  payload 33 B -> padding 13 B -> celkový TX stream 72 B

tb_gmii_tx_mac_no_padding
  payload 60 B -> padding 0

tb_gmii_tx_mac_ifg
  dva packet starty za sebou -> medzi frame musí byť 12 idle cyklov

tb_gmii_tx_mac_crc_scope
  overiť, že CRC nezahŕňa preambulu/SFD/FCS/IFG, ale zahŕňa header/payload/padding

tb_axis_packet_gate
  FIFO má miesto -> packet prejde
  FIFO nemá miesto -> celý packet sa zahodí, nie iba časť

tb_axis_packet_fifo_tlast
  tdata aj tlast prejdú korektne cez FIFO
```

---

## Čo si z toho odniesť

Tento kód je dobrý ako **výukový TX packet generator**, ale nie ako priamy základ GMII knižnice.

Použiteľné pre nás:

```text
+ FSM členenie TX cesty
+ oddelené CRC enable len pre header/data
+ IFG/WAIT stav
+ packet admission control na začiatku packetu
+ FIFO pred TX cestou
```

Nepoužiteľné alebo rizikové:

```text
- MII_WIDTH=2 RMII/MII serializer
- fixná dĺžka payloadu
- chýba padding
- FIFO count mieša slová a bajty
- FIFO nenesie tlast
- CRC je externý a bit-width špecifický
- header shiftovanie cez packed struct je endian-risk
```

Pre `eth_test_03` by som teda z tohto návrhu prevzal **architektúru TX FSM a packet-gating myšlienku**, ale implementoval by som ich nanovo ako čisté 8-bit GMII moduly: `gmii_tx_mac`, `axis_packet_gate` a `axis_packet_fifo`.
