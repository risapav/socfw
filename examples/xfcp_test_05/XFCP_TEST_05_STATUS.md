# XFCP_TEST_05 — Status

**Projekt:** XFCP switch s dvoma nezavislymi vstupmi (UART + ETH-UDP)
**Takt:** 125 MHz (PLL: 50 MHz sys_clk → 125 MHz clk125)
**Board:** QMTech EP4CE55
**IP:** 192.168.0.5 | MAC: 00:0A:35:01:FE:C5

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
                  -> udp_xfcp (Faza B) -> arb port 2

  UART: axis_uart_rx -> xfcp_fifo(8) -> xfcp_arbiter_2to1.s0
  ETH-UDP XFCP: (Faza B) -> xfcp_arbiter_2to1.s1

  xfcp_arbiter_2to1 (2->1, fixed priority UART>ETH):
    - Port 0 (UART): parsuje XFCP hlavicku, generuje synteticke TLAST
    - Port 1 (ETH): pouziva prirodzeny TLAST z UDP framu
    - Order FIFO (depth=8): sleduje smer kazdeho requestu pre routing response

  xfcp_fabric_endpoint (NUM_SLAVES=7):
    Slot 0 @ 0xFF000000: axil_sys_ctrl
    Slot 1 @ 0xFF010000: axil_uart_adapter
    Slot 2 @ 0xFF020000: axil_regs (LED onboard 6-bit)
    Slot 3 @ 0xFF030000: axil_regs (PMOD J10 8-bit)
    Slot 4 @ 0xFF040000: axil_regs (PMOD J11 8-bit)
    Slot 5 @ 0xFF050000: axil_seven_seg_adapter
    Slot 6 @ 0xFF060000: axil_diag_ctrl
```

---

## Fazy

### Faza A — Zakladna struktura [AKTUALNY]
- [x] Projektova struktura (project.yaml, timing.yaml, Makefile)
- [x] XFCP moduly skopirovane z xfcp_test_04 (rtl/xfcp/)
- [x] `xfcp_arbiter_2to1.sv` — novy 2:1 XFCP packet arbiter
- [x] `xfcp_test_05_top.sv` — top-level (ETH stack + UART XFCP + arbiter + endpoint)
- [x] sim/Makefile zakladna struktura
- [x] tb_xfcp_arbiter_2to1.sv — unit test pre arbiter (14/14 PASS)
- [x] tb_xfcp_test_05_top.sv — integracny test (10/10 PASS)
- [x] Simulacia prebehne — regression PASSED

**Stav Faza A:** UZAVRETA (2026-06-08)

### Faza B — ETH-UDP XFCP integrácia [UZAVRETA 2026-06-09]
- [x] `udp_xfcp_server.sv` — 4-FSM buffer module (RX/OUT/RESP/TX FSMs, MAX_PKT_BYTES=128)
- [x] `tb_udp_xfcp_server.sv` — unit test 5 testov (T1-T5): port drop, READ, UDP reply header, oversize drop, busy drop — 27/27 PASS
- [x] Zapojit ETH XFCP cestu do top-level (udp_xfcp_server + ipv4_tx_udp na arb port 2)
- [x] `tb_xfcp_test_05_top.sv` — T11 (ETH READ), T12 (ETH WRITE) — 12/12 PASS
- [x] `sim/common/tb_eth_pkg.sv` — CRC32 + Ethernet frame helper
- [x] Simulacia regression PASSED
- [x] HW test: XFCP cez UDP — 7/7 PASS (2026-06-09)

### Faza C — Python tools [UZAVRETA 2026-06-09]
- [x] `tools/main.py` — dual-transport menu (UART + UDP, transport switch pri beh)
- [x] `tools/xfcp/transport.py` — SerialTransport + UdpTransport
- [x] `tools/xfcp/bus.py` — XfcpBus(transport injection), .uart() + .udp() factory
- [x] `tools/xfcp/timeouts.py` — XfcpTimeouts s udp_s polom
- [x] `tools/modules/diag_ctrl.py` — DiagCtrl (axil_diag_ctrl, 17 registrov, snapshot/reset)
- [x] `tools/core/scanner.py` — DynamicScanner num_slots=7, DIAG v CLASS_MAP
- [x] `tools/test_hw.py` — skriptovany HW test (--uart/--udp, --repeat, --rw, --diag)
- [x] `Makefile` test-uart / test-udp / test-rw / hw-test targety
- [x] HW test UDP: 7/7 slotov PASS, DIAG bez chyb (2026-06-09)

---

## XFCP Protokol

```
Paket format:
  Bajt 0:   SOP  (0xFE = request, 0xFD = response, 0xFF = rpath)
  Bajt 1:   OPCODE (0x10=READ, 0x11=WRITE, 0x00=ID)
  Bajt 2:   SEQ
  Bajt 3-4: COUNT [15:0] Big-Endian (pocet payload bajtov pre WRITE)
  Bajt 5-8: ADDR  [31:0] Big-Endian
  Bajt 9+:  PAYLOAD (COUNT bajtov, len pre WRITE)
```

---

## Porovnanie s predchadzajucimi projektmi

| Vlastnost       | xfcp_test_04        | xfcp_test_05        |
|-----------------|---------------------|---------------------|
| Takt            | 50 MHz              | 125 MHz (PLL)       |
| XFCP transport  | UART only           | UART + ETH-UDP      |
| Arbiter         | N/A                 | xfcp_arbiter_2to1   |
| ETH stack       | N/A                 | ARP+ICMP+UDP-XFCP   |
| BAUD_DIV 115200 | 434 (50 MHz)        | 1085 (125 MHz)      |

---

## Logy / Vysledky

### Faza A (2026-06-08)
- regression PASSED: 24/24 (14 unit arbiter + 10 integration UART)

### Faza B (2026-06-09)
- unit udp_xfcp_server: 27/27 PASS
- integration 12/12 PASS (T1-T10 UART, T11 ETH READ, T12 ETH WRITE)
- regression PASSED

### Faza C HW test (2026-06-09) — make test-udp
- ping: PASS
- 7/7 slotov × 3 opakovania: PASS (SYSC, UART, OUT_, OUT_, OUT_, SEG7, DIAG)
- DIAG snapshot: rx_sop=23, rx_hdr=23, fab_req=23, fab_resp=22, tx_pkt=22
- Chybove registre: 0 (rx_lost=0, rx_frame=0, rx_overrun=0, rx_bad_hdr=0, rx_drop=0)
- **PROJEKT UZAVRETY — vsetky fazy PASS**
