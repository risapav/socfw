# XFCP Library — Overview

**Version:** 1.6 (xfcp_lib_v1_6_mailbox_regs_pass)
**Target:** Intel Cyclone IV E (QMTech EP4CE55), Quartus Prime 25.1 Lite
**Language:** SystemVerilog
**Transport:** UART (115200 baud) + UDP (100 Mbps Ethernet)
**Status:** `xfcp_lib_v1_6_mailbox_regs_pass` @ commit `9fe2a97`

XFCP (eXtensible FPGA Control Protocol) je jednoduchý request/response protokol
pre prístup k registrom, AXI-Stream a pamäti cez UART alebo UDP.

---

## Module Hierarchy

```
xfcp_pkg.sv               -- opcodes, status codes, structs, helper functions (package)

xfcp_rx_parser.sv         -- byte stream -> decoded request headers + wdata flow
xfcp_tx_packetizer.sv     -- response headers + payload -> byte stream
xfcp_arbiter_2to1.sv      -- 2-port UART/UDP arbiter, fair round-robin

xfcp_fabric_endpoint.sv   -- multi-slave router: AXIL + AXIS + CAPS + TI + MEM
  xfcp_axi_engine.sv      -- AXI4-Lite master engine (READ/WRITE opcodes)
  xfcp_axis_adapter.sv    -- AXI-Stream loopback adapter (STREAM_WRITE/READ)
  xfcp_caps_adapter.sv    -- GET_CAPS responder (static parameters)
  xfcp_target_info_adapter.sv -- GET_TARGET_INFO responder (static ROM table)
  xfcp_mem_adapter.sv     -- AXI4-Full master engine (MEM_READ/MEM_WRITE)

xfcp_stream_mux.sv        -- 2-port stream_id dispatcher (CPU0 / STR0)

xfcp_fifo.sv              -- generic sync FIFO (power-of-2, no RAM style attr)
xfcp_fifo_reg.sv          -- sync FIFO s registrovanym vystupom (M9K safe, backpressure)

axis_byte_register_slice.sv -- 1-beat AXI-Stream register slice (byte-wide)
xfcp_udp_rx_adapter.sv    -- UDP RX framing -> XFCP byte stream
xfcp_udp_tx_adapter.sv    -- XFCP byte stream -> UDP TX framing
udp_xfcp_server.sv        -- complete UDP server (eth stack + adapters)

axifull_sram.sv           -- AXI4-Full slave SRAM, 256x32b, 4x M9K byte lanes (test_ip)
axil_cpu_mailbox.sv       -- CPU-facing AXI-Lite mailbox (RX/TX FIFO, host<->CPU)
```

---

## Architektura

```
UART RX ──► xfcp_rx_parser ──► xfcp_arbiter_2to1 ──► xfcp_fabric_endpoint
UDP  RX ──► xfcp_udp_rx_adapter ──►               │
                                                    │──► xfcp_axi_engine[0] ──► axil_slave[0]
                                                    │──► xfcp_axi_engine[1] ──► axil_slave[1]
                                                    │           ...
                                                    │──► xfcp_axis_adapter[0] ──► STR0 loopback FIFO
                                                    │──► xfcp_axis_adapter[1] ──► xfcp_stream_mux
                                                    │                                └──► axil_cpu_mailbox (CPU0)
                                                    │──► xfcp_caps_adapter
                                                    │──► xfcp_target_info_adapter
                                                    └──► xfcp_mem_adapter ──► axifull_sram
UART TX ◄── xfcp_tx_packetizer ◄── fabric response MUX
UDP  TX ◄── xfcp_udp_tx_adapter ◄──
```

---

## Protokol (stručne)

Každý request je séria bajtov: `SOP_REQ(FE) | OPCODE | SEQ | COUNT[15:8] | COUNT[7:0] | ADDR[31:24..0] | [payload]`

Každý response: `SOP_RESP(FD) | OPCODE_RESP | SEQ | STATUS | [payload] | 0x00+TLAST`

Podrobnosti: [protocol.md](protocol.md) | [status.md](status.md) | [targets.md](targets.md)

---

## Resource Usage (xfcp_test_12_cpu_mailbox_regs_top, Cyclone IV E, 125 MHz)

| Metric          | Hodnota               |
|-----------------|-----------------------|
| LEs             | 30,001 / 55,856 (54%) |
| Registers       | 23,632                |
| Memory bits     | 61,248 / 2,396,160 (3%) |
| PLLs            | 1 / 4                 |
| Fmax (85C slow) | 125+ MHz              |
| WNS CLK125      | +0.252 ns (SEED 5)    |
| WNS ETH_RXC     | +0.345 ns             |

Poznamka: zahrnuje cely SoC (ETH stack, UART periféria, LED/SEG7 registre, axil_cpu_mailbox).
Samotna XFCP infrastruktura (parser+packetizer+fabric+adaptery) je ~8 000–10 000 LEs.

---

## Simulation Coverage

| Testbench                                    | Testy   | Vysledok |
|----------------------------------------------|---------|----------|
| tb_xfcp_test_12_cpu_mailbox_regs_top         | T01–T49 | PASS     |

| Test              | Popis                                              |
|-------------------|----------------------------------------------------|
| T01–T10           | AXIL READ/WRITE (1B, 4B, burst, multiword)         |
| T11–T20           | STATUS, GET_CAPS, GET_TARGET_INFO, AXIS loopback   |
| T21–T30           | Multi-engine AXIL, STREAM_WRITE/READ sid=0/1       |
| T31–T37           | MEM_WRITE + MEM_READ (4B/16B/64B/256B), interleave |
| T38–T39           | xfcp_stream_mux dispatch sid=0/1                  |
| T40–T42           | CPUM ID/STATUS/CTRL rx_flush                      |
| T43               | GET_TARGET_INFO index=10 -> CPUM AXIL             |
| T44               | STREAM_WRITE 256B -> RX_LEVEL==256 -> rx_flush    |
| T45               | TX_PUSH_DATA 4B -> STATUS.tx_not_empty -> STREAM_READ |
| T46               | STREAM_WRITE 8B sid=1 -> RX_POP_DATA x8 + tlast  |
| T47               | RX underflow bit[10]==1 when FIFO empty           |
| T48               | STATUS sanity + rx_flush                          |
| T49               | TX_PUSH_DATA -> tx_flush -> TX_LEVEL==0           |

---

## HW Validation (QMTech EP4CE55, 125 MHz)

| Transport | Testy    | Vysledok    |
|-----------|----------|-------------|
| UART      | 98/98    | PASS        |
| UDP       | 98/98    | PASS        |

Testovana sada (98 testov): ping, slot scan (8 slots), GET_CAPS, GET_TARGET_INFO (11 targets + BAD_ADDRESS),
AXIL RW (5 hodnot), STREAM loopback STR0 (4B/16B/64B/256B), CPUM regs (ID/TX/RX/flush),
MEM loopback (4B/16B/64B/256B), DIAG counters.

---

## Python Client

```
tools/xfcp/
  __init__.py         -- exportuje XfcpBus
  bus.py              -- XfcpBus: ping, read32, write32, read_block, write_block,
                          stream_read, stream_write, mem_read, mem_write,
                          get_caps, get_target_info, list_targets
  protocol.py         -- encode_*/decode_* funkcie, opkody, MAX_* konstanty
  transport.py        -- SerialTransport, UdpTransport
  timeouts.py         -- XfcpTimeouts (read_s, write_s, drain_s)
  errors.py           -- XfcpError, XfcpTimeoutError, XfcpProtocolError,
                          XfcpStatusError, XfcpRecoveryError
```

Priklad pouzitia:

```python
from xfcp.bus import XfcpBus

with XfcpBus.uart('/dev/ttyUSB0', 115200) as bus:
    val = bus.read32(0xFF000000)
    bus.write32(0xFF020004, 0x3F)
    data = bus.mem_read(0x00000000, 64)
    bus.mem_write(0x00000000, bytes(range(64)))

with XfcpBus.udp('192.168.0.5', 50000) as bus:
    caps = bus.get_caps()
    targets = bus.list_targets()
```
