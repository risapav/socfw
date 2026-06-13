Skontroloval som oba archívy:

```text
xfcp_test_05(9).zip
SHA-256: 6d687a7599ab8c59f65f115359dc1b2375b829666814f0615ec48af317b867bd

xfcp_test_06.zip
SHA-256: fa835db65f0e9e90fa851258ae7419ce1fcddd85ca48f258b32d601287737217
```

## Verdikt

Progres je veľmi dobrý. `xfcp_test_05(9)` je stabilný timing-clean referenčný návrh pre `xfcp_lib_v0.9`. `xfcp_test_06` je prvý reálny krok smerom k `xfcp_lib_v1.0`, pretože už zavádza **STATUS byte v odpovedi** a Python nástroje ho dekódujú.

Aktuálne by som to zhrnul takto:

```text
xfcp_test_05(9):
  v0.9 reference design
  UART + UDP + AXI-Lite endpoint
  timing PASS
  sim/HW podľa statusu PASS
  bez explicitného STATUS byte

xfcp_test_06:
  v0.9+STATUS experiment / v1.0 candidate start
  response header = SOP + TYPE + SEQ + STATUS
  AXI BRESP/RRESP/TIMEOUT mapované do STATUS
  Python decoder už STATUS kontroluje
  sim PASS
  timing PASS
  HW log v archíve nevidím, takže HW treba ešte potvrdiť alebo doplniť do statusu
```

Najdôležitejšia zmena je, že sme sa posunuli od „fungujúceho control fabricu“ k protokolu, ktorý vie v odpovedi niesť chybu.

---

# 1. Stav `xfcp_test_05(9)`

`xfcp_test_05(9)` je podľa mňa uzavretý ako referenčný v0.9 návrh.

Reálny STA report v archíve:

```text
Slow 85C CLK125 setup slack:  +0.554 ns
Slow 85C ETH_RXC setup slack: +0.761 ns
Slow 85C CLK125 hold slack:   +0.428 ns
Fast 0C CLK125 setup slack:   +2.982 ns
TNS:                          0.000
Seed:                         5
```

Resource usage:

```text
Logic elements: 25,487 / 55,856  (46 %)
Registers:      20,124
Memory bits:    34,304
PLL:            1
```

Status v MD ešte v časti Fáza E uvádza staršiu hodnotu `+0.018 ns / SEED 3`, ale reporty v archíve ukazujú lepší stav `+0.554 ns / SEED 5`. Čiže dokumentácia je čiastočne pozadu.

Môj záver pre `xfcp_test_05(9)`:

```text
xfcp_test_05 = timing-clean v0.9 reference design
```

To by som už ďalej nemenil okrem dokumentačného upratania.

---

# 2. Stav `xfcp_test_06`

`xfcp_test_06` je nový smer: **STATUS vrstva**.

V `xfcp_pkg.sv` pribudlo:

```systemverilog
typedef enum logic [7:0] {
  XFCP_ST_OK             = 8'h00,
  XFCP_ST_BAD_OPCODE     = 8'h01,
  XFCP_ST_BAD_LENGTH     = 8'h02,
  XFCP_ST_BAD_ADDRESS    = 8'h03,
  XFCP_ST_AXI_SLVERR     = 8'h04,
  XFCP_ST_AXI_DECERR     = 8'h05,
  XFCP_ST_TIMEOUT        = 8'h06,
  XFCP_ST_BUSY           = 8'h07,
  XFCP_ST_OVERFLOW       = 8'h08,
  XFCP_ST_UNSUPPORTED    = 8'h09,
  XFCP_ST_INTERNAL_ERROR = 8'h7F
} xfcp_status_e;
```

A nový response header:

```text
byte 0: SOP      0xFD
byte 1: TYPE     0x12 READ_RESP / 0x13 WRITE_RESP
byte 2: SEQ
byte 3: STATUS
byte 4..payload
last: 0x00 trailer
```

Toto je presne krok, ktorý sme potrebovali pred AXI-Stream / AXI-Full / CPU adaptérmi.

---

# 3. Čo je v `xfcp_test_06` dobre

## 3.1 Packetizer už posiela STATUS

`xfcp_tx_packetizer.sv` má nový vstup:

```systemverilog
input wire [7:0] resp_status_i
```

a header:

```systemverilog
hdr_vec[ 0 +: 8] = XFCP_SOP_RESP;
hdr_vec[ 8 +: 8] = xfcp_op_e'(resp_type);
hdr_vec[16 +: 8] = resp_seq;
hdr_vec[24 +: 8] = resp_status_i;
```

Teda response už nie je starý 21-bajtový formát s `DEV_TYPE/DEV_STR`, ale krátky 4-bajtový header so statusom. To je lepšie pre knižnicu.

---

## 3.2 AXI engine mapuje AXI chyby do XFCP STATUS

V `xfcp_axi_engine.sv` je:

```systemverilog
output logic [7:0] resp_status_o
```

a engine zachytáva:

```systemverilog
BRESP 2'b10 -> XFCP_ST_AXI_SLVERR
BRESP 2'b11 -> XFCP_ST_AXI_DECERR

RRESP 2'b10 -> XFCP_ST_AXI_SLVERR
RRESP 2'b11 -> XFCP_ST_AXI_DECERR

watchdog timeout -> XFCP_ST_TIMEOUT
```

Výstup:

```systemverilog
assign resp_status_o =
  error_timeout ? 8'(XFCP_ST_TIMEOUT) : 8'(axi_status_q);
```

To je architektonicky správne. Konečne vie FPGA odpovedať „niečo sa pokazilo“ bez toho, aby host len timeoutol.

---

## 3.3 Fabric endpoint prenáša status až do packetizeru

V `xfcp_fabric_endpoint.sv` je:

```systemverilog
logic [7:0] eng_resp_status [NUM_SLAVES];
logic [7:0] resp_status_q;
```

Pri štarte odpovede sa status zachytí:

```systemverilog
resp_status_q <= eng_resp_status[ofifo_head_r.sel];
```

a potom ide do packetizeru:

```systemverilog
.resp_status_i(resp_status_q)
```

To je správne: status sa lakuje spolu so `sel/type/seq`, takže sa počas odpovede nemôže zmeniť.

---

## 3.4 Python nástroje už status kontrolujú

V `tools/xfcp/protocol.py`:

```python
if raw[3] != 0x00:
    raise XfcpStatusError(raw[3], context='read')
```

a pre write rovnako.

V `tools/xfcp/errors.py` sú status názvy:

```python
0x04: 'AXI_SLVERR'
0x05: 'AXI_DECERR'
0x06: 'TIMEOUT'
...
```

Toto je veľký posun. Už nebudeš mať len `TIMEOUT` alebo `bad response length`; klient vie rozlíšiť protokolovú chybu v odpovedi.

---

## 3.5 Simulácia prešla

Logy:

```text
tb_xfcp_arbiter_2to1:   PASS
tb_udp_xfcp_server:     PASS
tb_xfcp_test_06_top:    PASS
```

V integračnom teste sa už kontroluje:

```text
T11.xfcp_status == OK
T12.xfcp_status == OK
```

Teda STATUS je minimálne na OK ceste overený cez UART aj UDP response path.

---

## 3.6 Timing prešiel

`xfcp_test_06` STA:

```text
Slow 85C CLK125 setup slack:  +0.124 ns
Slow 85C ETH_RXC setup slack: +0.592 ns
Slow 85C CLK125 hold slack:   +0.427 ns
Fast 0C CLK125 setup slack:   +2.931 ns
TNS:                          0.000
```

Resource usage:

```text
Logic elements: 25,504 / 55,856  (46 %)
Registers:      20,130
Memory bits:    34,304
```

Nárast oproti `xfcp_test_05` je malý:

```text
+17 LEs
+6 registers
```

Čiže STATUS vrstva prakticky nerozbila resource ani timing. Rezerva je menšia než pri `xfcp_test_05(9)`, ale stále je to PASS.

---

# 4. Čo je ešte nedotiahnuté

## 4.1 Chýba `XFCP_TEST_06_STATUS.md`

V archíve `xfcp_test_06` nevidím hlavný status MD súbor ako pri `xfcp_test_05`.

To je škoda, lebo práve `xfcp_test_06` je nový protokolový míľnik. Doplnil by som:

```text
XFCP_TEST_06_STATUS.md
```

S obsahom:

```text
Cieľ:
  v0.9+STATUS response header

Zmeny:
  xfcp_status_e
  resp_status_o v axi_engine
  resp_status_i v packetizer
  Python XfcpStatusError

Sim:
  tb_xfcp_test_06_top PASS

Timing:
  WNS +0.124 ns

HW:
  doplniť po otestovaní
```

---

## 4.2 V archíve nevidím HW regresný log

Makefile a `tools/hw_regression.sh` existujú, ale nenašiel som uložený výstup z reálneho HW behu.

Čiže férový stav je:

```text
xfcp_test_06:
  sim PASS
  timing PASS
  HW test targety pripravené
  HW PASS v archíve nedokázaný
```

Ak si HW test už spustil lokálne, doplň výstup do statusu. Ak nie, toto je najbližší praktický test.

Príkaz:

```bash
make program
make hw-regression TEST_REPEAT=3
```

alebo detailne:

```bash
make test-uart TEST_REPEAT=3
make test-udp TEST_REPEAT=3
```

---

## 4.3 Testuje sa len STATUS=OK

Simulácia kontroluje `xfcp_status==OK`, ale zatiaľ netestuje chybové statusy:

```text
BAD_ADDRESS
AXI_SLVERR
AXI_DECERR
TIMEOUT
BAD_LENGTH
BAD_OPCODE
BUSY
OVERFLOW
```

Pre `xfcp_test_06` je toto hlavný nedostatok. STATUS vrstva existuje, ale musí sa overiť práve na chybách.

Minimálne testy, ktoré treba doplniť:

```text
1. READ z adresy mimo všetkých slotov -> BAD_ADDRESS
2. WRITE na zlú adresu -> BAD_ADDRESS
3. AXI slave model s RRESP=SLVERR -> AXI_SLVERR
4. AXI slave model s BRESP=DECERR -> AXI_DECERR
5. AXI slave, ktorý nikdy nedá ready/valid -> TIMEOUT
6. Neznámy opcode -> BAD_OPCODE alebo UNSUPPORTED
7. WRITE count nie je násobok 4 -> BAD_LENGTH
```

Až potom bude STATUS vrstva naozaj overená.

---

## 4.4 Invalid address zatiaľ pravdepodobne negeneruje response status

Pozor na dôležitú vec: v `xfcp_fabric_endpoint.sv` sa pri neplatnej adrese používa `invalid_req_r`, `drop_wdata_q`, ale podľa aktuálnej architektúry sa invalid request neposiela do žiadneho engine. Tým pádom nie je jasné, či sa pre invalid request vytvorí response s `XFCP_ST_BAD_ADDRESS`.

Z aktuálneho kódu mám podozrenie, že invalid request sa skôr zahodí/drainuje než korektne odpovie `BAD_ADDRESS`. To bolo prijateľné vo v0.9, ale pre v1.0 status protokol je lepšie:

```text
zlá adresa nesmie iba zmiznúť;
má vrátiť response:
  TYPE podľa requestu
  SEQ echo
  STATUS = BAD_ADDRESS
  bez payloadu
```

Toto by som riešil ako ďalší krok. Môžeš na to spraviť špeciálny „error response engine“ alebo priamo vetvu v `xfcp_fabric_endpoint`.

---

## 4.5 `xfcp_axil_bridge.sv` je zastaraný a nekompatibilný

V `rtl/xfcp/xfcp_axil_bridge.sv` sa stále instancuje:

```systemverilog
xfcp_tx_packetizer #(
  .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
  .XFCP_ID_STR    (ID_STR)
)
```

Lenže nový `xfcp_tx_packetizer` už parameter `XFCP_ID_STR` nemá a vyžaduje nový port:

```systemverilog
.resp_status_i(...)
```

Tento súbor nie je v `build/hal/files.tcl`, takže aktuálny build neovplyvňuje. Ale v knižnici je to nebezpečné: keď ho niekto použije, pravdepodobne neskompiluje.

Odporúčanie:

```text
buď odstrániť xfcp_axil_bridge.sv z tohto projektu,
alebo ho okamžite aktualizovať na nový packetizer,
alebo ho premenovať na legacy/xfcp_axil_bridge_v0.sv.
```

Pre knižnicu nechcem mať v `rtl/xfcp/` súbor, ktorý je mimo aktuálneho ABI.

---

## 4.6 Nové transport drafty stále nie sú zapojené

V `xfcp_test_05(9)` boli draft súbory:

```text
xfcp_udp_rx_adapter.sv
xfcp_udp_tx_adapter.sv
xfcp_udp_transport.sv
```

V `xfcp_test_06` stále existujú, ale build používa starý:

```text
udp_xfcp_server.sv
```

To je v poriadku. Len to treba brať ako návrh/draft, nie overenú časť knižnice.

---

# 5. Progres v návrhoch

Vidím jasný posun v troch krokoch:

## Krok A — `xfcp_test_05` uzavrel timing-clean dual transport

Toto bola stabilizácia:

```text
UART + UDP
AXI-Lite endpoint
timing clean
HW regression
```

To je `v0.9`.

## Krok B — návrhy definovali knižničnú architektúru

V návrhoch sa posunulo chápanie z:

```text
XFCP = UART/UDP priamo na AXI-Lite
```

na:

```text
XFCP = transport + protocol + transaction layer + backend adapters
```

To je správne.

## Krok C — `xfcp_test_06` začal protokolovú robustnosť

STATUS byte je prvý konkrétny kus budúcej `v1.0`.

To je správne poradie. Nerobíme ešte AXI-Stream ani AXI-Full, kým nemáme status/error model.

---

# 6. Čo riešiť ďalej

## Najbližší cieľ: dokončiť `xfcp_test_06_status`

Nie ďalší backend. Nie AXI-Stream. Najprv dokončiť chybové odpovede.

Konkrétny zoznam:

```text
1. Doplniť XFCP_TEST_06_STATUS.md.
2. Spustiť a uložiť HW regresiu UART + UDP.
3. Pridať error-response cestu pre BAD_ADDRESS.
4. Pridať sim test pre BAD_ADDRESS cez UART aj UDP.
5. Pridať AXI error slave model:
   - RRESP=SLVERR
   - BRESP=DECERR
   - timeout
6. Overiť Python XfcpStatusError na reálnych raw odpovediach.
7. Až potom označiť xfcp_lib_v1_0_rc1.
```

---

# 7. Ako riešiť BAD_ADDRESS

Toto je najdôležitejšia architektonická úprava v `xfcp_test_06`.

Navrhujem pridať do `xfcp_fabric_endpoint` interný error-response path.

Keď parser dodá request a decoder nenájde slot:

```text
req_valid && !dec_valid
```

tak endpoint má:

```text
1. zapamätať seq
2. určiť response type:
   READ  -> RESP_READ
   WRITE -> RESP_WRITE
3. nastaviť status = BAD_ADDRESS
4. spustiť packetizer bez payloadu
5. pri WRITE ešte odčerpať payload, ak existuje
```

Teda zlá adresa nebude len drop, ale riadna odpoveď.

Pre v1.0 by pravidlo malo byť:

```text
každý syntakticky platný XFCP request musí dostať odpoveď,
aj keď je odpoveď chybová.
```

Výnimky:

```text
neplatný SOP / rozbitý frame / recovery garbage
```

tie sa môžu zahodiť.

---

# 8. Ako riešiť BAD_OPCODE a BAD_LENGTH

`xfcp_rx_parser` už má náznaky:

```text
dec_opcode_ok
dec_count_ok
dec_addr
```

ale Quartus hlási, že sú nepoužité:

```text
dec_addr assigned but never read
dec_opcode_ok assigned but never read
dec_count_ok assigned but never read
```

To znamená, že parser už možno začal mať validáciu, ale ešte nie je zapojená do status/error path.

Pre `xfcp_test_06` by som z toho spravil jasný výstup:

```systemverilog
output logic             req_error_valid,
output xfcp_status_e     req_error_status,
output logic [7:0]       req_error_seq,
output xfcp_op_e         req_error_resp_type
```

Alebo jednoduchšie: `req_hdr` ide ďalej vždy, ale obsahuje `status`.

Napríklad:

```systemverilog
typedef struct packed {
  xfcp_op_e       opcode;
  logic [7:0]     seq;
  logic [31:0]    addr;
  logic [15:0]    count;
  xfcp_status_e   parse_status;
} xfcp_req_hdr_t;
```

Potom endpoint vie:

```text
parse_status != OK -> okamžite error response
parse_status == OK -> normálna AXI cesta
```

To je čisté riešenie.

---

# 9. Warningy pred knižnicou

Tieto warningy by som ešte upratal:

## `xfcp_out.TKEEP/TUSER/TID/TDEST` no driver

V `xfcp_fabric_endpoint` doplniť:

```systemverilog
assign xfcp_out.TKEEP = '1;
assign xfcp_out.TUSER = '0;
assign xfcp_out.TID   = '0;
assign xfcp_out.TDEST = '0;
```

## `ASYNC_REG` ignorovaný Quartusom

V `cdc_two_flop_synchronizer.sv` pre Intel pridať Quartus-compatible atribút, napríklad formou `altera_attribute`.

## `xfcp_axi_engine` case warnings

Quartus hlási:

```text
case item expression covers a value already covered by a previous case item
```

pri BRESP/RRESP case. Toto by som upratal, aby status/error engine nepôsobil podozrivo.

## `xfcp_rx_parser` unused decode signals

Buď ich zapojiť do BAD_OPCODE/BAD_LENGTH, alebo odstrániť. Keďže teraz ideme robiť status, odporúčam ich zapojiť.

---

# 10. Čo nerobiť hneď

Zatiaľ by som nerobil:

```text
AXI-Stream adapter
AXI-Full adapter
CPU mailbox
GET_TARGET_TABLE
source routing
N-port generic router
```

Dôvod: STATUS vrstva je začatá, ale ešte nie je plne overená na chybách. Každý z týchto adaptérov bude potrebovať presne tie error stavy, ktoré ešte chýbajú.

---

# 11. Navrhované označenie stavu

```text
xfcp_test_05(9):
  xfcp_lib_v0_9_final_candidate

xfcp_test_06:
  xfcp_lib_v1_0_status_rc0
```

`xfcp_test_06` je ešte `rc0`, nie `rc1`, lebo zatiaľ testuje hlavne OK status, nie chyby.

---

## Záver

Progres v návrhoch je správny a veľmi výrazný:

```text
1. xfcp_test_05 uzavrel funkčný a timing-clean dual-transport control fabric.
2. návrhy správne posunuli architektúru ku vrstvenej knižnici.
3. xfcp_test_06 začal najdôležitejší v1.0 krok: STATUS/ERROR response model.
```

Najbližšie riešiť:

```text
dokončiť xfcp_test_06_status:
  BAD_ADDRESS
  BAD_OPCODE
  BAD_LENGTH
  AXI_SLVERR/DECERR
  TIMEOUT
  Python XfcpStatusError testy
  HW regression log
```

Až potom má zmysel otvoriť `xfcp_test_07_axis`.
