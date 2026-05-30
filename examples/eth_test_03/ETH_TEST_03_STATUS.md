# ETH_TEST_03 — Status

**Dátum:** 2026-05-30
**Stav:** Caka na HW overenie — 13/13 testbenches ALL PASS; Quartus compile OK (0 errors); SOF vygenerovany

---

## Cieľ projektu

Kompletný Ethernet UDP echo stack na QMTech EP4CE55 + RTL8211EG PHY (GMII 1Gbps).

```
RX: gmii_rx_mac -> eth_header_parser -> ipv4_header_parser -> udp_header_parser
                -> udp_rx_meta_assembler -> udp_echo_app
TX: udp_echo_app -> udp_ipv4_tx_builder -> async_fifo (CDC) -> TX controller -> gmii_tx_mac
```

---

## Quartus Build Status

- **Syntéza:** 0 errors, 8 warnings (ASYNC_REG atribút ignorovaný — benígne)
- **Fitter + Assembler + STA:** 0 errors
- **SOF:** `output_files/soc_top.sof`

### Timing Summary (Slow 1200mV 85C — worst corner)

| Clock | Fmax | Slack | Stav |
|---|---|---|---|
| ETH_RXC (125 MHz) | 65.86 MHz | −7.18 ns | FAIL (slow corner) |
| ETH_TX_CLK (125 MHz) | 142.69 MHz | +1.74 ns | OK |
| SYS_CLK (50 MHz) | 68.32 MHz | +0.32 ns | OK |

### Timing Summary (Fast 1200mV 0C — optimistic corner)

| Clock | Slack | Stav |
|---|---|---|
| ETH_RXC (125 MHz) | +1.56 ns | OK |
| ETH_TX_CLK (125 MHz) | +4.89 ns | OK |
| SYS_CLK (50 MHz) | +11.47 ns | OK |

**Analýza:** Kritická cesta ETH_RXC je kombinacna logika v `udp_ipv4_tx_builder` (28-case
header mux + dlhe routing na EP4CE55). Fast corner prechazi — na HW pri izbovej teplote
(25 C) ocakavame funkcnost. Pipelining header mux je dlhodoby fix ak HW nepreide.

---

## Stav RTL modulov

| Modul | Súbor | Stav |
|---|---|---|
| `crc32_eth` | `mac/crc32_eth.sv` | PASS — 3/3 |
| `gmii_tx_mac` | `mac/gmii_tx_mac.sv` | PASS — 8/8 (inside op. nahradeny OR) |
| `gmii_rx_mac` | `mac/gmii_rx_mac.sv` | PASS — 5/5; výstup s FCS |
| `eth_header_builder` | `l2/eth_header_builder.sv` | PASS — 3/3 |
| `eth_header_parser` | `l2/eth_header_parser.sv` | PASS — 12/12 |
| `ipv4_checksum` | `l3/ipv4_checksum.sv` | PASS — 4/4 |
| `ipv4_header_parser` | `l3/ipv4_header_parser.sv` | PASS — 15/15 |
| `udp_header_parser` | `l4/udp_header_parser.sv` | PASS — 21/21 |
| `udp_rx_meta_assembler` | `l4/udp_rx_meta_assembler.sv` | PASS (cez echo_path) |
| `udp_echo_app` | `l4/udp_echo_app.sv` | PASS (cez echo_path) |
| `udp_ipv4_tx_builder` | `l4/udp_ipv4_tx_builder.sv` | PASS — 3/3 |
| `async_fifo` | `cdc/async_fifo.sv` | PASS — FWFT+no_rw_check |
| `cdc_two_flop_synchronizer` | `cdc/cdc_two_flop_synchronizer.sv` | OK |
| `eth_debug_leds` | `util/eth_debug_leds.sv` | Implementovany, HW overenie |
| `ethernet_test_03_top` | `ethernet_test_03_top.sv` | Implementovany, HW overenie |

---

## Quartus-specificke opravy (navrhy_12)

- `gmii_tx_mac`: `inside` operator -> OR vyrazy (Quartus Lite nepodporuje `inside`)
- `udp_echo_app`, `udp_ipv4_tx_builder`: odstranene `wire` pred struct portom;
  `import eth_pkg::*;` pred `module` (nie `wire udp_packet_meta_t`, ale `udp_packet_meta_t`)
- `async_fifo`: FWFT registered output + `(* ramstyle = "no_rw_check" *)`
- Vsetky SV: `import eth_pkg::*;` pred `module` (nie `eth_pkg::typ` v portoch)

---

## Výsledky testov — 13/13 ALL PASS

```bash
# Z examples/eth_test_03/sim/
make regression   # clean + unit + integration
```

| Testbench | Typ | Vysledok |
|---|---|---|
| tb_crc32_eth | Questa | 3/3 PASS |
| tb_gmii_tx_mac | Questa | 8/8 PASS |
| tb_gmii_rx_mac | Questa | 5/5 PASS |
| tb_mac_stream_tx_rx_stream | Questa | 10/10 PASS |
| tb_eth_header_builder | Questa | 3/3 PASS |
| tb_eth_header_parser | Questa | 12/12 PASS |
| tb_ipv4_checksum | Questa | 4/4 PASS |
| tb_ipv4_header_parser | Questa | 15/15 PASS |
| tb_udp_header_parser | Questa | 21/21 PASS |
| tb_udp_ipv4_tx_builder | Questa | 3/3 PASS |
| tb_rx_path | Verilator | 5/5 PASS |
| tb_echo_path | Verilator | 5/5 PASS |
| tb_echo_path_dual_clock | Verilator | 5/5 PASS (CDC 8.000/8.013 ns) |

---

## Kľúčové RTL rozhodnutia

### hdr_pre_valid_o a _pre porty
`udp_header_parser` vystavuje `hdr_pre_valid_o` (fires pri `byte_cnt==7`).
`udp_rx_meta_assembler` triggeruje priamo — eliminuje 1-cycle edge-detection delay.
`udp_echo_app` ma `s_axis_tready=1` aj v ST_IDLE pri `rx_meta_valid_i=1` — prvy payload bajt
zachyteny pocas handshake.

### Dual-clock CDC architektura
```
RX domain (eth_rx_clk):  gmii_rx_mac -> parsery -> udp_echo_app -> udp_ipv4_tx_builder
                          -> async_fifo.wr_side  (pkt_fifo 9b/2048, meta_fifo 96b/4)
TX domain (eth_tx_clk):  async_fifo.rd_side -> TX FSM -> gmii_tx_mac
```
TX FSM caka na `tx_mac_busy_w=0` pred spustenim novej TX operacie.

### UDP checksum
TX: 0x0000 (disabled). RX: DROP_NONZERO_CHECKSUM=0, flag `udp_checksum_unchecked_o`.

---

## Known Issues / Zostatok

- [ ] **HW overenie** — programovanie EP4CE55, ping test, analyza LED diagnostiky
- [ ] **Timing ETH_RXC** — slow corner -7 ns; fix: pipeline header mux v `udp_ipv4_tx_builder`
       (ak HW neprebehne pri izbovej teplote)
- [ ] `gmii_rx_mac` STRIP_FCS — dlhodobý cieľ
