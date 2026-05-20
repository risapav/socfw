# XFCP Test 03 — stav projektu

> Stav k: 2026-05-20 (inicializacia z xfcp_test_02 stav 75fdc5a)
> Board: QMTech EP4CE55F23C8 @ 50 MHz
> Protokol: XFCP cez UART 115200 baud (SOP=0xFE)
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

**Stav:** OPRAVENÉ — čaká na Quartus rekompiláciu a HW test.

---

## Historický prehľad

| Dátum | Čo sa zmenilo |
|---|---|
| 2026-05-20 | Inicializácia xfcp_test_03 z xfcp_test_02 stav 75fdc5a |
| 2026-05-20 | Navrhy_04–08 z xfcp_test_02 skopírované ako navrhy_01–05 |
| 2026-05-20 | ROOT CAUSE identifikovaný: xfcp_fifo ramstyle → sync RAM breaks fall-through |
| 2026-05-20 | FIX aplikovaný: ramstyle "no_rw_check" → "logic" v xfcp_fifo.sv |
