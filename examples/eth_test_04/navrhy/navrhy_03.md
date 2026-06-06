Presne. `eth_test_04` by som už neposúval ako „raw byte loopback“, ale ako **čistý MAC datapath** s oddelenou diagnostikou.

Cieľová filozofia:

```text
GMII RX
  -> RX MAC: preambula/SFD, hlavička, MAC filter, veľkosť, FCS/CRC check
  -> čistý AXI-Stream payload
  -> voliteľná aplikačná logika / echo / FIFO
  -> TX MAC: doplní hlavičku, swap MAC, padding, CRC/FCS, preambula/SFD
  -> GMII TX
```

Diagnostika má bežať paralelne, nie tak, že zmení dátovú cestu.

---

# 1. Potrebné moduly

Navrhol by som tieto moduly:

```text
gmii_rx_if.sv
eth_rx_mac.sv
eth_crc32_8.sv
eth_rx_header_parser.sv
eth_rx_filter.sv
eth_rx_diag.sv

axis_async_fifo.sv
axis_meta_fifo.sv

eth_tx_mac.sv
eth_tx_header_builder.sv
eth_tx_fcs.sv
eth_tx_diag.sv

eth_loopback_app.sv alebo eth_echo_app.sv
ethernet_test_04_top.sv
```

Nie všetky musia byť veľké. Niektoré môžu byť najprv vnútorné bloky v `eth_rx_mac` / `eth_tx_mac`, ale architektonicky by som ich držal oddelene.

---

# 2. Rozdelenie vrstiev

## RX strana

RX modul má dostať surové GMII:

```systemverilog
input  logic       gmii_rx_clk_i;
input  logic [7:0] gmii_rxd_i;
input  logic       gmii_rx_dv_i;
input  logic       gmii_rx_er_i;
```

a na výstupe má dať:

```systemverilog
output logic [7:0] payload_tdata_o;
output logic       payload_tvalid_o;
input  logic       payload_tready_i;
output logic       payload_tlast_o;
output logic       payload_tuser_o;
```

plus metadata:

```systemverilog
output logic       rx_meta_valid_o;
input  logic       rx_meta_ready_i;
output eth_rx_meta_t rx_meta_o;
```

Čiže payload a metadata idú oddelene.

---

## TX strana

TX modul dostane čistý payload:

```systemverilog
input  logic [7:0] payload_tdata_i;
input  logic       payload_tvalid_i;
output logic       payload_tready_o;
input  logic       payload_tlast_i;
input  logic       payload_tuser_i;
```

plus metadata pre novú hlavičku:

```systemverilog
input  logic       tx_meta_valid_i;
output logic       tx_meta_ready_o;
input  eth_tx_meta_t tx_meta_i;
```

a vyrobí GMII:

```systemverilog
output logic [7:0] gmii_txd_o;
output logic       gmii_tx_en_o;
output logic       gmii_tx_er_o;
```

---

# 3. Dôležité: payload nestačí, potrebuješ metadata

Ak RX očistí frame a na stream pošle iba dáta, TX nebude vedieť:

```text
komu odpovedať,
aký EtherType použiť,
či bol frame broadcast/unicast,
aká bola pôvodná veľkosť,
či treba padding,
či bol frame prijatý s chybou.
```

Preto musí RX okrem payload streamu vyrobiť aj `rx_meta`.

Napríklad:

```systemverilog
typedef struct packed {
    logic [47:0] dst_mac;
    logic [47:0] src_mac;
    logic [15:0] eth_type_len;

    logic        is_broadcast;
    logic        is_multicast;
    logic        is_unicast_to_me;

    logic        is_length_field;
    logic [15:0] payload_len;
    logic [15:0] frame_len;

    logic        fcs_ok;
    logic        rx_er_seen;
    logic        too_short;
    logic        too_long;
    logic        mac_match;
    logic        header_ok;

    logic [31:0] fcs_rx;
    logic [31:0] fcs_calc;
} eth_rx_meta_t;
```

TX potom použije zjednodušené metadata:

```systemverilog
typedef struct packed {
    logic [47:0] dst_mac;
    logic [47:0] src_mac;
    logic [15:0] eth_type_len;
    logic [15:0] payload_len;
    logic        insert_padding;
} eth_tx_meta_t;
```

Pre echo/swap:

```systemverilog
tx_meta.dst_mac      = rx_meta.src_mac;
tx_meta.src_mac      = LOCAL_MAC;
tx_meta.eth_type_len = rx_meta.eth_type_len;
tx_meta.payload_len  = rx_meta.payload_len;
```

---

# 4. RX MAC FSM

RX MAC by mal mať približne tieto stavy:

```text
RX_IDLE
RX_PREAMBLE
RX_SFD
RX_HEADER
RX_PAYLOAD
RX_FCS
RX_DROP
RX_DONE
```

## RX_IDLE

Čaká na `gmii_rx_dv_i`.

```text
RXDV = 0 -> idle
RXDV = 1 -> začína preambula alebo frame
```

---

## RX_PREAMBLE

Očakáva bajty `0x55`.

Nemusíš vyžadovať presne sedem bajtov, ale pre diagnostiku ich počítaj.

```text
55 55 55 55 55 55 55 D5
```

Prakticky:

```text
ak byte == 0x55 -> preamble_count++
ak byte == 0xD5 -> SFD nájdené, pokračuj HEADER
inak -> drop
```

Diagnosticky si ulož:

```text
preamble_count
sfd_seen
bad_preamble
```

---

## RX_HEADER

Zachytíš prvých 14 bajtov po SFD:

```text
0..5   destination MAC
6..11  source MAC
12..13 EtherType/Length
```

Do CRC sa počíta všetko od `destination MAC`, nie preambula a nie SFD.

Čiže CRC enable začne až po SFD:

```text
CRC includes:
DST MAC
SRC MAC
TYPE/LEN
PAYLOAD
PADDING

CRC excludes:
preamble
SFD
FCS
```

---

## RX_PAYLOAD

Payload posielaš do AXI streamu až keď je header akceptovaný.

Tu sú dve možnosti:

### Režim A — cut-through po hlavičke

Pošleš payload hneď po 14 bajtoch.

Výhoda:

```text
malá latencia
```

Nevýhoda:

```text
FCS ešte nevieš, či je OK.
Ak FCS zlyhá, už si poslal zlé dáta ďalej.
```

Potom musíš na poslednom bajte nastaviť:

```systemverilog
payload_tuser_o = error;
```

### Režim B — store-and-forward

Najprv uložíš celý frame do FIFO/RAM, overíš FCS, až potom pustíš payload.

Výhoda:

```text
von ide iba overený payload
```

Nevýhoda:

```text
potrebuješ frame buffer minimálne 2 kB
väčšia latencia
```

Pre tvoju vetu „na výstupe do streamu pôjdu iba dáta očistené“ by som odporúčal **store-and-forward** aspoň pre diagnostickú fázu.

---

## RX_FCS

Posledné 4 bajty frame sú FCS. RX musí oneskoriť stream minimálne o 4 bajty, aby ich neposlal ako payload.

Prakticky potrebuješ malý 4-byte shift register:

```text
každý prijatý bajt ide do fcs_shift[0..3]
payload von púšťaš až bajt, ktorý je o 4 bajty starší
```

Tým prirodzene stripneš FCS.

Na konci frame:

```text
fcs_rx   = posledné 4 bajty z linky
fcs_calc = ~crc_state
fcs_ok   = fcs_rx == fcs_calc
```

Pozor na Ethernet byte order:

```text
FCS na linke ide LSB byte first:
fcs[7:0]
fcs[15:8]
fcs[23:16]
fcs[31:24]
```

---

# 5. RX validácie

RX MAC by mal kontrolovať:

```text
SFD nájdené
minimálna dĺžka frame
maximálna dĺžka frame
MAC destination:
  - local MAC
  - broadcast
  - voliteľne multicast
EtherType/Length field
FCS OK
RX_ER nebol počas frame
```

Pre Ethernet minimum:

```text
bez preambuly/SFD/FCS:
  60 bajtov minimum

vrátane FCS:
  64 bajtov minimum
```

Ak prijmeš frame kratší než 64 bajtov vrátane FCS, je to runt frame.

Max štandardne:

```text
1518 bajtov bez VLAN vrátane FCS
1522 bajtov s VLAN
```

Pre začiatok:

```systemverilog
parameter int MIN_FRAME_LEN = 64;
parameter int MAX_FRAME_LEN = 1518;
parameter bit ACCEPT_BROADCAST = 1'b1;
parameter bit ACCEPT_MULTICAST = 1'b0;
```

---

# 6. TX MAC FSM

TX musí robiť opačnú operáciu:

```text
TX_IDLE
TX_PREAMBLE
TX_SFD
TX_HEADER
TX_PAYLOAD
TX_PAD
TX_FCS
TX_IFG
```

## TX_PREAMBLE

Vyslať:

```text
55 55 55 55 55 55 55
```

## TX_SFD

Vyslať:

```text
D5
```

## TX_HEADER

Vygenerovať:

```text
DST MAC = tx_meta.dst_mac
SRC MAC = tx_meta.src_mac
TYPE/LEN = tx_meta.eth_type_len
```

Do CRC sa počíta header, payload aj padding.

## TX_PAYLOAD

Číta AXI stream payload.

Každý bajt:

```text
ide na GMII
ide do CRC32
počíta sa payload_count
```

## TX_PAD

Ak je header + payload kratší než 60 bajtov bez FCS, doplníš nuly.

```text
min_frame_no_fcs = 60
header_len = 14
min_payload_with_pad = 46
```

Teda:

```text
ak payload_len < 46:
  doplniť 46 - payload_len nulových bajtov
```

## TX_FCS

Po poslednom payload/pad bajte:

```text
fcs = ~crc_state
```

vyslať:

```text
fcs[7:0]
fcs[15:8]
fcs[23:16]
fcs[31:24]
```

## TX_IFG

Držať `TXEN=0` aspoň 12 byte-time:

```text
12 bajtov IFG = 96 bit times
pri GMII 1G = 96 ns
```

---

# 7. CRC modul

Použi wrapper nad `taxi_lfsr`, aby sa nikdy nepomýlili parametre.

```systemverilog
module eth_crc32_8 (
    input  logic [7:0]  data_i,
    input  logic [31:0] crc_i,
    output logic [31:0] crc_o
);

    taxi_lfsr #(
        .LFSR_W(32),
        .LFSR_POLY(32'h04c11db7),
        .LFSR_GALOIS(1'b1),
        .LFSR_FEED_FORWARD(1'b0),
        .REVERSE(1'b1),
        .DATA_W(8),
        .DATA_IN_EN(1'b1),
        .DATA_OUT_EN(1'b0)
    ) u_lfsr (
        .data_in   (data_i),
        .state_in  (crc_i),
        .data_out  (),
        .state_out (crc_o)
    );

endmodule
```

CRC pravidlá:

```text
init:        32'hffff_ffff
update cez:  DST MAC + SRC MAC + TYPE/LEN + PAYLOAD + PAD
neupdate cez: preambula, SFD, FCS, IFG
final:       ~crc_state
FCS order:   LSB byte first
```

---

# 8. Ako zapojiť diagnostiku bez poškodenia dátovej cesty

Diagnostiku by som robil v troch úrovniach.

## Úroveň 1 — sticky event flags

Na J10/J11 alebo LED:

```text
rx_seen
sfd_seen
header_done
mac_match
payload_seen
fcs_ok
frame_accepted
frame_dropped

tx_started
tx_header_sent
tx_payload_sent
tx_fcs_sent
tx_done
tx_underflow
```

Toto je jednoduché a robustné.

---

## Úroveň 2 — status FIFO

RX MAC po každom frame zapíše jeden status záznam:

```systemverilog
typedef struct packed {
    logic [31:0] seq;
    logic [47:0] dst_mac;
    logic [47:0] src_mac;
    logic [15:0] eth_type_len;
    logic [15:0] frame_len;
    logic [15:0] payload_len;

    logic        fcs_ok;
    logic        mac_match;
    logic        broadcast;
    logic        rx_er;
    logic        too_short;
    logic        too_long;
    logic        dropped;

    logic [31:0] fcs_rx;
    logic [31:0] fcs_calc;
} eth_rx_status_t;
```

Tento status môžeš:

```text
vyviesť cez UART,
čítať cez jednoduchý debug register,
alebo mapovať na J11 po stránkach.
```

---

## Úroveň 3 — packet trace FIFO

Pre hlbšiu diagnostiku si ulož prvých napríklad 64 bajtov prijatého frame:

```text
preamble_count
SFD
DST
SRC
TYPE
prvých 32/64 payload bajtov
FCS
```

Toto nech je samostatný debug FIFO, nie súčasť hlavného payload streamu.

Napríklad:

```systemverilog
typedef struct packed {
    logic [7:0] byte;
    logic       valid;
    logic       sop;
    logic       eop;
    logic       is_header;
    logic       is_payload;
    logic       is_fcs;
} eth_trace_byte_t;
```

Dôležité: diagnostický tap musí byť neblokujúci.

```text
Ak trace FIFO je plné, nastav diag_overflow,
ale nezastavuj RX MAC.
```

---

# 9. Navrhované top-level zapojenie

Pre testovací loopback:

```text
                 RX clock domain ETH_RXC
             ┌───────────────────────┐
GMII RX ---> │ gmii_rx_if             │
             └──────────┬────────────┘
                        │
             ┌──────────▼────────────┐
             │ eth_rx_mac_clean       │
             │ - preamble/SFD detect  │
             │ - header parse         │
             │ - MAC filter           │
             │ - length check         │
             │ - CRC/FCS check        │
             │ - strip header/FCS     │
             └──────┬─────────┬──────┘
                    │         │
                    │         └── rx_status / trace -> diag
                    │
                    │ clean payload AXIS + rx_meta
                    ▼
             ┌───────────────────────┐
             │ axis_payload_fifo      │  RXC -> TX_CLK
             └──────────┬────────────┘
                        │
             ┌──────────▼────────────┐
             │ eth_echo_app           │
             │ - wait rx_meta         │
             │ - create tx_meta       │
             │ - swap MAC             │
             │ - forward payload      │
             └──────────┬────────────┘
                        │
             ┌──────────▼────────────┐
             │ eth_tx_mac_clean       │
             │ - preamble/SFD insert  │
             │ - header insert        │
             │ - padding              │
             │ - CRC/FCS generate     │
             └──────────┬────────────┘
                        │
                     GMII TX
```

Ak RX a TX clock domény sú rozdielne:

```text
ETH_RXC domain:
  RX MAC
  RX CRC
  RX status
  write side FIFO

ETH_TX_CLK domain:
  read side FIFO
  echo app alebo TX scheduler
  TX MAC
  TX CRC
```

Metadata musia ísť cez samostatný async FIFO:

```text
rx_payload_fifo
rx_meta_fifo
rx_status_fifo
```

---

# 10. Čo má robiť `eth_echo_app`

Pre prvú verziu:

```text
vstup:
  rx_meta
  rx_payload stream

výstup:
  tx_meta
  tx_payload stream
```

Logika:

```text
ak rx_meta.fcs_ok == 1
a rx_meta.mac_match == 1
a rx_meta.dropped == 0
potom:
  tx_meta.dst_mac      = rx_meta.src_mac
  tx_meta.src_mac      = LOCAL_MAC
  tx_meta.eth_type_len = rx_meta.eth_type_len
  tx_meta.payload_len  = rx_meta.payload_len
  payload forward
inak:
  drop payload
```

Dôležité: ak RX MAC používa store-and-forward, `eth_echo_app` dostane iba platné frame. Ak používa cut-through, echo app musí sledovať `tuser` a vedieť dropnúť chybný frame.

---

# 11. Store-and-forward vs cut-through

Pre tvoju fázu odporúčam:

```text
RX: store-and-forward
TX: normálny streaming
```

Prečo?

Lebo chceš:

```text
korektne prejsť frame,
vypočítať CRC,
skontrolovať hlavičku,
MAC,
veľkosť,
a až potom pustiť očistené dáta.
```

To sa bez bufferovania nedá úplne čisto, pretože FCS poznáš až na konci frame.

Minimálny frame buffer:

```text
payload FIFO 2048 bajtov
meta FIFO niekoľko položiek
status FIFO niekoľko položiek
```

Pre normálny Ethernet frame stačí `2048`.

---

# 12. Minimálne rozhranie RX MAC

Navrhujem:

```systemverilog
module eth_rx_mac #(
    parameter logic [47:0] LOCAL_MAC = 48'h000A3501FEC0,
    parameter bit ACCEPT_BROADCAST = 1'b1,
    parameter bit ACCEPT_MULTICAST = 1'b0,
    parameter int MAX_FRAME_LEN = 1518
)(
    input  logic       clk,
    input  logic       rst_n,

    input  logic [7:0] gmii_rxd,
    input  logic       gmii_rx_dv,
    input  logic       gmii_rx_er,

    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    input  logic       m_axis_tready,
    output logic       m_axis_tlast,
    output logic       m_axis_tuser,

    output logic       m_meta_valid,
    input  logic       m_meta_ready,
    output eth_rx_meta_t m_meta,

    output eth_rx_status_t status_o,
    output logic       status_valid_o,

    output eth_rx_debug_t debug_o
);
```

---

# 13. Minimálne rozhranie TX MAC

```systemverilog
module eth_tx_mac #(
    parameter int MIN_PAYLOAD_LEN = 46
)(
    input  logic       clk,
    input  logic       rst_n,

    input  logic       s_meta_valid,
    output logic       s_meta_ready,
    input  eth_tx_meta_t s_meta,

    input  logic [7:0] s_axis_tdata,
    input  logic       s_axis_tvalid,
    output logic       s_axis_tready,
    input  logic       s_axis_tlast,
    input  logic       s_axis_tuser,

    output logic [7:0] gmii_txd,
    output logic       gmii_tx_en,
    output logic       gmii_tx_er,

    output eth_tx_status_t status_o,
    output logic       status_valid_o,

    output eth_tx_debug_t debug_o
);
```

---

# 14. Dátový kontrakt

Toto si treba zapísať do komentárov modulov, inak sa v tom neskôr stratíme.

## RX output payload stream

```text
Neobsahuje:
  preambulu
  SFD
  destination MAC
  source MAC
  EtherType/Length
  FCS

Obsahuje:
  iba payload podľa Ethernet frame

tlast:
  posledný payload bajt

tuser:
  chyba frame, ak sa používa cut-through
```

## RX metadata

```text
Obsahuje:
  dst_mac
  src_mac
  eth_type_len
  payload_len
  frame_len
  fcs_ok
  mac_match
  error flags
```

## TX input payload stream

```text
Obsahuje:
  iba payload

Neobsahuje:
  header
  padding
  FCS
```

## TX metadata

```text
Obsahuje:
  destination MAC
  source MAC
  EtherType/Length
  payload_len
```

TX sám doplní:

```text
preamble
SFD
header
padding
FCS
IFG
```

---

# 15. Poradie implementácie

Navrhoval by som toto poradie:

## Krok 1 — `eth_crc32_8`

Najprv validovať testom:

```text
"123456789" -> 0xCBF43926
```

Bez toho nemá zmysel riešiť MAC.

---

## Krok 2 — TX MAC samostatne

V simulácii dať payload + meta a očakávať:

```text
55 55 55 55 55 55 55 D5
DST
SRC
TYPE
PAYLOAD
PAD
FCS
IFG
```

Toto je ľahšie otestovať než RX.

---

## Krok 3 — RX MAC samostatne

Do RX pustiť známy validný Ethernet frame s FCS.

Overiť:

```text
header parse OK
MAC match OK
payload von bez headeru/FCS
fcs_ok = 1
status sedí
```

Potom pustiť frame so zlým FCS:

```text
payload nesmie ísť von v store-and-forward režime
status.fcs_ok = 0
drop counter++
```

---

## Krok 4 — RX + TX loopback

Zapojenie:

```text
RX clean payload + meta -> echo_app -> TX
```

PC pošle:

```text
DST = FPGA_MAC
SRC = PC_MAC
TYPE = 0x9000
PAYLOAD = MAGIC
```

FPGA vráti:

```text
DST = PC_MAC
SRC = FPGA_MAC
TYPE = 0x9000
PAYLOAD = MAGIC
valid FCS
```

---

## Krok 5 — diagnostika

Až keď RX/TX funguje v simulácii, pridať:

```text
J10/J11 sticky flags
status FIFO
trace FIFO
UART dump
```

---

# 16. Najdôležitejšie návrhové rozhodnutie

Ja by som pre `eth_test_04` zvolil:

```text
RX MAC = store-and-forward, čistý payload von len po FCS OK
TX MAC = normálny streaming, generuje header/padding/FCS
diagnostika = paralelný status/trace, neblokujúci tap
```

Tým sa vyhneš tomu, že chybné frame prejdú do aplikácie, a zároveň budeš mať presné informácie:

```text
prečo bol frame dropnutý,
aký bol MAC,
aký bol typ,
koľko bajtov prišlo,
aké bolo prijaté FCS,
aké bolo vypočítané FCS.
```

To je oveľa lepší základ než raw loopback.

tu je modul pre crc:
// SPDX-License-Identifier: CERN-OHL-S-2.0
/*

Copyright (c) 2016-2026 FPGA Ninja, LLC

Authors:
- Alex Forencich

*/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Parametrizable combinatorial parallel LFSR/CRC
 */
module taxi_lfsr #
(
    // width of LFSR
    parameter LFSR_W = 31,
    // LFSR polynomial
    parameter logic [LFSR_W-1:0] LFSR_POLY = 31'h10000001,
    // LFSR configuration: 0 for Fibonacci (PRBS), 1 for Galois (CRC)
    parameter logic LFSR_GALOIS = 1'b0,
    // LFSR feed forward enable
    parameter logic LFSR_FEED_FORWARD = 1'b0,
    // bit-reverse input and output
    parameter logic REVERSE = 1'b0,
    // width of data ports
    parameter DATA_W = 8,
    // enable data input and output
    parameter logic DATA_IN_EN = 1'b1,
    parameter logic DATA_OUT_EN = 1'b1,
    // shift control
    parameter STATE_SHIFT_PRE = 0,
    parameter STATE_SHIFT_POST = 0
)
(
    input  wire logic [DATA_W-1:0]  data_in,
    input  wire logic [LFSR_W-1:0]  state_in,
    output wire logic [DATA_W-1:0]  data_out,
    output wire logic [LFSR_W-1:0]  state_out
);

/*

Fully parametrizable combinatorial parallel LFSR/CRC module.  Implements an unrolled LFSR
next state computation, shifting DATA_W bits per pass through the module.  Input data
is XORed with LFSR feedback path, tie data_in to zero if this is not required.

Works in two parts: statically computes a set of bit masks, then uses these bit masks to
select bits for XORing to compute the next state.

Ports:

data_in

Data bits to be shifted through the LFSR (DATA_W bits)

state_in

LFSR/CRC current state input (LFSR_W bits)

data_out

Data bits shifted out of LFSR (DATA_W bits)

state_out

LFSR/CRC next state output (LFSR_W bits)

Parameters:

LFSR_W

Specify width of LFSR/CRC register

LFSR_POLY

Specify the LFSR/CRC polynomial in hex format.  For example, the polynomial

x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10 + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1

would be represented as

32'h04c11db7

Note that the largest term (x^32) is suppressed.  This term is generated automatically based
on LFSR_W.

LFSR_GALOIS

Specify the LFSR configuration, either Fibonacci (0) or Galois (1).  Fibonacci is generally used
for linear-feedback shift registers (LFSR) for pseudorandom binary sequence (PRBS) generators,
scramblers, and descrambers, while Galois is generally used for cyclic redundancy check
generators and checkers.

Fibonacci style (example for 64b66b scrambler, 0x8000000001)

   DIN (LSB first)
    |
    V
   (+)<---------------------------(+)<-----------------------------.
    |                              ^                               |
    |  .----.  .----.       .----. |  .----.       .----.  .----.  |
    +->|  0 |->|  1 |->...->| 38 |-+->| 39 |->...->| 56 |->| 57 |--'
    |  '----'  '----'       '----'    '----'       '----'  '----'
    V
   DOUT

Galois style (example for CRC16, 0x8005)

    ,-------------------+-------------------------+----------(+)<-- DIN (MSB first)
    |                   |                         |           ^
    |  .----.  .----.   V   .----.       .----.   V   .----.  |
    `->|  0 |->|  1 |->(+)->|  2 |->...->| 14 |->(+)->| 15 |--+---> DOUT
       '----'  '----'       '----'       '----'       '----'

LFSR_FEED_FORWARD

Generate feed forward instead of feed back LFSR.  Enable this for PRBS checking and self-
synchronous descrambling.

Fibonacci feed-forward style (example for 64b66b descrambler, 0x8000000001)

   DIN (LSB first)
    |
    |  .----.  .----.       .----.    .----.       .----.  .----.
    +->|  0 |->|  1 |->...->| 38 |-+->| 39 |->...->| 56 |->| 57 |--.
    |  '----'  '----'       '----' |  '----'       '----'  '----'  |
    |                              V                               |
   (+)<---------------------------(+)------------------------------'
    |
    V
   DOUT

Galois feed-forward style

    ,-------------------+-------------------------+------------+--- DIN (MSB first)
    |                   |                         |            |
    |  .----.  .----.   V   .----.       .----.   V   .----.   V
    `->|  0 |->|  1 |->(+)->|  2 |->...->| 14 |->(+)->| 15 |->(+)-> DOUT
       '----'  '----'       '----'       '----'       '----'

REVERSE

Bit-reverse LFSR input and output.  Shifts MSB first by default, set REVERSE for LSB first.

DATA_W

Specify width of input and output data bus.  The module will perform one shift per input
data bit, so if the input data bus is not required tie data_in to zero and set DATA_W
to the required number of shifts per clock cycle.

DATA_IN_EN, DATA_OUT_EN

Enable data input and/or output ports.  Useful for CRC computation where the
data shifted out of the register is not used, or PRBS generation where no data
is shifted in to the register.  Disabling unused inputs and outputs will
increase simulation speed.

STATE_SHIFT_PRE, STATE_SHIFT_POST

Shift the state before/after shifting the data.  Useful for either shifting the
state only, or for performing a split CRC computation on a wide/segmented data
bus.  Positive shift values are equivalent to extending the data input port with
zeros.  Negative shift amounts shift the state backwards, useful for removing
zero padding and similar.

Settings for common LFSR/CRC implementations:

Name        Configuration           Length  Polynomial      Initial value   Notes
CRC16-IBM   Galois, bit-reverse     16      16'h8005        16'hffff
CRC16-CCITT Galois                  16      16'h1021        16'h1d0f
CRC32       Galois, bit-reverse     32      32'h04c11db7    32'hffffffff    Ethernet FCS; invert final output
CRC32C      Galois, bit-reverse     32      32'h1edc6f41    32'hffffffff    iSCSI, Intel CRC32 instruction; invert final output
PRBS6       Fibonacci               6       6'h21           any
PRBS7       Fibonacci               7       7'h41           any
PRBS9       Fibonacci               9       9'h021          any             ITU V.52
PRBS10      Fibonacci               10      10'h081         any             ITU
PRBS11      Fibonacci               11      11'h201         any             ITU O.152
PRBS15      Fibonacci, inverted     15      15'h4001        any             ITU O.152
PRBS17      Fibonacci               17      17'h04001       any
PRBS20      Fibonacci               20      20'h00009       any             ITU V.57
PRBS23      Fibonacci, inverted     23      23'h040001      any             ITU O.151
PRBS29      Fibonacci, inverted     29      29'h08000001    any
PRBS31      Fibonacci, inverted     31      31'h10000001    any
64b66b      Fibonacci, bit-reverse  58      58'h8000000001  any             10G Ethernet
pcie        Galois, bit-reverse     16      16'h0039        16'hffff        PCIe gen 1/2
128b130b    Galois, bit-reverse     23      23'h210125      any             PCIe gen 3

*/

localparam INPUT_DATA_IN_STATE = DATA_IN_EN && LFSR_GALOIS && !LFSR_FEED_FORWARD && DATA_W <= LFSR_W;
localparam INPUT_STATE_IN_DATA = DATA_IN_EN && LFSR_GALOIS && !LFSR_FEED_FORWARD && DATA_W > LFSR_W;
localparam OUTPUT_DATA_IN_STATE = DATA_OUT_EN && !LFSR_GALOIS && !LFSR_FEED_FORWARD && DATA_W <= LFSR_W;
localparam OUTPUT_STATE_IN_DATA = DATA_OUT_EN && !LFSR_GALOIS && !LFSR_FEED_FORWARD && DATA_W > LFSR_W;

localparam DATA_IN_INT = DATA_IN_EN && !INPUT_DATA_IN_STATE;
localparam DATA_OUT_INT = DATA_OUT_EN && !OUTPUT_DATA_IN_STATE;

localparam IN_W = INPUT_STATE_IN_DATA ? DATA_W : (LFSR_W+(DATA_IN_INT ? DATA_W : 0));
localparam OUT_W = OUTPUT_STATE_IN_DATA ? DATA_W : (LFSR_W+(DATA_OUT_INT ? DATA_W : 0));

function [OUT_W-1:0][IN_W-1:0] lfsr_mask();
    logic [LFSR_W-1:0] lfsr_mask_state[LFSR_W-1:0];
    logic [DATA_W-1:0] lfsr_mask_data[LFSR_W-1:0];
    logic [LFSR_W-1:0] output_mask_state[DATA_W-1:0];
    logic [DATA_W-1:0] output_mask_data[DATA_W-1:0];

    logic [LFSR_W-1:0] state_val;
    logic [DATA_W-1:0] data_val;

    logic [DATA_W-1:0] data_mask;

    // init bit masks
    for (integer i = 0; i < LFSR_W; i = i + 1) begin
        lfsr_mask_state[i] = '0;
        lfsr_mask_state[i][i] = 1'b1;
        lfsr_mask_data[i] = '0;
    end
    for (integer i = 0; i < DATA_W; i = i + 1) begin
        output_mask_state[i] = '0;
        output_mask_data[i] = '0;
    end

    // simulate shift register
    if (LFSR_GALOIS) begin
        // Galois configuration

        // Shift state alone before shifting data
        if (STATE_SHIFT_PRE > 0) begin
            // forward shift
            for (integer i = 0; i < STATE_SHIFT_PRE; i = i + 1) begin
                // determine shift in value
                // current value in last FF, XOR with input data bit (MSB first)
                state_val = lfsr_mask_state[LFSR_W-1];
                data_val = lfsr_mask_data[LFSR_W-1];

                // shift
                for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j-1];
                    lfsr_mask_data[j] = lfsr_mask_data[j-1];
                end
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = '0;
                end
                lfsr_mask_state[0] = state_val;
                lfsr_mask_data[0] = data_val;

                // add XOR inputs at correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
                        lfsr_mask_data[j] = lfsr_mask_data[j] ^ data_val;
                    end
                end
            end
        end else if (STATE_SHIFT_PRE < 0) begin
            // reverse shift
            for (integer i = 0; i < -STATE_SHIFT_PRE; i = i + 1) begin
                state_val = lfsr_mask_state[0];
                data_val = lfsr_mask_data[0];

                // add XOR inputs at correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
                        lfsr_mask_data[j] = lfsr_mask_data[j] ^ data_val;
                    end
                end

                // shift
                for (integer j = 0; j < LFSR_W-1; j = j + 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j+1];
                    lfsr_mask_data[j] = lfsr_mask_data[j+1];
                end
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = '0;
                end
                lfsr_mask_state[LFSR_W-1] = state_val;
                lfsr_mask_data[LFSR_W-1] = data_val;
            end
        end

        // Shift data
        if (DATA_IN_EN || DATA_OUT_EN) begin
            for (data_mask = {1'b1, {DATA_W-1{1'b0}}}; data_mask != 0; data_mask = data_mask >> 1) begin
                // determine shift in value
                // current value in last FF, XOR with input data bit (MSB first)
                state_val = lfsr_mask_state[LFSR_W-1];
                data_val = lfsr_mask_data[LFSR_W-1];
                data_val = data_val ^ data_mask;

                // shift
                for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j-1];
                    lfsr_mask_data[j] = lfsr_mask_data[j-1];
                end
                for (integer j = DATA_W-1; j > 0; j = j - 1) begin
                    output_mask_state[j] = output_mask_state[j-1];
                    output_mask_data[j] = output_mask_data[j-1];
                end
                output_mask_state[0] = state_val;
                output_mask_data[0] = data_val;
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = data_mask;
                end
                lfsr_mask_state[0] = state_val;
                lfsr_mask_data[0] = data_val;

                // add XOR inputs at correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
                        lfsr_mask_data[j] = lfsr_mask_data[j] ^ data_val;
                    end
                end
            end
        end

        // Shift state alone after shifting data
        if (STATE_SHIFT_POST > 0) begin
            // forward shift
            for (integer i = 0; i < STATE_SHIFT_POST; i = i + 1) begin
                // determine shift in value
                // current value in last FF, XOR with input data bit (MSB first)
                state_val = lfsr_mask_state[LFSR_W-1];
                data_val = lfsr_mask_data[LFSR_W-1];

                // shift
                for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j-1];
                    lfsr_mask_data[j] = lfsr_mask_data[j-1];
                end
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = '0;
                end
                lfsr_mask_state[0] = state_val;
                lfsr_mask_data[0] = data_val;

                // add XOR inputs at correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
                        lfsr_mask_data[j] = lfsr_mask_data[j] ^ data_val;
                    end
                end
            end
        end else if (STATE_SHIFT_POST < 0) begin
            // reverse shift
            for (integer i = 0; i < -STATE_SHIFT_POST; i = i + 1) begin
                state_val = lfsr_mask_state[0];
                data_val = lfsr_mask_data[0];

                // add XOR inputs at correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
                        lfsr_mask_data[j] = lfsr_mask_data[j] ^ data_val;
                    end
                end

                // shift
                for (integer j = 0; j < LFSR_W-1; j = j + 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j+1];
                    lfsr_mask_data[j] = lfsr_mask_data[j+1];
                end
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = '0;
                end
                lfsr_mask_state[LFSR_W-1] = state_val;
                lfsr_mask_data[LFSR_W-1] = data_val;
            end
        end
    end else begin
        // Fibonacci configuration

        // Shift state alone before shifting data
        if (STATE_SHIFT_PRE > 0) begin
            // forward shift
            for (integer i = 0; i < STATE_SHIFT_PRE; i = i + 1) begin
                // determine shift in value
                // current value in last FF, XOR with input data bit (MSB first)
                state_val = lfsr_mask_state[LFSR_W-1];
                data_val = lfsr_mask_data[LFSR_W-1];

                // add XOR inputs from correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        state_val = lfsr_mask_state[j-1] ^ state_val;
                        data_val = lfsr_mask_data[j-1] ^ data_val;
                    end
                end

                // shift
                for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j-1];
                    lfsr_mask_data[j] = lfsr_mask_data[j-1];
                end
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = '0;
                end
                lfsr_mask_state[0] = state_val;
                lfsr_mask_data[0] = data_val;
            end
        end else if (STATE_SHIFT_PRE < 0) begin
            // reverse shift
            for (integer i = 0; i < -STATE_SHIFT_PRE; i = i + 1) begin
                state_val = lfsr_mask_state[0];
                data_val = lfsr_mask_data[0];

                // shift
                for (integer j = 0; j < LFSR_W-1; j = j + 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j+1];
                    lfsr_mask_data[j] = lfsr_mask_data[j+1];
                end
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = '0;
                end
                lfsr_mask_state[LFSR_W-1] = state_val;
                lfsr_mask_data[LFSR_W-1] = data_val;

                // add XOR inputs from correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        state_val = lfsr_mask_state[j-1] ^ state_val;
                        data_val = lfsr_mask_data[j-1] ^ data_val;
                    end
                end
            end
        end

        // Shift data
        if (DATA_IN_EN || DATA_OUT_EN) begin
            for (data_mask = {1'b1, {DATA_W-1{1'b0}}}; data_mask != 0; data_mask = data_mask >> 1) begin
                // determine shift in value
                // current value in last FF, XOR with input data bit (MSB first)
                state_val = lfsr_mask_state[LFSR_W-1];
                data_val = lfsr_mask_data[LFSR_W-1];
                data_val = data_val ^ data_mask;

                // add XOR inputs from correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        state_val = lfsr_mask_state[j-1] ^ state_val;
                        data_val = lfsr_mask_data[j-1] ^ data_val;
                    end
                end

                // shift
                for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j-1];
                    lfsr_mask_data[j] = lfsr_mask_data[j-1];
                end
                for (integer j = DATA_W-1; j > 0; j = j - 1) begin
                    output_mask_state[j] = output_mask_state[j-1];
                    output_mask_data[j] = output_mask_data[j-1];
                end
                output_mask_state[0] = state_val;
                output_mask_data[0] = data_val;
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = data_mask;
                end
                lfsr_mask_state[0] = state_val;
                lfsr_mask_data[0] = data_val;
            end
        end

        // Shift state alone after shifting data
        if (STATE_SHIFT_POST > 0) begin
            for (integer i = 0; i < STATE_SHIFT_POST; i = i + 1) begin
                // determine shift in value
                // current value in last FF, XOR with input data bit (MSB first)
                state_val = lfsr_mask_state[LFSR_W-1];
                data_val = lfsr_mask_data[LFSR_W-1];

                // add XOR inputs from correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        state_val = lfsr_mask_state[j-1] ^ state_val;
                        data_val = lfsr_mask_data[j-1] ^ data_val;
                    end
                end

                // shift
                for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j-1];
                    lfsr_mask_data[j] = lfsr_mask_data[j-1];
                end
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = '0;
                end
                lfsr_mask_state[0] = state_val;
                lfsr_mask_data[0] = data_val;
            end
        end else if (STATE_SHIFT_POST < 0) begin
            // reverse shift
            for (integer i = 0; i < -STATE_SHIFT_POST; i = i + 1) begin
                state_val = lfsr_mask_state[0];
                data_val = lfsr_mask_data[0];

                // shift
                for (integer j = 0; j < LFSR_W-1; j = j + 1) begin
                    lfsr_mask_state[j] = lfsr_mask_state[j+1];
                    lfsr_mask_data[j] = lfsr_mask_data[j+1];
                end
                if (LFSR_FEED_FORWARD) begin
                    // only shift in new input data
                    state_val = '0;
                    data_val = '0;
                end
                lfsr_mask_state[LFSR_W-1] = state_val;
                lfsr_mask_data[LFSR_W-1] = data_val;

                // add XOR inputs from correct indicies
                for (integer j = 1; j < LFSR_W; j = j + 1) begin
                    if (LFSR_POLY[j]) begin
                        state_val = lfsr_mask_state[j-1] ^ state_val;
                        data_val = lfsr_mask_data[j-1] ^ data_val;
                    end
                end
            end
        end
    end

    // disable broken linter
    /* verilator lint_off WIDTH */
    if (REVERSE) begin
        // output reversed
        if (OUTPUT_STATE_IN_DATA) begin
            for (integer i = 0; i < DATA_W; i = i + 1) begin
                if (INPUT_STATE_IN_DATA) begin
                    for (integer j = 0; j < DATA_W; j = j + 1) begin
                        lfsr_mask[i][j] = output_mask_data[DATA_W-i-1][DATA_W-j-1];
                    end
                end else begin
                    for (integer j = 0; j < LFSR_W; j = j + 1) begin
                        lfsr_mask[i][j] = output_mask_state[DATA_W-i-1][LFSR_W-j-1];
                    end
                    if (DATA_IN_INT) begin
                        for (integer j = 0; j < DATA_W; j = j + 1) begin
                            lfsr_mask[i][j+LFSR_W] = output_mask_data[DATA_W-i-1][DATA_W-j-1];
                        end
                    end
                end
            end
        end else begin
            for (integer i = 0; i < LFSR_W; i = i + 1) begin
                if (INPUT_STATE_IN_DATA) begin
                    for (integer j = 0; j < DATA_W; j = j + 1) begin
                        lfsr_mask[i][j] = lfsr_mask_data[LFSR_W-i-1][DATA_W-j-1];
                    end
                end else begin
                    for (integer j = 0; j < LFSR_W; j = j + 1) begin
                        lfsr_mask[i][j] = lfsr_mask_state[LFSR_W-i-1][LFSR_W-j-1];
                    end
                    if (DATA_IN_INT) begin
                        for (integer j = 0; j < DATA_W; j = j + 1) begin
                            lfsr_mask[i][j+LFSR_W] = lfsr_mask_data[LFSR_W-i-1][DATA_W-j-1];
                        end
                    end
                end
            end
            if (DATA_OUT_INT) begin
                for (integer i = 0; i < DATA_W; i = i + 1) begin
                    if (INPUT_STATE_IN_DATA) begin
                        for (integer j = 0; j < DATA_W; j = j + 1) begin
                            lfsr_mask[i+LFSR_W][j] = output_mask_data[DATA_W-i-1][DATA_W-j-1];
                        end
                    end else begin
                        for (integer j = 0; j < LFSR_W; j = j + 1) begin
                            lfsr_mask[i+LFSR_W][j] = output_mask_state[DATA_W-i-1][LFSR_W-j-1];
                        end
                        if (DATA_IN_INT) begin
                            for (integer j = 0; j < DATA_W; j = j + 1) begin
                                lfsr_mask[i+LFSR_W][j+LFSR_W] = output_mask_data[DATA_W-i-1][DATA_W-j-1];
                            end
                        end
                    end
                end
            end
        end
    end else begin
        // output normal
        if (OUTPUT_STATE_IN_DATA) begin
            for (integer i = 0; i < DATA_W; i = i + 1) begin
                if (INPUT_STATE_IN_DATA) begin
                    lfsr_mask[i] = output_mask_data[i];
                end else if (DATA_IN_INT) begin
                    lfsr_mask[i] = {output_mask_data[i], output_mask_state[i]};
                end else begin
                    lfsr_mask[i] = output_mask_state[i];
                end
            end

        end else begin
            for (integer i = 0; i < LFSR_W; i = i + 1) begin
                if (INPUT_STATE_IN_DATA) begin
                    lfsr_mask[i] = lfsr_mask_data[i];
                end else if (DATA_IN_INT) begin
                    lfsr_mask[i] = {lfsr_mask_data[i], lfsr_mask_state[i]};
                end else begin
                    lfsr_mask[i] = lfsr_mask_state[i];
                end
            end
            if (DATA_OUT_INT) begin
                for (integer i = 0; i < DATA_W; i = i + 1) begin
                    if (INPUT_STATE_IN_DATA) begin
                        lfsr_mask[i+LFSR_W] = output_mask_data[i];
                    end else if (DATA_IN_INT) begin
                        lfsr_mask[i+LFSR_W] = {output_mask_data[i], output_mask_state[i]};
                    end else begin
                        lfsr_mask[i+LFSR_W] = output_mask_state[i];
                    end
                end
            end
        end
    end
    /* verilator lint_on WIDTH */
endfunction

wire [OUT_W-1:0][IN_W-1:0] mask = lfsr_mask();

wire [IN_W-1:0] lfsr_in;
wire [OUT_W-1:0] lfsr_out;

if (DATA_IN_EN) begin
    if (INPUT_STATE_IN_DATA) begin
        if (DATA_W == LFSR_W) begin
            assign lfsr_in = data_in ^ state_in;
        end else begin
            if (REVERSE) begin
                assign lfsr_in = data_in ^ {{DATA_W - LFSR_W{1'b0}}, state_in};
            end else begin
                assign lfsr_in = data_in ^ {state_in, {DATA_W - LFSR_W{1'b0}}};
            end
        end
    end else if (INPUT_DATA_IN_STATE) begin
        if (REVERSE) begin
            assign lfsr_in = {{LFSR_W - DATA_W{1'b0}}, data_in} ^ state_in;
        end else begin
            assign lfsr_in = {data_in, {LFSR_W - DATA_W{1'b0}}} ^ state_in;
        end
    end else begin
        assign lfsr_in = {data_in, state_in};
    end
end else begin
    assign lfsr_in = state_in;
end

for (genvar n = 0; n < OUT_W; n = n + 1) begin
    assign lfsr_out[n] = ^(lfsr_in & mask[n]);
end

if (OUTPUT_DATA_IN_STATE) begin
    assign state_out = lfsr_out;
    assign data_out = REVERSE ? lfsr_out[OUT_W-1 -: DATA_W] : lfsr_out[0 +: DATA_W];
end else if (OUTPUT_STATE_IN_DATA) begin
    assign state_out = REVERSE ? lfsr_out[OUT_W-1 -: LFSR_W] : lfsr_out[0 +: LFSR_W];
    assign data_out = lfsr_out;
end else begin
    assign state_out = lfsr_out[0 +: LFSR_W];

    if (DATA_OUT_EN) begin
        assign data_out = lfsr_out[LFSR_W +: DATA_W];
    end else begin
        assign data_out = '0;
    end
end

endmodule

`resetall
