# XFCP_TEST_09_TARGETS — Status

**Projekt:** XFCP v1.2+TARGETS — GET_TARGET_INFO (0x03) / RESP_GET_TARGET_INFO (0x04) rozsirenie
**Takt:** 125 MHz (PLL: 50 MHz sys_clk → 125 MHz clk125)
**Board:** QMTech EP4CE55
**IP:** 192.168.0.5 | MAC: 00:0A:35:01:FE:C5
**Stav:** Faza B UZAVRETA — sim T01-T30 PASS (142 checks, 0 failures)

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
      xfcp_caps_adapter: proto_minor=2, caps_flags=0x0F

    TI backend (0x03 GET_TARGET_INFO → 0x04 RESP_GET_TARGET_INFO):
      xfcp_target_info_adapter: staticka tabulka 8 targetov (16B/target)
```

---

## XFCP Protokol — GET_TARGET_INFO

```
GET_TARGET_INFO REQUEST (op=0x03):
  FE 03 seq 00 00 00 00 00 [index]  (9B, COUNT=0, ADDR[7:0]=target_index)

RESP_GET_TARGET_INFO RESPONSE (op=0x04, status=OK):
  FD 04 seq 00 W0[3..0] W1[3..0] W2[3..0] W3[3..0] 00
  Celkovo 22B (4B header + 16B payload + 1B TLAST byte)

RESP_GET_TARGET_INFO RESPONSE (op=0x04, status=BAD_ADDRESS, invalid index):
  FD 04 seq 03 00*16 00
```

### Target struct (16 bajtov, 4×32-bit slov MSB-first)

| Offset | Byte  | Popis |
|--------|-------|-------|
| 0      | W0[3] | target_type: 0x01=AXIL, 0x02=STREAM |
| 1      | W0[2] | target_id (== index) |
| 2      | W0[1] | flags (0x00) |
| 3      | W0[0] | reserved (0x00) |
| 4-7    | W1    | base_addr (32b big-endian) |
| 8-9    | W2[3:2] | max_transfer (16b big-endian) |
| 10     | W2[1] | align |
| 11     | W2[0] | reserved (0x00) |
| 12-15  | W3    | name (4 ASCII chars) |

### GET_CAPS — aktualizovane hodnoty

| Byte | Hodnota | Popis |
|------|---------|-------|
| 0 | 0x01 | proto_major |
| 1 | **0x02** | proto_minor (2 = pridany TI) |
| 2 | 0x07 | num_axil_slots |
| 3 | 0x01 | num_stream_slots |
| 4 | 0x01 | max_stream_bytes[15:8] = 256 |
| 5 | 0x00 | max_stream_bytes[7:0] |
| 6 | 0x04 | stream_align |
| 7 | **0x0F** | caps_flags: bit0=HAS_AXIL, bit1=HAS_STREAM, bit2=HAS_CAPS, bit3=HAS_TARGETS |

---

## Target tabulka (8 targetov, index 0-7)

| Index | Type   | Name | Base addr   | max_xfer | align |
|-------|--------|------|-------------|----------|-------|
| 0     | AXIL   | SYSC | 0xFF000000  | 128B     | 4     |
| 1     | AXIL   | UART | 0xFF010000  | 128B     | 4     |
| 2     | AXIL   | OUT_ | 0xFF020000  | 128B     | 4     |
| 3     | AXIL   | OUT_ | 0xFF030000  | 128B     | 4     |
| 4     | AXIL   | OUT_ | 0xFF040000  | 128B     | 4     |
| 5     | AXIL   | SEG7 | 0xFF050000  | 128B     | 4     |
| 6     | AXIL   | DIAG | 0xFF060000  | 128B     | 4     |
| 7     | STREAM | STR0 | 0x00000000  | 256B     | 4     |
| 8+    | —      | —    | —           | —        | — (BAD_ADDRESS) |

---

## Nove moduly oproti xfcp_test_08_caps

| Modul | Zmena | Popis |
|-------|-------|-------|
| `xfcp_target_info_adapter.sv` | **NOVY** | FSM ST_IDLE→ST_DONE_PLS→ST_DATA, 4×32-bit ROM z parametrov, bad_index→BAD_ADDRESS |
| `xfcp_pkg.sv` | upraveny | +XFCP_OP_GET_TARGET_INFO=0x03, +XFCP_OP_RESP_GET_TARGET_INFO=0x04, +xfcp_op_is_targets(), xfcp_resp_has_payload() + xfcp_resp_for_op() rozsirene |
| `xfcp_rx_parser.sv` | upraveny | XFCP_OP_GET_TARGET_INFO pridany do opcode_valid() |
| `xfcp_fabric_endpoint.sv` | upraveny | 4. backend (TI vedla AXIL+AXIS+CAPS): is_ti routing, ti_done_cnt_q, arb_is_ti_q, arb_is_axil_q teraz preregistrovany ako !axis && !caps && !ti |
| `xfcp_caps_adapter.sv` | upraveny | PROTO_MINOR=2, CAPS_FLAGS=0x0F (HAS_TARGETS bit set) |

---

## Fazy

### Faza A — GET_TARGET_INFO RTL [UZAVRETA]

- [x] xfcp_pkg.sv: XFCP_OP_GET_TARGET_INFO (0x03) / XFCP_OP_RESP_GET_TARGET_INFO (0x04)
- [x] xfcp_rx_parser.sv: opcode_valid() rozsirena o GET_TARGET_INFO
- [x] xfcp_target_info_adapter.sv: novy modul, staticka ROM 4×32b, FSM IDLE→DONE_PLS→DATA
- [x] xfcp_fabric_endpoint.sv: 4. backend TI — is_ti routing, ti_done_cnt_q, arb_is_ti_q
- [x] xfcp_test_09_targets_top.sv: xfcp_target_info_adapter inštancia (8 targetov)
- [x] caps_adapter: proto_minor=2, caps_flags=0x0F
- [x] project.yaml + IP YAML: opravene na xfcp_test_09_targets_top

**Stav:** UZAVRETA (2026-06-14), commit 7ae6326

---

### Faza B — Simulacia T01-T30 [UZAVRETA]

- [x] sim/Makefile: xfcp_target_info_adapter.sv pridany do XFCP_COMMON, target premenovat
- [x] tb_xfcp_test_09_targets_top.sv: T23/T24/T25 update (proto_minor=2, caps_flags=0x0F)
- [x] T26: GET_TARGET_INFO index=0 → SYSC AXIL 0xFF000000 (16B overenie)
- [x] T27: GET_TARGET_INFO index=6 → DIAG AXIL 0xFF060000
- [x] T28: GET_TARGET_INFO index=7 → STR0 STREAM base=0 max=256
- [x] T29: GET_TARGET_INFO index=8 (invalid) → status=BAD_ADDRESS (0x03)
- [x] T30: GET_CAPS + GET_TARGET_INFO + AXIL READ interleaved (in-order)
- [x] sim regression: ALL PASSED (142 checks, 0 failures)
- [x] Python tools: protocol.py/bus.py/test_hw.py doplnene o GET_TARGET_INFO

**Stav:** UZAVRETA (2026-06-14), commit 7ae6326

---

### Faza C — Quartus build + timing closure [CAKAJUCA]

- [ ] `socfw build project.yaml` → pregenerovat build/
- [ ] skontrolovat `build/hal/files.tcl`: xfcp_target_info_adapter.sv + xfcp_test_09_targets_top.sv
- [ ] Quartus compile (target SEED z xfcp_test_08_caps)
- [ ] Timing: CLK125 WNS >= 0, ETH_RXC WNS >= 0

Ocakavany vysledok: timing by mal PASS priamo (iba 1 novy FF-chain TI adapter, ziadna nova
kriticka cesta; arb_is_axil_q=!(axis||caps||ti) je uz preregistrovane z Fazy B xfcp_test_08_caps).

---

### Faza D — HW regresia [CAKAJUCA]

- [ ] `make program`
- [ ] `make arp-setup`
- [ ] `make hw-regression` (UART + UDP, kazdy s --caps --targets --rw --stream --diag)

Odhadovany pocet test bodov (repeat=3):
- Slot scan: 21 (7 slotov x 3)
- GET_CAPS:  3
- GET_TARGET_INFO: 8×3 + 1 (bad_addr) = 25
- R/W (LED): 5
- STREAM: 4 vektory x 3 = 12
- Ping: 1
- Celkovo: ~67 / transport → ~134 celkovo

**Tag po PASS:** `xfcp_lib_v1_3_targets_pass`

---

## Simulacia — prehlad testov

| Test    | Popis                                             | Stav |
|---------|---------------------------------------------------|------|
| T01-T10 | AXIL READ/WRITE (UART, 10 adries)                 | PASS |
| T11-T12 | AXIL ETH-UDP READ + WRITE                         | PASS |
| T13-T15 | STREAM_WRITE/READ 4B/16B/64B loopback             | PASS |
| T16     | STREAM_READ count=0 → BAD_LENGTH                  | PASS |
| T17     | STREAM_WRITE sid=1 → UNSUPPORTED                  | PASS |
| T18     | STREAM_READ sid=1 → UNSUPPORTED                   | PASS |
| T19     | Mixed AXIL WRITE + STREAM + AXIL READ             | PASS |
| T20     | STREAM 256B loopback (max)                        | PASS |
| T21-T22 | ETH-UDP STREAM_WRITE/READ 256B                    | PASS |
| T23     | GET_CAPS UART (proto_minor=2, flags=0x0F)         | PASS |
| T24     | GET_CAPS ETH-UDP                                  | PASS |
| T25     | GET_CAPS + AXIL READ interleaved                  | PASS |
| T26     | GET_TARGET_INFO index=0 (SYSC) — 16B overenie     | PASS |
| T27     | GET_TARGET_INFO index=6 (DIAG)                    | PASS |
| T28     | GET_TARGET_INFO index=7 (STR0 STREAM, max=256)    | PASS |
| T29     | GET_TARGET_INFO index=8 (invalid) → BAD_ADDRESS   | PASS |
| T30     | GET_CAPS + GET_TARGET_INFO + AXIL READ interleaved | PASS |

**Celkovo: T01-T30 ALL PASSED (142 checks, 0 failures) — 2026-06-14**

---

## Commits

| Commit  | Popis |
|---------|-------|
| 7ae6326 | Faza A+B — RTL + sim T01-T30 PASS, Python tools |

---

## Timing

Zatial nespusteny (Faza C prebieha).

Referencia: xfcp_test_08_caps (8b_caps SEED 5):
```
CLK125 WNS: +0.355 ns
ETH_RXC WNS: +0.749 ns
```
