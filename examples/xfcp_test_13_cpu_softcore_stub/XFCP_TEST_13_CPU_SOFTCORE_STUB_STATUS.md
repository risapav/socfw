# XFCP_TEST_13_CPU_SOFTCORE_STUB — Status

## Aktuálny stav: **UZAVRETÝ — HW UART+UDP 102/102 PASS**

**Tag:** `xfcp_lib_v1_7_cpu_stub_pass` @ af902a8  
**Protokol:** XFCP v1.3+MEM+MAILBOX+CPU_STUB

---

## Prehľad

Rozšírenie xfcp_test_12 o aktívny CPU-side agent (`xfcp_cpu_stub`).
Demonštruje bidirektcionálny mailbox tok kde CPU-side FSM číta XFCP príkazy
a generuje odpovede — bez AXI-Lite zásahu hosta.

**Kľúčový rozdiel oproti test_12:**

| test_12 (pasívny mailbox) | test_13 (aktívny CPU stub) |
|---------------------------|---------------------------|
| host zapíše do RX FIFO | host zapíše do RX FIFO |
| dáta ostanú v RX FIFO | CPU stub ich okamžite spotrebuje |
| host číta cez RX_POP_DATA | CPU stub vygeneruje odpoveď do TX FIFO |
| žiadna automatická odpoveď | host číta PONG/ERR\n cez STREAM_READ |

---

## Nové RTL moduly

### `xfcp_cpu_stub.sv` (lokálny, demo/test IP)

4-stavový FSM (ST_IDLE → ST_RX → ST_PROC → ST_TX):

```
PING (4B "PING") → PONG (4B "PONG")
iný payload      → ERR\n (4B)
MAX_CMD_BYTES=8  → dlhší payload → ERR\n
```

Používa native CPU porty `axil_cpu_mailbox` (nie AXI-Lite registre).

### `axil_cpu_mailbox.sv` — native CPU porty (pridané v test_13)

| Port | Smer | Popis |
|------|------|-------|
| `cpu_rx_valid_o` | O | RX FIFO má dáta |
| `cpu_rx_data_o[8:0]` | O | {tlast, data[7:0]} |
| `cpu_rx_pop_i` | I | pop strobe (len keď valid=1) |
| `cpu_tx_ready_o` | O | TX FIFO má miesto |
| `cpu_tx_data_i[8:0]` | I | {tlast, data[7:0]} |
| `cpu_tx_push_i` | I | push strobe (len keď ready=1) |

**Priorita:** CPU porty majú prednosť pred AXI-Lite pri súčasnom prístupe:
```sv
wire axil_rx_pop_w = (rd_state_q == RD_LATCH) && (ar_addr_q == ADDR_RX_POP) && !cpu_rx_pop_i;
wire axil_tx_push_w = ... && !cpu_tx_push_i;
```

---

## Architektonická mapa

```
UART/UDP → xfcp_rx_parser
               ↓
         xfcp_fabric_endpoint
          ├── xfcp_axi_engine  (AXIL 8 slotov)
          │    └── axil_cpu_mailbox @ 0xFF070000 (CPUM)
          ├── xfcp_stream_mux
          │    ├── xfcp_axis_adapter (sid=0 STR0 loopback)
          │    └── xfcp_axis_adapter (sid=1 → axil_cpu_mailbox.s_axis/m_axis)
          │                               ↑↓ native CPU porty
          │                          xfcp_cpu_stub (FSM)
          ├── xfcp_mem_adapter (MEM @ 0x0)
          ├── xfcp_caps_adapter
          └── xfcp_target_info_adapter
               ↓
         xfcp_tx_packetizer → UART/UDP
```

---

## AXI-Lite mapa (stride 0x10000)

| Slot | Adresa | Modul |
|------|--------|-------|
| 0 | 0xFF000000 | axil_sys_ctrl |
| 1 | 0xFF010000 | axil_uart_adapter |
| 2 | 0xFF020000 | axil_regs (LED 6-bit) |
| 3 | 0xFF030000 | axil_regs (PMOD J10) |
| 4 | 0xFF040000 | axil_regs (PMOD J11) |
| 5 | 0xFF050000 | axil_seven_seg_adapter |
| 6 | 0xFF060000 | axil_diag_ctrl |
| 7 | 0xFF070000 | axil_cpu_mailbox (CPUM) |

---

## Simulácia

| Fáza | Výsledok |
|------|---------|
| unit: xfcp_arbiter_2to1 | PASS |
| unit: udp_xfcp_server | PASS |
| integration T01-T54 | **PASS (0 failures)** |
| REGRESSION | **PASSED 2026-06-17** |

### Testy T01–T54

| Rozsah | Obsah |
|--------|-------|
| T01–T17 | Základný PING, AXIL READ/WRITE regresia |
| T18 | STREAM_WRITE sid=1 → RX_LEVEL==0 (stub spotreboval) + TX ERR\n |
| T19–T37 | READ/WRITE/STATUS/CAPS/TARGETS regresia |
| T38 | TX flush pred AXIL priamym testom |
| T39–T43 | MEM/AXIL regresia |
| T44 | STREAM_WRITE 256B → ERR\n (MAX_CMD_BYTES=8 limit) |
| T45–T49 | CPUM register sanity (stub-aware: RX_LEVEL==0 po write) |
| T50 | PING → PONG (1×) |
| T51 | ABCD → ERR\n (1×) |
| T52 | PING × 4 (loop) |
| T53 | STR0 izolácia (sid=0 neovplyvnený stubom na sid=1) |
| T54 | 8B "PING"+padding → ERR\n (MAX_CMD_BYTES limit) |

### Kľúčové adaptácie TB oproti test_12

- T18/T44/T46/T48: po STREAM_WRITE sid=1 → overuj `RX_LEVEL==0` (nie ==N)
- T38: `tx_flush` pred AXIL TX_PUSH_DATA testom (stub mohol naplniť TX FIFO)
- T45–T49: stub-aware sanity — neoverujú pôvodné FIFO dáta cez AXI-Lite pop

---

## HW build — Timing Closure

| Koreň | Slack |
|-------|-------|
| CLK125 Slow 85°C | **+0.241 ns** ✅ |
| ETH_RXC Slow 85°C | +0.345 ns ✅ |

SEED=7, Resources: 38657 LE, 23675 reg, 61248 memory bits.

---

## HW Validácia (2026-06-17)

```
make test-uart  →  UART  102/102 PASS
make test-udp   →  UDP   102/102 PASS
```

`--caps --targets --rw --stream --cpum --stub --mem --diag --repeat 3`

Žiadne rx_lost / rx_frame / rx_bad_hdr / rx_drop chyby.

---

## Python test_hw.py — stub-aware zmeny

| Funkcia | Zmena |
|---------|-------|
| `run_stub_test()` | `stream_write(PING, stream_id=1)` / `stream_read(len(PONG), stream_id=1)` — opravené poradie argumentov |
| `run_cpum_regs_test()` | RX path: verifikuje `RX_LEVEL==0` (stub spotreboval), drainuje ERR\n cez CTRL tx_flush |

---

## Fázy vývoja

| Fáza | Popis | Stav |
|------|-------|------|
| Fáza 1 | RTL: xfcp_cpu_stub + native CPU porty do axil_cpu_mailbox | **DONE 2026-06-17** |
| Fáza 2 | TB adaptácia T18/T38/T44/T46/T48 pre aktívny stub | **DONE 2026-06-17** |
| Fáza 3 | Sim T01-T54 REGRESSION PASS | **DONE 2026-06-17** |
| Fáza 4 | Timing closure SEED=7 WNS +0.241 ns | **DONE 2026-06-17** |
| Fáza 5 | HW UART+UDP 102/102 PASS | **DONE 2026-06-17** |
| Fáza C | Konsolidácia: README, tools/xfcp root, RTL warning fix | **DONE 2026-06-17** |
