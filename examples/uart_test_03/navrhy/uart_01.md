Áno — `uart_test_03` je logický a dobrý nasledovník `uart_test_02`. Tento projekt už rieši presne to, čo bolo pri `uart_test_02` ešte obmedzenie: **bulk prenos cez UART loopback bez sekvenčného byte-by-byte workaroundu**.

```text
uart_test_03.zip
SHA-256: 6aaf55bb47a3040e18eaf6e66f912d37df6dbebcba7ec4debed3e6b80d23e59f
```

## Krátky verdikt

Za mňa: **ideme na syntézu**.

Nevidím v RTL nič, čo by bolo blockerom pred Quartusom. Projekt je dobre poskladaný:

```text
uart_core_rx / uart_core_tx / uart
        ↓
uart_fifo
        ↓
uart_stream_loopback_status
        ↓
uart_test_03_top
```

Nové moduly `sync_fifo.sv` a `uart_fifo.sv` sú zmysluplné, testy prechádzajú a architektúra je primeraná. Pred syntézou by som spravil iba pár malých doplnkov, nie väčší refaktor.

---

# Čo je v `uart_test_03` dobré

## 1. Správne rieši obmedzenie `uart_test_02`

V `uart_test_02` bol loopback iba:

```text
RX byte -> 1-byte elastic buffer -> TX byte
```

To stačilo na smoke test, ale pri bulk write z PC vedel vzniknúť overrun.

V `uart_test_03` už máš:

```text
Serial RX
  -> uart_core_rx
  -> RX FIFO 64 B
  -> loopback/status
  -> TX FIFO 64 B
  -> uart_core_tx
  -> Serial TX
```

Toto je správny ďalší krok. RX a TX sú oddelené FIFO frontami a loopback modul už nie je jediný buffer v systéme.

---

## 2. `sync_fifo.sv` je jednoduchý a vhodný ako knižničný modul

Rozhranie je pekné:

```systemverilog
wr_data_i
wr_valid_i
wr_ready_o

rd_data_o
rd_valid_o
rd_ready_i
```

Čiže AXI-Stream-like z oboch strán.

Správanie:

```text
wr_ready_o = !full
rd_valid_o = !empty
rd_data_o  = mem[tail]
level_o    = level_q
```

Podporuje simultaneous read/write a testy to overujú:

```text
F05 simultaneous write+read: level unchanged
F07 overflow attempt: level unchanged, no corruption
```

To je dobrý základ pre ďalšie použitie aj mimo UARTu.

---

## 3. `uart_fifo.sv` je správne navrhnutý wrapper

`uart_fifo` nerobí zbytočne veľa. Iba obaľuje existujúce UART jadro dvoma FIFO:

```text
RX FIFO:
  uart.rx_data/valid -> FIFO -> user rx_data/valid

TX FIFO:
  user tx_data/valid -> FIFO -> uart.tx_data/valid
```

To je presne správna separácia vrstiev.

Dobré je aj to, že statusy sú vyvedené:

```systemverilog
tx_fifo_level_o
rx_fifo_level_o
tx_fifo_full_o
tx_fifo_empty_o
rx_fifo_full_o
rx_fifo_empty_o
overrun_err_o
frame_err_o
parity_err_o
```

Toto už začína byť použiteľné ako knižničná UART IP vrstva.

---

## 4. Simulácie sú zmysluplné

Máš dva nové testy:

```text
tb_sync_fifo
tb_uart_fifo_loopback
```

Podľa logov:

```text
tb_sync_fifo: all tests passed
tb_uart_fifo_loopback: all tests passed
```

`tb_uart_fifo_loopback` už netestuje len jeden znak, ale aj:

```text
T01 single byte
T02 burst 16 bytes back-to-back
T03 burst 64 bytes back-to-back
T04 frame error recovery
T05 512-byte LFSR stream
```

To je dobrý integračný test pre túto fázu.

---

# Veci, ktoré by som ešte upravil pred syntézou

Nie sú to blockery, ale sú to malé čisté zlepšenia.

## 1. Doplniť ochranné assertiony do `uart_fifo.sv`

`sync_fifo.sv` si už kontroluje `DEPTH`:

```systemverilog
assert(DEPTH > 1)
assert(2**PTR_W == DEPTH)
```

Ale `uart_fifo.sv` by mal mať vlastné top-level assertiony, aby chyba bola jasná už pri jeho použití:

```systemverilog
// synthesis translate_off
initial begin
  assert(DATA_WIDTH == 8)
    else $fatal(1, "uart_fifo: DATA_WIDTH must be 8");

  assert(RX_FIFO_DEPTH > 1)
    else $fatal(1, "uart_fifo: RX_FIFO_DEPTH must be > 1");

  assert(TX_FIFO_DEPTH > 1)
    else $fatal(1, "uart_fifo: TX_FIFO_DEPTH must be > 1");

  assert(2**$clog2(RX_FIFO_DEPTH) == RX_FIFO_DEPTH)
    else $fatal(1, "uart_fifo: RX_FIFO_DEPTH must be a power of 2");

  assert(2**$clog2(TX_FIFO_DEPTH) == TX_FIFO_DEPTH)
    else $fatal(1, "uart_fifo: TX_FIFO_DEPTH must be a power of 2");
end
// synthesis translate_on
```

Nie je to nutné, lebo `sync_fifo` to zachytí, ale pre knižničnú použiteľnosť je lepšie, keď wrapper hlási chybu s vlastným menom.

---

## 2. Pridať `overflow/drop` status do FIFO

Aktuálny `sync_fifo` správne deassertuje `wr_ready_o`, takže korektný upstream nič nestratí. Ale ako knižničný modul by sa hodil sticky indikátor, že niekto skúšal zapisovať do plnej FIFO:

```systemverilog
output logic overflow_o;
output logic underflow_o;
input  wire  err_clear_i;
```

V tomto projekte to nie je nutné, pretože UART core rešpektuje `ready`. Ale do budúcnosti sa to oplatí.

Minimálna verzia:

```systemverilog
if (wr_valid_i && !wr_ready_o)
  overflow_q <= 1'b1;

if (rd_ready_i && !rd_valid_o)
  underflow_q <= 1'b1;
```

Potom `uart_fifo` môže vyviesť:

```systemverilog
rx_fifo_overflow_o
tx_fifo_overflow_o
rx_fifo_underflow_o
tx_fifo_underflow_o
```

Toto bude veľmi užitočné, keď `uart_fifo` použiješ v reálnom SoC alebo AXI-Lite wrapperi.

---

## 3. Status dokument má drobnú nekonzistenciu

V tabuľke máš:

```text
Faza 2    Simulacia    UZAVRETA
```

ale nižšie nadpis:

```text
## Faza 2 — Simulacia (PREBIEHA)
```

Keďže logy ukazujú PASS, zmeň to na:

```text
## Faza 2 — Simulacia (UZAVRETA)
```

Nie je to technický problém, len nech status sedí.

---

## 4. T05 v simulácii je „sequential echo“, nie úplne agresívny bulk stress

Status hovorí:

```text
T05 512-byte LFSR stream (seed=0xA5), sequential echo
```

To je dobré ako dlhý test dátovej integrity. Ale pre FIFO projekt by som časom doplnil ešte jeden agresívnejší test:

```text
T06: host pošle burst väčší než RX_FIFO_DEPTH + TX_FIFO_DEPTH
    napr. 160 alebo 256 bajtov back-to-back
    očakávanie:
      buď všetko prejde, ak testbench súčasne číta TX,
      alebo korektne vznikne overrun/error, ak TX nie je odoberaný
```

Dnes to nie je blocker pre syntézu. Ale ako ďalší sim test by bol dobrý, lebo presne ukáže hranice bufferingu.

---

# Dôležitá poznámka k FIFO kapacite

`uart_test_03` má:

```text
RX FIFO = 64 B
TX FIFO = 64 B
loopback elastic buffer = 1 B
UART core holding register = 1 B
```

To neznamená, že FPGA dokáže donekonečna absorbovať ľubovoľne veľký burst bez toho, aby TX zároveň odchádzal. Znamená to, že má rozumný buffer na rozdiel medzi RX a TX prúdom.

Pri loopbacku sú RX a TX rovnaký baud. Po prvom prijatom byte začne FPGA hneď vysielať späť, takže počas dlhšieho prenosu sa buffery priebežne plnia aj vyprázdňujú. Preto môže fungovať aj `--count 256`.

Ak by host vysielal rýchlejšie než UART linka alebo by TX cesta bola zastavená, 64+64 B nie je nekonečný buffer. To je úplne normálne.

---

# Čo by som skontroloval v syntéze

Keď spustíš Quartus, pozeral by som hlavne:

```text
1. Či prejde Analysis & Synthesis bez warningov o package order.
2. Či sa FIFO implementuje rozumne — pri 64x8 pravdepodobne v LE/registeroch, nie M9K.
3. Či nie sú warningy na latch/combinational loop.
4. Či CLK125 timing prejde s rezervou.
5. Či pin assignments pre UART/LED majú IO standard.
```

Očakávam, že timing pri 125 MHz prejde bez problémov. Logika je malá.

---

# Odporúčaný postup teraz

## 1. Pred syntézou drobné upratanie

Spravil by som len toto:

```text
- opraviť status: Faza 2 UZAVRETA
- doplniť assertiony do uart_fifo.sv
```

Voliteľne:

```text
- pridať overflow/underflow sticky status do sync_fifo.sv
```

Ak nechceš teraz meniť API `sync_fifo`, môžeš to nechať na `uart_test_04`.

---

## 2. Spustiť syntézu

Potom už:

```bash
make full
```

alebo podľa tvojho flow:

```bash
make gen
make compile
make timing
```

Ak to prejde:

```bash
make program
make hw-test-quick
make hw-test HW_COUNT=256
make hw-test HW_COUNT=1024
```

Pri `HW_COUNT=1024` by som už sledoval, či nie je problém s PC serial bufferom alebo oneskorením, ale FPGA by to pri normálnom loopbacku mala zvládnuť.

---

# HW test, ktorý by som doplnil

Tvoj `tools/test_loopback.py` je dobrý. Pridal by som ešte jeden argument:

```bash
--chunksize
```

Napríklad:

```bash
python3 tools/test_loopback.py --count 1024 --chunksize 1
python3 tools/test_loopback.py --count 1024 --chunksize 8
python3 tools/test_loopback.py --count 1024 --chunksize 64
python3 tools/test_loopback.py --count 1024 --chunksize 256
```

Tým rozlíšiš:

```text
- byte-by-byte režim
- malé bursty
- veľké host bulk write
```

Teraz `loopback_bulk()` zapisuje celý payload naraz. To je OK, ale `chunksize` ti dá lepšiu diagnostiku.

---

# Hodnotenie kvality

Moje hodnotenie `uart_test_03`:

```text
Architektúra:     veľmi dobrá
sync_fifo:        dobrý jednoduchý FIFO
uart_fifo:        čistý wrapper, vhodný smer ku knižnici
simulácie:        dobré pre túto fázu
HW pripravenosť:  áno, po malom uprataní
knižničnosť:      lepšia než uart_test_02, stále bez AXI-Lite wrappera
```

Známka:

```text
Ako board demo:             9/10
Ako UART FIFO wrapper:      8/10
Ako finálna UART IP sada:   7/10
```

Finálna UART IP sada ešte bude potrebovať:

```text
uart_axil.sv
interrupts
runtime baud/config
per-byte error/tuser
voliteľne oversampling RX
```

Ale `uart_test_03` je správna ďalšia fáza a podľa mňa je pripravený na syntézu.

---

## Záver

Ja by som teraz nebrzdil veľkým refaktorom.

Odporúčam:

```text
1. drobne upraviť UART_TEST_03_STATUS.md,
2. prípadne doplniť assertiony do uart_fifo.sv,
3. spustiť syntézu,
4. ak timing prejde, urobiť HW bulk loopback test.
```

Teda odpoveď na tvoju otázku: **áno, ideme na syntézu**.
