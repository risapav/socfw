Analyzoval som nový `xfcp_test_03.zip`. Toto je aktuálne výrazne posunutý stav oproti predchádzajúcej verzii. Zhrnutie: **RTL jadro je podstatne stabilnejšie, hlavný pôvodný HW bug je pravdepodobne správne identifikovaný a opravený, ale HW stále nie je uzavretý kvôli fyzickému TX→RX coupling problému.**

## Aktuálny stav

Podľa `XFCP3_STATUS.md` a súborov v ZIPe je stav takýto:

```text
Projekt:       xfcp_test_03
Dátum stavu:   2026-05-21
Board:         QMTech EP4CE55F23C8 @ 50 MHz
Protokol:      UART XFCP, SOP_REQ=0xFE, SOP_RESP=0xFD
Quartus:       PASS
Timing:        PASS
HW:            zlepšenie z 2/12 na ~5–7/12 podľa testu
```

Quartus build je úspešný:

```text
Flow Status: Successful
Logic elements: 16,982 / 55,856 = 30 %
Registers: 13,539
Memory bits: 0
Setup slack: +4.609 ns
Hold slack:  +0.447 ns
```

Z pohľadu syntézy a timing closure je teda projekt v dobrom stave.

---

# Najväčší úspech: root cause `xfcp_fifo`

Toto považujem za najdôležitejší nález celého vývoja.

V `xfcp_fifo.sv` je už:

```systemverilog
(* ramstyle = "logic" *)
logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
```

Predtým bolo použité `no_rw_check`, čo Quartusu umožnilo syntetizovať FIFO ako synchrónnu RAM. Tvoj FIFO však očakáva **fall-through kombinačné čítanie**:

```systemverilog
assign r_data = mem[rd_ptr_q];
```

Ak Quartus urobil synchronnú RAM, vzniklo toto:

```text
r_valid = okamžite platný
r_data  = stale / oneskorený o 1 takt
```

To je kritické hlavne pre `order_fifo`, kde `ofifo_rdata.sel` určuje, na ktorý engine má arbiter čakať. Ak bol `sel` stale, arbiter čakal na nesprávny engine a packetizer sa nikdy nespustil. To veľmi dobre vysvetľuje pôvodné `0B response`.

Tento fix je správny.

---

# Dôležité RTL opravy sú už zapracované

## 1. Invalid address / invalid WRITE path

V aktuálnom `xfcp_fabric_endpoint.sv` už vidím opravené:

```systemverilog
assign invalid_req  = req_valid && !dec_valid;

assign req_ready    = invalid_req ? 1'b1 :
                      dec_valid && !eng_busy[dec_sel]
                      && eng_req_ready[dec_sel] && ofifo_wready;

assign ofifo_wvalid = req_fire && !invalid_req;
```

A pre invalid WRITE payload:

```systemverilog
wire drain_wdata = drop_wdata_q ||
                   (invalid_req && req_hdr.opcode == XFCP_OP_WRITE);

assign wdata_valid = wdata_valid_raw && !drain_wdata;
assign wdata_ready = drain_wdata ? 1'b1 : eng_wdata_ready[wdata_sel];
```

Toto rieši pôvodný Problem F:

```text
invalid WRITE už nemá ísť do slave 0
invalid request už nemá zaseknúť header FIFO
payload invalid WRITE sa odčerpáva
```

To je veľký posun.

---

## 2. `eng_busy` sa nenastavuje pri invalid requeste

Toto je tiež opravené:

```systemverilog
if (req_valid && req_ready && !invalid_req && dec_sel == SEL_W'(i))
  eng_busy[i] <= 1'b1;
```

Predtým hrozilo, že invalid request nastaví `eng_busy[0]`.

---

## 3. `resp_type` z engine sa už prenáša do fabricu

Vo fabricu už je:

```systemverilog
logic [7:0] eng_resp_type [NUM_SLAVES];
```

a engine je zapojený:

```systemverilog
.resp_type(eng_resp_type[gi])
```

Pri štarte odpovede sa používa:

```systemverilog
resp_type_q <= xfcp_op_e'(eng_resp_type[ofifo_rdata.sel]);
```

Toto je dôležité, lebo pri READ timeoute engine vie vrátiť `RESP_WRITE`, aby packetizer nečakal na neexistujúci READ payload.

---

## 4. `ST_RD_WAIT` AXI chyba je opravená

V `xfcp_axi_engine.sv` už je správne:

```systemverilog
ST_RD_WAIT: begin
  if (m_axil.RVALID && m_axil.RREADY) state_n = ST_NEXT;
end
```

Predtým tam bolo riziko, že FSM prejde ďalej iba na `RVALID`, aj keď `RREADY=0`.

---

# Protokolové zmeny

## Oddelený request/response SOP

V `xfcp_pkg.sv` už je:

```systemverilog
XFCP_SOP_REQ  = 8'hFE;
XFCP_SOP_RESP = 8'hFD;
```

A v Python protokole:

```python
SOP_REQ  = 0xFE
SOP_RESP = 0xFD
```

To je dobrý krok. Odpoveď z FPGA už nezačína rovnakým bajtom ako request z PC.

Ale podľa statusu sa ukázalo, že samotné `SOP_RESP=0xFD` nevyriešilo celý problém, pretože coupling vie generovať aj deformované bajty, z ktorých niektoré náhodne vyzerajú ako `0xFE`.

---

## `MAX_COUNT_BYTES=256`

V `xfcp_rx_parser.sv` je už limit:

```systemverilog
localparam int MAX_COUNT_BYTES = 256;
```

a validácia:

```systemverilog
dec_count_ok = (dec_count[1:0] == 2'b00)
            && (dec_count <= COUNT_WIDTH'(MAX_COUNT_BYTES));
```

Toto je dobrá bezpečnostná brzda. Bez nej by náhodný garbage packet mohol vytvoriť obrovský `COUNT`, napríklad desiatky tisíc bajtov, a endpoint by sa na dlho zasekol generovaním AXI transakcií alebo odpovedí.

---

# Tools refactoring už začal

V ZIPe už existuje nová štruktúra:

```text
tools/xfcp/
├── bus.py
├── errors.py
├── protocol.py
├── timeouts.py
└── transport.py
```

Legacy `tools/bus/xfcp.py` je už iba shim:

```python
from xfcp.bus import XfcpBus as XFCPBus
```

To je presne smer, ktorý sme chceli.

Pozitívne zmeny:

```text
- protokol oddelený do protocol.py
- transport oddelený do transport.py
- chyby majú vlastné triedy
- timeouty sú v XfcpTimeouts
- read_block/write_block už robia chunking
```

V `tools/xfcp/protocol.py` je:

```python
MAX_BURST_WORDS = 32
```

a `XfcpBus.read_block()` chunkuje väčšie čítania. To je správne, pretože `xfcp_axi_engine` má read FIFO depth 32.

---

# Najväčší otvorený problém: fyzický TX→RX coupling

Podľa `XFCP3_STATUS.md` je aktuálna interpretácia:

```text
ramstyle fix zlepšil HW z 2/12 na 7/12
SOP_RESP=0xFD + ďalšie mitigácie dávajú približne 5–6/12
zvyšok je fyzický TX→RX coupling
```

Toto je dôležité: už to nevyzerá ako primárny RTL deadlock. Skôr to vyzerá tak, že FPGA TX signál sa nejakou cestou dostáva späť na FPGA RX.

Možné príčiny:

```text
1. FTDI echo / loopback konfigurácia
2. kapacitívna väzba na PCB alebo v kábli
3. zle pripojené TX/RX vodiče
4. floating alebo príliš citlivý RX vstup
5. nedostatočný idle pull-up/pull-down podľa zapojenia
```

Najdôležitejší ďalší krok teda nie je ďalší RTL patch, ale **fyzická diagnostika UART linky**.

---

# Dôležitá nekonzistencia v ZIPe

V `XFCP3_STATUS.md` sa píše, že simulácie sú `13/13 ALL PASSED`.

Ale v priložených logoch som našiel:

```text
sim/logs/tb_xfcp_uart_mmio_top.log:
** Fatal: uart_recv timeout after 200001 clocks — DUT did not respond
Errors: 1
```

To znamená, že v ZIPe je aspoň jeden integračný log, ktorý **nie je čistý PASS**.

Možné vysvetlenia:

```text
- log je starý z neúspešného behu
- status bol aktualizovaný po inom behu, ale logy v ZIPe nie
- test je nestabilný alebo ešte neaktualizovaný na nový SOP_RESP
- regression kontrola nebola spustená po poslednom stave
```

Odporúčam preto spraviť čistý beh:

```bash
cd sim
make clean
make regression
```

A potom overiť:

```bash
grep -R "Fatal\|FAILED\|Errors: [1-9]" logs/
```

Kým toto nie je čisté alebo vysvetlené, nepísal by som, že simulácie sú bezvýhradne uzavreté.

---

# Otvorené technické riziká

## 1. `resp_done_mux` hack stále existuje

Vo `xfcp_fabric_endpoint.sv` je stále:

```systemverilog
resp_done_mux = resp_start_pulse || resp_done_held_q;
```

Status to zatiaľ akceptuje, pretože aktuálny model predpokladá, že READ dáta sú celé vo FIFO pred štartom packetizera. Pri chunk limite 32 slov je to krátkodobo použiteľné.

Dlhodobo by som však stále odporúčal prejsť na čistejší model:

```text
read_data
read_data_valid
read_data_ready
read_data_last
```

alebo preniesť `count` cez `order_entry_t`.

Momentálne to nie je prvá priorita, ale je to architektonický dlh.

---

## 2. `MAX_COUNT_BYTES=256`, ale engine FIFO je 32 slov

`MAX_COUNT_BYTES=256` znamená 64 slov. Ale `xfcp_axi_engine` má FIFO depth 32 slov.

Tools chunkujú na 32 slov, takže normálny PC request je bezpečný. Ale náhodný garbage request s `COUNT=256` môže stále vyvolať 64-word READ. To môže prekročiť internú read FIFO kapacitu.

Odporúčam zjednotiť limity:

```systemverilog
MAX_COUNT_BYTES = 128; // 32 slov × 4 bajty
```

alebo zväčšiť FIFO depth na 64 a explicitne to zdokumentovať.

Pre robustnosť by som teraz zvolil jednoduchšie:

```systemverilog
localparam int MAX_COUNT_BYTES = 128;
```

Tým sa protokolový limit zhoduje s aktuálnym read FIFO limitom.

---

## 3. Ešte neexistuje `RESP_ERROR`

Invalid request sa už neblokuje, ale stále zrejme nevracia plnohodnotnú error response.

Dlhodobo by malo platiť:

```text
každý validne prijatý request musí dostať response
invalid address → RESP_ERROR/BAD_ADDRESS
slave timeout   → RESP_ERROR/SLAVE_TIMEOUT
bad opcode      → parser drop + error counter
```

Zatiaľ je to skôr „nezablokuj sa“, nie ešte „diagnosticky odpovedz“.

---

## 4. Chýba SEQ ID a CRC

Tieto veci zatiaľ nie sú implementované:

```text
SEQ ID
CRC16
RESP_ERROR payload
diagnostické registre endpointu
soft reset endpointu
```

To je v poriadku, ak je projekt ešte vo fáze fyzického bring-upu. Ale pre dlhodobé použitie XFCP na CPU aplikácie a testovanie modulov budú potrebné.

---

# Čo by som robil teraz

## Najbližší krok 1: potvrdiť simulácie

Najprv by som upratal logy:

```bash
cd sim
make clean
make regression
```

Potom:

```bash
grep -R "Fatal\|FAILED" logs/
grep -R "Errors: [1-9]" logs/
```

Očakávané `$error` v negatívnych testoch by som zmenil na `$warning` alebo `$display`, aby CI nevyzeralo ako čiastočný fail.

---

## Najbližší krok 2: fyzicky overiť UART RX počas FPGA TX

Toto je teraz najdôležitejšie.

Postup:

```text
1. osciloskop alebo logic analyzer na FPGA RX pine
2. spustiť READ request
3. sledovať, či sa počas FPGA TX response objavujú pulzy aj na FPGA RX
```

Interpretácia:

```text
RX je počas TX úplne pokojný:
  problém bude skôr v FTDI echo / adaptéri / konfigurácii

RX kopíruje alebo čiastočne kopíruje TX:
  fyzický coupling alebo zlé zapojenie
```

Skúsil by som aj:

```text
- iný USB-UART adaptér, ideálne CP2102 alebo CH340
- kratšie vodiče
- oddeliť TX a RX vodiče
- pridať sériový odpor 1k na FPGA RX
- prípadne slabý pull-up/pull-down podľa idle polarity
```

RC filter 1k + 10nF môže pomôcť, ale pozor: pri 115200 baud je bit ~8.68 µs, takže 10 µs časová konštanta už môže byť veľa. Skôr by som začal jemnejšie, napríklad:

```text
1k + 1nF až 2.2nF
```

Až potom skúšať väčšie hodnoty.

---

## Najbližší krok 3: znížiť `MAX_COUNT_BYTES` na 128

Toto je malá RTL zmena, ktorá lepšie ladí s FIFO depth:

```systemverilog
localparam int MAX_COUNT_BYTES = 128;
```

Kým engine read FIFO ostáva 32 slov, je to bezpečnejšie než 256.

---

## Najbližší krok 4: po fyzickej oprave očakávať 12/12

Po výmene adaptéra alebo fyzickom potlačení coupling by mal `hw_diag.py` ísť na:

```text
12/12 OK
frame=False
overrun=False
parity=False
```

Ak ani po inom adaptéri nebude 12/12, potom by som sa vrátil k RTL a pridal SignalTap.

---

# Stav projektu v jednej vete

**XFCP3 má už opravený hlavný RTL root cause v `xfcp_fifo`, má lepší fabric invalid-path, oddelený response SOP, burst chunking v tools a dobrý timing; aktuálny blocker už vyzerá skôr ako fyzický UART TX→RX coupling než čistý RTL bug.**

Najbližšie by som nerobil veľký protokolový refaktor. Najprv by som uzavrel fyzický UART problém a vyčistil sim logy. Potom by mali prísť `RESP_ERROR`, `SEQ ID`, diagnostické registre a endpoint recovery.
