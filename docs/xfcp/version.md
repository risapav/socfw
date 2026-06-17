# XFCP Library — Version History

---

## v1.6 — `xfcp_lib_v1_6_mailbox_regs_pass` (2026-06-17)

**Tag:** `xfcp_lib_v1_6_mailbox_regs_pass` @ commit `9fe2a97`
**Projekt:** `examples/xfcp_test_12_cpu_mailbox_regs`

### Nové funkcie

- `axil_cpu_mailbox.sv` — CPU-facing AXI-Lite mailbox s RX/TX FIFO (DEPTH=256)
- `xfcp_stream_mux.sv` — 2-port stream_id dispatcher (sid=0 STR0 / sid=1 CPU0)
- `GET_TARGET_INFO` index 10 = CPUM AXIL 0xFF070000 max=128B
- `GET_CAPS`: `num_axil_slots=8`, `num_stream_slots=2`
- CPUM AXI-Lite register mapa (0xFF070000):
  - 0x00 ID=0x4350554D (RO)
  - 0x04 CTRL [0]=rx_flush [1]=tx_flush
  - 0x08 STATUS [0]=rx_not_empty [1]=rx_full [2]=tx_not_empty [3]=tx_full
  - 0x10 RX_LEVEL / 0x14 TX_LEVEL (RO)
  - 0x18 RX_POP_DATA: read=pop; [7:0]=data [8]=tlast [10]=underflow
  - 0x1C TX_PUSH_DATA: write=push; [7:0]=data [8]=tlast
- Python: `test_hw.py --cpum` (ID, TX_PUSH→STREAM_READ, STREAM_WRITE→RX_POP, flush)
- `xfcp_mem_adapter.sv` fix: manualne rfifo pole nahradene `xfcp_fifo_reg` instaciou
  (eliminuje Quartus Warning 276020 — M9K read-during-write bypass combinatorial path)

### Timing (Cyclone IV E, SEED 5)

```
CLK125 WNS:  +0.252 ns
ETH_RXC WNS: +0.345 ns
TNS:         0.000
```

### HW Validation (2026-06-17)

```
UART: 98/98 PASS  rx_lost/rx_frame/rx_overrun/rx_bad_hdr/rx_drop = 0
UDP:  98/98 PASS  rx_lost/rx_frame/rx_overrun/rx_bad_hdr/rx_drop = 0
```

---

## v1.5 — `xfcp_lib_v1_5_cpu0_stream_mailbox_pass` (2026-06-16)

**Tag:** `xfcp_lib_v1_5_cpu0_stream_mailbox_pass` @ commit (xfcp_test_11)
**Projekt:** `examples/xfcp_test_11_cpu_mailbox`

### Nové funkcie

- `xfcp_axis_adapter` rozšírený na 2 STREAM sloty (sid=0 STR0, sid=1 CPU0)
- `GET_TARGET_INFO` index 9 = CPU0 STREAM (stream_id=1)
- `GET_CAPS`: `num_stream_slots=2`
- CPU0 sid=1 ako independent stream endpoint (loopback FIFO 256B)

### Timing (Cyclone IV E, SEED 5)

```
CLK125 WNS:  +0.081 ns
ETH_RXC WNS: +0.345 ns
```

### HW Validation

```
UART: 96/96 PASS
UDP:  96/96 PASS
```

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

## v1.7 — `xfcp_lib_v1_7_cpu_stub_pass` (2026-06-17)

**Tag:** `xfcp_lib_v1_7_cpu_stub_pass` @ commit `af902a8`
**Projekt:** `examples/xfcp_test_13_cpu_softcore_stub`

### Nové funkcie

- `xfcp_cpu_stub.sv` — CPU-side FSM agent (4 stavy: ST_IDLE/ST_RX/ST_PROC/ST_TX)
  - PING (4B) → PONG (4B)
  - ľubovoľný iný payload → ERR\n (4B), MAX_CMD_BYTES=8
- `axil_cpu_mailbox.sv` rozšírený o native CPU porty:
  - `cpu_rx_valid_o`, `cpu_rx_pop_i`, `cpu_rx_data_o[8:0]` — čítanie z RX FIFO
  - `cpu_tx_ready_o`, `cpu_tx_push_i`, `cpu_tx_data_i[8:0]` — zápis do TX FIFO
  - CPU má prioritu pred AXI-Lite pri simultánnom prístupe
- Python: `test_hw.py --stub` (PING→PONG, ABCD→ERR\n, N×PING)
- `run_cpum_regs_test()` adaptovaný: po STREAM_WRITE sid=1 sa overuje RX_LEVEL==0
  (stub konzumuje okamžite), nie RX_POP_DATA

### Timing (Cyclone IV E, SEED 7)

```
CLK125 WNS:  +0.241 ns
ETH_RXC WNS: +0.345 ns
TNS:         0.000
Resources:   38657 LE, 23675 reg, 61248 memory bits
```

### HW Validation (2026-06-17)

```
UART: 102/102 PASS  rx_lost/rx_frame/rx_overrun/rx_bad_hdr/rx_drop = 0
UDP:  102/102 PASS  rx_lost/rx_frame/rx_overrun/rx_bad_hdr/rx_drop = 0
```

---

## Plánované (future)

```
v1.8 — kniznicna konsolidacia (xfcp_lib_core_cleanup)
         jeden zdroj pravdy pre RTL: rtl/xfcp/ (aktualne)
         jeden zdroj pravdy pre Python klienta: tools/xfcp/
         aktualne docs, minimum warningov, manifest/ip.yaml
```
