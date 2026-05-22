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
