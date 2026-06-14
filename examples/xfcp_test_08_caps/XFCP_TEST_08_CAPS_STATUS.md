# XFCP_TEST_08_CAPS — Status

**Projekt:** XFCP v1.1+CAPS — GET_CAPS (0x01) / RESP_GET_CAPS (0x02) rozsirenie
**Takt:** 125 MHz (PLL: 50 MHz sys_clk → 125 MHz clk125)
**Board:** QMTech EP4CE55
**IP:** 192.168.0.5 | MAC: 00:0A:35:01:FE:C5
**Stav:** Faza C ciastocne — HW link PASS (ARP 4/4, ICMP 4/4), caka HW XFCP regression

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

  xfcp_arbiter_2to1 -> xfcp_fabric_endpoint:

    AXIL backends (0x10/0x11):
      Slot 0 @ 0xFF000000: axil_sys_ctrl
      Slot 1 @ 0xFF010000: axil_uart_adapter
      Slot 2 @ 0xFF020000: axil_regs (LED onboard 6-bit)
      Slot 3 @ 0xFF030000: axil_regs (PMOD J10 8-bit)
      Slot 4 @ 0xFF040000: axil_regs (PMOD J11 8-bit)
      Slot 5 @ 0xFF050000: axil_seven_seg_adapter
      Slot 6 @ 0xFF060000: axil_diag_ctrl

    AXIS backend (0x20/0x21):
      stream_id=0: loopback (xfcp_fifo_reg, DEPTH=256)

    CAPS backend (0x01 GET_CAPS → 0x02 RESP_GET_CAPS):
      xfcp_caps_adapter: 8-bajtova staticka odpoved z parametrov
```

---

## XFCP Protokol — GET_CAPS

```
GET_CAPS REQUEST (op=0x01):
  FE 01 seq 00 00 00 00 00 00  (8B header, COUNT=0)

RESP_GET_CAPS RESPONSE (op=0x02):
  FD 02 seq status W0[3] W0[2] W0[1] W0[0] W1[3] W1[2] W1[1] W1[0] 00
  Celkovo 12B (4B header + 8B payload + 1B TLAST byte)
```

### CAPS struct (8 bajtov, MSB-first v 32-bit slovach)

| Offset | Byte | Hodnota | Popis |
|--------|------|---------|-------|
| 0 | W0[3] | 0x01 | proto_major |
| 1 | W0[2] | 0x01 | proto_minor |
| 2 | W0[1] | 0x07 | num_axil_slots |
| 3 | W0[0] | 0x01 | num_stream_slots |
| 4 | W1[3] | 0x01 | max_stream_bytes[15:8] = 256 |
| 5 | W1[2] | 0x00 | max_stream_bytes[7:0] |
| 6 | W1[1] | 0x04 | stream_align |
| 7 | W1[0] | 0x07 | caps_flags: bit0=HAS_AXIL, bit1=HAS_STREAM, bit2=HAS_CAPS |

---

## Nové moduly oproti xfcp_test_07_axis

| Modul | Zmena | Popis |
|-------|-------|-------|
| `xfcp_caps_adapter.sv` | **NOVY** | 3-stavovy FSM (ST_IDLE→ST_DONE_PLS→ST_DATA), 2×32-bit ROM z parametrov |
| `xfcp_pkg.sv` | upraveny | +XFCP_OP_GET_CAPS=0x01, +XFCP_OP_RESP_GET_CAPS=0x02, +xfcp_op_is_caps(), xfcp_resp_has_payload() rozsirena |
| `xfcp_rx_parser.sv` | upraveny | XFCP_OP_GET_CAPS pridany do opcode_valid() |
| `xfcp_fabric_endpoint.sv` | upraveny | 3. backend (CAPS vedla AXIL+AXIS), is_caps routing, caps_done_cnt_q, arb_is_caps_q, arb_done_now, arb_is_axil_q |
| `xfcp_axi_engine.sv` | upraveny | read_data_ready_r — registracia pre timing closure |

---

## Fazy

### Faza A — GET_CAPS extension + sim T01-T25 [UZAVRETA]

- [x] xfcp_pkg.sv: XFCP_OP_GET_CAPS (0x01) / XFCP_OP_RESP_GET_CAPS (0x02), xfcp_op_is_caps()
- [x] xfcp_rx_parser.sv: opcode_valid() rozsirena o GET_CAPS (COUNT=0 uz bolo platne)
- [x] xfcp_caps_adapter.sv: novy modul, staticka ROM 2×32b, FSM IDLE→DONE_PLS→DATA
- [x] xfcp_fabric_endpoint.sv: 3. backend — is_caps routing, caps_done_cnt_q, arb_is_caps_q
- [x] T23: GET_CAPS cez UART (overenie vsetkych 8 caps bajtov)
- [x] T24: GET_CAPS cez ETH-UDP
- [x] T25: GET_CAPS + AXIL READ interleaved (in-order check)
- [x] sim T01-T25 ALL PASS (commit 1dd3f0f)

**Bug A1: opcode_valid() chybajuci GET_CAPS**
- `xfcp_rx_parser.sv` neprijimala op=0x01 → PROTOCOL ERROR → S_DROP
- Fix: `8'(XFCP_OP_GET_CAPS) : return 1'b1;` v case statement opcode_valid()

**Stav:** UZAVRETA (2026-06-14)

---

### Faza B — Quartus build + timing closure [UZAVRETA]

**Quartus setup:**
- `socfw build project.yaml` → `build/rtl/soc_top.sv`, `build/hal/files.tcl`, `build/timing/soc_top.sdc`
- Pridane: `Makefile` (include ../../Makefile.common), `soc_top.qpf`, `soc_top.qsf`, `cores/clkpll/`
- SEED 5 (zdedeny z xfcp_test_07_axis)

**Timing failure (pred fix):**
- Kriticka cesta: `i_packetizer|state_q.ST_PAYLOAD → g_engine[0].i_engine|i_read_buffer|rd_ptr_q`
- Data arrival: 8.087 ns vs period 8.000 ns → WNS = -0.205 ns (vsetky SEED 1-10 rovnake)
- Pricina: ~7 LUT cesta: `state_q → read_data_ready → rfifo_rready_w → FIFO rd_ptr_q`
- CAPS pridanie `arb_is_caps_q` do `read_data_ready` predlzilo cestu vs xfcp_test_07_axis

**Pokus 1 — arb_is_axil_q (NEPOMOHLO):**
- Preregistrovany `!(arb_is_axis_q || arb_is_caps_q)` → WNS stale -0.205 ns
- Pricina: bottleneck nie je tento termin ale dlzka celej cesty

**Fix — read_data_ready_r (USPECH):**
- `xfcp_axi_engine.sv`: `read_data_ready_r <= read_data_ready` (FF registracia portu)
- `rfifo_rready_w = !read_data_valid || read_data_ready_r`
- Skratena cesta: `read_data_ready_r (FF) → rfifo_rready_w → rd_ptr_q` (~3 LUT, ~3 ns)
- 1-takt latency pri backpressure acknowledge — prijatelne (UART/AXI-S ms-dominancia)

**Vysledok:**
- WNS: **-0.205 ns → +0.355 ns** (SEED 5)
- Fmax (Slow 85C CLK125): **130.8 MHz**
- Sim T01-T25 ALL PASS po zmene

**Stav:** UZAVRETA (2026-06-14), commit 42402c0

---

### Faza C — HW link sanity [UZAVRETA]

`make hw-test` overuje iba sietovu dostupnost (ARP + ICMP), nie XFCP samotne.

- [x] `make program` — FPGA naprogramovany
- [x] `make arp-setup` — staticka ARP entry
- [x] ARP 4/4 PASS (2026-06-14)
- [x] ICMP 4/4 PASS, RTT min/avg/max = 0.127/0.151/0.168 ms

**Poznamka (navrh_01.md):** Aktualny `hw-test` je len „link sanity test" — nevolá Python XFCP
klienta, necita GET_CAPS, netestuje AXIL/STREAM/DIAG. HW XFCP regression este nie je
overena, pretoze Python nastroje nie su prenesene z `xfcp_test_07_axis`.

**Stav:** UZAVRETA (2026-06-14)

---

### Faza D — HW XFCP regression [PLANOVANA]

Podla navrh_01.md: preniest Python nastroje + implementovat `get_caps()` + rozsirit Makefile.

**Potrebne kroky:**

- [ ] Preniest `tools/` z `xfcp_test_07_axis` (protocol.py, bus.py, transport_*.py, test_hw.py)
- [ ] Pridat `bus.get_caps()` → decode 8B payload do dict
- [ ] Rozsirit Makefile: `hw-link-test` / `test-uart` / `test-udp` / `hw-regression`
- [ ] UART: GET_CAPS, AXIL READ/WRITE, STREAM 4/64/256B, DIAG snapshot
- [ ] UDP:  GET_CAPS, AXIL READ/WRITE, STREAM 4/64/256B, DIAG snapshot
- [ ] DIAG: rx_bad_hdr = rx_recovery = rx_drop = 0
- [ ] Tag: `xfcp_lib_v1_2_caps_pass`

**Ocakavane hodnoty GET_CAPS:**
```
proto_major       1
proto_minor       1
num_axil_slots    7
num_stream_slots  1
max_stream_bytes  256
stream_align      4
caps_flags        0x07
```

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
| T20     | STREAM_WRITE/READ 256B (UART) | PASS |
| T21     | ETH-UDP STREAM_WRITE 256B | PASS |
| T22     | ETH-UDP STREAM_READ 256B | PASS |
| T23     | GET_CAPS cez UART — 8 caps bajtov | PASS |
| T24     | GET_CAPS cez ETH-UDP | PASS |
| T25     | GET_CAPS + AXIL READ interleaved | PASS |

**Celkovo: T01-T25 ALL PASSED (0 failures) — 2026-06-14**

---

## Bugy

| Bug | Komponent | Popis | Fix |
|-----|-----------|-------|-----|
| A1 | xfcp_rx_parser.sv | opcode_valid() neobsahovala GET_CAPS → S_DROP | 1 riadok v case statement |
| B1 | xfcp_axi_engine.sv | Kriticka cesta ~7 LUT → WNS -0.205 ns | read_data_ready_r registracia |

---

## Timing (commit 42402c0, SEED 5)

```
CLK125 (Slow 1200mV 85C):
  Setup WNS:    +0.355 ns
  Hold  WNS:    +0.427 ns
  TNS:           0.000 ns
  Fmax:         130.8 MHz (target 125 MHz)

ETH_RXC (Slow 1200mV 85C):
  Setup WNS:    +0.749 ns
```

---

## Resource usage (commit 42402c0, SEED 5)

```
Logic elements: 26,258 / 55,856  (47 %)
Registers:      20,617
Memory bits:    44,544 / 2,396,160  (2 %)
Pins:           66 / 325  (20 %)
PLLs:           1 / 4
```

---

## Commits

| Commit | Popis |
|--------|-------|
| 1dd3f0f | Faza A — GET_CAPS extension, sim T01-T25 PASS |
| 7c1d8c8 | Pridaj cores/clkpll (PLL IP pre Quartus) |
| 238b0f8 | Pridaj Makefile + soc_top.qpf pre Quartus |
| 42402c0 | Faza B — timing closure WNS +0.355 ns (read_data_ready_r) |
| 3724b8e | Pridaj XFCP_TEST_08_CAPS_STATUS.md |
