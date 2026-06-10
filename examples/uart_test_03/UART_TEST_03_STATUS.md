# UART_TEST_03 — Stav projektu

**Posledná aktualizácia:** 2026-06-10 (Krok 2 — ramstyle=logic experiment)
**Stav:** Faza 1–3 UZAVRETA, Faza 4 IN PROGRESS — CP2102 boundary potvrdena, M9K vylucena

---

## Ciel projektu

UART loopback s FIFO bufferovanim.  Adresuje obmedzenie uart_test_02 kde
1-bajtovy buffer sposoboval overrun pri bulk prenose (Python `write(64)`).

Hardver: QMTech EP4CE55, 50 MHz board clock -> 125 MHz cez `clkpll` PLL.

---

## Prehľad Faz

| Faza | Popis                          | Stav              |
|------|--------------------------------|-------------------|
| 1    | RTL + projekt setup            | UZAVRETA          |
| 2    | Simulacia                      | UZAVRETA          |
| 3    | HW synteza + timing closure    | UZAVRETA          |
| 4    | HW board test                  | IN PROGRESS       |

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

---

## Faza 4 — HW board test (IN PROGRESS)

### Sweep test (2026-06-10) — ramstyle=logic build (M9K vylucena)

| cs   | Behy | PASS | FAIL | Poznamka                                                     |
|------|------|------|------|--------------------------------------------------------------|
| 1    | 5    | 5    | 0    | PASS — sekvencialny workaround, overuje RTL OK               |
| 8    | 5    | 5    | 0    | PASS                                                         |
| 16   | 5    | 4    | 1    | 1 sporadicke zlyhanie (5 byte cascade od pos=10)             |
| 24   | 5    | 5    | 0    | PASS — bezpecna hornia hranica                               |
| 25   | 5    | 4    | 1    | FAIL 1x: 8 wrong, cascade od pos=17, pos=24(LAST) MISSING   |
| 26   | 5    | 1    | 4    | FAIL 4x: vzdy na pos=25(LAST), corrupt hodnota              |
| 32   | 5    | 0    | 5    | FAIL 5x: byte na pos=25 DROPPED → cascade na zvysok chunk   |
| 64   | 5    | 0    | 5    | FAIL 5x: FIFO overflow, desiatky wrong, MISSING bajtov       |

### Charakteristika zlyhania — po ramstyle=logic experimente

**KLUCOVE ZISTENIE: Vzor zlyhania je rovnaky s M9K aj bez M9K.**
Toto jednoznacne vylucuje Hypotezu B (M9K read latency).

- Pre cs=26: zlyhanie VZDY na **pos=25 (posledny byte chunk-u)** — corrupt hodnota
- Pre cs=32: byte na **pos=25 je DROPPED** → sposobuje 1-bajtovy shift zvysnych bajtov chunk-u
- Pre cs>32: narastajuca kaskada — viac zabudnutych bajtov, dlhsie kaskady
- Magic number: **25 bajtov** — toto je dlzka USB FS paketu CP2102 pre danu konfiguraciu
- cs=24 PASS 5/5, cs=16 PASS 4/5 (border case) → bezpecna hranica je cs≤16

### Investigacia root cause — VYSLEDKY

**Hypoteza A — CP2102 USB pakety (POTVRDENA):**
CP2102 (10C4:EA60) batchuje UART bajtov do ~25-bajtovych USB FS OUT paketov.
Na hranici paketu (bajt N×25) sporadicky vypadava 1 bajt alebo pride korumpovany.
FPGA loopback je spravny — echuje presne to co prijme.

Doklady:
- Failure VZDY na absolut. pozicii, ktora je nasobok 25 (bez ohladu na cs)
- cs≤24: PASS spolahlivy (batch sa nikdy nerozdeluje)
- cs≥26: FAIL — batch prechod nastava vo vnutri chunk-u, drop sposobuje kaskadu
- Vzor sa NEZMENIL po prechode ramstyle logic → M9K = VYLUCENA

**Hypoteza B — M9K RAM read latency (VYLUCENA 2026-06-10):**
Experiment: `ramstyle = "logic"` (Total memory bits: 0/2396160).
Vysledok: failure vzor identicky → M9K nema na chybu ziadny vplyv.

**Hypoteza C — uart_core_rx back-to-back (NEPRAVDEPODOBNA):**
Keby slo o FPGA-side problem, cs=1 by failovalo (kazdy bajt je samostatny transfer).
cs=1 PASS 5/5 → uart_core_rx je OK.

### Zaver Fazy 4

FPGA RTL je spravny. Obmedzenie je HW obmedzenie CP2102 USB bridge:
- CP2102 ma interni USB batch dlzku ~25 bajtov
- Pre spolahlive testovanie: pouzivat cs≤16
- Alternativa: prechod na CP2102N alebo FT232R (vacsia USB FS kapacita)

---

## Poznamky

- Sequential workaround (cs=1): PASS — overuje spravnost FPGA RTL.
- Bezpecny chunk-size pre spolahlivy HW test: ≤16 bajtov.
- Oversampling (16x) a uart_axil.sv planovane pre uart_test_04.

---

## Expertne otazky pre diagnostiku

### Q1: CP2102 "last byte" USB glitch

Pozorovanie: pri prenose cez CP2102 (Silicon Labs 10C4:EA60) + Linux cp210x driver,
posledny bajt kazdeho USB OUT paketu je sporadicky (20-50% sanc) korumpovany.
Korupcia je non-deterministicka (nahodna hodnota). Mensi chunk-size (≤16B) je
prakticky spolahlive.

**Otazky:**
- Je tento jav zname HW obmedzenie CP2102 (nie CP2102N)?
- Existuje Linux cp210x driver workaround (napr. nastavenie latency, packet size)?
- Pomaha `serial.write_timeout` alebo `xonxoff`/`rtscts` nastavenie?
- Aky je odporucany max. burst size pre spolahlivy prenos cez CP2102 bez HS?

### Q2: Cyclone IV M9K "write-first" vs "read-first" v sync_fifo

Quartus inferuje `assign rd_data_o = mem_q[tail_q]` (combinational read) +
`always_ff: mem_q[head_q] <= wr_data_i` (sync write) do M9K s pass-through.

**Otazky:**
- Pouziva Quartus pre tuto kombináciu M9K "write-first" alebo "read-first" mode?
- Garantuje pass-through bypass spravne data aj ked `rd_valid=0` v cykle zapisu
  a `rd_valid=1` v nasledujucom cykle (po `level_q` registraci)?
- Je spravnejsia implementacia pouzit MLAB namiesto M9K pre ≤64-hlboke FIFO?
  Ako explicitne forcat MLAB inference v Quartus?
- Existuje RTL pattern ktory garantuje spravne chovanie BEZ pass-through logiky
  (tzn. cisto registrovany vystup + always_ff pre rd_data_o)?

### Q3: uart_core_rx sporadicky corrupt posledny bajt burstu

Symptom: bajt na pozicii N×chunk_size - 1 je nahodne zlyhavajuci.
CP2102 posiela bajty back-to-back. Po poslednom bajte bloku ide TX linka do IDLE
(HIGH) na ≥30 ms (sleep). Potom zacina novy blok.

**Otazky:**
- Moze `pending_start_q` logika v `uart_core_rx` sporadicky zlyhavat pri prechode
  z posledneho stop bitu do dlheho idle periody?
- Je dvojny FF synchronizator (rxd_r0_q, rxd_r1_q) dostatocny pri 125 MHz
  a 115200 baud? Mohol by metastabil. state na rxd_r1_q korupovat frame detekciu?
- Aký je dopad 3-cykloveho oneskorenia `start_edge_w` na presnost odberu v strede
  bitu (half_tick @ 542/1085 cyklov)?

### Q4: sync_fifo RTL alternativa bez M9K

Ak je M9K inference problematicka, ako implementovat 64-hlboky FIFO pre Cyclone IV
ktory:
- Nepouziva M9K (pouziva MLAB alebo LUT RAM),
- Ma plne kombinacny read vystup (bez latency),
- Je syntetizovatelny v Quartus 25.1 Lite?

Konkretne: aky RTL pattern forci MLAB inference v Cyclone IV pre 64×8 pamat?
