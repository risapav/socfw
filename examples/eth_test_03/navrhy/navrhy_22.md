Spravil som to odznova z nového ZIP-u a začínam jasným odtlačkom súboru:

```text
SHA256 eth_test_03.zip =
c4671dc3ee1fa7ed5433f1c149df9c66acea75dc1ebe8c67bdb1cb0017b752a8
```

Tento odtlačok je z aktuálne nahraného `/mnt/data/eth_test_03.zip`.

A teraz vecne: **tento ZIP už naozaj obsahuje aktuálny full top s J10/J11 debug busom, `txb_fire_w`, dual-clock FIFO architektúrou a timing PASS.** Moje predchádzajúce tvrdenia o chýbajúcom debug buse a starom top-e pre tento ZIP neplatia.

---

# 1. Overené zo ZIP-u

## Top je aktuálny full top

V `rtl/eth/ethernet_test_03_top.sv` je:

```systemverilog
output logic [7:0] dbg_mac_data_o,
output logic [7:0] dbg_ctrl_o
```

a vo vygenerovanom `build/rtl/soc_top.sv` sú tieto porty skutočne pripojené:

```systemverilog
.dbg_ctrl_o(PMOD_J11_LED8),
.dbg_mac_data_o(PMOD_J10_LED8),
```

Teda J10/J11 debug bus je vygenerovaný do topu.

## Board priradenia pre J10/J11 existujú

V `build/hal/board.tcl` sú priradenia:

```text
PMOD_J10_LED8[0] -> PIN_H1
PMOD_J10_LED8[1] -> PIN_F1
PMOD_J10_LED8[2] -> PIN_E1
PMOD_J10_LED8[3] -> PIN_C1
PMOD_J10_LED8[4] -> PIN_H2
PMOD_J10_LED8[5] -> PIN_F2
PMOD_J10_LED8[6] -> PIN_D2
PMOD_J10_LED8[7] -> PIN_C2

PMOD_J11_LED8[0] -> PIN_R1
PMOD_J11_LED8[1] -> PIN_P1
PMOD_J11_LED8[2] -> PIN_N1
PMOD_J11_LED8[3] -> PIN_M1
PMOD_J11_LED8[4] -> PIN_R2
PMOD_J11_LED8[5] -> PIN_P2
PMOD_J11_LED8[6] -> PIN_N2
PMOD_J11_LED8[7] -> PIN_M2
```

A `output_files/soc_top.pin` ich tiež vidí ako výstupy. Čiže J10/J11 sú v tomto ZIP-e reálne v bitstreame.

## Timing je PASS

Aktuálny `output_files/soc_top.sta.summary`:

```text
ETH_RXC setup slow 85C:    +0.235 ns
ETH_TX_CLK setup slow 85C: +0.922 ns
SYS_CLK setup slow 85C:    +4.893 ns

ETH_RXC hold slow 85C:     +0.449 ns
ETH_TX_CLK hold slow 85C:  +0.449 ns
```

Čiže na rozdiel od starších stavov: **tento ZIP má timing uzavretý**.

## Vygenerovaný top používa debug porty

`build/rtl/soc_top.sv` má:

```systemverilog
output wire [7:0] PMOD_J10_LED8,
output wire [7:0] PMOD_J11_LED8,
...
.dbg_ctrl_o(PMOD_J11_LED8),
.dbg_mac_data_o(PMOD_J10_LED8),
```

Toto je dôležité: už sa nemusíme baviť, či debug bus existuje. Existuje.

---

# 2. Aktuálny top: čo presne debug bus ukazuje

V `ethernet_test_03_top.sv` je:

```systemverilog
assign dbg_mac_data_o = mac_tvalid ? mac_tdata : 8'hEE;

assign dbg_ctrl_o = {
  eth_rxer_i,
  eth_rxdv_i,
  mac_drop_pulse_w,
  dbg_mac_accept_w,
  mac_hdr_done_w,
  mac_frame_done_w,
  mac_tlast,
  mac_tvalid
};
```

Teda:

```text
J10[7:0] = mac_tdata, ale iba ak mac_tvalid=1
           inak 0xEE sentinel

J11[0] = mac_tvalid
J11[1] = mac_tlast
J11[2] = gmii_rx_mac frame_done
J11[3] = eth_header_parser hdr_done_pulse
J11[4] = dbg_mac_accept_w, držaný capture z parsera
J11[5] = mac_drop_pulse
J11[6] = raw eth_rxdv_i
J11[7] = eth_rxer_i
```

Pri meraní na logic analyzéri teda platí:

```text
ber ako platné dáta iba cykly, kde J11[0] = 1
```

Očakávaný začiatok platných bajtov z J10:

```text
00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00 45 00 ...
```

Ak uvidíš `D5`, ale pri `J11[0]=0`, tak to nie je SFD leak. Je to len nevalidná hodnota v pipeline. Preto je dobré, že top posiela `0xEE` mimo valid.

---

# 3. LED mapa v tomto ZIP-e

V aktuálnom top-e je:

```systemverilog
eth_debug_leds #(
  ...
  .LAYER_DEBUG   (1'b0),
  .MAC_DEBUG     (1'b0)
)
```

Čiže LED3/4/5 nie sú layer debug ani MAC debug. Sú normálny režim:

```text
LED3 = rx_meta_valid
LED4 = tx_mac_busy_w
LED5 = eth_txen_o
```

Keď hovoríš, že LED3/4/5 neblikajú, z tohto konkrétneho topu vyplýva:

```text
rx_meta_valid = 0
tx_mac_busy_w = 0
eth_txen_o = 0
```

Teda TX sa ani nemá prečo spustiť. Problém je stále pred `udp_rx_meta_assembler` alebo priamo v jeho okolí.

Nie je to zatiaľ TX fyzický problém.

---

# 4. Dôležitý stav filtrov: L2/L3/L4 sú v promiscuous režime

V aktuálnom top-e je:

```systemverilog
eth_header_parser:
  .promiscuous_i(1'b1)

ipv4_header_parser:
  .promiscuous_i(1'b1)

udp_header_parser:
  .promiscuous_i(1'b1)
```

To znamená:

```text
L2 MAC filter je obídený.
L3 IP/protocol filter je obídený.
L4 UDP port filter je obídený.
```

Preto ak `rx_meta_valid` nevzniká, už to nemôže byť normálny MAC/IP/port filter. Ostáva dátové zarovnanie, tok valid/ready, alebo konkrétne `udp_hdr_pre_valid`.

---

# 5. Najpravdepodobnejší reálny bod zastavenia

V tejto architektúre `rx_meta_valid` vzniká len tu:

```text
udp_header_parser.hdr_pre_valid_o
  -> udp_rx_meta_assembler
  -> rx_meta_valid
```

Konkrétne `udp_rx_meta_assembler` robí:

```systemverilog
if (udp_hdr_pre_valid_i) begin
  valid_q <= 1'b1;
  meta_q  <= ...
end else if (valid_q && rx_meta_ready_i) begin
  valid_q <= 1'b0;
end
```

Teda ak LED3 nebliká, môžu nastať iba tieto prípady:

```text
A) udp_hdr_pre_valid_i nikdy nevznikne
B) udp_hdr_pre_valid_i vznikne, ale rx_meta_valid je príliš krátky/nesprávne zachytený LEDkou
C) rx_meta_valid vznikne, ale eth_debug_leds ho z nejakého dôvodu nezachytí
```

Možnosť C je menej pravdepodobná, lebo LED modul používa toggle synchronizáciu. Ale stále ju vieme overiť cez J11, ak tam vyvedieme `rx_meta_valid`.

Aktuálny J11 však `rx_meta_valid` neukazuje. Ukazuje len po L2.

---

# 6. Aktuálny J10/J11 debug je dobrý, ale odpovie iba na otázku „RX MAC/L2“

Tento debug bus vie odpovedať:

```text
Vidím správne bajty za gmii_rx_mac?
Prebehol frame_done?
Prebehol eth_header_parser hdr_done?
Bol L2 accept/drop?
```

Nevie odpovedať:

```text
Prešiel IPv4 parser?
Prešiel UDP parser?
Vznikol udp_hdr_pre_valid?
Vznikol rx_meta_valid?
```

A práve toto teraz potrebuješ, lebo normálne LED hovoria, že `rx_meta_valid=0`.

---

# 7. Čo treba spraviť teraz: nový debug mód RX_PIPE_DEBUG

Teraz by som neprepínal na TX debug. Najprv treba zistiť, kde sa stratí RX cesta pred `rx_meta_valid`.

Navrhujem do top-u pridať parameter:

```systemverilog
parameter bit RX_PIPE_DEBUG = 1'b1
```

a dočasne nahradiť `dbg_ctrl_o` týmto:

```systemverilog
assign dbg_ctrl_o = {
  rx_meta_valid,       // [7]
  rx_meta_ready,       // [6]
  udp_tlast,           // [5]
  udp_tvalid,          // [4]
  udp_hdr_pre_valid,   // [3]
  ipv4_hdr_valid_w,    // [2]
  eth_hdr_valid_w,     // [1]
  mac_frame_done_w     // [0]
};
```

A dátový mux:

```systemverilog
always_comb begin
  if (udp_tvalid)       dbg_mac_data_o = udp_tdata;
  else if (ip_tvalid)   dbg_mac_data_o = ip_tdata;
  else if (eth_tvalid)  dbg_mac_data_o = eth_tdata;
  else if (mac_tvalid)  dbg_mac_data_o = mac_tdata;
  else                  dbg_mac_data_o = 8'hEE;
end
```

Toto je teraz najdôležitejší debug build.

Interpretácia:

```text
J11[0] frame_done = 0:
  problém gmii_rx_mac / PHY RX stream

J11[0]=1, J11[1] eth_hdr_valid=0:
  problém L2 parser alebo alignment

J11[1]=1, J11[2] ipv4_hdr_valid=0:
  problém IPv4 parser / offsety / header bytes

J11[2]=1, J11[3] udp_hdr_pre_valid=0:
  problém UDP parser / UDP offset / dĺžka / s_axis_tlast

J11[3]=1, J11[7] rx_meta_valid=0:
  problém udp_rx_meta_assembler alebo handshake/ready

J11[7]=1, LED3 nebliká:
  problém LED synchronizácie, nie dátovej cesty
```

Toto už nie je hádanie. Jeden capture na J10/J11 povie presnú vrstvu.

---

# 8. Potenciálny RTL problém: `udp_echo_app` + prvý payload byte

Toto nie je dôvod, prečo `rx_meta_valid=0`, ale bude ďalší rizikový bod.

`udp_echo_app` je navrhnutý tak, že prvý payload byte môže prísť v tom istom cykle ako `rx_meta_valid_i`. Preto má:

```systemverilog
assign s_axis_tready = (state_q == ST_RX) ||
                       (state_q == ST_IDLE && rx_meta_valid_i);
```

a v `ST_IDLE`:

```systemverilog
if (rx_meta_valid_i && rx_meta_ready_o) begin
  ...
  if (s_axis_tvalid) begin
    mem[0] <= s_axis_tdata;
    write_ptr_q <= 1;
  end
end
```

Toto je citlivé, ale simulácie ti prechádzajú. Zatiaľ to nechaj tak. Najprv potrebujeme vidieť, či `udp_hdr_pre_valid` a `rx_meta_valid` vôbec vznikajú.

---

# 9. Potenciálny RTL problém: `eth_header_parser` short frame vetva

V `eth_header_parser` je v `ST_HEADER`:

```systemverilog
if (s_axis_tlast) begin
  // Short frame before byte 13 -- discard, reset
end else begin
  byte_cnt_q <= byte_cnt_q + 1;
  case (byte_cnt_q)
    ...
  endcase
end
```

To znamená, že ak by `gmii_rx_mac` z nejakého dôvodu vyrobil `tlast` pred alebo na header byte 13, parser by frame zahodil.

Ale pri normálnych Ethernet rámcoch to nemá nastať. A nové SFD/alignment testy prechádzajú. Skôr by som to overil J11:

```text
mac_frame_done a eth_hdr_valid/hdr_done
```

---

# 10. Potenciálne riziko: `gmii_rx_mac` ignoruje `m_axis_tready`

`gmii_rx_mac` má komentár:

```text
No AXI-Stream backpressure — assumes downstream can always accept data at line rate.
```

a naozaj ignoruje `m_axis_tready`.

V aktuálnej pipeline to zatiaľ môže fungovať, pretože parsery v header/drop stavoch berú dáta stále a echo app má byť pripravená pri UDP payloade. Ale architektonicky je to riziko.

Ak by downstream niekde stiahol ready počas RX rámca, `gmii_rx_mac` bude ďalej posielať dáta a tie sa stratia. Toto by mohlo spôsobiť, že v HW niekedy parsery uvidia posunuté alebo orezané dáta.

Pre prvý bring-up to ešte nemusíš meniť, ale dlhodobo by som dal za `gmii_rx_mac` malý RX FIFO:

```text
gmii_rx_mac -> axis_fifo/small skid FIFO -> eth_header_parser
```

Pre aktuálny problém však najprv zmeraj `RX_PIPE_DEBUG`.

---

# 11. Dôležité upozornenie k Quartus warningu async FIFO

Quartus hlási:

```text
Inferred dual-clock RAM node async_fifo:u_pkt_fifo|mem_rtl_0 ...
read-during-write behavior of a dual-clock RAM is undefined
```

Toto je bežný warning pri ručne inferovanom dual-clock RAM. Tvoj FIFO používa gray pointery a samostatné domény. Ak je FIFO správne navrhnuté, nemal by si čítať a zapisovať tú istú adresu v nebezpečnom stave, ale Quartus to formálne nevie zaručiť.

Nie je to priamy dôvod LED3=0, lebo LED3 je pred FIFO. Ale pre neskoršiu TX cestu by som túto tému nezametol. Po vyriešení RX/meta by som zvážil buď:

```text
- explicitnú altsyncram dual-clock FIFO implementáciu,
- alebo ponechať, ale dôsledne testovať dual-clock FIFO corner cases.
```

---

# 12. Čo teraz spraviť v poradí

## Krok 1 — zachyť aktuálny J10/J11 MAC debug

S aktuálnym bitstreamom zmeraj:

```text
J10 = dbg_mac_data_o
J11 = dbg_ctrl_o
```

Pri jednom UDP pakete skontroluj:

```text
J11[0] mac_tvalid
J11[2] frame_done
J11[3] hdr_done
J11[4] dbg_mac_accept_w
J11[5] mac_drop
```

Ak už tu `hdr_done` alebo `mac_accept` nevyzerajú dobre, ostávame pri RX/L2.

Ak tu všetko vyzerá dobre, pokračuj na krok 2.

## Krok 2 — sprav RX_PIPE_DEBUG build

Pridaj mapu:

```text
J11[0] = mac_frame_done
J11[1] = eth_hdr_valid_w
J11[2] = ipv4_hdr_valid_w
J11[3] = udp_hdr_pre_valid
J11[4] = udp_tvalid
J11[5] = udp_tlast
J11[6] = rx_meta_ready
J11[7] = rx_meta_valid
```

Toto ti dá presný bod zastavenia.

## Krok 3 — podľa výsledku

Ak `ipv4_hdr_valid_w=0`, pozri IP header bajty cez J10 mux.

Ak `udp_hdr_pre_valid=0`, pozri UDP header bajty cez J10 mux.

Ak `udp_hdr_pre_valid=1`, ale `rx_meta_valid=0`, chyba je v `udp_rx_meta_assembler`.

Ak `rx_meta_valid=1`, ale LED3 nebliká, chyba je v LED synchronizácii alebo interpretácii LED.

## Krok 4 — až keď `rx_meta_valid=1`, rieš TX

Potom až prepni debug na:

```text
tx_meta_valid
tx_meta_ready
echo_tvalid
txb_tvalid
txb_tready
txb_fire_w
meta_wr_valid_q
eth_txen_o
```

---

# 13. Oprava statusu

Status v ZIP-e hovorí „Fáza 4C: ipv4_header_parser promiscuous_i=1“. To už nesedí úplne s realitou, lebo v top-e sú promiscuous všetky tri vrstvy:

```text
L2 promiscuous_i = 1
L3 promiscuous_i = 1
L4 promiscuous_i = 1
```

Status by som upravil na:

```text
Fáza 4C: full RX filter bypass, diagnostika miesta pred rx_meta_valid.
Timing PASS.
J10/J11 debug bus prítomný.
Normal LED: LED3=rx_meta_valid, LED4=tx_mac_busy, LED5=ETH_TXEN.
Aktuálny HW problém: LED3/4/5 neblikajú → rx_meta_valid nevzniká.
```

---

## Krátky záver

Tento ZIP som už overil konzistentne:

```text
SHA256: c4671dc3ee1fa7ed5433f1c149df9c66acea75dc1ebe8c67bdb1cb0017b752a8
```

Z tohto ZIP-u vyplýva:

```text
1. Top je aktuálny full top.
2. J10/J11 debug porty sú v top-e, YAML aj vygenerovanom soc_top.
3. Timing je PASS.
4. txb_fire_w je zapracovaný.
5. Filtre L2/L3/L4 sú v promiscuous režime.
6. LED3/4/5 neblikajú znamená: rx_meta_valid nevzniká, TX sa nespustí.
```

Najbližší správny krok je teda **nie ďalšia všeobecná simulácia**, ale **RX_PIPE_DEBUG build na J10/J11**, ktorý naraz ukáže:

```text
frame_done
eth_hdr_valid
ipv4_hdr_valid
udp_hdr_pre_valid
udp_tvalid
rx_meta_valid
```

Tým sa problém rozdelí na presnú vrstvu a prestaneme hádať.
