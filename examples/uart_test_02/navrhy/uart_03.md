Aktuálny `uart_test_02(1).zip` je výrazne lepší než predošlý stav.

```text
uart_test_02(1).zip
SHA-256: 4dd81a34fd678bd5fa2477030c5b3e7cabdf3b48ebf88971db907ba695c4fce5
```

## Krátky verdikt

Teraz by som to už hodnotil ako **dobrý UART simple-core v1.1 kandidát**.

Oproti minulému stavu sú reálne opravené hlavné integračné veci:

```text
files.tcl má uart_pkg.sv na 1. mieste
UART_RX v auto tb je idle 1
PLL locked je privedený do uart_test_02_top
reset sa uvoľňuje až po pll_locked_i
RX valid/data sú držané do ready_i
TXD je registrovaný výstup
RX pending_start_q test prechádza
unit + integration simulácie existujú a prechádzajú
```

Simulačný stav:

```text
tb_uart_core_tx:    PASS
tb_uart_core_rx:    PASS
tb_uart_loopback:   PASS
Regression:         57/57 PASS
```

To je už veľmi dobrý míľnik.

---

# 1. Čo je už opravené správne

## 1.1 File order pre Quartus je už OK

`build/hal/files.tcl` má správne poradie:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_pkg.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_baud_gen.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_core_rx.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_core_tx.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart_stream_loopback_status.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart_test_02_top.sv"
```

Toto je dôležité, lebo `uart_core_rx`, `uart_core_tx` a `uart.sv` robia:

```systemverilog
import uart_pkg::*;
```

Teda pre syntézu už je to v poriadku.

`build/sim/files.f` začína `soc_top.sv` a až potom `uart_pkg.sv`. To nie je ideálne esteticky, ale prakticky to nemusí vadiť, lebo `soc_top.sv` neimportuje package; iba instancuje moduly. Package je stále pred `uart.sv`, `uart_core_rx.sv` a `uart_core_tx.sv`. Pre čistotu by som ale aj v `files.f` preferoval:

```text
uart_pkg.sv
uart_baud_gen.sv
uart_core_rx.sv
uart_core_tx.sv
uart.sv
uart_stream_loopback_status.sv
uart_test_02_top.sv
soc_top.sv
tb_soc_top.sv
```

Nie je to blocker, ale je to lepšie pre prenositeľnosť medzi simulátormi.

---

## 1.2 PLL locked reset je už zapojený

V `soc_top.sv`:

```systemverilog
wire w_clkpll_locked;

clkpll clkpll (
  .areset(~RESET_N),
  .c0(clkpll_c0),
  .inclk0(SYS_CLK),
  .locked(w_clkpll_locked)
);

uart_test_02_top uart_test_02_top (
  .clk_i(clkpll_c0),
  .pll_locked_i(w_clkpll_locked),
  .rst_ni(reset_n),
  ...
);
```

A v `uart_test_02_top.sv`:

```systemverilog
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) rst_sync_q <= 2'b00;
  else         rst_sync_q <= {rst_sync_q[0], pll_locked_i};
end

wire rstn_w = rst_sync_q[1];
```

Toto je správne. Modul sa nespustí, kým PLL nie je locked a reset sa neuvoľní synchronizovane v `clk125` doméne.

Drobnosť: komentár v statuse hovorí:

```text
reset deassertuje po ~2 hodinach clk125
```

To je preklep. Má byť:

```text
po ~2 hranách clk125
```

---

## 1.3 RX valid/ready je teraz korektný

V `uart_core_rx.sv`:

```systemverilog
if (frame_done_w && (!rx_valid_q || ready_i)) begin
  rx_hold_q  <= rx_data_w;
  rx_valid_q <= 1'b1;
end else if (!frame_done_w && rx_valid_q && ready_i) begin
  rx_valid_q <= 1'b0;
end
```

Výstup:

```systemverilog
assign valid_o = rx_valid_q;
assign data_o  = rx_hold_q;
```

Toto už spĺňa základné AXI-Stream pravidlo:

```text
valid drží 1, kým ready neprijme byte
data je stabilné počas valid && !ready
```

A testy to overujú:

```text
T05 valid held when ready=0
T05 data stable when ready=0
T06 overrun_err set
T06 byte1 intact after overrun
```

Toto je veľký posun.

---

## 1.4 TXD je registrovaný

`uart_core_tx.sv` už má:

```systemverilog
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) txd_q <= 1'b1;
  else       txd_q <= txd_next_w;
end

assign txd_o = txd_q;
```

Toto je vhodné pre knižničnú IP. TX pin nie je kombinačne závislý od `valid_i`.

---

## 1.5 Testy sú už reálne, nie iba „SIM OK“

Pribudli:

```text
sim/unit/tb_uart_core_tx.sv
sim/unit/tb_uart_core_rx.sv
sim/integration/tb_uart_loopback.sv
```

A logy ukazujú:

```text
tb_uart_core_tx:  all tests passed
tb_uart_core_rx:  all tests passed
tb_uart_loopback: all tests passed
```

Toto už má hodnotu. Testy pokrývajú:

```text
TX idle, ready, 0x55, 0x00, 0xFF
TX back-to-back
TX busy ready=0
odd parity

RX idle
RX 0x55, 0x00, 0xFF
RX ready stall
RX overrun
frame error
parity error
back-to-back
pending_start_q
loopback burst
loopback recovery po frame error
```

To je veľmi dobrý základ.

---

# 2. Čo by som ešte opravil v tomto stave

## 2.1 `uart_baud_gen`: ošetriť nebezpečný `prescale_i`

V `uart.sv` máš assert:

```systemverilog
assert(PRESCALE_VALUE >= 8);
```

To chráni wrapper pri compile-time konfigu. Ale `uart_baud_gen.sv` je samostatný modul s runtime vstupom:

```systemverilog
input wire [PRESCALE_WIDTH-1:0] prescale_i
```

a vnútri:

```systemverilog
assign half_offset_w = (prescale_i - PRESCALE_WIDTH'(1)) >> 1;
...
count_q <= prescale_i - PRESCALE_WIDTH'(1);
```

Ak by niekto použil `uart_baud_gen` mimo wrappera a dal `prescale_i = 0` alebo `1`, podtečie to.

Pre knižnicu by som pridal ochranu priamo do `uart_baud_gen`:

```systemverilog
localparam int MIN_PRESCALE = 8;

wire [PRESCALE_WIDTH-1:0] prescale_safe_w =
  (prescale_i < PRESCALE_WIDTH'(MIN_PRESCALE))
    ? PRESCALE_WIDTH'(MIN_PRESCALE)
    : prescale_i;

assign half_offset_w = (prescale_safe_w - PRESCALE_WIDTH'(1)) >> 1;
```

a všade použiť `prescale_safe_w`.

Alebo explicitne:

```systemverilog
initial assert(PRESCALE_WIDTH >= 4);
```

Toto nie je urgentné pre `uart_test_02`, ale pre knižničný modul áno.

---

## 2.2 `start_tick_i` a `half_tick_i` porty v TX sú stále nepoužité

V `uart_core_tx.sv`:

```systemverilog
input wire start_tick_i, // unused
input wire half_tick_i,  // unused
input wire end_tick_i,
```

V `uart_core_rx.sv`:

```systemverilog
input wire start_tick_i, // unused
input wire half_tick_i,
input wire end_tick_i,
```

Pre vývoj je to OK, ale pre knižnicu by som sa rozhodol:

### Varianta A — nechať kompatibilitu

Potom to v komentári jasne označiť:

```text
start_tick_i je rezervovaný pre budúcu kompatibilitu / oversampling variant.
```

### Varianta B — vyčistiť API

Pre simple TX:

```systemverilog
input wire bit_tick_i
```

Pre simple RX:

```systemverilog
input wire sample_tick_i,
input wire bit_tick_i
```

Ja by som pre `uart_simple_v1` API vyčistil. Nepoužité porty v knižnici často spôsobujú otázky a varovania.

---

## 2.3 RX per-byte error ešte chýba

Sticky error flagy sú:

```text
overrun_err
frame_err
parity_err
```

Ale konkrétny prijatý byte nemá priradenú chybu. Pri frame/parity error dostane downstream stále `data_o` + `valid_o`, ale nevie, či práve tento byte bol chybný.

Pre loopback demo to nevadí. Pre knižnicu by som už pripravil aspoň voliteľné signály:

```systemverilog
output logic rx_frame_err_o,
output logic rx_parity_err_o
```

platné spolu s `valid_o`.

Ešte lepšie AXI-Stream štýl:

```systemverilog
output logic [1:0] rx_user_o;
// rx_user_o[0] = frame error
// rx_user_o[1] = parity error
```

Aj keby si to nechal až do UART v2, zapísal by som to do roadmapy ako `v1.2`.

---

## 2.4 RX 1x sampler zostáva zámerné obmedzenie

Status správne hovorí:

```text
Oversampling (16x, majority vote) ponechane pre uart v2.0
```

S tým súhlasím. Teraz to netreba miešať do `uart_test_02`.

Len treba v dokumentácii jasne pomenovať:

```text
uart_test_02 = simple 1x center-sample UART core
not industrial noisy-line UART receiver
```

Pre FPGA board + CP2102 na krátkom vedení je to v poriadku. Pre knižnicu by som chcel neskôr:

```text
uart_rx_oversample.sv
OVERSAMPLE=16
majority vote
break detect
baud mismatch tolerance tests
```

---

## 2.5 `err_clear_o` automatika je pre demo OK, pre knižnicu voliteľná

V loopbacku:

```systemverilog
assign err_clear_o = any_error_w;
```

Pre demo je to praktické: LED si chybu latchne a UART core sa odblokuje.

Pre knižničný helper by som pridal parameter:

```systemverilog
parameter bit AUTO_CLEAR_ERRORS = 1'b1
```

a:

```systemverilog
assign err_clear_o = AUTO_CLEAR_ERRORS ? any_error_w : 1'b0;
```

Tak bude modul použiteľný aj v režime, kde chceš chyby držať sticky až do explicitného clearu.

---

## 2.6 `error_latch_q` nemá clear okrem resetu

LED error latch sa nastaví:

```systemverilog
if (any_error_w) error_latch_q <= 1'b1;
```

a vynuluje sa len resetom. Pre board demo je to výborné, lebo chybu neprehliadneš.

Do budúcna by sa hodilo:

```systemverilog
input wire error_latch_clear_i
```

alebo parameter:

```systemverilog
parameter bit ERROR_LATCH_STICKY = 1'b1
```

Nie je to blocker.

---

# 3. Veci, ktoré by som doplnil do simulácie

Aktuálne testy sú veľmi dobré pre v1.1. Ešte by som doplnil tieto testy.

## 3.1 Even parity test

TX testuje odd parity. RX testuje wrong odd parity. Chýba even parity.

Doplniť:

```text
TX even parity:
  0xAA -> parity bit 0
  0x55 -> parity bit 0
  0xFF -> parity bit 0
  0x81 -> parity bit 0
  0x07 -> parity bit 1

RX even parity:
  správny parity bit -> no error
  zlý parity bit -> parity_err
```

## 3.2 5/6/7 data bits

Package podporuje:

```text
DBITS 00 = 8
DBITS 01 = 7
DBITS 10 = 6
DBITS 11 = 5
```

Ale logy ukazujú hlavne 8-bit režim + odd parity. Pre knižnicu treba testovať:

```text
TX 7N1
TX 6N1
TX 5N1
RX 7N1
RX 6N1
RX 5N1
```

Dôležitý test:

```text
send 0xFF v 5-bit režime -> očakávaj 0x1F, horné bity nulované
```

## 3.3 2 stop bits

Konfigurácia `STOP2` je implementovaná, ale nevidím explicitný test v logoch.

Doplniť:

```text
TX 8N2: overiť dva stop bity high
RX 8N2: valid až po druhom stop bite
RX 8N2: start edge medzi prvým a druhým stop bitom musí byť frame error/drop, nie nový byte
```

Tento posledný bod je dôležitý. Pri 2 stop bitoch nesmie nový start bit začať po prvom stop bite, ak konfigurácia vyžaduje 2 stop bity.

V tvojom RX kóde `pending_start_q` sa nastavuje po `stop_sampled_ok_q` a `start_edge_w`. Pri `STOP2=1` treba overiť, že to neakceptuje začiatok druhého rámca príliš skoro. Status tvrdí „funguje aj pre 2-stop-bit konfiguráciu“, ale v logoch nevidím samostatný 2-stop test.

## 3.4 Baud mismatch test

Keďže je to 1x sampler, dôležitý je aspoň základný mismatch test:

```text
TX BFM bit time = 16 clk
RX prescale = 16

potom test:
BFM bit time = 15 alebo 17 clk
```

Alebo presnejšie s real delay:

```text
+/- 1 %
+/- 2 %
```

Knižničný simple UART nemusí zvládnuť veľa, ale treba vedieť, kde je hranica.

## 3.5 False start glitch test

V predošlej analýze sme hovorili o false-start ochrane. V kóde je:

```systemverilog
UART_START:
  if (half_tick_i && rxd_sync_w) state_d = UART_IDLE;
```

Doplnil by som test:

```text
rxd spadne na 0 kratšie než half bit
potom sa vráti na 1
očakávaj valid=0, frame_err=0
```

## 3.6 Break condition test

Nie je nutné pre v1.1, ale praktické:

```text
RX low dlhšie než celý frame
očakávaj frame_err
do budúcna break_detect
```

---

# 4. HW fáza: čo presne spraviť teraz

Status má Fázu 3 a 4 ako TODO. Súhlasím.

## 4.1 Spustiť syntézu a timing

```bash
make synth
```

Skontrolovať:

```text
WNS CLK125
počet warnings
či Quartus akceptoval package order
či nepíše warningy o ignored altera_attribute
či nemá latch / combinational loop / truncated width warningy
```

Očakávanie pre UART je, že 125 MHz timing má byť ľahko splnený. Ak nie, bude problém v PLL/constraints/generatori, nie v UART logike.

## 4.2 Board test

Po `make program`:

```bash
python3 tools/test_uart_loopback.py --port /dev/ttyUSB0 --baud 115200 --count 4096
```

Tento tool zatiaľ v ZIP-e nevidím. Odporúčam ho doplniť.

Mal by robiť:

```text
otvoriť serial port
reset input buffer
poslať pattern
čítať späť rovnaký počet bajtov
porovnať presne
otestovať single bytes aj burst
zmerať timeouty
vypísať mismatch offset
```

Minimálne patterny:

```text
0x00
0xFF
0x55
0xAA
counter 0..255
random 4096 B
text payload
```

---

# 5. Knižničná štruktúra — ďalší krok po board teste

`uart_test_02` je teraz výborný example. Aby sa z toho stala knižničná sada, ďalšie moduly by som plánoval takto:

```text
rtl/uart/
  uart_pkg.sv
  uart_baud_gen.sv
  uart_core_rx.sv
  uart_core_tx.sv
  uart.sv

  uart_fifo.sv        ďalší krok
  uart_axil.sv        potom
  uart_rx_oversample.sv  v2.0
```

## `uart_fifo.sv`

Pridať wrapper s RX/TX FIFO:

```text
UART RX -> RX FIFO -> stream output
stream input -> TX FIFO -> UART TX
```

Status:

```text
rx_fifo_level
tx_fifo_level
rx_fifo_overflow
tx_fifo_underflow
```

## `uart_axil.sv`

AXI-Lite register mapa:

```text
0x00 ID
0x04 BAUD_DIV
0x08 CONF
0x0C CTRL / ERR_CLEAR
0x10 STATUS
0x14 TX_DATA
0x18 RX_DATA
0x1C FIFO_LEVEL
0x20 IRQ_ENABLE
0x24 IRQ_STATUS
```

To bude veľmi vhodné pre XFCP, lebo potom budeš vedieť UART jadro ovládať cez rovnakú AXI-Lite infraštruktúru.

---

# 6. Menšie poznámky ku kódu

## 6.1 `UART_POSTSTOP` a `UART_VALIDATE` v enum-e sa nepoužívajú

V `uart_pkg.sv`:

```systemverilog
UART_POSTSTOP,
UART_VALIDATE
```

Tieto stavy sa aktuálne nepoužívajú.

Nie je to chyba, ale pre čistotu by som buď:

```text
odstránil nepoužité enum položky
```

alebo ich komentoval:

```text
reserved for future RX oversampling/validate implementation
```

Pre knižnicu by som preferoval nechať enum minimálny.

## 6.2 `status_o` ako packed struct je dobré, ale wrapper používa iba niektoré bity

To je OK. Pri neskoršom AXI-Lite wrapperi tento struct pekne použiješ.

## 6.3 `set_clock_groups -asynchronous -group {CLK125} -group {SYS_CLK}`

Keďže `CLK125` je PLL-generated zo `SYS_CLK`, formálne to nie je asynchrónna doména. Ak nemáš žiadne dátové cesty medzi SYS_CLK a CLK125 okrem PLL, prakticky to teraz neublíži. Ale do budúcna by som v socfw generátore rozlišoval:

```text
generated related clocks
skutočne asynchronous clocks
```

Nie je to UART bug.

---

# 7. Aktualizovaný stav projektu

Ja by som status formuloval takto:

```text
Fáza 1 — RTL simple UART core: UZAVRETÁ
Fáza 2A — socfw/generator integration fixes: UZAVRETÁ
Fáza 2B — unit/integration sim: UZAVRETÁ, 57/57 PASS
Fáza 3 — Quartus synth/timing: TODO
Fáza 4 — HW board loopback test: TODO
Fáza 5 — library wrappers FIFO/AXI-Lite: PLÁN
Fáza 6 — oversampling RX v2.0: PLÁN
```

Nie je dôvod brzdiť sa pred HW testom. Teraz je správny čas skúsiť syntézu a dosku.

---

## Najbližší konkrétny postup

1. Spustiť:

```bash
make synth
```

2. Skontrolovať Quartus warningy a timing.

3. Ak timing prejde:

```bash
make program
```

4. Doplniť alebo spustiť Python loopback test:

```bash
python3 tools/test_uart_loopback.py --port /dev/ttyUSB0 --baud 115200 --count 4096
```

5. Po HW PASS urobiť tag/commit:

```bash
git commit -m "uart_test_02: simple UART core with held RX valid and registered TXD"
git tag uart_simple_v1_1_sim_hw_pass
```

6. Následne začať `uart_fifo.sv` alebo `uart_axil.sv`.

---

## Celkové hodnotenie

`uart_test_02(1)` už spĺňa dobrý štandard pre **simple UART core**:

```text
čitateľné rozdelenie RX/TX/baud/package
správny held-valid RX stream
registrovaný TX pin
reset cez PLL locked
správny file order pre Quartus
reálne unit/integration testy
```

Ako knižničná sada ešte chýba:

```text
HW board test
FIFO wrapper
AXI-Lite wrapper
per-byte error/tuser
2-stop/even/5-6-7-bit testy
neskôr 16x oversampling
```

Ale oproti `uart_test_01` je to už veľmi zdravý základ.
