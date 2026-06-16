# XFCP Library — Overview

**Version:** 1.4 (xfcp_lib_v1_4_mem_pass)
**Target:** Intel Cyclone IV E (QMTech EP4CE55), Quartus Prime 25.1 Lite
**Language:** SystemVerilog
**Transport:** UART (115200 baud) + UDP (100 Mbps Ethernet)
**Status:** `xfcp_lib_v1_4_mem_pass` @ commit `755cc2e`

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

xfcp_fifo.sv              -- generic sync FIFO (power-of-2, no RAM style attr)
xfcp_fifo_reg.sv          -- register-based FIFO, depth=2 (backpressure buffer)

axis_byte_register_slice.sv -- 1-beat AXI-Stream register slice (byte-wide)
xfcp_udp_rx_adapter.sv    -- UDP RX framing -> XFCP byte stream
xfcp_udp_tx_adapter.sv    -- XFCP byte stream -> UDP TX framing
udp_xfcp_server.sv        -- complete UDP server (eth stack + adapters)

axifull_sram.sv           -- AXI4-Full slave SRAM, 256x32b, 4x M9K byte lanes
```

---

## Architektura

```
UART RX ──► xfcp_rx_parser ──► xfcp_arbiter_2to1 ──► xfcp_fabric_endpoint
UDP  RX ──► xfcp_udp_rx_adapter ──►               │
                                                    │──► xfcp_axi_engine[0] ──► axil_slave[0]
                                                    │──► xfcp_axi_engine[1] ──► axil_slave[1]
                                                    │           ...
                                                    │──► xfcp_axis_adapter ──► m_axis / s_axis
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

## Resource Usage (xfcp_test_10_axifull_top, Cyclone IV E, 125 MHz)

| Metric          | Hodnota               |
|-----------------|-----------------------|
| LEs             | 26,868 / 55,856 (48%) |
| Registers       | 20,977                |
| Memory bits     | 54,784 / 2,396,160 (2%) |
| PLLs            | 1 / 4                 |
| Fmax (85C slow) | 130.33 MHz            |
| WNS CLK125      | +0.327 ns (SEED 10)   |
| WNS ETH_RXC     | +0.870 ns             |

Poznamka: zahrnuje cely SoC (ETH stack, UART periféria, LED/SEG7 registre).
Samotna XFCP infrastruktura (parser+packetizer+fabric+adaptery) je ~8 000–10 000 LEs.

---

## Simulation Coverage

| Testbench                    | Testy       | Vysledok   |
|------------------------------|-------------|------------|
| tb_xfcp_test_10_axifull_top  | T01–T37     | PASS       |

| Test              | Popis                                              |
|-------------------|----------------------------------------------------|
| T01–T10           | AXIL READ/WRITE (1B, 4B, burst, multiword)         |
| T11–T20           | STATUS, GET_CAPS, GET_TARGET_INFO, AXIS loopback   |
| T21–T30           | Multi-engine AXIL (eng0 + eng1 interleaved)        |
| T31–T34           | MEM_WRITE + MEM_READ (4B / 16B / 64B / 256B)      |
| T35               | GET_TARGET_INFO index=8 -> MEM0                   |
| T36               | GET_CAPS HAS_MEM flag                             |
| T37               | MEM_WRITE + AXIL READ interleaved (order test)    |

---

## HW Validation (QMTech EP4CE55, 125 MHz)

| Transport | Testy    | Vysledok    |
|-----------|----------|-------------|
| UART      | 81/81    | PASS        |
| UDP       | 81/81    | PASS        |

Testovana sada (81 testov): ping, slot scan, GET_CAPS, GET_TARGET_INFO (9 targets),
AXIL RW (5 hodnot), STREAM loopback (4B/16B/64B/256B), MEM loopback (4B/16B/64B/256B), DIAG.

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
