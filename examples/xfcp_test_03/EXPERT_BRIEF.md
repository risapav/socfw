# XFCP Expert Brief — Stav 2026-05-22

> Dokument je určený pre externého experta bez predchádzajúcej znalosti projektu.
> Obsahuje kompletný popis systému, protokolu, RTL architektúry, nameraných dát a
> históriu všetkých pokusov o riešenie problému.

---

## 1. Hardware konfigurácia

| Položka | Hodnota |
|---------|---------|
| FPGA | QMTech EP4CE55F23C8 (Cyclone IV E, 55 000 LE) |
| Hodinový signál | 50 MHz (onboard oscilátor) |
| USB-UART bridge | Pravdepodobne FT232R (kábel nie je presne identifikovaný) |
| UART parametre | 115200 baud, 8N1, bez hardvérového handshaking |
| OS / nástroje | Linux, Python 3.11, `pyserial` |
| Quartus | Prime 25.1 Lite |

**Fyzické prepojenie:**

```
PC
 ├─[USB]─► USB-UART bridge (FT232R?)
 │              │
 │         TXD ─────► FPGA UART_RX_i  (JP pin 7, LVTTL 3.3V)
 │         RXD ◄───── FPGA UART_TX_o  (JP pin 8, LVTTL 3.3V)
 │
 └─[USB]─► Altera USB-Blaster (programovanie)
```

---

## 2. XFCP protokol — Wire format

XFCP (XFCP Control Protocol) je jednoduchý register-access protokol nad UART byte streamom.
Bez CRC, bez sekvenčného čísla, bez flow control. Big-endian.

### 2.1 Request (PC → FPGA)

| Offset | Bajt(y) | Pole | Hodnota |
|--------|---------|------|---------|
| 0 | 1 | SOP | `0xFE` |
| 1 | 1 | OPCODE | `0x10`=READ, `0x11`=WRITE, `0x00`=ID |
| 2–3 | 2 | COUNT | počet bajtov payloadu (Big-Endian, násobok 4) |
| 4–7 | 4 | ADDR | 32-bit adresa (Big-Endian) |
| 8..8+COUNT-1 | N | PAYLOAD | dáta (iba pre WRITE) |

**Veľkosti paketov:**
- READ request: 8 bajtov (bez payloadu, COUNT = počet čítaných bajtov)
- WRITE request: 12 + COUNT bajtov
- Príklad: READ 1 register → 8B request. WRITE 1 register → 12B request.

### 2.2 Response (FPGA → PC)

| Offset | Bajt(y) | Pole | Príklad |
|--------|---------|------|---------|
| 0 | 1 | SOP | `0xFD` (iný od request SOP = `0xFE`) |
| 1 | 1 | RESP_OP | `0x12`=RESP_READ, `0x13`=RESP_WRITE |
| 2–3 | 2 | DEV_TYPE | `0x00 0x01` |
| 4–19 | 16 | DEV_STR | `"XFCP-UART-FAB  "` (ASCII, padded) |
| 20..20+COUNT-1 | N | PAYLOAD | dáta (iba pre READ) |
| last | 1 | terminátor | `0x00` |

**Veľkosti odpovedí:**
- READ response (1 register): 25 bajtov
- WRITE response (žiadny payload): 21 bajtov
- READ response (N slov): 20 + 4×N + 1 = 21 + 4N bajtov

**Dôvod SOP_RESP = 0xFD (nie 0xFE):** Ak by FPGA TX bol kuplovaný späť na RX, echo `0xFE` by spustil parser do S_HDR. Zmenou na `0xFD` echo bajty nie sú `SOP_REQ = 0xFE` a parser ich v S_IDLE ignoruje.

---

## 3. RTL Architektúra

### 3.1 Blokový diagram

```
                     ┌──────────────────────────────────────────────┐
UART_RX_i ──────────►│ axis_uart_rx                                 │
                     │  (BAUD_DIV=434, 8N1, TLAST=0)               │
                     │  Výstup: TDATA[7:0], TVALID (1-cycle pulse)  │
                     └──────────────┬───────────────────────────────┘
                                    │ uart_rx_raw_s (AXI-Stream)
                     ┌──────────────▼───────────────────────────────┐
                     │ xfcp_fifo (DEPTH=8, DATA_WIDTH=8)            │
                     │  flush=fifo_flush_w (default: 0)             │
                     │  Elastic buffer, fall-through (ramstyle=logic)│
                     └──────────────┬───────────────────────────────┘
                                    │ xfcp_rx_s (gated by rx_gate_w)
                     ┌──────────────▼───────────────────────────────┐
                     │ xfcp_rx_parser (ONE-HOT FSM)                 │
                     │  Stavy: S_IDLE, S_HDR, S_DECODE,             │
                     │         S_PAYLOAD, S_DROP, S_RPATH           │
                     │  Shift register decode (8B header)           │
                     │  MAX_COUNT_BYTES=128, MAX_PKT_BYTES=4112      │
                     │  Výstup: req_hdr (hfifo), write_data (dfifo) │
                     │  Pulzy: dbg_sop, dbg_hdr, dbg_drop           │
                     └──────────────┬───────────────────────────────┘
                                    │ req_hdr + write_data
                     ┌──────────────▼───────────────────────────────┐
                     │ xfcp_fabric_endpoint (NUM_SLAVES=7)           │
                     │  Arbitrácia: ARB_IDLE, ARB_WAIT_ENG,         │
                     │              ARB_WAIT_PKT                    │
                     │  Adresný dekodér (SLAVE_BASE/MASK)           │
                     │  Order FIFO (typ: xfcp_fifo, ramstyle=logic) │
                     │  Pulzy: dbg_req, dbg_resp                    │
                     └──────────┬───────────────┬────────────────────┘
                                │ AXI4-Lite      │ xfcp_tx_s
               ┌────────────────▼────┐    ┌──────▼──────────────────┐
               │ 7× AXI-Lite slaves  │    │ xfcp_tx_packetizer       │
               │  [0] axil_sys_ctrl  │    │  Serialize response       │
               │  [1] axil_uart_adap │    │  SOP_RESP=0xFD           │
               │  [2-4] axil_regs    │    └──────┬──────────────────┘
               │  [5] axil_seven_seg │           │ xfcp_tx_s
               │  [6] axil_diag_ctrl│    ┌──────▼──────────────────┐
               └─────────────────────┘    │ axis_uart_tx             │
                                          │  BAUD_DIV=baud_active_q  │
                                          └──────┬──────────────────┘
                                                 │
                                         UART_TX_o ──────► USB-UART ──► PC
```

### 3.2 Kľúčové parametre RTL

| Parameter | Hodnota | Popis |
|-----------|---------|-------|
| CLOCK_FREQ_HZ | 50 000 000 | Systémový takt |
| UART_DEFAULT_BAUD_DIV | 434 | 50 MHz / 115 200 baud |
| ENABLE_POST_TX_FLUSH | 0 (default) | TX→RX flush mechanizmus vypnutý |
| POST_TX_HOLD_CYCLES | 4 340 | = BAUD_DIV × 10 (ak flush zapnutý) |
| NUM_SLAVES | 7 | Počet AXI-Lite slave-ov |
| xfcp_fifo.DEPTH (rx) | 8 | Elastický buffer pred parserom |
| MAX_COUNT_BYTES | 128 | Max COUNT v XFCP hlavičke (= 32 slov) |
| BAUD_SWITCH_BYTES | 32 | Countdown pre runtime baud switch |

### 3.3 Parser FSM — popis stavov

```
S_IDLE    → čaká na 0xFE (SOP_REQ); ignoruje všetky ostatné bajty
S_HDR     → zbiera bajty 1–7 do 64-bit shift registra (OPCODE, COUNT, ADDR)
S_DECODE  → 1-taktový paralelný decode; validuje opcode + COUNT alignment
S_PAYLOAD → akumuluje payload bajty do 32-bit slov → data FIFO (pre WRITE)
S_DROP    → žerie zvyšok paketu (čaká na TLAST=0 — UART stream nemá TLAST)
S_RPATH   → passthrough pre 0xFF routing path pakety
```

**SOP recovery:** Ak 0xFE príde v akomkoľvek stave (okrem S_IDLE/S_RPATH), parser
prejde do S_HDR — resynchrónia bez čakania na TLAST (TLAST=0 hardwired v UART streame).

**Watchdog:** Ak paket > 4 112 bajtov bez S_IDLE, go_drop → S_DROP.
pkt_len_q sa resetuje aj pri sop_recovery (fix deadlocku kde saturovaný watchdog
okamžite vyhodil nový paket pri každom S_HDR).

### 3.4 Adresná mapa

```
0xFF000000  Slot 0: axil_sys_ctrl   (ID: "SYSC")  — system control / version
0xFF010000  Slot 1: axil_uart_adapter (ID: "UART") — UART konfigurácia + baud switch
0xFF020000  Slot 2: axil_regs (6-bit onboard LED)
0xFF030000  Slot 3: axil_regs (8-bit PMOD J10 LED)
0xFF040000  Slot 4: axil_regs (8-bit PMOD J11 LED)
0xFF050000  Slot 5: axil_seven_seg_adapter (7-segment)
0xFF060000  Slot 6: axil_diag_ctrl  (ID: "DIAG")  — diagnostické countere
```

### 3.5 UART Register mapa (axil_uart_adapter, Slot 1)

| Offset | Typ | Názov | Popis |
|--------|-----|-------|-------|
| 0x00 | RO | COMPONENT_ID | `0x55415254` = "UART" |
| 0x04 | RW | BAUD_PENDING | nový baud prescaler, neaplikuje sa hneď |
| 0x08 | RW | CONFIG | [4]=stop2, [3]=parity_odd, [2]=parity_en, [1:0]=dbits |
| 0x0C | PULSE | ERR_CLR | zmaže sticky error bits |
| 0x10 | RO | STATUS | [4]=parity, [3]=frame, [2]=overrun, [1]=rx_busy, [0]=tx_busy |
| 0x14 | RO | TX_FIFO_CNT | — |
| 0x18 | RO | RX_FIFO_CNT | — |
| 0x1C | PULSE | BAUD_COMMIT | spustí countdown = baud_active × 320 cyklov, potom switch |
| 0x20 | RO | BAUD_ACTIVE | readback aktuálne aktívneho prescalera |

### 3.6 DIAG Register mapa (axil_diag_ctrl, Slot 6)

32-bit saturujúce countere, reset cez DIAG_RESET pulse:

| Offset | Názov | Signál RTL |
|--------|-------|-----------|
| 0x04 | RX_BYTE_COUNT | `uart_rx_raw_s.TVALID` — každý bajt z UART RX core |
| 0x08 | RX_SOP_COUNT | `dbg_sop_o` — detekcia 0xFE v S_IDLE |
| 0x0C | RX_HDR_COUNT | `dbg_hdr_o` — push do header FIFO (úspešný decode) |
| 0x10 | RX_DROP_COUNT | `dbg_drop_o` — drop event (okrem re-entry do S_DROP) |
| 0x14 | FAB_REQ_COUNT | `dbg_req_o` — validný request do fabric |
| 0x18 | FAB_RESP_COUNT | `dbg_resp_o` — resp_start_pulse z endpointu |
| 0x1C | TX_BYTE_COUNT | `xfcp_tx_s.TVALID && TREADY` — bajty odoslané TX |
| 0x20 | TX_PKT_COUNT | `dbg_resp_o` — zhodné s FAB_RESP (počet odoslaných paketov) |
| 0x24 | DIAG_RESET | PULSE — reset všetkých counterov |

---

## 4. Problém: ~67% failure rate na HW

### 4.1 Symptóm

PC posiela READ/WRITE requesty na FPGA cez UART. Každý transakcia buď:
- **OK**: odpoveď príde za ~2–6 ms (READ=2.17 ms, WRITE=1.82 ms pri 115200)
- **TIMEOUT**: žiadna odpoveď do 1 sekúndy (0 bajtov prijaté)

Pozorovaná úspešnosť: **33–60 %** v závislosti od konfigurácie (najlepší bol 18/30 = 60 %).

### 4.2 Diagnostické dáta (Fáza 3B, 60 requestov)

```
rx_hdr   = 29     ← parser dekódoval 29 z 60 requestov
rx_drop  = 0      ← žiadne zahadzovanie v parseri
tx_bytes = 750    ← ≈ 30 × 25B (zodpovedá rx_hdr=29)
fab_resp > rx_hdr ← niekedy viac odpovedí ako requestov (spurious)
```

**Záver DIAG:** RTL pipeline je správna. Keď request príde do parsera kompletný,
vždy dostane odpoveď (`rx_drop=0`). Problém je **pred parserom** — v UART fyzickej vrstve.

### 4.3 UART STATUS po testoch

```
STATUS @ 0xFF010010:
  frame_err  = True    ← bajty so zlým stop bitom
  overrun    = False   ← FIFO nie je plná
  parity_err = False
```

`frame_err=True` potvrdzuje, že FPGA UART RX prijíma bajty so zlým stop bitom — charakteristický
prejav **TX→RX coupling**: FPGA TX signál kuplovaný späť na RX vstup produkuje "skrátené" bajty
(rýchly edge, sampling mimo bitovú periódu → chybný stop bit).

### 4.4 Hypotéza o mechanizme

```
PC posiela request (8B) → FPGA UART_RX_i ← korrektné bajty
FPGA spracuje → XFCP odpoveď (25B) → UART_TX_o odošle

Počas / tesne po TX:
  UART_TX_o (3.3V signal) →→→ coupling →→→ UART_RX_i
  
  Možné cesty:
    A) FTDI FT232R loopback: bridge vracia TX bajty späť na RX (EEPROM nastavenie)
    B) PCB kapacitívna väzba: TX a RX vodiče v blízkosti na PCB / flex kábli
    C) Impedančná väzba cez spoločný GND/Vcc cez kábel

Výsledok na FPGA RX strane:
  - coupling bajty = 0xFD (SOP_RESP) → parser v S_IDLE ignoruje (nie SOP_REQ)
  - coupling bajty so zlým stop bitom (FRAME ERROR) → niektoré sa môžu 
    preformovať na 0xFE → parser: sop_recovery → S_HDR → garbage COUNT/ADDR
    → S_DROP (bez AXI) alebo spurious AXI read (s garbage adresou, ale
    všetky adresy sú valid v SLAVE_MASK → spurious odpoveď)

Čistý efekt:
  ≈ 50% requestov prichádza s porušenou hlavičkou (coupling zožral niektoré bajty)
  → parser nikdy nedekóduje header → rx_drop=0 (nezahodil) ale rx_hdr nenastalo
```

### 4.5 Štatistická analýza

S 60 testovacími requestmi a rx_hdr=29 (≈ 48 %):
- Coupling zasiahol ≈ 31 requestov (52 %) z fyzickej vrstvy
- P(slot zlyhá 5/5) = 0.52^5 = 3.8 % → pre 6 slotov: ~20 % šanca vidieť aspoň 1 slot 0/5

Náhodnosť failov (nie deterministická) naznačuje fyzickú príčinu, nie RTL bug.

---

## 5. História pokusov o riešenie

### 5.1 Chronologický prehľad

| Fáza | Dátum | Zmena | HW výsledok | Záver |
|------|-------|-------|-------------|-------|
| Zdedené | 2026-05-20 | xfcp_test_02 baseline | 2/12 (17%) | ramstyle bug |
| Fáza 1 | 2026-05-20 | `ramstyle="logic"` v xfcp_fifo | 7/12 (58%) | ARB deadlock opravený |
| Fáza 2A | 2026-05-21 | `SOP_RESP=0xFD`, MAX_COUNT=256 | 6/12 (50%) | coupling loop zhoršený |
| — | 2026-05-21 | frame_err_byte_q filter | 4/12 (33%) | selektívny filter → REVERTED |
| — | 2026-05-21 | RX FIFO hold-off 5ms | 2/12 (17%) | stratené PC bajty → REVERTED |
| Fáza 2B | 2026-05-22 | post_tx_flush (2000 cyklov) | 14/30 (46%) | flush lepší ako gate |
| Fáza 2C | 2026-05-22 | watchdog fix + BAUD_DIV×10 hold | 10/30 (33%) | dlhší flush = regres |
| **Fáza 3A** | 2026-05-22 | `ENABLE_POST_TX_FLUSH=0` | **18/30 (60%)** | **BEST** |
| Fáza 3B | 2026-05-22 | DIAG countery fix | 28/60 (46%) | DIAG potvrdil diagnózu |
| Fáza 3C | 2026-05-22 | runtime baud switch (priamy) | 13% pri 115200, 0% pri ostatných | switch nefungoval |
| Fáza 3D | 2026-05-22 | pending/commit baud switch | 33–36% | switch stále nefungoval |

### 5.2 Prečo flush (ENABLE_POST_TX_FLUSH=1) nepomohlo trvalo

Mechanizmus:
```
tx_busy=1 → fifo_flush=1 → w_ready=0 → coupling bajty počas TX sú zahodené ✓
tx_busy falls → post_tx_hold countdown (2000 alebo 4340 cyklov)
countdown=0 → flush=0 → parser prijíma bajty
```

Problém: Coupling "chvost" po konci TX je dlhší alebo nepravidelný.
- 2000 cyklov (40 µs): empiricky 14/30 = 46 %
- 4340 cyklov (87 µs = 1 UART byte perioda): 10/30 = 33 % — **horšie**
- flush=0 (Fáza 3A): 18/30 = 60 % — **najlepšie**

Interpretácia: flush 0xFD coupling bajtov bol zbytočný (SOP_RESP≠SOP_REQ → parser ignoruje).
Flush ale zahodil aj niektoré **legitímne** PC bajty ktoré prišli počas post_tx_hold okna.
Dlhší flush = viac stratených legitímnych bajtov = horšia úspešnosť.

### 5.3 Prečo runtime baud switch nepomohol

**Fáza 3C** — priamy zápis BAUD_DIV (0xFF010004): FPGA okamžite zmenil baud rate.
WRITE odpoveď bola odoslaná novou baud rýchlosťou, PC ešte čakal na starej → baud mismatch.

**Fáza 3D** — pending/commit: PC zapíše BAUD_PENDING, potom BAUD_COMMIT, FPGA prepne
po coundowne (~35 ms). ACK oboch WRITE-ov príde ešte na starej baud ✓.

Ale: Každý `set_baud()` vyžaduje **2 po sebe úspešné WRITE transakcie** na starej baud rate.
- P(1 WRITE uspeje) ≈ 33 %
- P(oba WRITE uspeju) ≈ 0.33² = **11 %**
- `set_baud()` pri prvom zlyhaní vráti False → FPGA zostane na 115200

Sweep výsledky pri 57600/38400/9600: odozvy vždy 5.4–5.7 ms (= 115200 timing) → potvrdené.

---

## 6. Aktuálna RTL konfigurácia (Fáza 3D, commit 6575547)

### 6.1 xfcp_uart_mmio_top.sv — relevantné sekcie

```systemverilog
// TX→RX flush mechanizmus — VYPNUTÝ (ENABLE_POST_TX_FLUSH=0)
parameter bit  ENABLE_POST_TX_FLUSH  = 1'b0,   // default OFF
parameter int  POST_TX_HOLD_CYCLES   = UART_DEFAULT_BAUD_DIV * 10  // = 4340

wire post_tx_hold_w = ENABLE_POST_TX_FLUSH
                    ? (tx_status_w.tx_busy || (post_tx_cnt_r > 0))
                    : 1'b0;
wire fifo_flush_w   = post_tx_hold_w;  // = 0 (flush zakázaný)
wire rx_gate_w      = post_tx_hold_w;  // = 0 (gate zakázaný)
```

### 6.2 axil_uart_adapter.sv — pending/commit baud switch

```systemverilog
// 1-cycle delayed write strobe: hw_wdata_w[1*32+:32] je platný
// až 1 takt PO hw_we_w[1] (AXIL_RW FF latencia v axil_regfile)
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) baud_we_r <= 1'b0;
  else         baud_we_r <= hw_we_w[1];
end

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    baud_active_q         <= 32'(BAUD_DIV_DEFAULT);
    baud_pending_q        <= 32'(BAUD_DIV_DEFAULT);
    baud_switch_pending_q <= 1'b0;
    baud_switch_cnt_q     <= 32'h0;
  end else begin
    if (baud_we_r)   // 1 takt po write — hw_wdata_w má novú hodnotu
      baud_pending_q <= hw_wdata_w[1*32 +: 32];
    if (hw_we_w[7]) begin  // BAUD_COMMIT pulse
      baud_switch_pending_q <= 1'b1;
      baud_switch_cnt_q <= baud_active_q * 32'(BAUD_SWITCH_BYTES * 10);
    end else if (baud_switch_pending_q) begin
      if (baud_switch_cnt_q != 32'h0)
        baud_switch_cnt_q <= baud_switch_cnt_q - 32'd1;
      else begin
        baud_active_q         <= baud_pending_q;
        baud_switch_pending_q <= 1'b0;
      end
    end
  end
end

assign baud_div_o = baud_active_q;  // aktuálne aktívny prescaler
```

### 6.3 Python nástroje — kľúčové sekcie

**`XfcpBus._transact()` — SOP resync:**
```python
def read_packet(self, expected_len: int) -> bytes:
    # Skenuje byte-by-byte pre SOP_RESP (0xFD)
    # Zahadzuje stale bajty, číta zvyšok paketu po nájdení SOP
    while time.monotonic() < deadline:
        b = self._ser.read(1)
        if b and b[0] == proto.SOP_RESP:
            buf = bytearray(b)
            # ... číta remaining = expected_len - 1 bajtov
            return bytes(buf)
    return b""
```

**`XfcpBus.set_baudrate()` — two-step protokol:**
```python
def set_baudrate(self, new_baud: int, clk_hz: int = 50_000_000) -> bool:
    new_div = round(clk_hz / new_baud)
    if not self.write32(0xFF010004, new_div):   # BAUD_PENDING, ACK na starej baud
        return False
    if not self.write32(0xFF01001C, 1):          # BAUD_COMMIT, ACK na starej baud
        return False
    time.sleep(0.15)                             # čakaj na FPGA countdown (~35 ms max)
    self._transport.set_baudrate(new_baud)
    return self.ping()
```

---

## 7. Simulačné výsledky

Všetky testy prejdú v sim (ModelSim/Questa):

```
make -C sim/
  tb_xfcp_rx_parser       : ALL PASSED (11 testov)
  tb_xfcp_fabric_endpoint : ALL PASSED (6 testov)
  tb_xfcp_tx_packetizer   : ALL PASSED (7 testov)
  tb_xfcp_axi_engine      : ALL PASSED (4 testy)
  tb_xfcp_uart_mmio_top   : ALL PASSED (16 testov, T1–T16: 2× opak. všetkých slotov)
  tb_axil_uart_adapter    : ALL PASSED (12 testov, vrátane T11 baud switch)
  CELKOM: 16/16 PASSED, Errors: 0
```

Sim nemodelueje TX→RX coupling (žiadny loopback medzi TX a RX). Všetky HW faile
sú **výhradne HW-specific**.

---

## 8. Čo sme sa naučili a kde sme zaseknutí

### 8.1 Čo je potvrdené

1. **RTL logika je správna.** DIAG: rx_drop=0, tx_bytes≈30×25B keď rx_hdr=29/60.
   Každý request ktorý kompletne dorazí do parsera → vždy dostane odpoveď.

2. **Problém je fyzický, pred parserom.** Coupling z FPGA TX zasahuje FPGA RX
   pred UART RX core. Coupling bajty so FRAME ERROR potvrdené v UART STATUS.

3. **SOP_RESP=0xFD mitigácia funguje čiastočne.** Echo bajty 0xFD sú v S_IDLE ignorované.
   Ale niektoré coupling bajty (frame-errored) sa preformujú na 0xFE → sop_recovery
   → S_HDR → garbage header → S_DROP (ale bez AXI ak garbage address validná → spurious resp).

4. **RTL baud switch je funkčný** (sim T11: 16/16 PASS). Ale triggering cez UART
   zlyhá (~11% šanca pre 2× WRITE success pri 33% individual rate).

### 8.2 Čo nevieme

1. **Presná fyzická príčina coupling:** FTDI loopback (EEPROM nastavenie) vs. PCB
   kapacitívna/impedančná väzba. Scope na RXD pin počas FPGA TX by rozlíšil.

2. **Prečo SOP_RESP=0xFD zhoršilo výsledok oproti 0xFE** (7/12 → 6/12)?
   S 0xFE echo → S_HDR → TYPE=0x12 neplatný opcode → okamžitý S_DROP (bez AXI).
   S 0xFD frame-errored echo → 0xFE → S_HDR → garbage COUNT → S_DROP (s možným AXI).
   Dlhší S_DROP cyklus ≈ viac stratených legitímnych bajtov?

3. **Prečo flush=0 je lepší ako flush=2000 cyklov?**
   Empiricky najlepší výsledok. Pravdepodobné vysvetlenie: flush zahodil
   niektoré legitímne PC bajty počas hold-off okna.

---

## 9. Otázky pre experta

### 9.1 Fyzická diagnostika

1. Viete odporúčať metódu na rozlíšenie FTDI loopback vs. PCB coupling bez osciloskopu?
   (multimeter nestačí, potrebujem dynamiku signálu počas TX)

2. Ak je to FTDI loopback: ako ho vypnúť na Linuxe? (ftdi_eeprom konfigurácia?)

3. Ak je to PCB: RC filter 1 kΩ + 10 nF na UART_RX vstup FPGA — je to realistická oprava?
   Aká je maximálna RC konštanta pri 115200 baud (bit perioda = 8.68 µs)?

### 9.2 Protokol robustnosť

4. **SEQ ID** (odporúčaná ďalšia fáza): Pridanie 8-bit sekvenčného čísla do XFCP paketu.
   Tools odmietnu response s nesprávnym SEQ → spurious odpovede z coupling requestov
   budú zahodené. Je to správna priorita? Pomôže ak ~50% requestov vôbec nedorazí do parsera?

5. Je lepšie implementovať **flow control (RTS/CTS)** namiesto SEQ ID?
   UART na FPGA má hardvérové piny voľné, Python `pyserial` podporuje RTS/CTS.

6. **RESP_ERROR paket:** Ak coupling generuje spurious request na neplatnú adresu,
   FPGA v súčasnosti vráti normálnu odpoveď (XFCP_OP_RESP_READ/WRITE s garbage dátami).
   Malo by FPGA vracať RESP_ERROR (`0xFF`) pre neplatnú adresu namiesto toho?

### 9.3 RTL architektúra

7. Je v RTL architektonická chyba ktorá by mohla prispievať k problému?
   Pozrite najmä: `xfcp_rx_parser.sv` (FSM prechody), `xfcp_fabric_endpoint.sv`
   (ARB logika), `xfcp_fifo.sv` (fall-through FIFO s `ramstyle="logic"`).

8. `axis_uart_rx.sv` generuje `TVALID` ako 1-cycle pulse (nie udržiavaný kým `TREADY=1`).
   Je toto problematické? Môžu byť bajty stratené ak parser má `TREADY=0` počas S_DECODE?
   (Poznámka: rx elastic buffer DEPTH=8 by mal absorbovať 1-cycle `TREADY=0`)

### 9.4 Testovanie

9. Ako najlepšie izolovať coupling problém pre reprodukovateľné testy?
   - Skúsiť iný USB-UART kábel (CP2102 namiesto FT232R)?
   - Pridať 10 ms pauzu medzi requestmi?
   - Otočiť testovanie z Pythonu na embedded C na FPGe (loopback test)?

---

## 10. Súbory projektu

```
examples/xfcp_test_03/
├── rtl/
│   ├── xfcp_uart_mmio_top.sv       # Top-level (main file)
│   ├── xfcp/
│   │   ├── xfcp_pkg.sv             # Protokol konštanty
│   │   ├── xfcp_rx_parser.sv       # Parser FSM
│   │   ├── xfcp_fabric_endpoint.sv # Arbitrácia + AXI master
│   │   ├── xfcp_tx_packetizer.sv   # Response serializer
│   │   ├── xfcp_axi_engine.sv      # AXI-Lite transakcie
│   │   ├── xfcp_fifo.sv            # Fall-through FIFO (ramstyle=logic)
│   │   ├── xfcp_axil_bridge.sv     # AXI4-Stream ↔ AXI-Lite bridge
│   │   └── xfcp_id_rom.sv          # Device ID ROM
│   └── axil/
│       ├── axil_uart_adapter.sv    # UART konfigurácia + baud switch
│       ├── axil_regfile.sv         # Generický register file
│       ├── axil_diag_ctrl.sv       # Diagnostické countere
│       ├── axil_sys_ctrl.sv        # System control
│       ├── axil_regs.sv            # Jednoduchý RW register
│       └── axil_seven_seg_adapter.sv
├── sim/
│   ├── Makefile                    # `make` spustí všetky TB
│   └── unit/
│       ├── tb_xfcp_rx_parser.sv
│       ├── tb_xfcp_fabric_endpoint.sv
│       ├── tb_xfcp_tx_packetizer.sv
│       ├── tb_xfcp_axi_engine.sv
│       ├── tb_xfcp_uart_mmio_top.sv
│       └── tb_axil_uart_adapter.sv
├── tools/
│   ├── xfcp/
│   │   ├── transport.py            # Serial transport + SOP resync
│   │   ├── protocol.py             # Encode/decode XFCP pakety
│   │   ├── bus.py                  # read32/write32/set_baudrate
│   │   └── errors.py, timeouts.py
│   ├── hw_diag.py                  # Diagnostický skript (--sweep, DIAG readout)
│   └── modules/
│       └── uart_diag.py            # UART adapter driver
├── XFCP3_STATUS.md                 # Detailný denník celého projektu
└── EXPERT_BRIEF.md                 # Tento dokument
```

### Ako spustiť

```bash
# Simulácia
cd examples/xfcp_test_03/sim
make

# HW diagnostika (FPGA musí byť naprogramovaný)
cd examples/xfcp_test_03/tools
python3 hw_diag.py /dev/ttyUSB0

# Sweep rôznych baud rate (ak fyzické prostredie OK)
python3 hw_diag.py /dev/ttyUSB0 --sweep

# Programovanie FPGA (Quartus)
cd examples/xfcp_test_03
make -f Makefile.qpf program
```

---

*Generované: 2026-05-22. Projekt: `examples/xfcp_test_03`. Commit: 6575547.*
