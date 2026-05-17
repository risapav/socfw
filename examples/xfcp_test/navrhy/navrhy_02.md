Nižšie je návrh testovania aj ďalšieho postupu. Beriem do úvahy aktuálny stav: cieľom projektu je XFCP cez UART do AXI-Lite periférií, pričom hardvérové testy sú podľa statusu ešte nezačaté .

## Aktuálne zistenie z posledného logu

Nový log už je lepší než predtým: simulácia **nevisí potichu**, ale končí timeoutom:

```text
Fatal: uart_recv timeout ... DUT did not respond
```

Kľúčové je toto:

```text
UART valid: data=0xfe
...
S_HDR byte cnt=0 data=0x44
```

Testbench posiela po `0xFE` opcode `0x11`, ale UART RX do parsera prijme `0x44`. To znamená, že problém teraz nie je primárne AXI-Lite periféria, ale **UART RX / testbench UART timing / dekódovanie sériovej linky**. Parser nedostane korektný header, takže bridge nikdy nevygeneruje AXI transakciu ani odpoveď.

Preto by som testovanie rozdelil zdola nahor.

---

# 1. Testovanie modulov — odporúčaná pyramída

## Úroveň A — čisté utility moduly

Tieto testy sú najlacnejšie a majú byť stabilné pred integráciou.

### `xfcp_fifo.sv`

Otestovať:

```text
T1 reset empty
T2 single write/read
T3 fill to full
T4 read from full to empty
T5 simultaneous read/write
T6 fall-through správanie
T7 flush
T8 random backpressure
```

Dôležité checky:

```systemverilog
assert(w_ready == 0 pri full);
assert(r_valid == 0 pri empty);
assert(data_order == expected_order);
```

### `xfcp_id_rom.sv`

Otestovať:

```text
T1 ID response začne správnym SOP/opcode
T2 DEV_TYPE má očakávanú hodnotu
T3 ID_STR má presne 16 bajtov
T4 TLAST príde iba na poslednom bajte
T5 backpressure na výstupe nezmení poradie dát
```

### `uart_baud_gen.sv`

Otestovať samostatne, pretože aktuálny problém vyzerá práve na UART timing.

```text
T1 prescale=16: end_tick každých 16 taktov
T2 half_tick je v strede bitu
T3 start_i znovu nafázuje counter
T4 enable_i=0 zastaví tickovanie
T5 prescale malé hodnoty: 2, 3, 4
```

---

## Úroveň B — UART core testy

Tu treba teraz začať, lebo aktuálny log ukazuje zlé prijatie bajtu.

### `uart_core_rx.sv`

Najprv bez AXI wrappera.

Otestovať sekvencie:

```text
T1 prijmi 0x00
T2 prijmi 0xFF
T3 prijmi 0x55
T4 prijmi 0xAA
T5 prijmi 0x11
T6 prijmi 0xFE
T7 back-to-back bajty bez medzery
T8 back-to-back bajty s 1 stop bitom navyše
T9 frame error: stop bit = 0
T10 false start: krátky impulz na RX
```

Pre aktuálny problém sú najdôležitejšie bajty:

```text
0xFE
0x11
0x00
0x04
0xFF
0x02
0x00
0x04
```

Presne tie tvoria začiatok XFCP WRITE paketu.

Ak `uart_core_rx` prijme `0x11` ako `0x44`, netreba ešte riešiť XFCP.

### `uart_core_tx.sv`

Otestovať:

```text
T1 odvysielaj 0x00
T2 odvysielaj 0xFF
T3 odvysielaj 0x55
T4 odvysielaj 0xAA
T5 odvysielaj 0x11
T6 ready_o je 0 počas vysielania
T7 tx_done_pulse_o príde po stop bite
```

### `uart.sv` loopback

Potom spojiť TX → RX:

```systemverilog
assign rx_i = tx_o;
```

Testy:

```text
T1 pošli 1 bajt, prijmi rovnaký
T2 pošli 16 bajtov back-to-back
T3 pošli XFCP header sekvenciu
T4 prescale=16 sim
T5 prescale=434 približný HW režim
```

---

## Úroveň C — AXI-Stream UART wrappery

### `axis_uart_rx`

Otestovať:

```text
T1 z UART linky príde 0xFE → m_axis.TDATA=0xFE
T2 10 bajtov back-to-back
T3 TREADY=0 na pár taktov → overrun/error správanie
T4 AXIS_TLAST=0 režim: TLAST musí byť vždy 0
T5 AXIS_TLAST=1 režim: TLAST pri každom bajte, ak to wrapper podporuje
```

Pre XFCP cez UART odporúčam fixné pravidlo:

```systemverilog
xfcp_rx_s.TLAST = 1'b0;
```

alebo `axis_uart_rx #(.AXIS_TLAST(1'b0))`.

### `axis_uart_tx`

Otestovať:

```text
T1 jeden AXIS bajt → sériový UART bajt
T2 viac bajtov po sebe
T3 TVALID držané počas TREADY=0
T4 TLAST ignorovaný alebo korektne prenesený iba ako metadata
```

---

## Úroveň D — XFCP parser / packetizer bez UART

Toto treba testovať priamo cez AXI-Stream bajty, nie cez UART. Tak sa oddelí protokol od sériovej linky.

### `xfcp_rx_parser.sv`

Priamo poslať bajty:

```text
FE 10 00 04 FF 02 00 04
FE 11 00 04 FF 02 00 04 00 00 00 3F
```

Testy:

```text
T1 READ header: opcode=READ, count=4, addr=0xFF020004
T2 WRITE header + payload: write_data=0x0000003F
T3 COUNT nie je násobok 4 → error_protocol
T4 zlý opcode → error_protocol
T5 zlý SOP ignorovaný
T6 SOP recovery počas poškodeného paketu
T7 backpressure na req_ready
T8 backpressure na write_data_ready
T9 TLAST=1 uprostred headera → drop
T10 UART režim TLAST=0 celý čas → musí fungovať podľa COUNT
```

Pozor: v `xfcp_rx_parser.sv` vidím podozrivý nesúlad medzi komentárom a dekódovaním:

```systemverilog
wire [7:0] dec_opcode = hdr_shift_n_comb[55:48];
wire [15:0] dec_count = hdr_shift_n_comb[47:32];
wire [31:0] dec_addr  = hdr_shift_n_comb[31:0];
```

Pri 7 bajtoch po SOP by logicky malo byť skôr:

```systemverilog
dec_opcode = hdr_shift_n_comb[55:48];
dec_count  = hdr_shift_n_comb[47:32];
dec_addr   = hdr_shift_n_comb[31:0];
```

Toto je konzistentné s tým, že SOP sa do shift registra neukladá a po siedmich bajtoch máš:

```text
[55:48] opcode
[47:32] count
[31:0]  addr
```

Čiže samotné aktuálne priradenie vyzerá použiteľne, ale komentáre vyššie v súbore stále opisujú staršie rozloženie `[63:56]`. Odporúčam komentáre vyčistiť, aby ťa neskôr nezavádzali.

### `xfcp_tx_packetizer.sv`

Testovať bez AXI a bez UART:

```text
T1 WRITE response: FE 13 ... 00, TLAST na poslednom bajte
T2 READ response: FE 12 ... DATA ... 00
T3 data MSB-first
T4 backpressure na m_axis_tready
T5 dve odpovede po sebe
T6 ID_STR presne 16 bajtov
```

---

## Úroveň E — `xfcp_axi_engine.sv` s AXI-Lite slave modelom

Tu už netreba UART. Vstupom sú `req_hdr` a `write_data`.

Testy:

```text
T1 WRITE jeden word → AW/W/B
T2 READ jeden word → AR/R
T3 WRITE viac wordov: count=8 alebo 16
T4 READ viac wordov
T5 adresa sa inkrementuje +4
T6 AXI slave oneskorí AWREADY
T7 AXI slave oneskorí WREADY
T8 AXI slave oneskorí BVALID
T9 AXI slave oneskorí RVALID
T10 timeout keď slave neodpovie
```

Dôležitý test pre tvoju opravu:

```text
WRITE nesmie začať, kým nie je dostupný payload word vo wfifo.
```

Čiže v testbenchi zámerne držať `write_data_valid=0` po príchode headera a overiť, že engine nevygeneruje AW/W predčasne.

---

## Úroveň F — `xfcp_axil_bridge_2.sv` bez UART

Toto je najdôležitejší integračný test pred top-level UART testom.

Vstup: AXI-Stream bajty priamo do `xfcp_in`.

Výstup: AXI-Stream bajty z `xfcp_out`.

Pripojiť jednoduchý AXI-Lite slave model.

Testy:

```text
T1 XFCP WRITE LED addr → AXI WRITE, potom WRITE response
T2 XFCP READ LED addr → AXI READ, potom READ response s dátami
T3 WRITE + READ back-to-back
T4 READ počas packetizer busy
T5 AXI slave s wait-state
T6 zlý opcode → žiadna AXI transakcia
T7 count=8 multiword write
T8 count=8 multiword read
```

Až keď toto prejde, má zmysel testovať UART top.

---

## Úroveň G — `xfcp_uart_mmio_top.sv`

Toto je až posledná simulácia v reťazci.

Aktuálne `tb_xfcp_uart_mmio_top.sv` má dobrý smer, ale pred jeho opakovaním treba vyriešiť UART byte mismatch.

Top-level testy:

```text
T1 UART WRITE LED 0x3F → led_o=0x3F
T2 UART READ LED → 0x0000003F
T3 UART READ SYSC COMPONENT_ID → 0x53595343
T4 UART READ UART COMPONENT_ID → 0x55415254
T5 UART READ OUT_ COMPONENT_ID → 0x4F55545F
T6 UART READ SEG7 COMPONENT_ID → 0x53454737
T7 UART WRITE SEG7 digits
T8 UART WRITE baud_div/config, overiť zmenu config_w
T9 zlý packet → žiadna odpoveď alebo error podľa politiky
T10 back-to-back READ/WRITE bez resetu
```

---

# 2. Okamžitý debug krok pre aktuálny timeout

Teraz by som neriešil ešte AXI decoder. Najprv over UART RX.

Do `tb_xfcp_uart_mmio_top.sv` dočasne pridaj log priamo v `uart_send()`:

```systemverilog
task automatic uart_send(input logic [7:0] b);
  $display("[%0t] TB UART SEND 0x%02h", $time, b);
  @(negedge clk); uart_rx_i = 1'b0;
  repeat(BAUD_DIV) @(posedge clk);

  for (int i = 0; i < 8; i++) begin
    @(negedge clk); uart_rx_i = b[i];
    repeat(BAUD_DIV) @(posedge clk);
  end

  @(negedge clk); uart_rx_i = 1'b1;
  repeat(BAUD_DIV) @(posedge clk);
endtask
```

Potom porovnaj:

```text
TB UART SEND 0x11
DBG UART valid: data=?
```

Ak bude stále `0x44`, problém je čisto v UART RX alebo v časovaní TB.

Na rýchle obídenie problému odporúčam dočasný testbench režim bez sériovej linky:

```systemverilog
// Namiesto uart_send() priamo tlačiť bajty do xfcp_rx_s
task automatic axis_send(input logic [7:0] b);
  @(posedge clk);
  force dut.xfcp_rx_s.TDATA  = b;
  force dut.xfcp_rx_s.TVALID = 1'b1;
  force dut.xfcp_rx_s.TLAST  = 1'b0;
  wait (dut.xfcp_rx_s.TREADY);
  @(posedge clk);
  force dut.xfcp_rx_s.TVALID = 1'b0;
  release dut.xfcp_rx_s.TDATA;
  release dut.xfcp_rx_s.TVALID;
  release dut.xfcp_rx_s.TLAST;
endtask
```

Ešte lepšie je vytvoriť samostatný testbench pre `xfcp_axil_bridge_2`, kde UART vôbec nebude.

---

# 3. RTL problémy, ktoré by som opravil pred ďalším postupom

## 3.1 V top module je chyba v komentári aj potenciálne v kóde

V `xfcp_uart_mmio_top.sv` je pri LED registroch:

```systemverilog
axil_regs u_led_regs (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .rst_ni(rst_ni),
    .s_axil(axil_led.slave),
    .data_o(led_data_w)
);
```

Je tam duplicitné `.rst_ni(rst_ni)`. Ak to prešlo kompiláciou, možno sa kompiluje iná verzia, ale v zdrojáku to treba odstrániť.

Správne:

```systemverilog
axil_regs u_led_regs (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .s_axil(axil_led.slave),
    .data_o(led_data_w)
);
```

## 3.2 AXI-Lite decoder používa `aw_slot_w` aj pre W kanál

Aktuálne:

```systemverilog
assign axil_led.WVALID = axil_m.WVALID & (aw_slot_w == 2'h2);
```

To je bezpečné len vtedy, ak master vždy drží AWADDR stabilnú počas W fázy a AW/W idú spolu. AXI-Lite to negarantuje všeobecne.

Robustnejšie je používať registrovaný write slot po AW handshake:

```systemverilog
assign axil_sysc.WVALID   = axil_m.WVALID & (wr_slot_r == 2'h0);
assign axil_uart_s.WVALID = axil_m.WVALID & (wr_slot_r == 2'h1);
assign axil_led.WVALID    = axil_m.WVALID & (wr_slot_r == 2'h2);
assign axil_seg.WVALID    = axil_m.WVALID & (wr_slot_r == 2'h3);
```

A tiež `WREADY` multiplexovať podľa `wr_slot_r`, nie podľa aktuálneho `aw_slot_w`.

Pre aktuálny engine, ktorý možno posiela AW a W blízko pri sebe, to môže fungovať, ale do frameworku by som to nedával ako finálne riešenie.

## 3.3 Nechať iba jeden `xfcp_axil_bridge`

Stále platí: mať v projekte naraz:

```text
xfcp_axil_bridge.sv
xfcp_axil_bridge_2.sv
```

a v oboch `module xfcp_axil_bridge` je riziko. Finálne odporúčam:

```text
xfcp_axil_bridge.sv      // aktuálna verzia
xfcp_axil_bridge_old.sv  // mimo compile listu, alebo odstrániť
```

---

# 4. Navrhované poradie ďalšieho postupu

## Fáza 1 — stabilizovať simulácie

Poradie:

```text
1. tb_uart_core_rx
2. tb_uart_core_tx
3. tb_uart_loopback
4. tb_xfcp_rx_parser
5. tb_xfcp_tx_packetizer
6. tb_xfcp_axi_engine
7. tb_xfcp_axil_bridge
8. tb_xfcp_uart_mmio_top
```

Exit kritérium pre fázu 1:

```text
Všetky uvedené testy skončia ALL PASSED.
Žiadny test nesmie visieť bez timeoutu.
Každý UART/XFCP helper má timeout.
```

---

## Fáza 2 — opraviť top-level integráciu

Úlohy:

```text
1. odstrániť duplicitu .rst_ni v u_led_regs
2. upraviť AXI decoder tak, aby W kanál používal registrovaný write slot
3. ponechať TLAST=0 z UART RX do XFCP parsera
4. potvrdiť LITTLE_ENDIAN politiku
5. vyčistiť komentáre v parseri a top module
```

Pri byte order by som zatiaľ nechal:

```systemverilog
.LITTLE_ENDIAN(1'b0)
```

a v Python nástroji aj TB posielať dáta MSB-first:

```text
0x0000003F -> 00 00 00 3F
```

To je jednoduché a zodpovedá aktuálnemu testbenchu.

---

## Fáza 3 — rozšíriť integračný top test

Po prvom PASS pre LED pridať register scan:

```text
READ 0xFF000000 → SYSC
READ 0xFF010000 → UART
READ 0xFF020000 → OUT_
READ 0xFF030000 → SEG7
```

Potom testovať zápisy:

```text
WRITE LED_STATE
WRITE SEG7 DIGITS
WRITE UART BAUD_DIV
WRITE UART ERRCLR
```

A negatívne testy:

```text
READ neexistujúci offset
READ neexistujúci slot
WRITE RO register
COUNT=0
COUNT=2
zlý opcode
zlý SOP
```

---

## Fáza 4 — Quartus build

Až keď simulácia prejde, zaradiť do Quartusu:

```text
xfcp_pkg.sv
axi_pkg.sv
axi_interfaces.sv
uart_pkg.sv
uart_baud_gen.sv
uart_core_rx.sv
uart_core_tx.sv
axis_uart_rx.sv
axis_uart_tx.sv
xfcp_fifo.sv
xfcp_rx_parser.sv
xfcp_axi_engine.sv
xfcp_tx_packetizer.sv
xfcp_id_rom.sv
xfcp_axil_bridge.sv
axil_sys_ctrl.sv
axil_uart_adapter.sv
axil_regs.sv
axil_seven_seg_adapter.sv
xfcp_uart_mmio_top.sv
```

Pred syntézou skontrolovať:

```text
1. žiadne duplicitné moduly
2. žiadne simulation-only $display mimo translate_off
3. správne include guards
4. top porty zodpovedajú board pinoutu
5. UART baud_div default = 434 pre 50 MHz / 115200
```

---

## Fáza 5 — prvý FPGA bring-up

Najprv nespúšťať celý Python framework. Spraviť malý minimálny skript:

```text
T1 otvor /dev/ttyUSB0 @115200
T2 READ SYSC ID
T3 READ UART ID
T4 READ OUT_ ID
T5 WRITE LED 0x01
T6 WRITE LED 0x02
T7 WRITE LED 0x3F
T8 READ LED back
T9 WRITE SEG7 0x00000C41 napr. "123" podľa mapovania
```

Až potom spúšťať `main.py` a scanner.

---

# 5. Projektový ďalší postup

## Najbližší praktický cieľ

Cieľ na najbližší krok by som definoval takto:

```text
Dosiahnuť PASS pre tb_xfcp_axil_bridge bez UART.
Dosiahnuť PASS pre tb_uart_core_rx na bajtoch XFCP headera.
Až potom znova pustiť tb_xfcp_uart_mmio_top.
```

Tým oddelíš dve veci:

```text
XFCP/AXI logika funguje?
UART linka funguje?
```

Teraz sú zamiešané dokopy a preto je debug ťažší.

## Potom

```text
1. stabilizovať RTL testy
2. opraviť top decoder
3. premenovať/odstrániť duplicitný bridge
4. vyčistiť Python scanner.py a main.py
5. spraviť minimálny bring-up skript
6. FPGA flash
7. Python DynamicScanner
8. rozšírenie frameworku o examples/xfcp_test
```

## Odporúčaná štruktúra `sim/`

```text
sim/
  common/
    uart_tasks.svh
    axis_tasks.svh
    axi_lite_slave_model.sv
    xfcp_tasks.svh

  unit/
    tb_uart_baud_gen.sv
    tb_uart_core_rx.sv
    tb_uart_core_tx.sv
    tb_xfcp_fifo.sv
    tb_xfcp_rx_parser.sv
    tb_xfcp_tx_packetizer.sv
    tb_xfcp_axi_engine.sv

  integration/
    tb_uart_loopback.sv
    tb_xfcp_axil_bridge.sv
    tb_xfcp_uart_mmio_top.sv

  run/
    run_unit.do
    run_integration.do
    run_all.do
```

---

# 6. Moje odporúčanie pre úplne ďalší krok

Sprav najprv nový malý test:

```text
tb_uart_core_rx.sv
```

a pošli do neho presne túto sekvenciu:

```text
FE 11 00 04 FF 02 00 04 00 00 00 3F
```

Ak prijme:

```text
FE 11 00 04 FF 02 00 04 00 00 00 3F
```

pokračuj na `tb_xfcp_rx_parser`.

Ak prijme:

```text
FE 44 ...
```

tak je chyba v UART RX alebo v TB `uart_send()` časovaní a top-level XFCP zatiaľ nemá zmysel ladiť.
