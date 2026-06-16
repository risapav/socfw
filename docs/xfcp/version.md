# XFCP Library — Version History

---

## v1.4 — `xfcp_lib_v1_4_mem_pass` (2026-06-16)

**Tag:** `xfcp_lib_v1_4_mem_pass` @ commit `755cc2e`  
**Projekt:** `examples/xfcp_test_10_axifull`

### Nové funkcie

- `MEM_READ` (0x30) / `MEM_WRITE` (0x31) opcodes — AXI4-Full burst backend
- `RESP_MEM_READ` (0x32) / `RESP_MEM_WRITE` (0x33) responses
- `xfcp_mem_adapter.sv` — single-outstanding AXI4-Full master (INCR, 32b, max 256 B)
- `axifull_sram.sv` — 256×32b SRAM, 4 byte-lane M9K bloky (test_ip, nie core)
- `GET_CAPS` rozšírený: `caps_flags` bit4 = `HAS_MEM`
- `GET_TARGET_INFO` rozšírený: type `0x03` = MEM
- Python: `bus.mem_read()`, `bus.mem_write()`, `protocol.py` MEM opkódy
- `xfcp_cli.py` — kompletný CLI klient (ping/caps/targets/read32/write32/read/write/mem-read/mem-write/stream-read/stream-write)
- RTL exportovaný do `rtl/xfcp/` (16 SV súborov), dokumentácia v `docs/xfcp/` (8 súborov)

### Opravené bugy

1. `xfcp_arbiter_2to1.sv`: `p0_is_write_w` nezahŕňal `XFCP_OP_MEM_WRITE`
2. `xfcp_fabric_endpoint.sv`: `write_data_valid` chybalo `&&!wdata_stage_is_mem_r`
3. `xfcp_mem_adapter.sv`: rfifo deadlock (2→64 entries)
4. `xfcp_mem_adapter.sv`: ST_AW_W timeout bežal aj pri čakaní na UART payload
5. `axifull_sram.sv`: LUT mux namiesto M9K — fix: 4 byte-lane dedikované `always_ff`

### Timing (Cyclone IV E, SEED 10)

```
CLK125 WNS: +0.327 ns
ETH_RXC WNS: +0.870 ns
Fmax: 130.33 MHz
TNS: 0.000
```

### Protokol

```
proto_major = 1
proto_minor = 3
caps_flags  = 0x1F  (AXIL | STREAM | CAPS | TARGETS | MEM)
```

---

## v1.3 — `xfcp_lib_v1_3_targets_pass` (2026-06-14)

**Tag:** `xfcp_lib_v1_3_targets_pass`  
**Projekt:** `examples/xfcp_test_09_targets`

- `GET_TARGET_INFO` (0x03) — statická ROM tabuľka N targetov
- `xfcp_target_info_adapter.sv`
- Target types: AXIL (0x01), STREAM (0x02)
- `caps_flags` bit3 = `HAS_TARGETS`
- Python: `bus.get_target_info()`, `bus.list_targets()`
- HW: 132/132 PASS (UART+UDP)

---

## v1.2 — `xfcp_lib_v1_2_caps_pass` (2026-06-14)

**Tag:** `xfcp_lib_v1_2_caps_pass`  
**Projekt:** `examples/xfcp_test_08_caps`

- `GET_CAPS` (0x01) — statická odpoveď s parametrami FPGA
- `xfcp_caps_adapter.sv`
- `caps_flags` bits: `HAS_AXIL` (0) | `HAS_STREAM` (1) | `HAS_CAPS` (2)
- Python: `bus.get_caps()`
- HW: 82/82 PASS (UART+UDP)

---

## v1.1 — `xfcp_lib_v1_1_axis_pass` (2026-06-14)

**Tag:** `xfcp_lib_v1_1_axis_pass`  
**Projekt:** `examples/xfcp_test_07_axis`

- `STREAM_WRITE` (0x20) / `STREAM_READ` (0x21) opcodes
- `xfcp_axis_adapter.sv` — AXI-Stream loopback
- Python: `bus.stream_write()`, `bus.stream_read()`
- HW: 38/38 PASS (UART+UDP)

---

## v0.9 — `xfcp_lib_v0_9_status_pass` (2026-06-13)

**Tag:** (interný míľnik)  
**Projekt:** `examples/xfcp_test_06`

- XFCP v0.9+STATUS: 4-bajtový response header (SOP+TYPE+SEQ+STATUS)
- `READ` (0x10) / `WRITE` (0x11) — AXI-Lite burst backend
- `xfcp_axi_engine.sv`, `xfcp_fabric_endpoint.sv`
- STATUS kódy: OK, BAD_OPCODE, BAD_LENGTH, BAD_ADDRESS, AXI_SLVERR, AXI_DECERR, TIMEOUT
- Python: `bus.read32()`, `bus.write32()`, `bus.read_block()`, `bus.write_block()`
- UART + UDP transport
- HW: 21/21 PASS

---

## Plánované (future)

```
v1.5 — CPU mailbox (xfcp_test_11_cpu_mailbox)
         STREAM slot 1 = CPU mailbox input/output
         IRQ/event flag pre CPU
```
