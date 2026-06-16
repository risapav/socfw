# XFCP_TEST_11_CPU_MAILBOX — Status

## Aktuálny stav: **UZAVRETÝ** — Sim + Timing + HW PASS

**Protokol:** XFCP v1.3+MEM+MAILBOX

---

## Prehľad

Rozšírenie xfcp_test_10_axifull o 2-way stream mux:
- `stream_id=0` (STR0): loopback FIFO 256B — zachované
- `stream_id=1` (CPU0): CPU mailbox loopback FIFO 256B — nový
- `GET_CAPS`: `num_stream=2` (bolo 1)
- `GET_TARGET_INFO`: index 9 = CPU0 STREAM base=0x00000001 (sid=1)

> **Pozn.:** CPU0 v tomto míľniku NIE JE pripojené CPU jadro.
> Je to druhý STREAM endpoint s loopback FIFO — mailbox transport layer,
> pripravený pre budúce reálne CPU-side registre/FIFO (test_12).

Kľúčový nový modul: `xfcp_stream_mux` — 2-way combinational dispatch.

---

## RTL súbory (lokálne)

| Súbor | Popis |
|-------|-------|
| `rtl/xfcp_test_11_cpu_mailbox_top.sv` | Top-level modul |
| `rtl/xfcp/xfcp_stream_mux.sv` | 2-way stream mux (nový) |
| `rtl/axifull_sram.sv` | AXI4-Full SRAM (skopírovaný z test_10) |
| `rtl/cdc/async_fifo.sv` | CDC async FIFO (skopírovaný z test_10) |

Zdieľané RTL z `../../rtl/xfcp/`:
- `xfcp_axis_adapter.sv` — parameter `STREAM_ID` pridaný (default=0, backward-compatible)

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

## GET_CAPS response

```
proto_major=1  proto_minor=3
num_axil=7     num_stream=2
max_stream=256  stream_align=4
caps_flags=0x1F (AXIL|STREAM|CAPS|TARGETS|MEM)
```

## GET_TARGET_INFO tabuľka (10 záznamov)

| Index | Typ | Adresa/SID | Max | Meno |
|-------|-----|-----------|-----|------|
| 0 | AXIL | 0xFF000000 | 128B | SYSC |
| 1 | AXIL | 0xFF010000 | 128B | UART |
| 2 | AXIL | 0xFF020000 | 128B | OUT_ |
| 3 | AXIL | 0xFF030000 | 128B | OUT_ |
| 4 | AXIL | 0xFF040000 | 128B | OUT_ |
| 5 | AXIL | 0xFF050000 | 128B | SEG7 |
| 6 | AXIL | 0xFF060000 | 128B | DIAG |
| 7 | STREAM | sid=0 | 256B | STR0 |
| 8 | MEM | 0x00000000 | 256B | MEM0 |
| 9 | STREAM | sid=1 | 256B | CPU0 |

---

## xfcp_stream_mux — Design notes

```
fab_req/wdata/rdata/resp
        |
  xfcp_stream_mux (sel_w = req_hdr.addr[7:0] == 1)
        |              |
   adapter[0]     adapter[1]
  (STREAM_ID=0)  (STREAM_ID=1)
  loopback FIFO  CPU0 FIFO
```

**Bug fix (2026-06-16):** `fab_resp_status_o` musí používať `active_q` (nie `a0_resp_done_i`)
ako selektor, lebo fabric endpoint číta status 1 cyklus PO `resp_done`.
Opravené: `assign fab_resp_status_o = active_q ? a1_resp_status_i : a0_resp_status_i;`

---

## Simulácia

| Fáza | Výsledok |
|------|---------|
| unit: xfcp_arbiter_2to1 | PASS |
| unit: udp_xfcp_server | PASS |
| integration T01-T42 | **PASS (42/42)** |
| REGRESSION | **PASSED** |

### Kľúčové testy

- T13-T15: STR0 loopback 4/16/64B — PASS
- T16: STREAM_READ count=0 → BAD_LENGTH — PASS
- T17-T18: CPU0 loopback 4/16B — PASS
- T20: STR0 256B max — PASS
- T21-T22: ETH-UDP STREAM 256B — PASS
- T23-T25: GET_CAPS num_stream=2 — PASS
- T28: GET_TARGET_INFO STR0 — PASS
- T29: GET_TARGET_INFO index=10 → BAD_ADDRESS — PASS
- T38: CPU0 256B max loopback — PASS
- T39: GET_TARGET_INFO CPU0 (sid=1) — PASS
- T40: STREAM_WRITE sid=2 → UNSUPPORTED — PASS
- T41: STREAM_READ sid=2 → UNSUPPORTED — PASS
- T42: Alternating STR0/CPU0 isolation — PASS

---

## HW build

| Parameter | Hodnota |
|-----------|---------|
| SEED | 5 |
| WNS CLK125 (85C) | +0.081 ns |
| WNS ETH_RXC (85C) | +0.712 ns |
| Logic elements | 27,236 / 55,856 (49%) |
| Registers | 21,310 |
| Memory bits | 58,880 / 2,396,160 (2%) |
| Bitfile | `output_files/soc_top.sof` |

---

## Fázy vývoja

| Fáza | Popis | Stav |
|------|-------|------|
| Fáza A | xfcp_stream_mux + 2x adapter + top RTL | DONE |
| Fáza B | Sim T01-T42 regression PASS | **DONE 2026-06-16** |
| Fáza C | Quartus build + timing closure | **DONE 2026-06-16** |
| Fáza D | HW regression UART+UDP | **DONE 2026-06-16** |
