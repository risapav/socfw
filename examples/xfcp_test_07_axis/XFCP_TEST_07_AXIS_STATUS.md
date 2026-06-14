# XFCP_TEST_07_AXIS — Status

**Projekt:** XFCP s STREAM_WRITE (0x20) / STREAM_READ (0x21) opkodmi — AXI-Stream loopback
**Takt:** 125 MHz (PLL: 50 MHz sys_clk → 125 MHz clk125)
**Board:** QMTech EP4CE55
**IP:** 192.168.0.5 | MAC: 00:0A:35:01:FE:C5
**Stav:** UZAVRETY — HW UART 38/38 PASS, UDP 38/38 PASS (2026-06-14)

---

## Architektura

```
sys_clk (50MHz) -> clkpll -> clk125 (125 MHz) = hlavny systemovy takt
eth_rx_clk (125 MHz z PHY, async)

[ETH RX - eth_rx_clk]
  gmii_rx -> altddio_in -> eth_rx_mac
  -> async_fifo (payload 2048x10, meta 8x113)

[SYSTEM - clk125]
  TX dispatcher -> eth_type_demux
    ARP:  arp_rx -> arp_tx -> eth_tx_arb port 0
    IPv4: ipv4_rx -> icmp_echo -> ipv4_tx -> arb port 1
                  -> udp_xfcp (MAX_PKT_BYTES=512) -> arb port 2

  UART: uart_fifo_os (16x OS, FIFO=64) -> xfcp_arbiter_2to1.s0
  ETH-UDP XFCP: udp_xfcp_server -> xfcp_arbiter_2to1.s1

  xfcp_arbiter_2to1 (2->1, fixed priority UART>ETH):
    - Port 0 (UART): parsuje XFCP hlavicku, generuje synteticke TLAST
    - Port 1 (ETH): pouziva prirodzeny TLAST z UDP framu
    - p0_is_write_w: rozoznava STREAM_WRITE pre spravnu dlzku syntetickeho TLAST

  xfcp_fabric_endpoint (A-light routing):
    Slot 0 @ 0xFF000000: axil_sys_ctrl
    Slot 1 @ 0xFF010000: axil_uart_adapter
    Slot 2 @ 0xFF020000: axil_regs (LED onboard 6-bit)
    Slot 3 @ 0xFF030000: axil_regs (PMOD J10 8-bit)
    Slot 4 @ 0xFF040000: axil_regs (PMOD J11 8-bit)
    Slot 5 @ 0xFF050000: axil_seven_seg_adapter
    Slot 6 @ 0xFF060000: axil_diag_ctrl

  xfcp_axis_adapter (stream_id=0 loopback slot):
    STREAM_WRITE -> m_axis -> u_axis_loopback (xfcp_fifo_reg 9-bit M9K, DEPTH=256)
    u_axis_loopback -> s_axis -> STREAM_READ
    i_rfifo: xfcp_fifo_reg (DATA_WIDTH=32, DEPTH=64) -- M9K registered output
```

---

## XFCP Protokol — rozsirenie

```
AXIL REQUEST:
  FE op seq COUNT_H COUNT_L ADDR[3:0] DATA[COUNT]  (op=0x10/0x11)

STREAM_WRITE REQUEST (op=0x20):
  FE 20 seq COUNT_H COUNT_L stream_id[3:0] DATA[COUNT]
  Response (5B): FD 22 seq status 00

STREAM_READ REQUEST (op=0x21):
  FE 21 seq COUNT_H COUNT_L stream_id[3:0]
  Response: FD 23 seq status DATA[COUNT] 00

COUNT = pocet datovych bajtov (musi byt nasobok 4, max 256)
```

---

## Nové moduly oproti xfcp_test_05

| Modul | Popis |
|-------|-------|
| `xfcp_axis_adapter.sv` | STREAM_WRITE/READ adapter s watchdog (1024 cyklov), RFIFO (DEPTH=64) |
| `xfcp_fifo_reg.sv` | M9K registered output FIFO (2-cycle latencia, timing-critical cesty) |
| `xfcp_pkg.sv` | +STREAM opkody + `xfcp_resp_has_payload()` funkcia |
| `xfcp_fabric_endpoint.sv` | A-light routing: AXIL (0x10/0x11) aj AXIS (0x20/0x21), axis_busy_q |
| `xfcp_arbiter_2to1.sv` | p0_is_write_w — rozoznava STREAM_WRITE pre dlzku syntetickeho TLAST |
| `xfcp_tx_packetizer.sv` | xfcp_resp_has_payload() + early-exit ST_PAYLOAD |
| `axis_byte_register_slice.sv` | 1-beat AXI-Stream register slice (nahradeny xfcp_fifo_reg v Faze D) |
| `tools/xfcp/protocol.py` | stream_write() + stream_read() (count % 4 == 0, max 256B) |
| `tools/xfcp/bus.py` | stream_write() + stream_read() cez XfcpBus |

---

## Fazy

### Faza A — AXIS adapter + sim T01-T19 [UZAVRETA]

- [x] xfcp_pkg.sv: STREAM_WRITE (0x20) / STREAM_READ (0x21) opkody
- [x] xfcp_rx_parser.sv: MAX_COUNT_BYTES=256, STREAM opkody povolene
- [x] xfcp_axis_adapter.sv: novy modul (watchdog, RFIFO, STREAM write/read FSM)
- [x] xfcp_fabric_endpoint.sv: A-light routing + axis_busy_q clear-wins fix
- [x] xfcp_arbiter_2to1.sv: p0_is_write_w pre spravny TLAST
- [x] xfcp_tx_packetizer.sv: xfcp_resp_has_payload()
- [x] xfcp_test_07_axis_top.sv: u_axis_loopback + u_axis_adapter
- [x] tools/xfcp/: stream_write() + stream_read()
- [x] sim T01-T19 ALL PASS (commit 94cc28f)
- [x] Makefile + hw_regression.sh --stream --rw

**Stav:** UZAVRETA (2026-06-13)

---

### Faza B — HW test — Bug 1/2/3 [UZAVRETA]

HW test (2026-06-13) odhalil 3 chyby:

**Bug 1: Stary bitstream (stale build)**
- FPGA bezal xfcp_test_06 bitstream (bez STREAM podpory)
- Fix: `socfw build project.yaml` + Quartus recompile

**Bug 2: xfcp_rx_parser.sv — MAX_COUNT_BYTES=128 odmietal COUNT=256**
- `dec_count[15:8]=0x01 != 0x00` → dec_valid_r=0 → go_drop → rx_bad_hdr++, rx_recovery++
- Fix: widened `dec_count_ok` a `early_count_ok` na: `(dec_count[1:0]==2'b00) && ((dec_count[15:8]==8'h00)||(dec_count==16'd256))`

**Bug 3: sop_recovery v S_PAYLOAD state — FPGA deadlock pri 256B STREAM_WRITE**
- Bajt `bytes(range(256))[254] = 0xFE` (= XFCP_SOP_REQ) spustil resync v S_PAYLOAD
- Po 3 pokusoch: hfifo plny, FPGA deadlock
- Fix: `state_q != S_PAYLOAD` pridany do sop_recovery podmienky
- T20 pridany do sim (256B UART loopback) — odhal Bug 3 v simulacii

**axis_busy_q critical fix (v Faza A):**
- `if (req_fire && is_stream_op) axis_busy_q <= 1'b1; if (axis_resp_done_i) axis_busy_q <= 1'b0;`
- Clear musi vyhrat nad set (posledny NB zapis vyhrava)

Sim T01-T20 ALL PASS. Commit: ebce26a

**Stav:** UZAVRETA (2026-06-13)

---

### HW vysledok po Faze B (reprogram 2026-06-13)

```
UART transport:
  AXIL PASS
  STREAM 4/16/64/256 B PASS  (38/38)
  DIAG: rx_bad_hdr=0, rx_recovery=0, rx_drop=0

UDP transport:
  AXIL PASS
  STREAM 4/16/64 B PASS
  STREAM 256 B FAIL  (35/38)
```

---

### Faza C — Bug 4 + T21/T22 [UZAVRETA]

**Bug 4: udp_xfcp_server.MAX_PKT_BYTES=128 — silent drop 256B UDP STREAM_WRITE**
- 265-bajtovy XFCP payload (FE+20+seq+COUNT+sid+256 data) presiahol 128B rx_buf
- udp_xfcp_server presiel do RX_DRAIN, nikdy nenastavil rx_complete_q
- DIAG: rx_bad_hdr=0, rx_recovery=0 — paket zahodeny PRED parsermi
- Rovnaky problem: 261B STREAM_READ response presiahol 128B resp_buf
- Fix: `MAX_PKT_BYTES (512)` v xfcp_test_07_axis_top.sv (pokryva oba smery + rezerva)

**T21/T22 — ETH-UDP 256B STREAM testy:**
- T21: STREAM_WRITE 256B cez Ethernet, overenie ack (FD 22 A2 00)
- T22: STREAM_READ 256B cez Ethernet, overenie vsetkych 256 bajtov payloadu
- `repeat(500) @(posedge clk_i)` medzi T21 a T22 — server_busy_w musi klesnuť

Sim T01-T22 ALL PASS. Commit: 8d6ac87

**Stav:** UZAVRETA (2026-06-13)

---

### Faza D — Bug 5/6 + xfcp_fifo_reg + timing closure [UZAVRETA]

**Bug 5: axis_done_cnt_q spurious increment (T19 sim failure)**
- Fast error STREAM request (IDLE→RESP→IDLE v 2 cykloch) spôsobuje:
  - axis_busy_q=0 (resp_done vyhrava), ale req_valid_r=1 este 1 cyklus
  - → axis_req_valid_o=1 (spurious 2. dispatch) → adapter fireuje axis_resp_done_o 2x
  - → axis_done_cnt_q += 2 misto 1 → stale +1 prezieva cez dalsie testy (T16→T17→T18→T19)
  - → ARB dispatch pre STREAM_READ pred datami (0→2 direct, preskoc WAIT_ENG)
  - → packetizer early exit → TLAST bez payloadu → uart_recv timeout
- Fix: `axis_req_valid_o = ... && !ofifo_wvalid_r`
  - ofifo_wvalid_r=1 presne v spurious cykle (1-cy delay req_fire)
  - Guard uz bol pritomny v req_ready pre STREAM, chybal v dispatch

**Bug 6: xfcp_fifo_reg Quartus Error 10200**
- `if (!rst_n || flush)` v `always_ff @(posedge clk or negedge rst_n)` — Quartus odmieta
- flush nie je hrana v sensitivity liste → latch inference
- Fix: oddelit do synchronnej vetvy: `if (!rst_n) ... else if (flush) ...`

**Timing: xfcp_fifo_reg nahradzuje xfcp_fifo + axis_byte_register_slice**
- Kriticka cesta (pred fix): xfcp_fifo.rd_ptr_q → velky LUT mux → axis_rdata_o (az -4 ns)
- xfcp_fifo_reg: M9K output register enable — eliminuje kombinacnu cestu (2-cycle latencia)
- Nahradeny v: u_axis_loopback (DATA_WIDTH=9, DEPTH=256) + xfcp_axis_adapter.i_rfifo (DW=32, DEPTH=64)
- SEED 3 → WNS -0.054 ns (Slow 85C) → SEED 5 → WNS +0.240 ns

Sim T01-T22 ALL PASS. Commits: 500e863 (intermediate RS), 42deb38 (xfcp_fifo_reg + SEED 5)

**Stav:** UZAVRETA (2026-06-14)

---

### Faza E — HW retest [UZAVRETA]

Reprogram s commit 42deb38 (SEED 5, WNS +0.240 ns):

```
UART transport: 38/38 PASS
UDP  transport: 38/38 PASS
RESULT: 2/2 PASS — USPECH
```

STREAM loopback (UART aj UDP):
- 4B PASS, 16B PASS, 64B PASS, 256B PASS

DIAG snapshot (UART + UDP):
```
rx_bad_hdr   0
rx_recovery  0
rx_drop      0
rx_lost      0
rx_frame     0
rx_overrun   0
```

Timing:
```
Slow 85C CLK125 WNS:  +0.240 ns
Slow 85C ETH_RXC WNS: +0.347 ns
Slow 85C CLK125 hold: +0.428 ns
TNS:                   0.000
SEED:                  5
```

**Stav:** UZAVRETA (2026-06-14)

---

## Simulacia — prehlad testov

| Test | Popis | Stav |
|------|-------|------|
| T01-T05 | AXIL READ/WRITE (UART) | PASS |
| T06-T10 | AXIL READ/WRITE (ETH-UDP) | PASS |
| T11-T14 | STREAM_WRITE/READ 4B/16B (UART) | PASS |
| T15-T16 | STREAM_WRITE/READ 64B (UART) | PASS |
| T17-T18 | STREAM chybove scenare (bad opcode, timeout) | PASS |
| T19     | STREAM mixed AXIL+STREAM (UART) | PASS |
| T20     | STREAM_WRITE/READ 256B (UART) — pokryva Bug 2 + Bug 3 | PASS |
| T21     | ETH-UDP STREAM_WRITE 256B — pokryva Bug 4 | PASS |
| T22     | ETH-UDP STREAM_READ 256B — pokryva Bug 4 TX path | PASS |

**Celkovo: T01-T22 ALL PASSED (108 checks, 0 failures) — 2026-06-14**

---

## Bugy (historia)

| Bug | Komponent | Popis | Fix |
|-----|-----------|-------|-----|
| 1 | build | Stary bitstream (xfcp_test_06) | socfw build project.yaml |
| 2 | xfcp_rx_parser.sv | MAX_COUNT_BYTES=128 odmietal COUNT=256 | dec_count_ok + early_count_ok rozsirene |
| 3 | xfcp_rx_parser.sv | sop_recovery v S_PAYLOAD — deadlock pri 256B | state_q != S_PAYLOAD guard |
| 4 | udp_xfcp_server.sv (instancia) | MAX_PKT_BYTES=128 silent drop 265B UDP paket | MAX_PKT_BYTES=512 |
| 5 | xfcp_fabric_endpoint.sv | axis_done_cnt_q spurious +1 z fast error → T19 uart_recv timeout | axis_req_valid_o += !ofifo_wvalid_r |
| 6 | xfcp_fifo_reg.sv | Quartus Error 10200 — flush v async rst_n condition | oddelit flush do sync else-if vetvy |

---

## Resource usage (commit 42deb38)

```
Logic elements: 26,191 / 55,856  (47 %)
Registers:      20,584
Memory bits:    44,544 / 2,396,160  (2 %)
Pins:           66 / 325
PLLs:           1 / 4
```

---

## Known limits (xfcp_test_07_axis)

```
COUNT musi byt nasobok 4 (byte-granular dlzky nie su podporovane)
MAX COUNT = 256 B
stream_id = 0 (jediny loopback slot)
single outstanding stream transaction
target discovery (GET_CAPS) nie je implementovana
```

---

## Commits

| Commit | Popis |
|--------|-------|
| 94cc28f | Faza A + B — AXIS adapter, sim 19/19 PASS |
| a4dacb7 | Makefile + hw_regression.sh --stream --rw |
| ebce26a | Faza C — 3 HW bugs fixed, sim T01-T20 PASS |
| 8d6ac87 | Faza C — Bug4 fix + T21/T22, sim T01-T22 PASS |
| 157176f | XFCP_TEST_07_AXIS_STATUS.md — status po Fazach A-D |
| 500e863 | Faza D — timing: rfifo RS + SEED 3 (intermediate) |
| 42deb38 | Faza D — Bug 5/6 fix + xfcp_fifo_reg + SEED 5, WNS +0.240 ns |

---

## Odporucany tag

```
xfcp_lib_v1_1_axis_pass
```

Verzie:
```
xfcp_lib_v0_9_status_pass  = UART + UDP + AXI-Lite + STATUS (xfcp_test_06)
xfcp_lib_v1_1_axis_pass    = + AXI-Stream backend: STREAM_WRITE/READ,
                               UART + UDP, 256B loopback, timing clean, HW PASS
```
