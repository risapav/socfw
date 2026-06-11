# UART_TEST_05_AXIL -- Stav projektu

**Posledna aktualizacia:** 2026-06-11
**Stav:** UZAVRETY -- sim 1186/1186 PASS, Fmax ~140.3 MHz, HW 256/256 PASS

---

## Ciel projektu

Syntetizovany priklad `uart_axil.sv` ako AXI-Lite UART periféria.

V `uart_test_04` bol `uart_axil.sv` overeny iba unit simulaciou (TB priamo
na AXI-Lite zbernici). V `uart_test_05_axil` sa `uart_axil` instanciuje
v syntéznom top-leveli a komunikacia prebieha cez interny AXI-Lite master
(`axil_uart_loopback`) — overenie end-to-end cesty cez registre.

---

## Architektura

```
UART RX  -->  uart_axil (RX FIFO)  -->  axil_uart_loopback  -->  uart_axil (TX FIFO)  -->  UART TX
                                     |                        |
                              AXI-Lite read               AXI-Lite write
                              STATUS + RX_DATA            TX_DATA
```

### axil_uart_loopback FSM (6 stavov)

```
ST_AR_STAT  -- assertni ARVALID pre STATUS (0x14)
ST_R_STAT   -- cakaj RVALID, skontroluj STATUS[6] (rx_valid)
               if rx_valid=1 -> ST_AR_RX, else -> ST_AR_STAT
ST_AR_RX    -- assertni ARVALID pre RX_DATA (0x1C, pop FIFO)
ST_R_RX     -- cakaj RVALID, zachyt rx_byte
ST_WR_TX    -- assertni AWVALID+WVALID pre TX_DATA (0x20)
ST_WAIT_B   -- cakaj BVALID, loop -> ST_AR_STAT
```

**Latencia na bajt:** ~7 hodinovych cyklov (2+2+3).
Pri 125 MHz = 56 ns << 8.7 us (UART bit period). Bottleneck je UART, nie FSM.

### AXI-Lite handshake

Vystupy su **kombinacne** (`always_comb` z `state_r`). Registrovane vystupy
by sposobili deadlock: slave by nikdy nevidel ARVALID=1 v rovnakom cykle ako
ARREADY, pretoze master by uz preskocil do ST_R_STAT.

### LED mapovanie

| LED   | Funkcia                        |
|-------|--------------------------------|
| [0]   | RX byte received (stretch ~33ms) |
| [1]   | TX byte sent (stretch ~33ms)   |
| [2]   | uart_axil IRQ (akykolvek)      |
| [3]   | unused (0)                     |
| [4]   | unused (0)                     |
| [5]   | Heartbeat ~0.93 Hz @ 125 MHz  |

---

## Prehľad Faz

| Faza | Popis                             | Stav              |
|------|-----------------------------------|-------------------|
| 1    | RTL + sim                         | UZAVRETA          |
| 2    | Quartus compile + timing          | UZAVRETA          |
| 3    | HW board test                     | UZAVRETA          |

---

## Faza 1 -- RTL + simulacia (UZAVRETA)

**Commit:** `79d62f2`

### Nove subory

| Subor                                   | Popis                                         |
|-----------------------------------------|-----------------------------------------------|
| `rtl/axil_uart_loopback.sv`            | AXI-Lite master FSM, loopback pre uart_axil   |
| `rtl/uart_test_05_axil_top.sv`         | Top-level: PLL reset, uart_axil, loopback, LED |
| `sim/unit/tb_uart_test_05_axil_top.sv` | Integration TB: T01-T04                        |
| `ip/uart_test_05_axil_top.ip.yaml`     | IP definicia pre socfw                         |
| `project.yaml`                          | socfw projekt pre QMTech EP4CE55               |

### Zdedene RTL (z rtl/uart/ + rtl/axi/)

- `uart_axil.sv`, `uart_fifo_os.sv`, `uart_os.sv`, `uart_core_rx_os.sv`
- `sync_fifo.sv`, `uart_baud_gen.sv`, `uart_core_tx.sv`, `uart_core_rx.sv`
- `axi4lite_if`, `axi_pkg`

### Simulacia

| Testbench                         | Testy                       | Vysledok          |
|-----------------------------------|-----------------------------|-------------------|
| `tb_uart_test_05_axil_top` (int) | T01-T04 (1186 asercii)      | **1186/1186 PASS** |

**Testy:**
- T01: echo 0x55 (fork send+recv)
- T02: burst 16 bajtov back-to-back
- T03: burst 64 bajtov back-to-back
- T04: 512 bajtov LFSR stream (fork, seed=0xA5, poly=0x61)

**Sim parametre:** `SIM_CLK=1_600_000`, `SIM_BAUD=12_500`, `FIFO_DEPTH=16`

---

## Faza 2 -- Quartus compile + timing (UZAVRETA)

**`make gen`** vygeneroval artefakty:
- `build/hal/files.tcl` -- file list pre Quartus (14 subory + PLL core)
- `build/timing/soc_top.sdc` -- timing constraints
- `build/rtl/soc_top.sv` -- wrapper top

**`make compile`** -- 0 errors, 3 warnings (ocakavane: LED[2:4] stuck-at-GND)

### Vysledky syntézy (Slow 1200mV 0C)

| Metrika              | Hodnota              |
|----------------------|----------------------|
| Logic Elements       | 1 674 / 55 856 (3 %) |
| Registers            | 1 254                |
| Pins                 | 10 / 325 (3 %)       |
| Memory bits          | 0 (LUT-based FIFOs)  |
| Fmax (CLK125)        | ~140.3 MHz           |
| Setup slack          | +0.871 ns            |
| Hold slack           | +0.379 ns            |
| Timing               | CLOSED               |

**Fix pri kompilacii:** Quartus 25.1 odmieta `N'(expr)` casting (SystemVerilog 2005 mode).
Opravene v `uart_axil.sv`: `~3'(...)` -> `~(...)`, `~5'(...)` -> `~(...)`, `5'(...)` -> `(...)`.

**Bitfile:** `output_files/soc_top.sof`

---

## Faza 3 -- HW board test (UZAVRETA)

| Test             | Bajty | Vysledok        |
|------------------|-------|-----------------|
| hw-test-quick    | 8     | **8/8 PASS**    |
| hw-test (bulk)   | 256   | **256/256 PASS**|

Port: `/dev/ttyUSB0`, 115200 8N1. Ziadne chyby ani timeouty.

---

## Rozdiel oproti uart_test_04

| Vlastnost           | uart_test_04             | uart_test_05_axil             |
|---------------------|--------------------------|-------------------------------|
| Loopback cez        | AXI-Stream (priamy wire) | AXI-Lite registre (FSM)       |
| uart_axil           | unit TB iba              | syntetizovany + timing        |
| Latencia loopback   | ~0 clk overhead          | ~7 clk (AXI-Lite FSM)         |
| Throughput          | rovnaky (UART bottleneck)| rovnaky (UART bottleneck)     |
| HW testovanie       | loopback tool (rovnaky)  | loopback tool (rovnaky)       |

---

## Zname problemy a poznamky

- `axil_uart_loopback.sv` musi pouzivat kombinacne vystupy (`always_comb`).
  Registrovane vystupy sposobia deadlock (ARVALID nikdy neaktivne pri ARREADY
  kontrole -- viz commit sprava 79d62f2).

- `IRQ_STATUS` level bity ([0]=rx_not_empty, [1]=tx_not_full) sa znova nastavia
  kazdy cyklus pokial podmienka trva. SW musi vedome cistit po spracovani.
  Pre tento demo bez IRQ_ENABLE, irq_o=0 pocas normalnej prevadzky.
