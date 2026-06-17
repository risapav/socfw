# socfw/rtl/xfcp — XFCP RTL Library

Reusable SystemVerilog moduly pre XFCP protokol na Cyclone IV E (QMTech EP4CE55).
Aktuálna stabilná verzia: **v1.7** — `xfcp_lib_v1_7_cpu_stub_pass`

---

## Adresárová štruktúra

```
rtl/xfcp/
  xfcp_pkg.sv                   -- opcodes, status codes, structs, helper functions
  xfcp_rx_parser.sv             -- byte stream -> request headers + wdata flow
  xfcp_tx_packetizer.sv         -- response headers + rdata -> byte stream
  xfcp_arbiter_2to1.sv          -- 2-port (UART/UDP) arbiter, fair round-robin
  xfcp_fabric_endpoint.sv       -- multi-slave router (AXIL+AXIS+CAPS+TI+MEM)
  xfcp_axi_engine.sv            -- AXI4-Lite master engine (READ/WRITE opcodes)
  xfcp_axis_adapter.sv          -- AXI-Stream adapter (STREAM_WRITE/READ, multi-slot)
  xfcp_mem_adapter.sv           -- AXI4-Full master engine (MEM_READ/MEM_WRITE)
  xfcp_caps_adapter.sv          -- GET_CAPS responder (static capability params)
  xfcp_target_info_adapter.sv   -- GET_TARGET_INFO responder (static ROM table)
  xfcp_stream_mux.sv            -- N-way stream dispatch (routes sid=0/1 to adapters)
  xfcp_fifo.sv                  -- generic sync FIFO (power-of-2)
  xfcp_fifo_reg.sv              -- 2-entry register-based FIFO
  axis_byte_register_slice.sv   -- 1-beat AXI-Stream byte register slice

  transport/
    xfcp_udp_rx_adapter.sv      -- UDP RX framing -> XFCP byte stream
    xfcp_udp_tx_adapter.sv      -- XFCP byte stream -> UDP TX framing
    udp_xfcp_server.sv          -- complete UDP server (eth stack + adapters)
```

**Nie sú súčasťou tejto knižnice** (demo/test IP, len v examples):
- `axifull_sram.sv` — testovacia SRAM pre MEM backend
- `xfcp_cpu_stub.sv` — demo CPU-side FSM agent (PING/PONG)

Knižničné moduly pre AXI-Lite mailbox: `rtl/axil/axil_cpu_mailbox.sv`

---

## Moduly a ich funkcia

| Modul                     | Funkcia                                                  |
|---------------------------|----------------------------------------------------------|
| `xfcp_pkg`                | Typy, opkódy, status kódy, encode/decode funkcie         |
| `xfcp_rx_parser`          | UART/UDP byte stream → parsed request header + payload   |
| `xfcp_tx_packetizer`      | Response header + payload → UART/UDP byte stream         |
| `xfcp_arbiter_2to1`       | Fair round-robin arbiter pre 2 transporty (UART+UDP)     |
| `xfcp_fabric_endpoint`    | Centrálny router: AXIL/AXIS/CAPS/TI/MEM backendy         |
| `xfcp_axi_engine`         | AXI4-Lite READ/WRITE master (burst, 8 slots)             |
| `xfcp_axis_adapter`       | AXI-Stream loopback FIFO, multi-slot (STREAM_WRITE/READ) |
| `xfcp_mem_adapter`        | AXI4-Full burst master, single-outstanding (MEM_READ/WRITE)|
| `xfcp_caps_adapter`       | GET_CAPS: statické parametre (flags, proto, veľkosti)    |
| `xfcp_target_info_adapter`| GET_TARGET_INFO: ROM tabuľka N targetov                  |
| `xfcp_stream_mux`         | Dispatch stream_id na správny axis_adapter slot          |
| `xfcp_fifo`               | Sync FIFO, parametrizovateľná hĺbka (power-of-2)        |
| `xfcp_fifo_reg`           | 2-entry reg FIFO, nulová latencia pre čítanie            |
| `axis_byte_register_slice`| 1-beat pipeline register pre AXI-Stream                  |
| `udp_xfcp_server`         | Kompletný UDP transport (ETH stack + RX/TX adaptery)     |

---

## Závislostimatrix

| Modul                     | Vyžaduje                                              |
|---------------------------|-------------------------------------------------------|
| `xfcp_fabric_endpoint`    | `axi_pkg`, `xfcp_pkg`, `xfcp_fifo`, `xfcp_fifo_reg` |
| `xfcp_axi_engine`         | `axi_pkg`, `xfcp_pkg`                                |
| `xfcp_mem_adapter`        | `axi_pkg`, `xfcp_pkg`, `xfcp_fifo_reg`              |
| `xfcp_axis_adapter`       | `xfcp_pkg`, `xfcp_fifo_reg`                          |
| `xfcp_stream_mux`         | `xfcp_pkg`                                           |
| `udp_xfcp_server`         | `rtl/eth/` (ETH stack)                               |
| ostatné core              | `xfcp_pkg`                                           |

---

## Protocol overview

```
caps_flags = 0x1F   (AXIL | STREAM | CAPS | TARGETS | MEM)
proto_major = 1
proto_minor = 3
max_stream_bytes = 256
max_mem_bytes    = 256
```

Opcodes: READ (0x10), WRITE (0x11), STREAM_WRITE (0x20), STREAM_READ (0x21),
         MEM_READ (0x30), MEM_WRITE (0x31), GET_CAPS (0x01), GET_TARGET_INFO (0x03).

---

## Odporúčané použitie pre nový projekt

1. Inštanciuj `xfcp_fabric_endpoint` s parametrami pre tvoje AXIL slave zariadenia.
2. Prepoj UART RX/TX na `xfcp_rx_parser` / `xfcp_tx_packetizer`.
3. Pre UDP prepoj `udp_xfcp_server` cez `xfcp_arbiter_2to1`.
4. Pre CPU mailbox pridaj `axil_cpu_mailbox` + vlastný CPU-side agent.

---

## Simulácia a HW Validácia

| Projekt   | TB testy | Transport | HW výsledok | Tag                              |
|-----------|----------|-----------|-------------|----------------------------------|
| test_06   | 12       | UART+UDP  | 21/21       | xfcp_lib_v0_9_status_pass        |
| test_07   | 22       | UART+UDP  | 38/38       | xfcp_lib_v1_1_axis_pass          |
| test_08   | 25       | UART+UDP  | 82/82       | xfcp_lib_v1_2_caps_pass          |
| test_09   | 30       | UART+UDP  | 132/132     | xfcp_lib_v1_3_targets_pass       |
| test_10   | 37       | UART+UDP  | 81/81       | xfcp_lib_v1_4_mem_pass           |
| test_11   | 42       | UART+UDP  | 96/96       | xfcp_lib_v1_5_cpu0_stream_mailbox_pass |
| test_12   | 49       | UART+UDP  | 98/98       | xfcp_lib_v1_6_mailbox_regs_pass  |
| test_13   | 54       | UART+UDP  | 102/102     | **xfcp_lib_v1_7_cpu_stub_pass**  |

Timing (Cyclone IV E, 125 MHz): WNS ≥ +0.081 ns vo všetkých verziách.

---

## Dokumentácia

`docs/xfcp/` obsahuje:
- `protocol.md` — protokol a opkódy
- `backend_axil.md`, `backend_axis.md`, `backend_mem.md`, `backend_mailbox.md`
- `targets.md` — GET_TARGET_INFO register mapa
- `cli.md` — Python CLI klient
- `version.md` — história verzií
- `status.md` — status kódy
