# XFCP_TEST_12_CPU_MAILBOX_REGS — Status

## Aktuálny stav: **FÁZA D — HW REGRESSION PENDING**

**Protokol:** XFCP v1.3+MEM+MAILBOX+CPUM_REGS

---

## Prehľad

Rozšírenie xfcp_test_11 o `axil_cpu_mailbox` — skutočný bidirektcný mailbox
s AXI-Lite registrovým rozhraním pre CPU:
- `stream_id=1` (CPU0): místo loopback FIFO → `axil_cpu_mailbox.s_axis/m_axis`
- `axil_cpu_mailbox` namapovaný na slot 7 @ `0xFF070000`
- `NUM_SLAVES=8`, `NUM_TARGETS=11`, `GET_CAPS num_axil=8`
- `GET_TARGET_INFO` index 10 = CPUM AXIL 0xFF070000 max=128B

### AXI-Lite mapa (stride 0x10000)

| Slot | Adresa | Modul |
|------|--------|-------|
| 0 | 0xFF000000 | axil_sys_ctrl |
| 1 | 0xFF010000 | axil_uart_adapter |
| 2 | 0xFF020000 | axil_regs (LED 6-bit) |
| 3 | 0xFF030000 | axil_regs (PMOD J10) |
| 4 | 0xFF040000 | axil_regs (PMOD J11) |
| 5 | 0xFF050000 | axil_seven_seg_adapter |
| 6 | 0xFF060000 | axil_diag_ctrl |
| 7 | 0xFF070000 | **axil_cpu_mailbox (NOVÝ)** |

### axil_cpu_mailbox register mapa (0xFF070000)

| Offset | Reg | Prístup | Popis |
|--------|-----|---------|-------|
| 0x00 | ID | RO | 0x4350554D ("CPUM") |
| 0x04 | CTRL | RW | [0]=rx_flush, [1]=tx_flush (single-cycle pulse) |
| 0x08 | STATUS | RO | [0]=rx_not_empty, [1]=rx_full, [2]=tx_not_empty, [3]=tx_full |
| 0x0C | IRQ_EN | RW | reserved |
| 0x10 | RX_LEVEL | RO | počet slov v RX FIFO |
| 0x14 | TX_LEVEL | RO | počet slov v TX FIFO |
| 0x18 | RX_POP_DATA | RO* | read=pop; [7:0]=data, [8]=tlast, [10]=underflow |
| 0x1C | TX_PUSH_DATA | WO* | write=push; [7:0]=data, [8]=tlast |

---

## RTL súbory

| Súbor | Popis |
|-------|-------|
| `rtl/axil_cpu_mailbox.sv` | Nový mailbox modul (AXI-Lite + 2× xfcp_fifo_reg) |
| `rtl/xfcp/xfcp_mem_adapter.sv` | AXI4-Full mem adapter (lokálna kópia — xfcp_fifo_reg fix) |
| `../../rtl/xfcp/xfcp_fifo_reg.sv` | Register-based FIFO (M9K, DEPTH=256) |

---

## Simulácia

| Fáza | Výsledok |
|------|---------|
| unit: xfcp_arbiter_2to1 | PASS |
| unit: udp_xfcp_server | PASS |
| integration T01-T49 | **PASS (49/49)** |
| REGRESSION | **PASSED 2026-06-17** |

### Kľúčové nové testy (T40-T49)

- T40: CPUM ID read 0x4350554D — PASS
- T41: STATUS bits — PASS
- T42: CTRL rx_flush — PASS
- T43: GET_TARGET_INFO CPUM — PASS
- T44: STREAM_WRITE 256B → RX_LEVEL==256 → rx_flush — PASS
- T45: TX_PUSH_DATA 4B → STATUS tx_not_empty → STREAM_READ — PASS
- T46: STREAM_WRITE 8B sid=1 → RX_POP_DATA x8 + tlast — PASS
- T47: RX underflow bit[10]==1 when empty — PASS
- T48: STATUS sanity + rx_flush — PASS
- T49: TX_PUSH_DATA → tx_flush → TX_LEVEL==0 — PASS

### RTL opravy (2026-06-17)

- `axil_cpu_mailbox.sv`: bit-concat chyba — ADDR_RX_POP mux bol 31-bitový (21+1+1+8),
  underflow bol na bit[9] namiesto bit[10]. Opravené pridaním `1'b0` pre bit[9].
- `rtl/xfcp/xfcp_mem_adapter.sv` (lokálna kópia): nahradenie manuálneho RFIFO poľa
  za `xfcp_fifo_reg` — eliminovalo Quartus Warning 276020 (M9K bypass path).

---

## HW build — TIMING CLOSURE

### Stav (2026-06-17, SEED=5, build #4)

| Koreň | Slack |
|-------|-------|
| CLK125 Slow 85°C | **+0.252 ns** ✅ |
| ETH_RXC Slow 85°C | +0.345 ns ✅ |

### Riešenie timing problému

**Pôvodný problém (build #3, WNS -0.220 ns):**
Quartus Warning 276020 — kombinačná cesta cez M9K read-during-write bypass mux:
`xfcp_mem_adapter|altsyncram:rfifo_data_q_rtl_0|portb_address_reg0 → rdata_r[26]`

**Riešenie:** nahradenie manuálneho RFIFO poľa (`logic [31:0] rfifo_data_q[64]`) za
`xfcp_fifo_reg` inštanciu — registrovaný výstup z M9K eliminuje bypass cestu.
Warning 276020 zmizol, WNS prešlo z -0.220 ns na +0.252 ns.

---

## Fázy vývoja

| Fáza | Popis | Stav |
|------|-------|------|
| Fáza A | axil_cpu_mailbox RTL | **DONE 2026-06-16** |
| Fáza B | Sim T01-T44 regression PASS | **DONE 2026-06-16** |
| Fáza C | Quartus timing closure WNS +0.252 ns | **DONE 2026-06-17** |
| Fáza D | Sim T01-T49 regression PASS | **DONE 2026-06-17** |
| Fáza E | HW regression UART+UDP | **PENDING** |
