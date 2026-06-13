Skontroloval som aktuálny `xfcp_test_05(6).zip`.

```text
xfcp_test_05(6).zip
SHA-256: 1be2fa99066150d9d2f3cfba74ff123c7b87f1f3f8cc2ffa2707268c91f8e969
```

## Verdikt

Toto je výrazný posun. Projekt je už **takmer timing-clean**.

Predchádzajúci stav:

```text
WNS: -0.744 ns
```

Aktuálny stav:

```text
CLK125 Slow 85C setup:
  WNS: -0.162 ns
  TNS: -0.557 ns

CLK125 Slow 0C setup:
  WNS: +0.343 ns
  TNS: 0.000 ns

ETH_RXC:
  setup/hold PASS

Fast model:
  CLK125 setup PASS
  ETH_RXC setup/hold PASS
```

To znamená:

```text
funkčne:         PASS
simulácia:       PASS
timing:          skoro PASS, ostáva iba malý Slow 85C deficit
knižničný smer:  veľmi dobrý, ale ešte nie úplne release-clean
```

Toto už nie je široký timing problém. Ostali prakticky posledné úzke miesta.

---

# 1. Najväčší progres oproti predchádzajúcemu stavu

V `xfcp_fabric_endpoint.sv` už vidím aplikovaný aj posledný veľký fix, ktorý sme navrhovali: `wdata_stage`.

Komentár v kóde:

```systemverilog
// wdata_stage: pipeline register between parser data FIFO and engine write FIFO.
// Breaks timing path: parser rd_ptr_q / req_op_r -> engine i_write_buffer.mem.
```

A implementácia:

```systemverilog
logic [AXI_DATA_WIDTH-1:0] wdata_stage_data_r;
logic [SEL_W-1:0]          wdata_stage_sel_r;
logic                      wdata_stage_valid_r;

wire wdata_stage_fire_w =
  wdata_stage_valid_r && eng_wdata_ready[wdata_stage_sel_r];
```

Výstup do engine:

```systemverilog
.write_data       (wdata_stage_data_r),
.write_data_valid (wdata_stage_valid_r && (wdata_stage_sel_r == SEL_W'(gi))),
.write_data_ready (eng_wdata_ready[gi]),
```

Toto je presne správny timing-safe krok. Rozbil si cestu:

```text
parser data FIFO / req_op_r
  -> selected engine write FIFO memory
```

Výsledok je vidieť v STA:

```text
predtým: WNS -0.744 ns
teraz:   WNS -0.162 ns
```

Čiže tento fix reálne zabral.

---

# 2. Aktuálne najhoršie timing cesty

Najhoršia cesta už nie je v parser → write engine ceste. Teraz je najhoršie:

```text
Slack: -0.162 ns

From:
  udp_xfcp_server.u_udp_xfcp.resp_buf RAM portb address register

To:
  eth_tx_arb.u_tx_arb.m_tdata_q[7]

Data delay:
  8.180 ns
```

Toto je dôležitá zmena. Hlavný zostávajúci problém už je mimo hlavnej XFCP fabric cesty. Je to v UDP/IPv4/Ethernet TX výstupnej ceste:

```text
udp_xfcp_server response buffer
  -> IPv4/UDP TX path
  -> eth_tx_arb
  -> m_tdata_q
```

Ďalšie menšie negatívne cesty:

```text
Slack: -0.079 ns

From:
  xfcp_fabric_endpoint.rdata_valid_r

To:
  xfcp_axi_engine[6].i_read_buffer.rd_ptr_q[*]
```

a niekoľko podobných:

```text
packetizer.slot0_valid_q
  -> engine[6].i_read_buffer.rd_ptr_q[*]

Slack: -0.024 ns
```

Čiže aktuálne máme dve oblasti:

```text
A. UDP/Ethernet TX data path:     -0.162 ns
B. endpoint read-data ready path: -0.079 ns
```

To je už veľmi blízko k nule.

---

# 3. Čo je už vyriešené

Doterajšie veľké timing problémy sú prakticky odstránené.

## 3.1 Header FIFO / request ready loop

Opravené cez:

```systemverilog
eng_req_ready_r
```

a registrovaný decode/request stage.

## 3.2 Order FIFO async read loop

Opravené cez:

```systemverilog
ofifo_head_r
ofifo_head_valid_r
```

Toto je veľmi dobré. Z hľadiska knižnice je to správny vzor: nepoužívať fall-through FIFO dáta priamo na rozhodovanie o vlastnom pop-e.

## 3.3 Engine response combinational path

Opravené cez:

```systemverilog
eng_done_rdy[i] = (eng_done_cnt[i] > 0);
```

Teda už tam nie je rýchla kombinácia cez `eng_resp_done`.

## 3.4 Read data výstup z engine

Opravené cez registrovaný výstup:

```systemverilog
read_data
read_data_valid
```

## 3.5 Write payload routing

Opravené cez:

```systemverilog
wdata_stage_data_r
wdata_stage_sel_r
wdata_stage_valid_r
```

Toto je veľký krok ku knižničnej kvalite.

---

# 4. Status dokument je už zastaraný

`XFCP_TEST_05_STATUS.md` stále uvádza:

```text
Aktuálne: -1.296 ns
WNS po rx_parser fixes: -1.296 ns
```

Ale reálny aktuálny compile má:

```text
WNS: -0.162 ns
TNS: -0.557 ns
```

Takže status treba aktualizovať.

Navrhovaný zápis:

```text
## Faza E — Timing Closure 125 MHz [PREBIEHA]

Aplikované:
- xfcp_rx_parser timing fixes
- eng_req_ready_r
- order FIFO head register
- eng_done_rdy counter-only
- read_data output register
- endpoint rdata skid/pipeline
- wdata_stage register parser -> engine write FIFO

Aktuálny výsledok:
- Slow 85C CLK125 WNS: -0.162 ns
- Slow 85C CLK125 TNS: -0.557 ns
- Slow 0C CLK125 WNS: +0.343 ns
- ETH_RXC: PASS
- Sim: 53/53 PASS

Zostáva:
- UDP response buffer -> ETH TX arbiter path
- minor read_data_ready path endpoint -> engine read FIFO
```

A stále by som nechal:

```text
Functional bring-up PASS.
Timing closure almost closed, but not yet release-clean.
```

---

# 5. Čo spraviť teraz pre posledných 0.162 ns

## Priorita 1 — pipeline/register slice na UDP/Ethernet TX ceste

Najhoršia cesta:

```text
udp_xfcp_server.resp_buf RAM
  -> eth_tx_arb.m_tdata_q
```

Najmenší zásah:

```text
vložiť AXIS register slice medzi UDP/IPv4 TX výstup a eth_tx_arb
```

Možné miesta:

```text
A) medzi udp_xfcp_server a ipv4_tx_udp
B) medzi ipv4_tx_udp a eth_tx_arb
C) priamo na vstup portu 2 v eth_tx_arb
D) výstupný register v eth_tx_arb pred m_tdata_q
```

Najbezpečnejšie by som zvolil:

```text
medzi ipv4_tx_udp a eth_tx_arb
```

Prečo? Lebo najhoršia cesta končí v `eth_tx_arb.m_tdata_q`. Ak pridáš register slice pred arbiter alebo v jeho vstupe, skrátiš dátovú cestu do výstupného muxu.

Ak už máš všeobecný `axis_skid_buffer` alebo `axis_register_slice`, použi ho:

```systemverilog
axis_register_slice #(
  .DATA_WIDTH(8)
) u_udp_tx_slice (
  .clk(clk_i),
  .rst_n(rstn_w),

  .s_valid(udp_ipv4_axis_valid),
  .s_data (udp_ipv4_axis_data),
  .s_last (udp_ipv4_axis_last),
  .s_ready(udp_ipv4_axis_ready),

  .m_valid(udp_to_arb_valid),
  .m_data (udp_to_arb_data),
  .m_last (udp_to_arb_last),
  .m_ready(udp_to_arb_ready)
);
```

Ak nemáš čistý register slice pre `valid/data/last`, doplň jednoduchý 1-beat skid. Pri Ethernet TX dátach je 1 cyklus navyše úplne v poriadku.

Očakávam, že toto odstráni hlavnú `-0.162 ns` cestu.

---

## Priorita 2 — read-data ready path

Druhá oblasť:

```text
rdata_valid_r / packetizer.slot0_valid_q
  -> engine[6].i_read_buffer.rd_ptr_q
```

To je cesta cez:

```text
packetizer read_data_ready
  -> endpoint rdata_ready_int
  -> engine read_data_ready
  -> engine rfifo_rready_w
  -> read buffer rd_ptr enable
```

Už je malá:

```text
-0.079 ns
```

Ak po UDP TX slice stále ostane negatívny slack, riešil by som ju takto:

### Možnosť A — registrovať `read_data_ready` do engine

V `xfcp_axi_engine` by sa read FIFO nepopovalo priamo podľa okamžitého downstream ready, ale cez lokálny 1-word output register/skid.

Teraz máš:

```systemverilog
assign rfifo_rready_w = !read_data_valid || read_data_ready;
```

Táto kombinácia robí cestu z packetizer/endpoinu do interného FIFO pointeru.

Knižničnejšie riešenie:

```text
read FIFO -> engine output register -> endpoint
```

s tým, že interný FIFO pop sa riadi iba lokálnym stavom registra, nie priamo packetizer ready cestou.

Teda:

```systemverilog
wire out_can_load_w = !read_data_valid || read_data_consumed_q;
```

kde `read_data_consumed_q` je registrovaná verzia handshaku, alebo použiť dvojprvkový skid, aby sa neťahala ready cesta späť do FIFO pointeru v rovnakom cykle.

### Možnosť B — nechať zatiaľ tak

Keďže je to iba `-0.079 ns`, je možné, že po malom placer seed alebo po UDP slice sa to presunie do plusu. Ale pre knižnicu by som časom chcel túto ready cestu tiež odstrihnúť.

---

# 6. Warningy, ktoré treba evidovať

Niektoré warningy sú neškodné, ale pár by som sledoval.

## 6.1 ALTDDIO input not packed to I/O pin

```text
Warning (176225): Can't pack node altddio_in input_cell_h[...] to I/O pin
```

Toto sme už videli pri ETH RX. Keďže ETH_RXC timing teraz hlási:

```text
ETH_RXC setup slack: +1.187 ns
ETH_RXC hold slack:  +0.430 ns
```

nie je to aktuálne blocker. Ale pre stabilitu GMII RX to treba mať stále v povedomí.

## 6.2 ASYNC_REG attribute nerozpoznaný

```text
Warning (10335): Unrecognized synthesis attribute "ASYNC_REG"
```

Quartus tento atribút ignoruje. Pre Intel by bolo vhodnejšie doplniť Intel/Quartus kompatibilný atribút alebo assignment pre synchronizer identification. Nie je to priamy blocker, ale CDC knižnica by to mala riešiť.

## 6.3 `xfcp_out.TKEEP/TUSER/TID/TDEST` no driver

```text
Output port "xfcp_out.TKEEP" has no driver
Output port "xfcp_out.TUSER[0]" has no driver
...
```

Pre AXI-Stream interface by bolo čistejšie tieto signály viazať:

```systemverilog
assign xfcp_out.TKEEP = '1;
assign xfcp_out.TUSER = '0;
assign xfcp_out.TID   = '0;
assign xfcp_out.TDEST = '0;
```

Nie je to funkčný problém, ale pre knižničný modul by som nechcel mať no-driver warningy.

## 6.4 `xfcp_rx_parser` unused regs

Warningy typu:

```text
dec_seq assigned but never read
dec_valid assigned but never read
opcode_q/count_q/addr_q assigned but never read
```

Sú pravdepodobne pozostatky po timing refaktore. Pre release by som ich odstránil alebo obalil debugom. Neprekáža to funkcii, ale knižničný kód by mal byť čistejší.

---

# 7. Stav voči cieľu `xfcp_lib`

## Knižnične dobré veci

Už máme dobrý základ:

```text
- dual transport: UART + UDP
- robustný UART transport cez uart_fifo_os
- UDP transport funguje
- spoločný AXI-Lite endpoint
- parser/packetizer oddelené
- arbiter s order FIFO routingom
- timing staging vo fabric endpointe
- sim 53/53 PASS
- HW funkčný stav z predchádzajúceho buildu
```

## Ešte nie je `xfcp_lib_v1_0`

Blokery:

```text
1. CLK125 stále má WNS -0.162 ns.
2. XFCP protokol stále nemá explicitný STATUS/ERROR byte.
3. DIAG ešte nemá plný last_error/timeout/drop model.
4. Arbiter je stále špecifický 2-port UART+UDP variant.
5. Dokumentácia statusu je zastaraná voči aktuálnemu compile.
```

Ale už sme veľmi blízko k:

```text
xfcp_lib_v0_9 timing-clean candidate
```

---

# 8. Navrhovaný ďalší postup

## Krok 1 — pridať register slice na UDP TX cestu

Najbližší RTL zásah:

```text
ipv4_tx_udp -> axis_register_slice -> eth_tx_arb
```

alebo ekvivalentný vstupný stage v `eth_tx_arb`.

Potom:

```bash
make sim
make compile
```

Cieľ:

```text
Slow 85C CLK125 WNS >= 0
TNS = 0
```

---

## Krok 2 — ak ešte ostane malý fail, riešiť read_data_ready path

Ak po UDP slice ostane napríklad `-0.05 ns`, potom riešiť:

```text
packetizer read_data_ready -> engine read FIFO pointer
```

cez lokálny output skid/register v `xfcp_axi_engine`.

---

## Krok 3 — aktualizovať status

Zmeniť `XFCP_TEST_05_STATUS.md` podľa aktuálneho stavu:

```text
WNS -0.162 ns
TNS -0.557 ns
wdata_stage aplikovaný
zostáva UDP TX path + minor read ready path
```

---

## Krok 4 — po timing PASS urobiť HW regresiu

Po timing-clean builde:

```bash
make program
make test-uart
make test-uart
make test-udp
make test-udp
make hw-test
```

A doplniť cross testy:

```bash
make test-cross-uart-udp
make test-cross-udp-uart
```

---

## Krok 5 — označiť `xfcp_lib_v0_9`

Keď timing prejde:

```text
xfcp_lib_v0_9:
  dual transport UART+UDP
  AXI-Lite endpoint
  timing-clean 125 MHz
  sim PASS
  HW UART/UDP PASS
```

---

## Krok 6 — až potom protokol STATUS/ERROR

Pre `xfcp_lib_v1_0` by som zaviedol:

```text
XFCP_STATUS_OK
XFCP_STATUS_BAD_OPCODE
XFCP_STATUS_BAD_LENGTH
XFCP_STATUS_BAD_ADDRESS
XFCP_STATUS_AXI_SLVERR
XFCP_STATUS_AXI_DECERR
XFCP_STATUS_TIMEOUT
XFCP_STATUS_BUSY
XFCP_STATUS_OVERFLOW
```

To bude hranica medzi:

```text
v0.9 = funkčne/timingovo stabilný transport + AXI-Lite endpoint
v1.0 = robustný vývojový protokol s chybovými odpoveďami
```

---

# 9. Moje hodnotenie aktuálneho stavu

```text
Funkčný stav:          veľmi dobrý
Timing progres:        výborný, ostáva iba -0.162 ns
Knižničný smer:        správny
UART transport:        vyriešený
UDP transport:         funkčný, teraz najhoršia timing cesta
Fabric endpoint:       výrazne zlepšený
Dokumentácia:          užitočná, ale teraz neaktuálna
Release stav:          ešte nie, ale veľmi blízko
```

Známka:

```text
Ako vývojový prototyp:       9/10
Ako timing-clean kandidát:   8.5/10
Ako xfcp_lib_v0.9:           takmer hotové
Ako xfcp_lib_v1.0:           ešte chýba STATUS/ERROR protokol
```

---

## Záver

Tento stav je veľmi dobrý. Doterajšie veľké timing problémy vo fabric endpointe sú skoro vyriešené. Ostal malý `-0.162 ns` deficit, pričom najhoršia cesta je už v UDP/Ethernet TX dátovej ceste, nie v hlavnej XFCP parser/engine architektúre.

Najbližší krok by som spravil presne tento:

```text
vložiť AXIS register slice medzi UDP/IPv4 TX cestu a eth_tx_arb,
prekompilovať,
a očakávať WNS >= 0.
```

Ak to prejde, máme veľmi silného kandidáta na `xfcp_lib_v0_9`. Potom už dáva zmysel začať protokolový `STATUS/ERROR` refaktor pre `xfcp_lib_v1_0`.
