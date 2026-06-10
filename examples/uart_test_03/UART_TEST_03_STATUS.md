# UART_TEST_03 — Stav projektu

**Posledná aktualizácia:** 2026-06-10
**Stav:** Faza 1–3 UZAVRETA — RTL + sim + syntéza PASS

---

## Ciel projektu

UART loopback s FIFO bufferovanim.  Adresuje obmedzenie uart_test_02 kde
1-bajtovy buffer sposoboval overrun pri bulk prenose (Python `write(64)`).

Hardver: QMTech EP4CE55, 50 MHz board clock -> 125 MHz cez `clkpll` PLL.

---

## Prehľad Faz

| Faza | Popis                          | Stav         |
|------|--------------------------------|--------------|
| 1    | RTL + projekt setup            | UZAVRETA     |
| 2    | Simulacia                      | UZAVRETA     |
| 3    | HW synteza + timing closure    | UZAVRETA     |
| 4    | HW board test                  | TODO         |

---

## Faza 1 — RTL + projekt setup (UZAVRETA)

### Nove moduly

| Subor                        | Popis                                          |
|------------------------------|------------------------------------------------|
| `rtl/uart/sync_fifo.sv`      | Genericky synchronny FIFO (power-of-2 depth)  |
| `rtl/uart/uart_fifo.sv`      | UART wrapper s RX a TX sync_fifo instaciami   |
| `rtl/uart_test_03_top.sv`    | Top-level: uart_fifo + uart_stream_loopback_status |

### Zdedene moduly (z uart_test_02, bez zmeny)

- `uart_pkg.sv`, `uart_baud_gen.sv`, `uart_core_rx.sv`, `uart_core_tx.sv`, `uart.sv`
- `uart_stream_loopback_status.sv`

### Architektura

```
Serial RX -> uart_core_rx -> RX FIFO (64B) -> uart_stream_loopback_status
                                               |
Serial TX <- uart_core_tx <- TX FIFO (64B) <--+
```

`uart_stream_loopback_status` je 1-bajtovy elastic buffer medzi FIFO vystupom
a TX FIFO vstupom — zabezpecuje flow control a LED status (pulse stretch, heartbeat,
error latch).

### Klucove technicky poznamky

- `sync_fifo`: AXI-Stream kompatibilne rozhranie, held-valid na RX strane
- `uart_fifo`: RX FIFO back-pressure propaguje do uart_core_rx (overrun iba ak
  RX FIFO plny A novy frame dokonceny)
- LED mapovanie: rovnake ako uart_test_02 (LED[0]=rx_pulse, [1]=tx_pulse,
  [2]=rx_busy, [3]=tx_busy, [4]=error_latch, [5]=heartbeat)

---

## Faza 2 — Simulacia (UZAVRETA)

### Vysledky

Regression: PASS, 0 FAIL.
- tb_sync_fifo: 22 PASS lines (F01-F07)
- tb_uart_fifo_loopback: 1191 PASS lines (T01-T05, vrátane 512-byte LFSR)

### Testy

**tb_sync_fifo (unit):**

| #   | Test                                          |
|-----|-----------------------------------------------|
| F01 | empty after reset: rd_valid=0, level=0        |
| F02 | write one byte: rd_valid=1, level=1           |
| F03 | read byte back: data correct, empty           |
| F04 | write until full: full=1, wr_ready=0          |
| F05 | simultaneous write+read: level unchanged      |
| F06 | drain full FIFO: empty after drain            |
| F07 | overflow attempt: level unchanged, no corruption |

**tb_uart_fifo_loopback (integration):**

| #   | Test                                                     |
|-----|----------------------------------------------------------|
| T01 | single byte echo: 0x55                                   |
| T02 | burst 16 bytes back-to-back (overflowed uart_test_02)    |
| T03 | burst 64 bytes back-to-back (4x FIFO depth)              |
| T04 | frame error recovery                                     |
| T05 | 512-byte LFSR stream (seed=0xA5), sequential echo        |

---

---

## Faza 3 — HW synteza (UZAVRETA)

Quartus Prime 25.1 Lite. Fitter warning: `sync_fifo.mem_q` inferovany ako M9K RAM (64x8, s pass-through logikou) — ocakavane spravanie.

### Timing closure

| Model            | WNS setup | WNS hold | Fmax      |
|------------------|-----------|----------|-----------|
| Slow 85C 1200mV  | +1.568 ns | +0.429 ns| 155.47 MHz|
| Slow  0C 1200mV  | +2.044 ns | +0.379 ns| —         |
| Fast  0C 1200mV  | +5.279 ns | —        | 167.9 MHz |

**Constraint: 125 MHz (8 ns), margin: +1.568 ns (20%)**

Poznamka: WNS nizsie nez v uart_test_02 (+2.529 ns) kvoli RAM pass-through logike pridanej Quartusom pre sync_fifo. Timing stale PASS s dostatocnou rezervou.

### Resource usage

| Metrika               | uart_test_02 | uart_test_03 | Delta  |
|-----------------------|--------------|--------------|--------|
| Logic elements (est.) | 232          | 372          | +140   |
| Registers             | 165          | 263          | +98    |
| Memory bits           | 0            | 1024         | +1024  |
| Pins                  | 10           | 10           | 0      |

1024 memory bits = 2x sync_fifo 64x8 inferovane do M9K blokov.

---

## Poznamky

- Bulk HW test: Python `loopback_bulk()` -- ziadny sequential workaround
- HW_COUNT default: 256 bajtov (vs 64 v uart_test_02)
- Oversampling (16x) a uart_axil.sv planovane pre uart_test_04
