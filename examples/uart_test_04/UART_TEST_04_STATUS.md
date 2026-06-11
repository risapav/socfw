
# UART_TEST_04 — Stav projektu

**Posledná aktualizácia:** 2026-06-11 (VSETKY FAZY UZAVRETE)
**Stav:** UZAVRETE — sim 18/18+512B PASS, HW 40/40 PASS (cs=1..64), Fmax=141.08 MHz

---

## Ciel projektu

16x oversampled UART RX s majority-vote sampleovanim.  Adresuje robustnost
voci krátkym rušeniam na RX linke (napr. USB-UART glitch pri CP2102 batch
boundary).

Hardver: QMTech EP4CE55, 50 MHz board clock → 125 MHz cez `clkpll` PLL.
UART: 115200 8N1, echo loopback cez FIFO.

---

## Prehľad Faz

| Faza | Popis                          | Stav              |
|------|--------------------------------|-------------------|
| 1    | RTL + sim                      | UZAVRETA          |
| 2    | Quartus compile + timing       | UZAVRETA          |
| 3    | HW board test + sweep          | UZAVRETA          |

---

## Faza 1 — RTL + simulacia (UZAVRETA)

**Commit:** `fec1edc`

### Nove moduly

| Subor                            | Popis                                                     |
|----------------------------------|-----------------------------------------------------------|
| `rtl/uart/uart_core_rx_os.sv`   | 16x OS RX jadro, majority vote na tickoch 6/7/8          |
| `rtl/uart/uart_os.sv`           | UART wrapper: OS RX + standard TX, 2 baud_gen instancie  |
| `rtl/uart/uart_fifo_os.sv`      | FIFO wrapper pouzivajuci uart_os                          |

### Zdedene moduly (z uart_test_03, bez zmeny)

- `uart_pkg.sv`, `uart_baud_gen.sv`, `uart_core_rx.sv`, `uart_core_tx.sv`
- `uart.sv`, `uart_fifo.sv`, `sync_fifo.sv`
- `uart_stream_loopback_status.sv`

### Architektura

```
Serial RX  -->  uart_core_rx_os  -->  RX FIFO (64B)  -->  uart_stream_loopback_status
               (16x OS baud_gen)                                  |
Serial TX  <--  uart_core_tx    <--  TX FIFO (64B)  <-----------+
               (1x TX baud_gen)
```

### 16x oversampled RX — princip cinnosti

```
          |<------ 1 bit = 128 clk = 16 OS ticks ------>|
          |                                              |
RXD:      |  START  |  D0  |  D1  | ... |  D7  | STOP  |
          |         |      |      |     |      |       |

OS ticks: 0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15
                               ^^  ^^  ^^
                               smpl6  smpl7  smpl8
                               (majority vote)
                                     ^
                               center sample (os_cnt_q==7)

Parametre (125 MHz / 115200 Bd):
  PRESCALE_OS  = floor(125_000_000 / (115200 * 16)) = 67
  BIT_CLKS     = 67 * 16 = 1072  (RX baud +1.22% faster than nominal)
```

### Klucove technicky poznamky

- `os_cnt_q[3:0]` pocita OS ticky 0..15 v ramci jedneho bitoveho okna;
  prirodzene pretecie z 15 na 0 → bez explicitneho resetovania medzi bitmi
- `rx_start_pulse_o` fazi baud_gen pri kazdom novom start bite (aj pri
  back-to-back ramcoch cez `pending_start_q`)
- False-start filter: ak `rxd_sync_w==1` pri `os_cnt_q==7` v START stave →
  navrat do IDLE bez vystupu
- Majoritny hlas: `majority_w = (s6&s7)|(s7&s8)|(s6&s8)` kde s6/s7/s8 su
  vzorky pri OS tickoch 6, 7, 8 datoveho bitu
- DUT vystavuje aj frame-error bajty s `rx_valid=1` (spotrebitel kontroluje
  status flaky); testovacie prostredie musi po frame error vycistit buffer

### Baud generátor — timing (PRESCALE=67)

```
start_i fires at E:
  E+0  : count_q = 66 (reset), start_tick_o = 1
  E+33 : half_tick_o = 1  (center)
  E+66 : end_tick_o  = 1  (pre-end)
  E+67 : start_tick (reload) -- perioda = 67 clk

Pre OS (16x): perioda = 67 clk → 16 * 67 = 1072 clk/bit
```

### Simulacia — vysledky

| Testbench                        | Testy         | Vysledok   |
|----------------------------------|---------------|------------|
| `tb_uart_core_rx_os` (unit)      | R01–R06 (18 asercii) | **18/18 PASS** |
| `tb_uart_fifo_loopback_os` (int) | T01–T05 (512B LFSR)  | **PASS**        |

**Unit testy (R01–R06):**
- R01: jednoduchy bajt 0x55
- R02: dva bajty sekvenčne 0xAA, 0x55
- R03: odmietnutie false-start glitchu (rxd LOW < half-bit)
- R04: frame error (bad stop bit) + err_clear + flush rx_valid
- R05: majority vote — glitch 1 OS tick na bite 0, spravne prijate 0x5A
- R06: burst 8 bajtov (fork: sender + consumer paralelne)

**Integracny test (T01–T05):**
- T01: echo 0x55
- T02: burst 16B back-to-back
- T03: burst 64B (4x FIFO)
- T04: frame error recovery
- T05: 512B LFSR stream (seed=0xA5, poly=0x71)

**Sim parametre:**
- `SIM_CLK_HZ = 1_600_000`, `SIM_BAUD = 12_500`
- `BIT_CLKS = 128`, `OS_PRESCALE = 8` (splna MIN_PRESCALE=8 v baud_gen)

---

## Faza 2 — Quartus compile + timing (UZAVRETA)

### Vysledky

- Fmax: **136.72 MHz** (constraint 125 MHz, margin +11.72 MHz)
- LUT + FF overhead vs uart_test_03: minimalny (len smpl6_q/smpl7_q/smpl8_q + os_cnt_q[3:0])
- Commit: `fec1edc`

### HW sweep — Faza 2 výsledky (FAIL → root cause nájdený)

Sweep parametrami: `cs=1,8,16,24,25,26,32,64`, 5 behov každý.

| cs  | Výsledok | Zlyhania |
|-----|----------|----------|
| 1   | **PASS** | 0        |
| 8   | FAIL     | 13       |
| 16  | FAIL     | 218      |
| 24  | FAIL     | 393      |
| 25  | FAIL     | 412      |
| 26  | FAIL     | 473      |
| 32  | FAIL     | 590      |
| 64  | FAIL     | 855      |

### Root cause — PRESCALE_OS rounding bug

**Problém:** `PRESCALE_RX_OS = round(125MHz / (115200×16)) = 68`
- FPGA baud = 125_000_000 / (68×16) = **114,890 baud** → 0.27% **pomalší** ako CP2102
- Každý UART frame trvá FPGA 68×16 = 1088 clk (ideál = 1085 clk → δ = +3 clk/frame)
- Cez `pending_start_q` (back-to-back alignment): fázová chyba sa akumuluje:
  `δ[N] = 3 + 30×N` clk per N-ty bajt v chunku
- Pre cs=8, bajt 7: δ = 3 + 30×7 = 213 clk = **3.1 OS tick period** drift → missampling

**Oprava:** `PRESCALE_RX_OS = floor(125MHz / (115200×16)) = 67`
- FPGA baud = 125_000_000 / (67×16) = **116,604 baud** → 1.2% **rýchlejší** ako CP2102
- FPGA vždy dokončí STOP bit skôr ako príde nasledujúci START → DUT ide do IDLE
- Každý bajt sa zarovná čerstvo z IDLE → δ = 3 clk (konštantné, bez akumulácie)
- Oprava aplikovaná v `rtl/uart/uart_os.sv` (riadok 68)

---

## Faza 3 — HW board test (IN PROGRESS)

### Prebehnuté testy (pred opravou PRESCALE_OS=68)

Sweep s `PRESCALE_OS=68` (nesprávne): cs=1 PASS, cs=8..64 FAIL (viď Faza 2 tabuľka).

### HW sweep — po oprave PRESCALE_OS=67 (FINÁLNE VÝSLEDKY)

`PRESCALE_OS`: 68 → 67 (floor namiesto round) v `rtl/uart/uart_os.sv`
Resyntetizované: Fmax = 141.08 MHz.

| cs  | Výsledok | Zlyhania |
|-----|----------|----------|
| 1   | **PASS** | 0        |
| 8   | **PASS** | 0        |
| 16  | **PASS** | 0        |
| 24  | **PASS** | 0        |
| 25  | **PASS** | 0        |
| 26  | **PASS** | 0        |
| 32  | **PASS** | 0        |
| 64  | **PASS** | 0        |

**40/40 behov PASS, 0 zlyhaní.**

Prekonanie pôvodného očakávania: uart_test_03 zlyhával pri cs>=25 (CP2102 USB FS
boundary). uart_test_04 s 16x OS + majority vote + PRESCALE_OS=67 prechádza aj
cs=32 a cs=64. FPGA rýchlejší o 1.2% + majority vote filtruje USB batch boundary
glitche — oba problémy vyriešené naraz.

### Diagnosticke LED mapovanie

| LED   | Funkcia                        |
|-------|--------------------------------|
| LED[0]| RX pulse (stretch)             |
| LED[1]| TX pulse (stretch)             |
| LED[2]| RX busy                        |
| LED[3]| TX busy                        |
| LED[4]| Error latch (overrun/frame/par)|
| LED[5]| Heartbeat (~1 Hz)              |

---

## Zname problemy / Investigacie

| Problem                          | Stav       | Poznamka                                              |
|----------------------------------|------------|-------------------------------------------------------|
| PRESCALE_OS=68 phase accumulation| OPRAVENY   | floor div → 67, FPGA faster, IDLE reset per byte      |
| CP2102 25B USB boundary          | VYRIESENY  | 16x OS + majority vote filtruje aj USB boundary glitch|
| OS vs standard RX latency diff   | VYRIESENY  | cs=1..64 PASS (uart_test_03 zlyhával pri cs>=25)      |
| Quartus LUT utilization          | ZMERANY    | Fmax=141.08 MHz, minimalny overhead                   |
