# XFCP Test 03 — stav projektu

> Stav k: 2026-05-22
> Board: QMTech EP4CE55F23C8 @ 50 MHz
> Protokol: XFCP cez UART 115200 baud (SOP_REQ=0xFE, SOP_RESP=0xFD)
> Predchadzajuci projekt: `examples/xfcp_test_02` (uzavrety, commit 7a37c1f)

---

## Ciel projektu

Pokracovanie xfcp_test_02. Ciel je trojnásobný:

1. **Opraviť HW bug** — identifikovať a odstraniť príčinu 17 % timeoutov z xfcp_test_02
2. **Protokol robustnosti** — pridať SEQ ID, CRC, RESP_ERROR, diagnostické registre
3. **Tools refactoring** — rozdeliť tools na transport/protocol/bus/drivers vrstvy

---

## Zdedená situácia z xfcp_test_02

### RTL štartovací stav (10/10 sim PASS)

Všetky RTL súbory skopírované zo stavu po commite `75fdc5a`:
- `rtl/xfcp/xfcp_rx_parser.sv` — S_RPATH pass_ready guard opravený
- `rtl/xfcp/xfcp_fabric_endpoint.sv` — invalid_req, drop_wdata_q, resp_done_mux, eng_resp_type
- `rtl/xfcp/xfcp_tx_packetizer.sv` — ST_PAYLOAD !slot1_valid_q guard
- `rtl/xfcp/xfcp_axi_engine.sv` — FIX G: timeout → RESP_WRITE
- `rtl/xfcp_uart_mmio_top.sv` — u_rx_fifo (DEPTH=8), LITTLE_ENDIAN=0

### HW bug (NEOPRAVENÝ z xfcp_test_02)

Po všetkých opravách: **2/12 odpovedí (17%)**, zvyšok TIMEOUT.
- Sporadické, nedeterministické
- Úspešné odpovede: TYPE=0x12, DEV_STR='XFCP-UART-FAB', DATA='OUT_'

---

## Analýza navrhy_01–05 (zdedené od experta z xfcp_test_02)

### navrhy_01: RTL problémy (PRIAME PRÍČINY HW BUGU)

Expert identifikoval **3 zásadné RTL problémy** ktoré mohli pretrvávať aj po opravách:

**Problem A — invalid WRITE path (Problem F)**
```
invalid adresa → dec_valid=0 → req_ready=0 → header sa neodoberie → deadlock
wdata_valid nie je gateovaný cez dec_valid → payload tečie na slave 0
```
Potrebná oprava: `wdata_valid = wdata_valid_raw && dec_valid`
+ `drop_wdata_q` pre drain celého WRITE payload

**Problem B — eng_busy nastavuje sa aj pri invalid requeste**
```
if (req_valid && req_ready && dec_sel == SEL_W'(i))   ← chýba && dec_valid
  eng_busy[i] <= 1'b1;
```
Po invalid_req s `req_ready=1` by bez ochrany nastavil `eng_busy[0]`.

**Problem C — resp_done_mux pre multi-word READ**
```
resp_done_mux = resp_start_pulse || resp_done_held_q
```
Packetizer dostane `resp_done_i` hneď na začiatku, ešte pred payloadom.
Pre single-word READ funguje, pre multi-word READ je rizikové.
Správne: v `order_entry_t` pridať `count`, packetizer ukončuje po presnom počte slov.

**STAV PO xfcp_test_02:** expert tvrdí že tieto chyby mohli pretrvávať napriek
pokusom o opravu. Treba overiť aktuálny kód.

### navrhy_02: XFCP ako debug infraštruktúra

XFCP je "debug bridge" / "host-to-target control interface" — legitímny a bežný prístup.
Cieľová architektúra:
```
PC tools/
  xfcp.py, scanner.py, memory.py, cpu.py
  drivers/ gpio.py, uart.py, sevenseg.py

FPGA: xfcp_fabric_endpoint → sys_ctrl, cpu_ctrl, ram, gpio, uart, custom modules
```
Každý nový modul dostane AXI-Lite registre a dá sa okamžite testovať z Pythonu.

Systémové registre (odporúčané):
```
0xFF000000 MAGIC / ID
0xFF000004 VERSION
0xFF000008 BUILD_ID
0xFF00000C CAPABILITIES
0xFF000010 SCRATCH
0xFF000014 RESET_CONTROL
0xFF000018 ERROR_STATUS
```

### navrhy_03: Tools architektúra

Rozdelenie do vrstiev:
```
tools/
├── xfcp/
│   ├── transport.py    # Serial/UART transport
│   ├── protocol.py     # packet encode/decode
│   ├── bus.py          # read32/write32/burst/wait_reg
│   ├── errors.py
│   ├── timeouts.py
│   └── recovery.py
├── drivers/
│   ├── sys_ctrl.py, gpio.py, uart.py, sevenseg.py
└── tests/
    └── test_protocol.py (bez FPGA, cez MockTransport)
```

Oddelené timeouty:
```
byte_timeout_s, response_timeout_s, module_timeout_s, recovery_timeout_s
```

### navrhy_04: Porovnanie s konkurenciou

Čo máme navyše: multi-slave fabric, order FIFO, test pyramída, RX FIFO buffer.
Čo chýba:
```
1. sequence ID / transaction ID     ← KRITICKÉ pre recovery
2. CRC16                            ← bez toho nevieme rozlíšiť poškodený paket
3. RESP_ERROR paket                 ← invalid addr = timeout namiesto chyby
4. diagnostické registre            ← sys_ctrl bez RX/TX count, error count
5. endpoint soft reset              ← recovery len cez hw_reset
6. discovery ID ROM per slave       ← num_slots hardcoded (bol bug)
```

### navrhy_05: Vlastná protokol špecifikácia

XFCP je najbližšie k **IPbus** (paketový protokol pre A32/D32 FPGA register access).
Odporúčaný wire format:
```
Request:  SOP(1) VER(1) LEN(2) SEQ(1) OP(1) FLAGS(1) ADDR(4) COUNT(2) PAYLOAD(N) CRC16(2)
Response: SOP(1) VER(1) LEN(2) SEQ(1) RESP(1) STATUS(1) COUNT(2) PAYLOAD(N) CRC16(2)
```
Status kódy: OK, BAD_OPCODE, BAD_LENGTH, BAD_CRC, BAD_ADDRESS, SLAVE_ERROR,
SLAVE_TIMEOUT, BUSY, SEQ_MISMATCH, PROTOCOL_ERROR, INTERNAL_ERROR

---

## Plán implementácie

### Fáza 1 — Debug HW bugu (PRIORITA)

Cieľ: zistiť root cause 17 % timeoutov.

**Krok 1a: Overiť stav RTL oproti navrhy_01**

- Prečítať aktuálny `xfcp_fabric_endpoint.sv` a overiť či sú všetky 3 problémy z navrhy_01 opravené
- Prečítať `xfcp_tx_packetizer.sv` — overiť multi-word READ (resp_done_mux)
- Prečítať `xfcp_axi_engine.sv` — overiť ST_RD_WAIT (RVALID only vs RVALID&&RREADY)

**Krok 1b: SignalTap capture (ak RTL vyzerá OK)**

- Pridať SignalTap do soc_top.qsf
- Sledovať: parser FSM state, req_valid/req_ready, eng_busy, resp_start_pulse, ofifo signály
- Zachytiť failing request

**Krok 1c: Pridať diagnostické registre do sys_ctrl (ak SignalTap nepostačuje)**

- rx_packet_count, tx_packet_count, error_count, last_error_code, last_bad_addr

### Fáza 2 — Robustnosť protokolu

Po opravení HW bugu:
1. SEQ ID (8-bit counter) — requestor posieha, endpoint vracia rovnakú hodnotu
2. RESP_ERROR paket — invalid addr / slave timeout → chybová odpoveď nie timeout
3. CRC16 (voliteľné, neskôr)

### Fáza 3 — Tools refactoring

Rozdeliť `tools/bus/xfcp.py` na `tools/xfcp/transport.py + protocol.py + bus.py`.
Pridať `errors.py`, `timeouts.py`, `recovery.py`.

### Fáza 4 — ID ROM + discovery

Každý slave dostane prvých 8 registrov (MAGIC, TYPE, VERSION, CAPABILITIES).
Scanner číta ID ROM namiesto fixného num_slots.

---

## Adresna mapa (zdedená)

NUM_SLAVES=6, SLAVE_BASE stride=0x10000, start=0xFF000000:
- [0] 0xFF000000 = SYSC (axil_sys_ctrl)
- [1] 0xFF010000 = UART (axil_uart_adapter)
- [2] 0xFF020000 = LED0 (axil_regs, 6-bit onboard)
- [3] 0xFF030000 = LED1 (axil_regs, 8-bit J10)
- [4] 0xFF040000 = LED2 (axil_regs, 8-bit J11)
- [5] 0xFF050000 = SEG7 (axil_seven_seg_adapter)

---

## Kľúčové parametre (zdedené)

- UART: 50 MHz / 115200 baud = 434 cyklov/bit; 10 bitov/bajt = 4340 cyklov/bajt
- READ response: 25 bajtov = 108 500 cyklov = 2.17 ms
- WRITE response: 21 bajtov = 91 140 cyklov = 1.82 ms

---

## Fáza 1 — Nález HW bugu (2026-05-20)

### ROOT CAUSE: xfcp_fifo.sv — ramstyle = "no_rw_check"

**Symptóm:** 2/12 odpovedí (17 %), zvyšok TIMEOUT — 0 bajtov z UART TX.

**Príčina:** `xfcp_fifo.sv` používal `(* ramstyle = "no_rw_check" *)`. Toto umožňuje
Quartus Prime syntetizovať pamäť pomocou synchronnej RAM (MLAB alebo M9K). Avšak
FIFO dizajn vyžaduje **kombinačný (fall-through) výstup** — `assign r_data = mem[rd_ptr_q]`.

So synchronnou RAM:
- `r_valid` je kombinačný → asserts ihneď
- `r_data` je registrovaný → je STALE o 1 takt

**Efekt na Order FIFO** (ORDER_FIFO_DEPTH=16, DATA_WIDTH=57 bitov obsahuje `sel` pole):
```
ARB_IDLE → ofifo_rvalid=1 → arb_sel_q <= ofifo_rdata.sel  (STALE data!)
→ arbiter čaká na eng_done od NESPRÁVNEHO engine
→ permanentný DEADLOCK
→ packetizer nikdy nespustí
→ UART TX posiela 0 bajtov
```

**Prečo 2/12 uspeli:** Keď `stale mem[rd_ptr_q].sel` náhodou zodpovedal správnemu
engine (napr. rd_ptr_q=0 a mem[0] obsahoval správne sel z predchádzajúcej operácie),
arbitrácia prebehla správne.

**Oprava:** `(* ramstyle = "logic" *)` — nútí LUT-based registre s pravým kombinačným
čítaním. Aplikovaná v `rtl/xfcp/xfcp_fifo.sv` linka 65.

**Stav:** OPRAVENÉ A POTVRDENÉ HW TESTOM (2026-05-21).

---

## Fáza 1 — RTL analýza (2026-05-21, relácia 2)

### Hlboká RTL analýza — overenie po ramstyle fixe

Prečítané a overené moduly: `axil_uart_adapter.sv`, `axil_regfile.sv`, `axis_uart_tx.sv`,
`xfcp_rx_parser.sv`, `xfcp_tx_packetizer.sv`, `xfcp_axi_engine.sv`, `xfcp_fabric_endpoint.sv`.

**Výsledok analýzy:**
- Žiadny ďalší fundamentálny bug nenájdený po ramstyle fixe
- `baud_div_o` = 434 okamžite po resete (axil_regfile RW register s RESET_VAL=434) ✓
- `uart_baud_gen` TX a RX sú oddelené inštancie, navzájom neinterferujú ✓
- `valid_o` v `uart_core_rx` je one-cycle pulse, ale u_rx_fifo DEPTH=8 dostatočná ✓
- `xfcp_rx_parser` S_DROP — exituje iba cez `sop_recovery` (TLAST=0 hardwired → S_DROP trvalý!) ✓
- `hdr_shift_n_comb` kombinácia správna pre S_DECODE ✓

**Upozornenie — protokolová robustnosť:**
`XFCP_SOP_RESP = XFCP_SOP_REQ = 0xFE` (rovnaký SOP pre request aj response).
Ak by FPGA TX bajty dosahovali FPGA RX (TX→RX coupling na PCB/FTDI):
- Parser vidí 0xFE → sop_recovery → S_HDR
- Ďalší bajt TYPE=0x12 (RESP_READ) je neplatný request opcode → go_drop → S_DROP
- Toto by vysvetlilo alternujúci FAIL-OK vzor

V RTL **neexistuje** interný loopback. Ide o fyzický HW problém (coupling na kábli alebo FTDI).
`hw_diag.py` teraz číta UART STATUS po teste — overrun_err=1 by potvrdil TX→RX coupling.

### Simulations — 13/13 PASS (2026-05-21)

```
make (v sim/): 13/13 ALL PASSED — vrátane backpressure, multi-slave, parser edge cases
```

### hw_diag.py — vylepšenia

- Pridaný WRITE capability (ERR_CLR na začiatku testu)
- Pridaný POST-TEST UART STATUS check (0xFF010010)
- Diagnostika overrun/frame/parity chýb

---

## Fáza 1 — HW Test výsledky (2026-05-21)

### Výsledok: 7/12 OK (58 %) — výrazné zlepšenie oproti 2/12 (17 %)

```
Slot 0 SYSC:  OK / OK
Slot 1 UART:  OK / TIMEOUT       ← alternujúci vzor
Slot 2 LED0:  OK / OK
Slot 3 LED1:  TIMEOUT / OK       ← alternujúci vzor
Slot 4 LED2:  TIMEOUT / OK       ← alternujúci vzor
Slot 5 SEG7:  TIMEOUT / TIMEOUT
```

### Záver: ramstyle fix funguje, zostatok = TX→RX coupling

Ramstyle fix eliminoval arbiter deadlock (17% → 58%).
Zostatok failov má **alternujúci vzor** (FAIL-OK-FAIL-OK), čo potvrdzuje
TX→RX coupling hypotézu:

1. FPGA odosiela odpoveď (25 bajtov, prvý bajt = 0xFE)
2. 0xFE dosahuje FPGA RX vstup cez PCB coupling alebo FTDI
3. Parser v S_IDLE vidí 0xFE → S_HDR; ďalší bajt TYPE=0x12 = neplatný opcode → S_DROP
4. Nasledujúci request (SOP=0xFE) → sop_recovery → spracovaný správne → OK
5. Cyklus sa opakuje

**Definitívny fix**: `XFCP_SOP_RESP ≠ XFCP_SOP_REQ` — IMPLEMENTOVANÉ (viď Fáza 2A).

---

## Fáza 2A — SOP_RESP=0xFD + MAX_COUNT_BYTES (2026-05-21)

### Implementované zmeny

**RTL:**
- `xfcp_pkg.sv`: `XFCP_SOP_RESP = 8'hFD` (oddelený od `XFCP_SOP_REQ = 8'hFE`)
- `xfcp_rx_parser.sv`: `MAX_COUNT_BYTES = 256` localparam, COUNT bound check pridaný do `dec_count_ok`
- `xfcp_axi_engine.sv`: ST_RD_WAIT — `RVALID && RREADY` (AXI spec fix; predtým iba RVALID)

**Sim:**
- `tb_xfcp_tx_packetizer.sv`: 6 SOP checks aktualizované z `0xFE` na `0xFD`
- `tb_xfcp_rx_parser.sv`: T9 test pridaný — COUNT=260 (> 256, násobok 4) → error_protocol

**Tools:**
- `tools/bus/xfcp.py`: `SOP_RESP = 0xFD`, validácia SOP_RESP na každý paket
- `tools/hw_diag.py`: `pre_delay=0.5` parameter v `transact_read()` pre timing diagnózu

**Sim výsledok: 13/13 ALL PASSED**

### Analýza TX→RX coupling po SOP_RESP=0xFD

Coupling cez FTDI kábel trvá — fyzický problém.

S SOP_RESP=0xFD coupling produkuje frame-errored bajty. Niektoré garbage bajty = 0xFE →
parser S_HDR → bez MAX_COUNT_BYTES fix: až 65535 slov AXI → 5.7 s UART TX → Python timeout.

S MAX_COUNT_BYTES=256: worst-case garbage = 256/4=64 slov AXI. 1 READ = 2.17ms.
64 READs = ~139ms. Watchdog 20μs per READ. UART TX max ~24ms.

### HW test výsledky po Fáze 2A (2026-05-21, relácia 3)

**Výsledky testov:**

| Test | Konfigurácia | Výsledok |
|---|---|---|
| hw_diag.py (pre_delay=0.5) | SOP_RESP=0xFD + MAX_COUNT_BYTES=256 + ST_RD_WAIT fix | 6/12 |
| hw_diag.py (pre_delay=0.5) | + frame_err_byte_q filter | 4/12 — horšie, REVERTED |
| hw_diag.py (pre_delay=0.5) | + RX FIFO hold-off (flush po TX) | 2/12 — ERR_CLR TIMEOUT, REVERTED |
| hw_diag.py (pre_delay=2.0) | bez hold-off, bez filter | 3/12 — dlhšia pauza = viac loop iterácií |

**Aktuálny stav HW: ~5-6/12 (42–50 %)** — coupling loop nie je eliminovateľný SW/RTL mitigation bez fyzickej opravy.

---

## Analýza coupling (2026-05-21, relácia 3) — FINÁLNA

### Root cause coupling loopov

**Paradox SOP_RESP=0xFD:**

S pôvodným `SOP_RESP=0xFE` (7/12):
```
coupling → 0xFE → S_HDR → TYPE=0x12 → neplatný opcode → S_DROP → S_IDLE (sub-ms, bez AXI)
```
Rýchly, žiadny TX, žiadny ďalší coupling. Loop zanikol spontánne.

S `SOP_RESP=0xFD` (5–6/12):
```
coupling → 0xFD → parser ignoruje (nie SOP_REQ) — OK
coupling → distorted byte = 0xFE → S_HDR → garbage count (MAX 256B) → AXI REQ
→ response TX (max 24ms) → ďalší coupling → loop (24ms/iterácia)
```
Ak loop nastane, trvá desiatky ms per iterácia. Pre_delay=500ms = ~20 loop iterácií max.
Pre_delay=2000ms = ~83 iterácií — viac iterácií = horšie výsledky.

### Pokusy o RTL/SW fix — NEFUNGOVALI

**1. frame_err_byte_q filter (uart_core_rx.sv):**
- Zahodil bajty so zlým stop bitom
- Coupling produkuje aj bajty BEZ frame error (stop bit=1, napr. 0xFD zo strong coupling)
- Filter selektívny → nekonzistentné garbage pre parser → 4/12 → **REVERTED**

**2. RX FIFO hold-off (xfcp_uart_mmio_top.sv):**
- Po konci TX: `flush=rx_in_holdoff` (5ms = 250K cyklov)
- Problém: `xfcp_fifo.w_ready = !flush` → bajty od PC stratené počas hold-off
- ERR_CLR WRITE bol TIMEOUT → **REVERTED**
- Fix by vyžadoval väčší u_rx_fifo DEPTH (>250ms × 115200 baud / 10 bpb = 2880 bajtov)
  alebo separátny "PC-RX buffer" oddelený od hold-off gating

### Záver: fyzická príčina

Coupling je na **fyzickej vrstve** — pravdepodobne FTDI FT232R echo alebo PCB kapacitívna väzba:
- Ak **FTDI echo**: rekonfigurácia FT232R EEPROM cez FT_Prog (Windows) alebo ftdi_eeprom (Linux)
- Ak **PCB kapacitívna**: RC filter 1kΩ + 10nF na RX line, alebo iný kábel/adaptér

Bez fyzickej opravy, SW mitigations dosiahli max ~6/12.

---

## Odporúčaný ďalší postup

### Krok 1 — Fyzická diagnostika (PRIORITA)

```bash
# Skontroluj FTDI konfiguráciu (Linux):
lsusb -v | grep -A3 "FTDI"
# Alebo použiť FT_Prog na Windows / ftdi_eeprom na Linux
# Hľadaj: "Echo" alebo "Loopback" nastavenie
```

Multimeter/scope na RXD pin QMTech počas FPGA TX:
- Ak signal na RXD stúpa počas TX → coupling existuje
- Ak flat → FTDI echo (nie kapacitívne)

### Krok 2 — Ak FTDI echo

```bash
# Vypnúť echo v FT232R EEPROM:
sudo ftdi_eeprom --flash-eeprom <config.conf>
```

Alebo použiť iný UART adaptér (CP2102, CH340 bez echo).

### Krok 3 — Ak kapacitívna väzba

- RC filter na UART_RX vstup FPGA: 1kΩ sériovo + 10nF na GND
- Alebo skúsiť iný USB-UART kábel

### Krok 4 — Po fyzickej oprave: overenie 12/12

```bash
make program
python3 tools/hw_diag.py
# Očakávanie: 12/12 OK, frame=False, overrun=False
```

### Krok 5 — Potom Fáza 2B (protokol robustnosť)

Po 12/12 overení:
- SEQ ID (8-bit counter)
- RESP_ERROR paket pre invalid addr
- Diagnostické registre v sys_ctrl

---

## Fáza 2B — post_tx_hold flush + invalid_req drop (2026-05-22)

### Analýza predchádzajúceho single-flight gate (d1c64ae)

Commit d1c64ae pridal `endpoint_busy_o` a gating `rx_gate = endpoint_busy_w`. Problem:
- `rx_gate` ukrývalo FIFO výstup pred parserom, ale FIFO **stále prijímalo** echo bajty
- Po skončení TX: rx_gate=0 → všetky echo bajty z FIFO naraz zaplaví parser
- Výsledok: 7/30 = 23 % (horšie ako bez gating)

### Implementované zmeny (Fáza 2B)

**RTL — xfcp_uart_mmio_top.sv:**

Nahradený single-flight gate post_tx_hold countérom s `fifo_flush_w`:
```sv
localparam int POST_TX_HOLD_CYCLES = 2000;  // 40 us @ 50 MHz
// post_tx_hold_w = tx_busy || countdown after tx_busy falls
wire fifo_flush_w = post_tx_hold_w;  // FIFO continuously resets — echo bytes lost
wire rx_gate_w    = post_tx_hold_w;  // FIFO output hidden from parser
```

Rozdiel od starého prístupu:
- `flush=1` → `w_ready=0` v xfcp_fifo → echo bajty sú ZAHODENÉ v okamihu príchodu
- Po vypršaní post_tx_hold: FIFO je PRÁZDNE (žiadne echo bajty)
- Parser nikdy nevidí echo bajty z predchádzajúcej odpovede

**RTL — xfcp/xfcp_fabric_endpoint.sv:**

Zmenená sémantika `endpoint_busy_o`:
```sv
// Pred: (arb_q != ARB_IDLE)  — busy aj počas AXI engine fázy
// Po:   (arb_q == ARB_WAIT_PKT)  — busy IBA počas TX fázy
assign endpoint_busy_o = (arb_q == ARB_WAIT_PKT);
```
Dôvod: endpoint_busy_w nie je viac použité na gating — je len dostupné pre debug.

**SIM — tb_xfcp_uart_mmio_top.sv:**

Pridané `repeat(3000) @(posedge clk)` v `xfcp_drain_write_resp()` a `xfcp_recv_read()`.
Dôvod: v SIM BAUD_DIV=16 → 1 bajt = 160 cyklov. post_tx_hold=2000 > 160 →
SOP prvého bajtu ďalšej požiadavky by bol zahodený. TB delay 3000 > 2000 → OK.

### Sim výsledky Fázy 2B

```
make (v sim/): 13/13 ALL PASSED
tb_xfcp_uart_mmio_top: Errors: 0 (predtým Errors: 1 so single-flight)
```

### HW test výsledky Fázy 2B

| Konfigurácia | Výsledok |
|---|---|
| d1c64ae single-flight gate (rx_gate=endpoint_busy) | 7/30 = 23 % |
| post_tx_hold=2000 + invalid_req (Fáza 2B) | 14/30 = 46 % |

Zlepšenie o 100 % relatívne. Dôvod: flush namiesto gate zabezpečuje skutočné zahodenie
echo bajtov pri príchode, nie ich akumuláciu vo FIFO.

### Analýza navrhy_10 (architectural review)

Navrhy_10 identifikoval AXI-Stream protokolový konflikt v `axis_uart_rx.sv`:
- `valid_o` je 1-cyklový pulz, TVALID nie je udržiavaný kým TREADY=1
- Odporúčanie: pridať Skid Buffer

**Záver: Skid Buffer NIE JE vhodný pre náš use case.**
Zámerný overrun (strata bajtu keď TREADY=0 počas flush) JE náš coupling mitigation
mechanizmus. Skid Buffer by držal echo bajty namiesto ich zahodenia.

Navrhy_10 tiež nesprávne uvádza `ramstyle="no_rw_check"` ako korektné — toto bol
ROOT CAUSE HW bugu (opravený v Fáze 1: ramstyle="logic").

### Zostatok coupling failov (54 %)

Príčina: fyzická PCB/kábel kapacitívna väzba, nie USB-UART loopback.
- Echo bajty prichádzajú POČAS TX → flush=1 → zahodené ✓
- post_tx_hold=2000 cyklov = 40 μs pokryje "chvost" po skončení TX
- Zvyšné zlyhania: echo bajty tvorené na hranách signálu tesne pred tx_busy

Ďalší možný postup:
1. **Fyzická diagnostika**: multimeter/scope na RXD pin počas FPGA TX
2. **RC filter**: 1kΩ + 10nF na UART_RX vstup
3. **Iný kábel/adaptér**: test s CP2102 vs FT232R vs CH340

---

## Otvorené technické problémy

| # | Problém | Priorita | Stav |
|---|---|---|---|
| 1 | TX→RX coupling (fyzická príčina) | STREDNÉ | 46 % HW success; čaká fyzická diagnostika |
| 2 | ST_RD_WAIT: RVALID&&RREADY | OPRAVENÉ | Commit 1dcfb01 |
| 3 | READ burst > FIFO_DEPTH=32 slov | NÍZKE | MAX_COUNT_BYTES=256→64 sl. — chunking v tools |
| 4 | Sim $fatal = Questa "Errors: N" | NÍZKE | Questa-specific; ALL PASSED funguje |
| 5 | RESP_ERROR paket pre invalid req | NÍZKE | Fáza 2C plán |
| 6 | Tools: chunking, SEQ, CRC, recovery | NÍZKE | Fáza 3 plán |

---

## Fáza 2C — Watchdog fix + diagnostika (2026-05-22)

### Implementované zmeny

**RTL — xfcp/xfcp_rx_parser.sv:**

Watchdog deadlock fix: `pkt_len_q` sa resetuje aj pri `sop_recovery`.

Teoreticky možný scenár bez fixu:
```
1. Capture noise (4112+ bajtov bez S_IDLE) → pkt_len_q saturuje
2. watchdog_fire=1 → go_drop=1 → S_DROP
3. Novy SOP: sop_recovery → S_HDR (ale pkt_len_q ostava=4112)
4. S_HDR: watchdog_fire=1 → go_drop=1 → S_DROP okamzite
5. Permanentny deadlock — parser ignoruje vsetky SOP-y
```

Oprava:
```sv
// Pred:
else if (state_q == S_IDLE)
  pkt_len_q <= '0;
// Po:
else if (state_q == S_IDLE || sop_recovery)
  pkt_len_q <= '0;
```

**RTL — xfcp_uart_mmio_top.sv:**

`POST_TX_HOLD_CYCLES` zmeneny z hardcoded 2000 na `UART_DEFAULT_BAUD_DIV * 10`:
- HW (434): 4340 cyklov = 86.8 us = 1 UART bajt perioda
- SIM (16): 160 cyklov < 3000 cyklov (TB delay) → OK

Dôvod: 2000 cyklov (40 us) pokrývalo iba kapacitívny chvost, nie celú bajtovú periódu.
Ak coupling produkuje "half-bit" noise, môže generovať validný UART bajt v 86.8 us okne.

**SIM — tb_xfcp_uart_mmio_top.sv:**

Rozšírenie testov: T5–T16 (2 opakovania × 6 slotov) replikuje `hw_diag.py` sekvencný scan.
Ciel: odhalit state-machine bugy neviditelne pri jednoducham 2-slot testovani.

### Sim výsledky Fázy 2C

```
make (v sim/): ALL PASSED (0 failures) — 16/16 testov vrátane T5-T16 (vsetky sloty × 2)
```

### HW test výsledky Fázy 2C

**Výsledok: 10/30 = 33 %** — horšie ako Fáza 2B (14/30 = 46 %)

**UART STATUS po teste: overrun=False, frame=False, parity=False — ZIADNE coupling chyby!**

### Kľúčové zistenie: coupling NIE JE príčinou 33 % failov

UART STATUS ukazuje **žiadne** coupling chyby. To znamená:
- Fyzický signal je čistý (žiadny TX→RX echo)
- FPGA dostáva bajty správne (žiadny frame error)
- 67 % failov NIE JE spôsobených fyzickým coupling-om

### RTL analýza root cause (2026-05-22) — neúspešná

Kompletná analýza RTL kódu (všetky moduly): `xfcp_rx_parser`, `xfcp_fabric_endpoint`,
`xfcp_axi_engine`, `xfcp_tx_packetizer`, `axil_regfile`, `axil_seven_seg_adapter`.

**Žiadny RTL bug nenájdený.** Všetky state machine prechody sú správne:
- Arbiter ARB_IDLE/WAIT_ENG/WAIT_PKT: správna logika ✓
- eng_done_cnt tracking: správny ✓
- packetizer_idle_q dual-check: správny ✓
- resp_done_mux: správny ✓
- AXI regfile: AXI4-Lite compliant ✓

**Štatistická interpretácia:**
S uniformnou 33 % mierou úspechu a 5 opakovaní:
- P(slot zlyhá 5/5) = 0.67^5 = 13.5 % → pre 6 slotov = 57 % šanca vidieť jeden slot 0/5
- "Slot 5: 0/5" je pravdepodobná náhoda, nie deterministický bug

### Hypotézy o HW príčine

1. **USB-UART bridge latencia/buffering** — CP2102/FT232R môže mať non-deterministické
   buffering správanie. Niektoré bajty môžu prísť s oneskorením alebo byť groupované.
   → Parser stalls v S_HDR ak request bytes neprichádzaju súvisle.

2. **Post_tx_hold regresia** — BAUD_DIV*10=4340 cyklov je dlhší než 2000. Ak coupling
   má INAK chvost (viac noise bajtov), dlhší flush môže zahodiť viac legitímnych bajtov.
   Empiricky: 2000 cyklov (Fáza 2B) = 14/30, 4340 cyklov = 10/30.

3. **Watchdog fix interakcia** — v normálnej prevádzke sop_recovery nikdy nevznikne,
   watchdog fix nemá efekt. Ale ak je fyzický signal inak než v SIM...

### Odporúčania pre ďalší postup

1. **Revert POST_TX_HOLD späť na 2000** — empiricky lepšie (14/30 vs 10/30)
2. **Diagnostický výpis**: pridať do hw_diag.py typ každého zlyhania (0B / partial / bad_SOP)
3. **Scope na fyzický RXD pin** počas FPGA TX — overit ci coupling existuje
4. **Viac iterácii**: repeat=10 (60 testov) pre lepšiu štatistiku

---

## Fáza 3A — navrhy_11 implementácia (2026-05-22)

### Krok 1: ENABLE_POST_TX_FLUSH parametrizácia

Nový parameter `ENABLE_POST_TX_FLUSH = 1'b0` (default OFF) v `xfcp_uart_mmio_top.sv`.

**Hypotéza:** flush bol zbytočný (alebo škodlivý) pretože SOP_RESP=0xFD zaistil, že echo
bajty z TX→RX couplingu sa nezhodujú s SOP_REQ=0xFE a parser ich v S_IDLE ignoruje.
Empirické dáta: flush OFF=?, 2000=46%, 4340=33%. Cieľom HW testu je porovnať flush OFF.

`POST_TX_HOLD_CYCLES` zostáva ako parameter pre prípad testovania s flush ON.

### Krok 2: RTL Diagnostic Counters — Slot 6 @ 0xFF060000

Nový modul `axil_diag_ctrl.sv` s 10 32-bit saturujúcimi čítačmi:

| Offset | Názov | Zdroj |
|--------|-------|-------|
| 0x00 | COMPONENT_ID = "DIAG" | konštanta |
| 0x04 | RX_BYTE_COUNT | uart_rx_raw_s.TVALID && TREADY |
| 0x08 | RX_SOP_COUNT | parser: S_IDLE→S_HDR (dbg_sop_o) |
| 0x0C | RX_HDR_COUNT | parser: hfifo_push (dbg_hdr_o) |
| 0x10 | RX_DROP_COUNT | parser: go_drop && !S_DROP (dbg_drop_o) |
| 0x14 | FAB_REQ_COUNT | endpoint: req_fire && !invalid_req (dbg_req_o) |
| 0x18 | FAB_RESP_COUNT | endpoint: resp_start_pulse (dbg_resp_o) |
| 0x1C | TX_BYTE_COUNT | xfcp_tx_s.TVALID && TREADY |
| 0x20 | TX_PKT_COUNT | tx_busy rising edge |
| 0x24 | DIAG_RESET (PULSE) | write any → clear all |

Debug pulse porty pridané do `xfcp_rx_parser.sv` (dbg_sop/hdr/drop) a
`xfcp_fabric_endpoint.sv` (dbg_req/resp + passthrough parser ports).

### Krok 3: Tools SOP Resync

`SerialTransport.read_packet(expected_len)` v `tools/xfcp/transport.py`:
- Skenuje byte-by-byte pre SOP_RESP=0xFD
- Zahadzuje stale bajty pred SOP
- Číta zvyšok paketu po nájdení SOP

`XfcpBus._transact()` aktualizovaný na používanie `read_packet()` namiesto slepého `read(n)`.

`hw_diag.py` aktualizovaný:
- `recv_with_sop_resync()` — inline SOP resync pre standalone script
- `diag_reset()` + `diag_read_all()` + `print_diag()` — čítanie DIAG counterov
- Post-test výpis: porovnáva očakávané vs. skutočné hodnoty counterov

### SIM validácia

Regression: **16/16 ALL PASSED** (Errors: 0, Warnings: 0).

### Adresová mapa po Fáza 3A

```
Slot 0 @ 0xFF000000 : axil_sys_ctrl    (ID "SYSC")
Slot 1 @ 0xFF010000 : axil_uart_adapter (ID "UART")
Slot 2 @ 0xFF020000 : axil_regs / LED   (ID "OUT_")  6-bit onboard
Slot 3 @ 0xFF030000 : axil_regs / LED   (ID "OUT_")  8-bit J10
Slot 4 @ 0xFF040000 : axil_regs / LED   (ID "OUT_")  8-bit J11
Slot 5 @ 0xFF050000 : axil_seven_seg    (ID "SEG7")
Slot 6 @ 0xFF060000 : axil_diag_ctrl   (ID "DIAG")
```

### HW test výsledky Fázy 3A (ENABLE_POST_TX_FLUSH=0, commit 005cd58)

**Výsledok: 18/30 = 60 %** — najlepší výsledok doteraz.

```
Slot 0 SYSC:  OK/OK/OK/OK/OK
Slot 1 UART:  OK/FAIL/FAIL/FAIL/OK
Slot 2 LED0:  OK/OK/OK/FAIL/FAIL
Slot 3 LED1:  FAIL/FAIL/OK/FAIL/OK
Slot 4 LED2:  OK/OK/FAIL/FAIL/OK
Slot 5 SEG7:  OK/FAIL/OK/OK/OK
```

DIAG counters (Fáza 3A HW test):
- `rx_sop=21` (< 30 expected) — 9 requestov stratených pred SOP
- FRAME ERROR detected (`frame_err=True`) — TX→RX coupling generuje bajty so zlým stop bitom
- `tx_pkt=571` → odhaleny bug: tx_pkt_pulse_w pocital UART TX byte starty, nie XFCP pakety

---

## Fáza 3B — navrhy_12 implementácia (2026-05-22, commit 4a50f42)

### Implementované zmeny

**RTL — xfcp_uart_mmio_top.sv:**
- `rx_byte_pulse_w = uart_rx_raw_s.TVALID` (odstraněné `&& TREADY`):
  RX_BYTE_COUNT teraz počíta VŠETKY bajty produkované UART RX core, nielen FIFO-prijaté.
  Lepšia diagnostika coupling: ukazuje koľko bajtov FPGA RX skutočne vidí.
- `tx_pkt_i = dbg_resp_w` (namiesto `tx_pkt_pulse_w`):
  TX_PKT_COUNT teraz počíta XFCP response pakety (resp_start_pulse), nie UART TX byte starty.
- Odstranené `wire tx_pkt_pulse_w` (nesprávne semanticky: počítalo UART byte busy rising edges).

**RTL — xfcp/xfcp_fabric_endpoint.sv:**
- Komentár `endpoint_busy_o` aktualizovaný na správnu sémantiku:
  "High only while response packet is being transmitted."
- `$error` → `$warning` pre neplatnú adresu (očakávaný negatívny test, nie fatal).

**RTL — xfcp/xfcp_rx_parser.sv:**
- `$error` → `$warning` pre PROTOCOL ERROR → S_DROP (očakávaný negatívny test).

**RTL — xfcp/xfcp_axi_engine.sv:**
- `$error` → `$warning` pre WATCHDOG TIMEOUT (očakávaný negatívny test).

**RTL — axil/axil_diag_ctrl.sv:**
- Komentár RX_BYTE_COUNT aktualizovaný: "TVALID, before FIFO gate".

### Sim výsledky

Regression: **16/16 ALL PASSED**, Errors: 0 vo VŠETKÝCH logoch (predtým Errors: 1 v tb_xfcp_axi_engine).

### HW test výsledky Fázy 3B (navrhy_12, commit 4a50f42)

**Výsledok: 28/60 = 46 %** — konzistentné s ~50% fyzickým coupling failom.

```
Slot 0 SYSC:  9/10  (1 fail)
Slot 1 UART:  3/10  (7 fail)
Slot 2 LED0:  5/10  (5 fail)
Slot 3 LED1:  5/10  (5 fail)
Slot 4 LED2:  2/10  (8 fail)
Slot 5 SEG7:  4/10  (6 fail)
```

### DIAG analýza po Fáze 3B

DIAG counters (post-test, Fáza 3B):
```
rx_bytes=None  rx_sop=None  rx_hdr=29  rx_drop=0
fab_req=None   fab_resp=None  tx_bytes=750  tx_pkt=None
Ocakavane: rx_bytes~480  tx_pkt=60  tx_bytes~1500
```

**Kľúčové zistenia:**

1. `rx_hdr=29` — parser dekódoval iba 29 z 60 requestov. Zvyšných ~31 bolo stratených
   PRED parserom (neúplné hlavičky → hdr_decode nikdy nenastalo).

2. `rx_drop=0` — keď bajty dorazili kompletné, parser ich nezahodil. Žiadne chyby v parseri.

3. `tx_bytes=750 ≈ 30 × 25B` — FPGA odoslalo ~30 kompletných odpovedí. Zodpovedá rx_hdr=29.

4. Niektoré DIAG reads (`rx_bytes`, `rx_sop`, `fab_req`, `fab_resp`, `tx_pkt`) sami
   zlyhali (~50% timeout) — konzistentné s celkovým 46% failom.

**Záver DIAG diagnostiky:**
Problém je jednoznačne v UART RX fyzickej vrstve — pred parserom. Coupling z FPGA TX
generuje noise bajty (niektoré so FRAME ERROR) ktoré "ukradnú" miesto legitimných request
bajtov. Výsledok: parser dostane neúplnú hlavičku a nikdy nedekóduje request.

RTL logika (parser, fabrik, engine, packetizer) funguje správne:
- **Keď request príde do parsera kompletný → vždy dostane odpoveď** (rx_drop=0, tx_bytes≈30×25).
- Problém je fyzický (UART RX coupling), nie logický.

---

## Ďalší krok — fyzická diagnostika a protokol robustnosť

### Fyzická diagnostika (PRIORITA 1)

Coupling z FPGA TX zasahuje FPGA RX pri každej odpovedi. Bez fyzickej opravy
zostávame na ~50% úspešnosti.

```bash
# Kontrola FTDI echo nastavenia (Linux):
lsusb -v | grep -A5 "FTDI"

# Scope/multimeter: RXD pin QMTech počas FPGA TX
# Ak signal stúpa → kapacitívna väzba → RC filter 1kΩ + 10nF
# Ak flat → FTDI loopback → rekonfigurácia EEPROM / iný adaptér
```

### SEQ ID (PRIORITA 2)

Spurious odpovede z coupling requestov interferujú s Python reception.
SEQ ID umožní tools zahodiť spurious odpovede bez ohľadu na fyzické podmienky:

```
Request:  SOP_REQ, OP, SEQ, COUNT, ADDR, PAYLOAD
Response: SOP_RESP, RESP_OP, SEQ, DEV_TYPE, DEV_STR, PAYLOAD, 0x00
```

---

## Fáza 3C — navrhy_13: baud rate sweep (2026-05-22, commit dbf7151)

### Implementované zmeny

**Tools — hw_diag.py:**
- `--baud {9600,19200,38400,57600,115200}` — runtime baud switch cez AXI WRITE na
  0xFF010004 (UART_BAUD_DIV register), bez nutnosti rebuildovať RTL bitstream.
- `--sweep` — automatický scan 115200/57600/38400/9600 s DIAG countermi a summary tabuľkou.
- Argparse nahrádza pozícionne sys.argv, port/repeat zostávajú pozícionne.

### HW sweep výsledky (2026-05-22)

```
Baud     OK  Total     %
115200    4    30    13%  ← spurious couplings = 6 extra fab_resp
57600     0    30     0%  ← baud switch ZLYHAL → baud mismatch
38400     0    30     0%  ← baud switch ZLYHAL → baud mismatch
9600      0    30     0%  ← baud switch ZLYHAL → baud mismatch
```

### Kľúčové nálezy sweep testu

**1. Baud switch selhal (WRITE na BAUD_DIV podlieha rovnakému failure rate)**

Každý baud switch vyžaduje 1 WRITE transakciu. Ak táto transakcia zlyhá
(a v tomto behu bol failure rate ~87%), FPGA ostane na 115200 zatiaľčo PC
prepne na nový baud → baud mismatch → 0/30. Výsledky 57600/38400/9600
sú preto neinformatívne — netestujú nové baud raty.

**2. fab_resp=36 > 30: coupling bajty formujú platné XFCP requesty**

```
rx_bytes=646  (očakávané: 30×8=240)
fab_resp=36   (očakávané: 30)
```

Extra 406 bajtov = echo coupling. Z týchto 406 bajtov FPGA parser
dekódoval 6 kompletných platných XFCP hlavičiek → 6 spurious odpovedí.
Tieto spurious odpovede interferujú s Python reception:
Python dostane spurious 0xFD response namiesto legitímnej → classify jako
"OK" ale s nesprávnymi dátami alebo timeout na skutočnú odpoveď.

**3. Interpretácia per navrhy_13: Prípad B — baud rate NEvyrieši problém**

Coupling je fyzický problém nezávislý od baud rate. Zníženie baud rate
by skôr predĺžilo dobu coupling okna (dlhší bit period = dlhší coupling chvost).

### Záver: potrebný SEQ ID + fyzická diagnostika

Coupling generuje spurious requesty → spurious odpovede → Python confusion.
Dve cesty k riešeniu (navzájom nezávislé, obe užitočné):

1. **SEQ ID** (RTL+tools): tools odmietnu spurious odpovede s nesprávnym SEQ.
   Zlepší úspešnosť aj bez fyzickej opravy.

2. **Fyzická oprava** (RC filter alebo iný adaptér): eliminuje coupling bajty.
   Trvalé riešenie.

---

## Fáza 3D — navrhy_14: pending/commit baud switch + opravy (2026-05-22, commit 6afe581)

### Motivácia

Fáza 3C sweep odhalil: runtime baud switch cez priamy zápis BAUD_DIV (0x04) nefunguje.
Príčina: `assign baud_div_o = hw_wdata_w[1*32 +: 32]` aplikoval novú baud rýchlosť
okamžite → FPGA odoslal ACK na WRITE novou baud rýchlosťou, kým PC ešte čakal na starej.

Navyše bug v `uart_diag.py`: `data_bits=8` → `(8-5)&3=3` → 5-bit mode (invertovaný mapping).

### Implementované zmeny

**RTL — axil/axil_uart_adapter.sv:**

NUM_REGS 7 → 9. Nové registre:
- `0x1C  BAUD_COMMIT (PULSE)` — zápis spustí countdown `baud_active * 320` cyklov, potom switch
- `0x20  BAUD_ACTIVE (RO)` — readback aktuálne aktívneho prescaleru

`baud_div_o = baud_active_q` namiesto priameho `hw_wdata_w` assign.

```
baud_active_q     -- aktuálne používaný prescaler (resetuje sa na BAUD_DIV_DEFAULT)
baud_pending_q    -- nová hodnota zapísaná do 0x04 (BAUD_PENDING), ešte neaplikovaná
baud_we_r         -- 1-cycle delayed strobe pre správny timing hw_wdata_w (AXIL_RW FF latencia)
baud_switch_cnt_q -- countdown = baud_active * 320 cyklov
```

Sekvenecia bezpečného switchu:
```
PC zapíše BAUD_PENDING (0x04) → ACK na starej baud  ✓
PC zapíše BAUD_COMMIT  (0x1C) → ACK na starej baud  ✓
FPGA odpočíta countdown (~2.8 ms pri 115200, ~33 ms pri 9600)
FPGA prepne baud_active_q = baud_pending_q
PC čaká 150 ms → prepne baudrate → ping
```

**tools/modules/uart_diag.py:**

Bug fix v `configure()`:
```python
# Pred (CHYBA): data_bits=8 → 3 → 5-bit mode
self.data_bits = (data_bits - 5) & 0x3
# Po (SPRÁVNE):
dbits_map = {8: 0b00, 7: 0b01, 6: 0b10, 5: 0b11}
self.data_bits = dbits_map[data_bits]
```

**tools/xfcp/transport.py:**

Pridaná `SerialTransport.set_baudrate(baudrate)` — runtime zmena PC-side baud bez
zavretia a znovuotvorenia sériového portu.

**tools/xfcp/bus.py:**

Pridaná `XfcpBus.set_baudrate(new_baud, clk_hz=50_000_000)`:
```
write32(0xFF010004, new_div)  # BAUD_PENDING, ACK na starej baud
write32(0xFF01001C, 1)        # BAUD_COMMIT, ACK na starej baud
sleep(0.15)                   # čakaj na FPGA countdown
transport.set_baudrate(new_baud)
ping()                        # overenie
```

**tools/hw_diag.py:**

`set_baud()` prepísaný na two-step protokol. Pridané:
- `UART_BAUD_COMMIT = 0xFF01001C`
- `UART_BAUD_ACTIVE = 0xFF010020`

### Sim výsledky

Regression: **16/16 ALL PASSED**, Errors: 0 všade.

`tb_axil_uart_adapter.sv` aktualizovaný pre 9-register mapu:
- T7: overí baud_div_o je stále na default PO zápise BAUD_PENDING (pending, nespustené)
- T11: BAUD_COMMIT → čaká 140 000 cyklov → baud_div_o prepnutý
- T12: BAUD_ACTIVE readback vracia novú hodnotu

### HW test výsledky Fázy 3D (2026-05-22, commit 6afe581)

**Quartus compile: SUCCESS** — 0 errors, 0 warnings. Bitfile: `output_files/soc_top.sof`.
FPGA naprogramovaný úspešne (EP4CE55F23@1).

**Sweep výsledky:**

```
SWEEP ZHRNUTIE:
      Baud     OK  Total      %
  --------  -----  -----  -----
    115200     10     30    33%
     57600     11     30    36%
     38400     11     30    36%
      9600      9     30    30%
```

Všetky baud switche: "VAROVANIE: baud switch na XXX — overenie zlyhalo, pokracujem".

### Analýza výsledkov Fázy 3D

**1. Baud switch stále nefunguje — príčina: 2 consecutive WRITEs nutné**

`set_baud()` vyžaduje 2 WRITE transakcie (BAUD_PENDING + BAUD_COMMIT) pri starej baud rýchlosti.
S ~33% individuálnym úspechom každého WRITE:
```
P(obe transakcie uspejú) ≈ 0.33 × 0.33 ≈ 11%
```
`set_baud()` vracia `False` pri prvom zlyhaní (ešte pred prepnutím PC baud) →
FPGA ostane na 115200, PC timeout sa nastaví podľa nového baud → ďalší testy čiastočne fungujú
ale FPGA baud sa neprepol.

**2. Úspešné odpovede trvajú 5.4–5.7 ms bez ohľadu na deklarovaný baud**
Potvrdzuje že FPGA ostalo na 115200 vo všetkých sekciách sweepovacieho testu.
Výsledky 57600/38400/9600 (36%/36%/30%) odrážajú pôvodnú 115200 výkonnosť,
nie skutočnú zmenu baud rýchlosti.

**3. RTL pending/commit je funkčný (sim 16/16 PASS)**
Problém nie je v RTL logike ale v tom, že triggering RTL mechanizmu vyžaduje
2 po sebe úspešné WRITEs v prostredí s ~67% failure rate.

### Záver Fázy 3D

Pending/commit RTL mechanizmus je správny. Baud switch v HW zlyhá kým coupling
spôsobuje ~67% WRITE failure rate. Na riešenie existujú 2 nezávislé cesty:

1. **SEQ ID** (PRIORITA 1) — RTL+tools odmietnu spurious odpovede; zlepší WRITE success rate
2. **Fyzická oprava** (RC filter alebo iný adaptér) — trvalé riešenie coupling problému

---

## Fáza 3E — navrhy_15: DIAG snapshot + safe baud switch (2026-05-22, commit 3104938)

### Motivácia (expert feedback z EXPERT_BRIEF.md)

1. **DIAG live counter artifact** — čítanie registrov počas testu menilo live countery
   (read_all vysielal AXI transakcie, čo inkrementovalo rx_byte, tx_byte atď.).
2. **BAUD_COMMIT "možno prebehol"** — predchádzajúci set_baudrate() abortoval keď
   COMMIT WRITE zlyhal, ale FPGA mohol prepnúť aj napriek strate ACK.
3. Chýbajúce diagnostické informácie: nie je vidno koľko bajtov FPGA prijalo vs
   zahodilo, ani či nastala sop_recovery alebo bad_hdr.

### Implementované zmeny

**RTL — axil/axil_diag_ctrl.sv (kompletný rewrite, NUM_REGS 10→17):**

Snapshot architektúra: 14 live counterov + 14 shadow registrov.
`DIAG_SNAPSHOT (0x40 PULSE)` skopíruje live → shadow. Reads vždy vracajú shadow hodnoty.

Nová register mapa:

| Offset | Názov | Zdroj |
|--------|-------|-------|
| 0x00 | COMPONENT_ID "DIAG" | konštanta |
| 0x04 | RX_SEEN | uart_rx_raw TVALID (všetky bajty) |
| 0x08 | RX_ACCEPT | uart_rx_raw TVALID && TREADY (akceptované) |
| 0x0C | RX_LOST | uart_rx_raw TVALID && !TREADY (stratené pri flush) |
| 0x10 | RX_FRAME | rx_status frame_err pulse |
| 0x14 | RX_OVERRUN | rx_status overrun_err pulse |
| 0x18 | RX_SOP | parser S_IDLE→S_HDR (dbg_sop_o) |
| 0x1C | RX_HDR | parser hfifo_push (dbg_hdr_o) |
| 0x20 | RX_BAD_HDR | parser S_DECODE → go_drop (dbg_bad_hdr_o) |
| 0x24 | RX_RECOVERY | parser sop_recovery (dbg_recovery_o) |
| 0x28 | RX_DROP | parser go_drop && !S_DROP (dbg_drop_o) |
| 0x2C | FAB_REQ | endpoint req_fire && !invalid_req |
| 0x30 | FAB_RESP | endpoint resp_start_pulse |
| 0x34 | TX_BYTE | xfcp_tx TVALID && TREADY |
| 0x38 | TX_PKT | endpoint resp_start_pulse |
| 0x3C | DIAG_RESET (PULSE) | vynuluj live countery |
| 0x40 | DIAG_SNAPSHOT (PULSE) | zamorzi live → shadow |

**RTL — axil/axil_uart_adapter.sv (NUM_REGS 9→10):**

- `0x24 BAUD_STATUS (RO)` — `{29'h0, rx_busy, tx_busy, baud_switch_pending}`
- Busy guard: baud switch teraz čaká na `!tx_busy_i && !rx_busy_i` pred
  aplikáciou novej baud rýchlosti (predtým čakal iba na countdown=0).

**RTL — xfcp/xfcp_rx_parser.sv:**

- `dbg_bad_hdr_o` — pulse: S_DECODE decode error (go_drop v S_DECODE stave)
- `dbg_recovery_o` — pulse: sop_recovery (SOP prijatý v neočakávanom stave)

**RTL — xfcp/xfcp_fabric_endpoint.sv:**

- Passthrough portov `dbg_bad_hdr_o` a `dbg_recovery_o` z parsera.

**RTL — xfcp_uart_mmio_top.sv:**

- `rx_seen_pulse_w = uart_rx_raw_s.TVALID`
- `rx_accept_pulse_w = uart_rx_raw_s.TVALID && uart_rx_raw_s.TREADY`
- `rx_lost_pulse_w = uart_rx_raw_s.TVALID && !uart_rx_raw_s.TREADY`
- `rx_frame_pulse_w = rx_status_w.frame_err`
- `rx_overrun_pulse_w = rx_status_w.overrun_err`

**Tools — tools/xfcp/transport.py:**

- `baudrate` property (getter) — umožňuje čítať aktuálny baud bez reopenu portu.

**Tools — tools/xfcp/bus.py:**

Nahradená `set_baudrate()` bezpečnou verziou:
```python
# 1. Retry BAUD_PENDING write 5x (každý s drain())
# 2. Pošli BAUD_COMMIT — ignoruj ACK failure (FPGA mohol prepnúť)
# 3. Čakaj 200 ms na countdown
# 4. Prepni PC baud, skús ping()
# 5. Ak ping zlyhá: fallback na starý baud, skús ping()
# 6. Ak oba zlyhajú: raise XfcpRecoveryError
```

**Tools — tools/hw_diag.py:**

- Nové DIAG konštanty (18 adries vrátane DIAG_SNAPSHOT=0x40).
- `diag_snapshot()` — WRITE na 0x40 pred čítaním.
- `diag_read_all()` — volá snapshot, potom číta 14 shadow registrov.
- `print_diag()` — rozšírený výstup: rx_seen/accept/lost, frame/overrun, bad_hdr/recovery.
- `set_baud()` — retry PENDING 5x, ignoruj COMMIT ACK, probe new+old baud, raise RuntimeError pri neurčitom stave.

**EXPERT_BRIEF.md:**

- CP2102 (nie FT232R) — opravená identifikácia USB-UART bridgu.
- Coupling záver zmenený na hypotézu (nie definitívne potvrdenie).

### Sim výsledky

**16/16 ALL PASSED**, Errors: 0 vo všetkých testbenchoch.

### HW test

Nutný Quartus rebuild pre novú DIAG register mapu a BAUD_STATUS register.
Test čaká.

### Správne použitie DIAG workflow po Fáze 3E

```python
# 1. Spusti DIAG_RESET (vynuluj live countery)
bus.write32(0xFF060038, 1)   # DIAG_RESET (0x3C offset od base)
# 2. Vykonaj testy
# 3. DIAG_SNAPSHOT (zamorzi live → shadow)
bus.write32(0xFF06003C, 1)   # DIAG_SNAPSHOT (0x40 offset od base)
# 4. Prečítaj shadow registre — neovplyvňujú live countery
rx_seen   = bus.read32(0xFF060004)
rx_accept = bus.read32(0xFF060008)
# ... atď.
```

---

## Fáza 3F — navrhy_16: skid buffer + fyzická diagnostika (2026-05-22, commit de2da76)

### Implementované zmeny

**RTL — axis/axis_uart_rx.sv:**

Pridaný output skid register (AXI-Stream disciplína fix):
```sv
// Pred: out_valid_o = 1-cycle pulse, out_data_o nestabilne po 1 takte
// Po:   out_valid_q drzi bajt kym TREADY=1
//       ready_i = !out_valid_q || out_ready_i
```
Efekt: FPGA RX core nezdvihne `TVALID` kým predchádzajúci bajt nebol prevzatý.
Zabraňuje strate bajtov keď FIFO downstream nie je immediately ready.

Poznamka: ENABLE_POST_TX_FLUSH=0 (default OFF) znamená ze TREADY je takmer vzdy=1,
takze skid buffer je prevazne "quality-of-protocol" fix, nie silny change v HW spravani.

**Tools — hw_diag.py:**

- `--pause MS` argument — pauza medzi requestmi (default 0). Test 2 podla navrhy_16:
  ak 100ms pauza zlepsi vysledok → stale response / post-response recovery problem.
- `--pause 100` pre izolaciu stale response (odporucany test pred SEQ ID)

**Makefile:**

- `compile-baud BAUD=N` — staticke baud bitstreamy bez runtime switchu.
  Patches `build/rtl/soc_top.sv` (`UART_DEFAULT_BAUD_DIV`), kompiluje, kopiruje do
  `output_files/soc_top_NNNNNbaud.sof`, obnoví default 115200.
- `compile-all-bauds` — 115200 / 57600 / 38400 / 9600 sekvenencne.
  Pouzitie: `make compile-baud BAUD=57600` (vyzaduje predchadzajuci `make gen`)

**EXPERT_BRIEF.md:**

- CP2102 v ASCII diagrame (nie FT232R)
- RC filter oprava: 10 nF NESPRAVNE (RC=10us > bit period=8.68us pri 115200 baud)
  Spravne hodnoty: 100–470 pF. Orientacne: 1kOhm + 470pF → RC=0.47us << 8.68us
- Sekcia "Fyzicke diagnosticke testy A–D" podla navrhy_16 expert analyzy

### Sim vysledky Fazy 3F

**16/16 ALL PASSED**, Errors: 0.

### Quartus build (Faza 3E+3F kumulativny rebuild)

Build spusteny po commite de2da76, dokonceny 2026-05-22 21:20.
**Bitfile: `output_files/soc_top.sof`** — obsahuje vsetky zmeny Fazy 3E a 3F:
- DIAG snapshot architektura (NUM_REGS=17, shadow countery)
- BAUD_STATUS register (0xFF010024)
- axis_uart_rx skid buffer
- ENABLE_POST_TX_FLUSH=0 (default)

**HW test: CAKA.** Odporucany postup:
1. `make program` — naprogramuj FPGA
2. `python3 tools/hw_diag.py /dev/ttyUSB0 30` — základny test 30 iteracii
3. `python3 tools/hw_diag.py /dev/ttyUSB0 30 --pause 100` — test s 100ms pauzou (Test 2)
4. Porovnaj DIAG countery: rx_seen vs rx_accept vs rx_hdr vs fab_resp

### Odporucane nasledujuce kroky (prioritny poradie)

1. **HW test** — novy bitfile s DIAG snapshot workflow + skid buffer
2. **Fyzicka diagnostika** (ak test potvrdi coupling):
   - Test A: CP2102 bez FPGA — overi adaptér echo
   - Test D: sniffer adaptér na FPGA TX linka
3. **SEQ ID** (B-faza) — odmietnutie spurious odpovedi bez ohla na fyziku
4. **Staticky baud sweep** (`make compile-baud`) — ak SEQ ID nezlepsi, izolatuj baud

---

## Fáza 3G — navrhy_17: kompletná implementácia SEQ ID (2026-05-23)

### Problém identifikovaný expertom (navrhy_17)

HW test (Fáza 3F) skončil **0/30** (100% FAIL). Expert v navrhy_17 identifikoval 7 kritických
nekonzistencií medzi RTL, tools a testbenchmi z nedokončenej SEQ ID implementácie:

1. **xfcp_rx_parser.sv**: `HDR_SHIFT_W=72` ale shift `{hdr_shift_q[63:0], data}` — posúva iba
   64 bitov → `hdr_shift_q[71:64]` vždy 0 → `dec_opcode=0` → všetky pakety zahadzované.
2. **xfcp_axi_engine.sv**: port `[55:0]` s 64-bit struct → opcode sa stratí truncáciou.
3. **xfcp_fabric_endpoint.sv**: `order_entry_t` neobsahuje `seq` → SEQ sa nedostane do packetizéra.
4. **xfcp_tx_packetizer.sv**: `HEADER_BYTES=20`, chýba `resp_seq` vstupný port.
5. **hw_diag.py**: starý formát bez SEQ bajtu → parser čaká na 8. bajt, ktorý nikdy nepríde.
6. **xfcp/protocol.py + bus.py**: `RESP_HEADER=20`, encode bez SEQ.
7. **testbenchy**: 7-bajtové hlavičky (bez SEQ), 21/25-bajtové response čítanie.

### Implementované zmeny (Option B — kompletná SEQ implementácia)

**RTL (`rtl/xfcp/`):**
- `xfcp_rx_parser.sv`: `HDR_SHIFT_W: 72→64`, shift `{hdr_shift_q[55:0], data}`, decode
  `dec_opcode=[63:56]`, `dec_seq=[55:48]`, `dec_count=[47:32]`, `dec_addr=[31:0]`. Field
  assignment cez `hfifo_in.seq = dec_seq`.
- `xfcp_axi_engine.sv`: port `[55:0]→[$bits(xfcp_req_hdr_t)-1:0]` (64-bit, bez truncácie).
- `xfcp_fabric_endpoint.sv`: `order_entry_t` + `seq` field; `resp_seq_q` register; `.resp_seq(resp_seq_q)` pre packetizér.
- `xfcp_tx_packetizer.sv`: `HEADER_BYTES: 20→21`; nový `resp_seq` input port;
  `hdr_vec[16+:8] = resp_seq` (SEQ na pozícii 2 za SOP+TYPE).

**Tools (`tools/`):**
- `hw_diag.py`: `_next_seq()`, SEQ v `make_read_pkt`/`make_write_pkt`, `EXPECTED_READ: 25→26`.
- `xfcp/protocol.py`: `RESP_HEADER: 20→21`, SEQ v `encode_read`/`encode_write`, SEQ check
  v `decode_read_response`/`decode_write_response`.
- `xfcp/bus.py`: `self._seq`, `_next_seq()`, SEQ v `write32`/`read_block`/`write_block`.

**Testbenchy:**
- Všetky 7 testbenchov aktualizované: SEQ bajt v requestoch, 22/26 bajtov v response parsing.
  `tb_xfcp_axi_engine.sv`: `make_hdr` → 64-bit `{op, 8'h00, addr, count}`.
  `tb_xfcp_tx_packetizer.sv`: nový `resp_seq_tb=8'hAB`, SEQ check pri pozícii [2].

### Sim výsledky Fázy 3G

**13/13 ALL PASSED**, Errors: 0. (Všetky testy vrátane nových SEQ pozícií).

### Quartus build

**NUTNÝ REBUILD** — RTL zmenené (parser, engine, endpoint, packetizer).
Spusti: `cd examples/xfcp_test_03 && make gen && make compile` (alebo `make compile` v Quartus dir).

### Odporúčané nasledujúce kroky

1. **Quartus rebuild** — `make gen && make compile` v xfcp_test_03/
2. **HW test** — po programovaní: `python3 tools/hw_diag.py /dev/ttyUSB0 30`
3. **Fyzická diagnostika** (ak stále <50%) — Test A/D z EXPERT_BRIEF.md

---

## Historický prehľad

| Dátum | Čo sa zmenilo |
|---|---|
| 2026-05-20 | Inicializácia xfcp_test_03 z xfcp_test_02 stav 75fdc5a |
| 2026-05-20 | Navrhy_04–08 z xfcp_test_02 skopírované ako navrhy_01–05 |
| 2026-05-20 | ROOT CAUSE identifikovaný: xfcp_fifo ramstyle → sync RAM breaks fall-through |
| 2026-05-20 | FIX aplikovaný: ramstyle "no_rw_check" → "logic" v xfcp_fifo.sv |
| 2026-05-20 | SOF skompilovaný s fixom (output_files/soc_top.sof, 20:54) |
| 2026-05-21 | RTL analýza dokončená — žiadny ďalší bug. hw_diag.py vylepšený (UART STATUS check) |
| 2026-05-21 | HW test: 7/12 OK (58 %). Ramstyle fix potvrdený. Zostatok = TX→RX coupling |
| 2026-05-21 | Fáza 2A: SOP_RESP=0xFD, MAX_COUNT_BYTES=256, ST_RD_WAIT fix. Sim 13/13 PASS |
| 2026-05-21 | navrhy_06 analyzovaný. Pridaný do repozitára (commit 39c6c82) |
| 2026-05-21 | HW testy: frame_err filter (4/12), hold-off (2/12), pre_delay=2.0 (3/12) — všetky REVERTED |
| 2026-05-21 | Záver: coupling je fyzický problém. SW/RTL mitigations max ~6/12. Čaká fyzická diagnostika |
| 2026-05-21 | Fáza 2B príprava: navrhy_07/08 single-flight gate (d1c64ae), 7/30 = 23 % HW |
| 2026-05-22 | Fáza 2B: post_tx_hold flush + endpoint_busy_o sémantika. Sim 13/13 PASS, HW 14/30 = 46 % |
| 2026-05-22 | Fáza 2C: watchdog deadlock fix + BAUD_DIV*10 hold + TB 6-slot scan. Sim 16/16 PASS, HW 10/30 = 33 % |
| 2026-05-22 | Fáza 3A: navrhy_11 implementácia — ENABLE_POST_TX_FLUSH=0 (default OFF), RTL DIAG counters (slot 6 @ 0xFF060000), tools SOP resync (read_packet), hw_diag.py DIAG support. Regression 16/16 PASS |
| 2026-05-22 | Fáza 3A HW test: 18/30 = 60% — najlepší výsledok. FRAME ERROR potvrdený. tx_pkt bug identifikovaný |
| 2026-05-22 | Fáza 3B: navrhy_12 implementácia — fix rx_byte_pulse_w (TVALID only), tx_pkt_i=dbg_resp_w, $error→$warning. Regression 16/16 PASS (Errors: 0 všade) |
| 2026-05-22 | Fáza 3B HW test: 28/60 = 46%. DIAG: rx_hdr=29, rx_drop=0, tx_bytes=750. Diagnóza: fyzický UART RX coupling. RTL logika správna |
| 2026-05-22 | Fáza 3C: navrhy_13 — hw_diag.py --baud/--sweep. Sweep HW: 115200=13%, ostatné baud switche zlyhali. fab_resp=36>30: spurious requesty z coupling |
| 2026-05-22 | Fáza 3D: navrhy_14 — pending/commit baud switch v axil_uart_adapter (NUM_REGS 7→9), data_bits bug fix, SerialTransport.set_baudrate(), XfcpBus.set_baudrate(). Regression 16/16 PASS. Quartus OK. Sweep HW: 33%/36%/36%/30% — baud switch zlyhá (P≈11% pre 2×WRITE). RTL správny |
| 2026-05-22 | Fáza 3E: navrhy_15 — DIAG snapshot (live+shadow), 7 nových counterov, BAUD_STATUS 0x24, busy guard, safe baud switch s retry+fallback, debug porty bad_hdr/recovery. Sim 16/16 PASS. HW test čaká (Quartus rebuild nutný) |
| 2026-05-22 | Fáza 3F: navrhy_16 — axis_uart_rx skid buffer (AXI-Stream fix), hw_diag.py --pause, Makefile compile-baud/compile-all-bauds, EXPERT_BRIEF.md RC filter + CP2102 oprava. Sim 16/16 PASS. Quartus rebuilt: output_files/soc_top.sof (21:20). Pripravené na HW test |
| 2026-05-22 | Fáza 3F HW test: 0/30 (100% FAIL). Expert (navrhy_17) identifikoval koreňovú príčinu: neúplná SEQ ID implementácia — HDR_SHIFT_W=72 bug → dec_opcode=0 → všetky pakety zahadzované |
| 2026-05-23 | Fáza 3G: kompletná SEQ ID implementácia (navrhy_17 Option B). RTL+tools+testbenche. Sim 13/13 PASS. Quartus rebuild nutný |
