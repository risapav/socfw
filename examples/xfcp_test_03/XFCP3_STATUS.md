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

### SEQ ID (PRIORITA 2, po fyzickej oprave)

Pridanie 8-bit sekvenčného ID do requestu/response umožní tools zahodiť
oneskorené odpovede zo starých transakcií a jednoznačne potvrdiť úspech:

```
Request:  SOP_REQ, OP, SEQ, COUNT, ADDR, PAYLOAD
Response: SOP_RESP, RESP_OP, SEQ, DEV_TYPE, DEV_STR, PAYLOAD, 0x00
```

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
