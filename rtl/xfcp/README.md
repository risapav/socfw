# socfw/rtl/xfcp — XFCP RTL Library

Reusable SystemVerilog moduly pre XFCP v1.3+MEM protokol na Cyclone IV E
(QMTech EP4CE55). Overené v HW: UART 81/81, UDP 81/81 PASS.

Pôvod: `examples/xfcp_test_10_axifull`, commit `755cc2e`.
Verzia: `xfcp_lib_v1_4_mem_pass`

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
  xfcp_axis_adapter.sv          -- AXI-Stream adapter (STREAM_WRITE/READ)
  xfcp_mem_adapter.sv           -- AXI4-Full master engine (MEM_READ/MEM_WRITE)
  xfcp_caps_adapter.sv          -- GET_CAPS responder (static params)
  xfcp_target_info_adapter.sv   -- GET_TARGET_INFO responder (static ROM table)
  xfcp_fifo.sv                  -- generic sync FIFO (power-of-2)
  xfcp_fifo_reg.sv              -- 2-entry register-based FIFO
  axis_byte_register_slice.sv   -- 1-beat AXI-Stream byte register slice

  transport/
    xfcp_udp_rx_adapter.sv      -- UDP RX framing -> XFCP byte stream
    xfcp_udp_tx_adapter.sv      -- XFCP byte stream -> UDP TX framing
    udp_xfcp_server.sv          -- complete UDP server (eth stack + adapters)

Poznamka: axifull_sram.sv NIE JE sucastou tejto kniznice.
Je to demo/test IP specificke pre examples/xfcp_test_10_axifull/rtl/.
Pouzivatel si pre MEM backend dodava vlastny AXI4-Full slave.
```

---

## Odporúčané použitie

| Pouzitie                      | Top modul               |
|-------------------------------|-------------------------|
| UART + UDP transport          | `xfcp_fabric_endpoint`  |
| Len UART (bez ETH stacku)     | `xfcp_fabric_endpoint` + priamy byte stream |
| UDP server                    | `udp_xfcp_server`       |

Pre nový projekt:
1. Inštanciuj `xfcp_fabric_endpoint` s parametrami pre tvoje AXIL slave zariadenia
2. Prepoj UART RX/TX na `xfcp_rx_parser` / `xfcp_tx_packetizer`
3. Pre UDP prepoj `udp_xfcp_server` a `xfcp_arbiter_2to1`

---

## Závislosti

| Modul                    | Vyžaduje                       |
|--------------------------|--------------------------------|
| xfcp_fabric_endpoint     | axi_pkg, xfcp_pkg              |
| xfcp_axi_engine          | axi_pkg, xfcp_pkg              |
| xfcp_mem_adapter         | xfcp_pkg                       |
| udp_xfcp_server          | rtl/eth/ (ETH stack)           |
| xfcp_arbiter_2to1        | xfcp_pkg                       |
| ostatné                  | xfcp_pkg                       |

---

## Simulácia

| Testbench                   | Testy  | Výsledok |
|-----------------------------|--------|----------|
| tb_xfcp_test_10_axifull_top | T01–T37| PASS     |

---

## HW Validácia (QMTech EP4CE55, 125 MHz)

| Transport | Testy | Výsledok |
|-----------|-------|----------|
| UART      | 81/81 | PASS     |
| UDP       | 81/81 | PASS     |

---

## Dokumentácia

Podrobná dokumentácia protokolu a backendov: `docs/xfcp/`
