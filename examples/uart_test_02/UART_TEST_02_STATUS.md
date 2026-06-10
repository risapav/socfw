# UART_TEST_02 — Stav projektu

**Posledná aktualizácia:** 2026-06-10
**Stav:** v1.1 UZAVRETA — RTL cleanup + rozsirene testy PASS, HW board test PASS

---

## Ciel projektu

Vylepšeny UART loopback demo nad `uart_test_01`. Preklenuté kriticke nedostatky
identifikovane v `navrhy/uart_01.md` a `navrhy/uart_02.md`.

Hardver: QMTech EP4CE55, 50 MHz board clock -> 125 MHz cez `clkpll` PLL.

---

## Prehľad Faz

| Faza | Popis                          | Stav         |
|------|--------------------------------|--------------|
| 1    | RTL + projekt setup            | UZAVRETA     |
| 2A   | Integracne opravy (uart_02.md) | UZAVRETA     |
| 2B   | Simulacia (UART BFM testy)     | UZAVRETA     |
| 2C   | RTL cleanup + rozsirene testy (uart_03.md) | UZAVRETA |
| 3    | HW synteza + timing closure    | UZAVRETA     |
| 4    | HW board test (loopback)       | UZAVRETA     |
| 5    | v1.1: RTL cleanup + rozsirene testy (uart_04.md) | UZAVRETA |

---

## Faza 1 — RTL + projekt setup (UZAVRETA)

### Opravy oproti uart_test_01 (z navrhy/uart_01.md)

| # | Problem                                  | Riešenie                          |
|---|------------------------------------------|-----------------------------------|
| 1 | RX valid je iba jednocyklový pulz        | Output holding register — TVALID drži do ready_i |
| 2 | TXD je kombinacny Mealy vystup           | Plne registrovaný TXD (Moore), 1 clock latency |
| 3 | uart_pkg.sv nie je prvy vo fileliste     | ip.yaml ma uart_pkg.sv na 1. mieste |
| 4 | err_clear_o z loopbacku nie je pripojeny | Spojene v uart_test_02_top.sv |
| 5 | Reset nie je sync-deassert               | 2-FF sync deassert v uart_test_02_top.sv |
| 6 | PRESCALE bez zaokruhlovania              | (CLK_FREQ_HZ + BAUD_RATE/2) / BAUD_RATE |
| 7 | DATA_WIDTH assert <= 16 zavadzajuci      | assert(DATA_WIDTH == 8) |
| 8 | Reset v baud_gen generuje start_tick=1   | Po resete: count=0, vsetky ticky=0 |
| 9 | Back-to-back frames: STOP -> IDLE vzdy   | pending_start_q zachytava skorsi edge |
| 10| always @ (nie always_ff) v loopback      | Opravene na always_ff |

---

## Faza 2A — Integracne opravy (UZAVRETA)

Na zaklade analyzy `navrhy/uart_02.md`.

### Opravy

| # | Problem (uart_02.md)                           | Riešenie                                         |
|---|------------------------------------------------|--------------------------------------------------|
| 1 | files.tcl / files.f triedi subory alphabetically | Odstranene `sorted()` v `files_tcl_emitter.py` a `sim_filelist_emitter.py` |
| 2 | PLL locked ignorovany v resete                 | Pridany port `pll_locked_i` do top modulu, zapojeny cez `connections` v project.yaml |
| 3 | clkpll.ip.yaml ma zlu domain (`eth_tx_clk`)    | Opravene na `clk125`                             |
| 4 | `txd_q` deklarovana po `always_ff`             | Presunutá pred `always_ff` v uart_core_tx.sv     |
| 5 | RX synchronizer bez ASYNC_REG atributu         | Pridany `altera_attribute SYNCHRONIZER_IDENTIFICATION FORCED` |
| 6 | Reset sync bez ASYNC_REG atributu              | Pridany atribut v uart_test_02_top.sv            |
| 7 | tb: UART_RX = 1'b0 (UART idle ma byt 1)        | Opravene v generatoru (tb template, case-insensitive heuristika pre _rx/_locked/_miso) |
| 8 | RX back-to-back: edge pred end_tick_i sa strati | `pending_start_q` register — zachytava edge po validnom stop bite |

### Technicke detaily

**PLL locked reset** (`uart_test_02_top.sv`):
- `pll_locked_i` je novy vstupny port
- Reset synchronizer (`rst_sync_q`) posunuje `pll_locked_i` namiesto `1'b1`
- `rstn_w` deassertuje az po: RESET_N=1 AND pll_locked=1 AND 2 clk125 hrany
- Spojenie: `project.yaml` connections: `clkpll.locked -> uart_test_02_top.pll_locked_i`

**RX back-to-back robustnost** (`uart_core_rx.sv`):
- `stop_sampled_ok_q`: nastaví sa pri `half_tick_i` v UART_STOP ak je stop bit vysoky
- `pending_start_q`: nastaví sa ak pride falling edge po `stop_sampled_ok_q`, pred `end_tick_i`
- Pri `end_tick_i`: prechod do UART_START ak `pending_start_q || start_edge_w`
- Funguje aj pre 2-stop-bit konfiguráciu

**Opravy generatora** (socfw):
- `files_tcl_emitter.py`: `sorted()` -> `list()`, zachovava poradie z ip.yaml
- `sim_filelist_emitter.py`: rovnaka oprava
- `tb_soc_top.sv.j2`: single-bit vstupy `*_rx`, `*_locked`, `*_miso` defaultuju na 1'b1

### Výsledok buildu po Faze 2A

```
socfw build -> OK
build/hal/files.tcl       OK (uart_pkg.sv na 1. mieste)
build/rtl/soc_top.sv      OK (pll_locked zapojeny)
build/sim/tb_soc_top.sv   OK (UART_RX = 1'b1)
build/timing/soc_top.sdc  OK
```

---

## Faza 2B — Simulacia (UZAVRETA)

Regression: 57 checkpoints PASS, 0 FAIL.

### Subory

```
sim/
  Makefile
  unit/tb_uart_core_tx.sv     -- T01-T07, 17 checkpoints
  unit/tb_uart_core_rx.sv     -- T01-T10, 22 checkpoints
  integration/tb_uart_loopback.sv -- T01-T04, 18 checkpoints
```

### Testy

**tb_uart_core_tx (17 PASS):**

| #   | Test                                    |
|-----|-----------------------------------------|
| T01 | TX idle=1 + ready=1 po resete           |
| T02 | 0x55 bitovy vzor 8N1                    |
| T03 | 0x00                                    |
| T04 | 0xFF                                    |
| T05 | back-to-back 0xAA, 0x55 (fork/join)    |
| T06 | ready=0 pocas TX, byte OK              |
| T07 | odd parity: 5 hodnot (0xAA, 0x55, 0xFF, 0x81, 0x07) |

**tb_uart_core_rx (22 PASS):**

| #   | Test                                          |
|-----|-----------------------------------------------|
| T01 | idle -- valid=0 bez dat                       |
| T02 | 0x55                                          |
| T03 | 0x00                                          |
| T04 | 0xFF                                          |
| T05 | rx_ready=0 -- valid/data drzane               |
| T06 | overrun: 2 bajty bez ready                    |
| T07 | frame error: stop bit nizky                   |
| T08 | parity error: wrong parity bit (odd parity)   |
| T09 | back-to-back: 2 bajty bez medzery (fork/join) |
| T10 | pending_start_q: start edge pred end_tick     |

**tb_uart_loopback (18 PASS):**

| #   | Test                                     |
|-----|------------------------------------------|
| T01 | single echo 0x55                         |
| T02 | burst 8 bajtov s medzerami [0xA0..0xA7] |
| T03 | burst 8 bajtov back-to-back [0xB0..0xB7] |
| T04 | frame error -> error_latch, recovery OK  |

### Opravy testbenchu (bugs odhalene pri simulacii)

| # | Problem                                            | Oprava                                                        |
|---|----------------------------------------------------|---------------------------------------------------------------|
| 1 | uart_core_tx.sv: bit_cnt_q/stop_cnt_q forward decl | Presunutie logic deklaracii pred always_comb (Questa)          |
| 2 | tb TX T05/T06: NBA race -- txd uz 0 pri @(negedge) | fork/join: monitor zacina pred fire, chyta negedge v NBA       |
| 3 | tb RX T05: NBA race -- rx_valid kontrola v rovnakom cykle | repeat(2) @(posedge clk) namiesto 1                     |
| 4 | tb RX T09/T10: send hotovy pred check -- byte1 konzumovany | fork/join send + recv paralelne                         |
| 5 | tb RX T10: stop_clks=8 prilis kratke pre 2FF sync  | Zmenene na BIT_CLKS*3/4=12 (half_tick vidi stop bit >= 1 clk) |
| 6 | Makefile regression grep: `^FAIL` nenajde `# FAIL` | Zmenene na `^# FAIL`                                          |

---

## Faza 2C — RTL cleanup + rozsirene testy (UZAVRETA)

Na zaklade analyzy `navrhy/uart_03.md`.

### RTL opravy

| # | Subor                              | Zmena                                                          |
|---|------------------------------------|----------------------------------------------------------------|
| 1 | uart_pkg.sv                        | Odstranene UART_POSTSTOP a UART_VALIDATE z enum uart_state_e   |
| 2 | uart_baud_gen.sv                   | Pridany prescale_safe_w (MIN_PRESCALE=8) pre ochranu podtecenia |
| 3 | uart_stream_loopback_status.sv     | Pridany parameter AUTO_CLEAR_ERRORS (default 1'b1)             |

### Nove testy

| #   | Testbench          | Test                                                       |
|-----|--------------------|------------------------------------------------------------|
| T08 | tb_uart_core_tx    | Even parity: 0xAA (4 ones) -> par=0, 0x07 (3 ones) -> par=1 |
| T11 | tb_uart_core_rx    | Even parity: wrong par -> error; correct par -> data OK    |
| T12 | tb_uart_core_rx    | False start glitch: BIT_CLKS/4 pulz -> FSM ostava IDLE    |

### Vysledok

Regression: PASS (vsetky testbench PASS, 0 FAIL)
- tb_uart_core_tx: 36 PASS lines
- tb_uart_core_rx: 26 PASS lines
- tb_uart_loopback: 38 PASS lines

---

## Faza 3 — HW synteza (UZAVRETA)

Quartus Prime 25.1 Lite.

- PRESCALE = 1085 (125 MHz / 115200, chyba < 0.01%)
- 125 MHz PLL locked -> reset deassertuje po ~2 hranach clk125

### Timing closure

| Model            | WNS setup | WNS hold | Fmax      |
|------------------|-----------|----------|-----------|
| Slow 85C 1200mV  | +2.529 ns | +0.441 ns| 182.78 MHz|
| Slow  0C 1200mV  | +2.916 ns | +0.395 ns| —         |
| Fast  0C 1200mV  | +5.676 ns | +0.184 ns| —         |

**Constraint: 125 MHz (8 ns), margin: +2.529 ns (32%)**

### Oprava SDC

Povodne zlyhaval timing na cestach `pulse_q -> ONB_LEDS` (WNS -6.337 ns).
Pricina: `set_output_delay 3 ns` na vsetkych vystupoch + velky clock skew
pri LED I/O bufferoch (rovnaka pricina ako UART_TX).
Oprava: pridany `set_false_path -to [get_ports {ONB_LEDS[*]}]` do SDC
(rovnaky vzor ako UART_TX — LED je asynchronny vizualny vystup).

Zdroj: `timing_config.yaml` aktualizovany, `build/timing/soc_top.sdc` regenerovat
pomocou `make gen` pri buducom builde.

---

## Faza 4 — HW board test (UZAVRETA)

Board: QMTech EP4CE55, pin `UART_RX`/`UART_TX` na USB-UART (CP2102).

### Vysledky

| Test | Popis                           | Vysledok |
|------|---------------------------------|----------|
| T1   | Single byte 0x55                | PASS     |
| T2   | Pattern burst 8 bajtov          | PASS     |
| T3   | Random 64 bajtov (seed=42)      | PASS     |

`make hw-test` — PASS, 74/74 bajtov spravnych.

### Poznamka k T3 (sekvenicalny mod)

FPGA `uart_stream_loopback_status` ma 1-bajtovy elasticky buffer — dizajnovany pre
interaktivny terminal, nie bulk prenos. Python test (`tools/test_loopback.py`) pouziva
`loopback_sequential()` pre T3: 1 bajt send -> 1 bajt recv, opakovane. Bulk write(64)
sposoboval overrun okolo bajtu 46 kvoli CP2102 USB-UART timing jittera.

### Vizualna verifikacia

- LED heartbeat: ~1 Hz blik (MSB HEARTBEAT_COUNTER_WIDTH=26 @ 125 MHz)
- LED RX/TX activity: pulzy viditelne pri typovani v terminali

---

## Faza 5 — v1.1 RTL cleanup + rozsirene testy (UZAVRETA)

Na zaklade analyzy `navrhy/uart_04.md`.

### RTL zmeny

| # | Subor                | Zmena                                                      |
|---|----------------------|------------------------------------------------------------|
| 1 | uart_core_tx.sv      | Odstranene nepoužívané porty: start_tick_i, half_tick_i    |
| 2 | uart_core_rx.sv      | Odstraneny nepoužívaný port: start_tick_i                  |
| 3 | uart.sv              | Aktualizovane instancie; TX/RX baud gen .start_tick_o()    |
| 4 | uart_pkg.sv          | Komentar: ABI registre pripravene pre uart_axil.sv         |

### Nove testy

| Testbench               | Test | Popis                                         |
|-------------------------|------|-----------------------------------------------|
| tb_uart_baud_gen (novy) | P01  | prescale=0 → clamped to 8                    |
| tb_uart_baud_gen        | P02  | prescale=7 → clamped to 8                    |
| tb_uart_baud_gen        | P03  | prescale=8 → no clamp                        |
| tb_uart_baud_gen        | P04  | prescale=12 → no clamp, period=12            |
| tb_uart_baud_gen        | P05  | half_tick position pre P=8                   |
| tb_uart_baud_gen        | P06  | period continuity = P                         |
| tb_uart_core_tx         | T09  | 7-bit data mode (DBITS=01): 0xFE → 7'h7E     |
| tb_uart_core_tx         | T10  | 2 stop bits: stop1 + stop2 obe vysoke         |
| tb_uart_core_rx         | T13  | 7-bit RX: 7'h7E → rx_data=0x7E (MSB=0)       |
| tb_uart_core_rx         | T14  | 2-stop-bit RX: frame prijaty korektne         |
| tb_uart_loopback        | T05  | 1024-byte LFSR stream (seed=0xA5), sequential |

### Vysledok

REGRESSION PASSED — vsetky 4 testbench, 0 FAIL.

---

## Poznamky

- `clkpll` konfiguracia: 50 MHz vstup x5/2 = 125 MHz vystup (rovnaka ako v xfcp_test_05)
- `HEARTBEAT_COUNTER_WIDTH=26`: MSB toggluje pri ~0.93 Hz @ 125 MHz
- `PULSE_STRETCH_WIDTH=24`: RX/TX activity LED ~134 ms @ 125 MHz
- Oversampling (16x, majority vote) ponechane pre uart_test_03 (v2.0)
- Per-byte error (tuser) ponechane pre uart_test_03 (v2.0)
- uart_fifo.sv, uart_axil.sv — buduce moduly v uart_test_03
