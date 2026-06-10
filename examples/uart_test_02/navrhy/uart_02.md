Analyzoval som `uart_test_02.zip`.

```text
uart_test_02.zip
SHA-256: 6b4d74fdef049e70e4f72e816a1ce69ce646028a20841fe5518975ef50c6776d
```

## Krátky verdikt

`uart_test_02` je výrazný krok dopredu oproti `uart_test_01`. Najdôležitejšie opravy sú už zapracované:

```text
RX valid už drží dáta do ready_i
TXD je registrovaný výstup
PRESCALE je zaokrúhlený
DATA_WIDTH je obmedzený na 8
reset v uart_test_02_top je sync-deassert
err_clear_o je pripojený
UART_RX je false-path
```

Ale ešte by som ho neoznačil ako hotovú knižničnú UART sadu. Stále sú tam tri vážne oblasti:

```text
1. generovaný filelist má stále zlé poradie package súboru,
2. testbench stále UART reálne netestuje,
3. RX časovanie/back-to-back príjem je stále jednoduchý 1x sampler a má slabú toleranciu voči baud mismatchu.
```

Ako **uart v1.1 simple core** je to dobrý smer. Ako **robustná knižničná IP** ešte treba doplniť testy, FIFO/AXI-Lite wrapper a neskôr 16x oversampling.

---

# 1. Stav podľa `UART_TEST_02_STATUS.md`

Status hovorí:

```text
FAZA 1 UZAVRETA — build OK, HW synteza zatial nespustena
```

To je v princípe správne, ale dve tvrdenia v tabuľke sú predčasné.

Status tvrdí:

```text
uart_pkg.sv nie je prvy vo fileliste -> ip.yaml ma uart_pkg.sv explicitne na 1. mieste
```

Áno, `ip/uart_test_02_top.ip.yaml` má správne poradie:

```yaml
- ../rtl/uart/uart_pkg.sv
- ../rtl/uart/uart_baud_gen.sv
- ../rtl/uart/uart_core_rx.sv
- ../rtl/uart/uart_core_tx.sv
- ../rtl/uart/uart.sv
```

Ale generované súbory sú stále zle.

`build/hal/files.tcl`:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_baud_gen.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_core_rx.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_core_tx.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_pkg.sv"
```

`uart_pkg.sv` je stále až po moduloch, ktoré robia:

```systemverilog
import uart_pkg::*;
```

Rovnako `build/sim/files.f` má `soc_top.sv` a `uart.sv` pred `uart_pkg.sv`.

Toto je stále blocker pre knižničné použitie. Oprava v `ip.yaml` nestačí, ak generator výstup pretriedi alebo nerešpektuje poradie artifactov.

---

# 2. `uart_pkg.sv`

Toto je dobrý základ ABI package.

Pozitíva:

```text
status bit positions sú pevne definované
uart_status_t je ABI-friendly packed struct
uart_conf_t jasne definuje stop/parity/dbits
calc_parity() maskuje dáta podľa DBITS
dbits_to_int() pokrýva 8/7/6/5 bitov
```

Toto by som ponechal.

Čo by som doplnil:

```systemverilog
localparam logic [31:0] UART_ID = 32'h5541_5254; // "UART"
localparam logic [7:0]  UART_ABI_VERSION = 8'd1;
```

A do statusu by som pridal ešte aspoň:

```text
rx_valid / rx_fifo_not_empty
tx_ready / tx_fifo_not_full
break_detect
rx_byte_error
```

Pre jednoduchý core to nemusí byť hneď, ale pre knižnicu áno.

---

# 3. `uart_baud_gen.sv`

Oprava resetu je dobrá:

```systemverilog
if (!rstn) begin
  count_q      <= '0;
  start_tick_o <= 1'b0;
  half_tick_o  <= 1'b0;
  end_tick_o   <= 1'b0;
end
```

A zaokrúhlený prescale v `uart.sv` je tiež dobrý:

```systemverilog
localparam int PRESCALE_VALUE =
  (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
```

Pre 125 MHz / 115200 vychádza:

```text
PRESCALE = 1085
real baud ≈ 115207.37
chyba ≈ +0.0064 %
```

To je výborné.

## Čo by som ešte upravil

`uart_baud_gen` je stále špecializovaný na jednoduchý 1x UART sampler. Ako simple v1 je to v poriadku. Pre knižničné použitie by som ale už teraz pripravil rozhranie tak, aby sa neskôr dala doplniť 8x/16x verzia.

Doplnil by som minimálne parameter:

```systemverilog
parameter int MIN_PRESCALE = 8
```

a assertion:

```systemverilog
initial begin
  assert(PRESCALE_WIDTH > 1);
end
```

A ak zostane `prescale_i` runtime vstup, potom vnútri bezpečne ošetriť:

```systemverilog
wire [PRESCALE_WIDTH-1:0] prescale_safe_w =
  (prescale_i < PRESCALE_WIDTH'(8)) ? PRESCALE_WIDTH'(8) : prescale_i;
```

Pretože standalone `uart_baud_gen` by nemal vedieť podtiecť pri `prescale_i = 0`.

---

# 4. `uart_core_tx.sv`

Toto je jedna z najlepších zmien v `uart_test_02`.

Registrovaný TXD výstup:

```systemverilog
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) txd_q <= 1'b1;
  else       txd_q <= txd_next_w;
end

assign txd_o = txd_q;
```

je správny knižničný smer. Odstránil si pôvodný Mealy výstup závislý od `valid_i`.

TX FSM je jednoduchý a čitateľný:

```text
IDLE -> START -> DATA -> PARITY -> STOP -> IDLE
```

Handshake:

```systemverilog
assign ready_o = (state_q == UART_IDLE);
wire fire_w = valid_i && ready_o;
```

je pre jednoduchý TX core v poriadku.

## Čo by som vylepšil

### 4.1 `txd_q` deklarovať pred použitím

Aktuálne máš:

```systemverilog
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) txd_q <= 1'b1;
  else       txd_q <= txd_next_w;
end

logic txd_q;
assign txd_o = txd_q;
```

SystemVerilog deklarácie uprostred modulu sú povolené, ale pre Quartus/Verible/čitateľnosť by som deklaroval `txd_q` pred `always_ff`:

```systemverilog
logic txd_q;

always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) txd_q <= 1'b1;
  else       txd_q <= txd_next_w;
end

assign txd_o = txd_q;
```

### 4.2 Pridať staging register alebo FIFO wrapper

Core samotný môže zostať bez FIFO, ale knižnica by mala mať wrapper:

```text
uart_tx_fifo.sv
```

s rozhraním:

```systemverilog
s_axis_tdata
s_axis_tvalid
s_axis_tready
```

a internou FIFO hĺbkou napríklad 16 alebo 64 bajtov.

Pre loopback demo stačí one-byte buffer, ale pre všeobecný UART je TX FIFO veľmi praktická.

---

# 5. `uart_core_rx.sv`

Tu je najväčší posun oproti `uart_test_01`.

## 5.1 Opravený valid/ready handshake

Toto je dobrá oprava:

```systemverilog
if (frame_done_w && (!rx_valid_q || ready_i)) begin
  rx_hold_q  <= rx_data_w;
  rx_valid_q <= 1'b1;
end else if (!frame_done_w && rx_valid_q && ready_i) begin
  rx_valid_q <= 1'b0;
end

assign valid_o = rx_valid_q;
assign data_o  = rx_hold_q;
```

Teraz už platí:

```text
valid_o drží 1, kým ready_i neprijme byte
data_o zostáva stabilné počas valid_o && !ready_i
```

To je správny AXI-Stream základ.

## 5.2 Overrun správanie

Toto je tiež rozumné:

```systemverilog
if (frame_done_w && rx_valid_q && !ready_i)
  overrun_err_q <= 1'b1;
```

Ak príde nový byte a starý ešte nebol prevzatý, nový sa zahodí a nastaví sa overrun.

To je akceptovateľné pre jednoduchý RX bez FIFO.

## 5.3 Najväčší problém: back-to-back frame detekcia je slabá

Komentár hovorí:

```text
Back-to-back frames: detected in UART_STOP -- if the line goes low on the
last stop bit, the FSM jumps directly to UART_START.
```

Kód:

```systemverilog
UART_STOP: begin
  if (end_tick_i && stop_cnt_q == 2'd1) begin
    state_d = start_edge_w ? UART_START : UART_IDLE;
  end
end
```

Toto zachytí iba prípad, keď `start_edge_w` nastane **presne v tom istom clock cykle** ako `end_tick_i`.

To je príliš úzke. V reálnom UARTe môže ďalší start bit prísť:

```text
trochu pred lokálnym end_tick_i, ak je vysielač rýchlejší,
trochu po end_tick_i, ak je vysielač pomalší.
```

Ak príde trochu po `end_tick_i`, budeš už v IDLE a je to v poriadku.

Ale ak príde trochu pred `end_tick_i`, edge nastane ešte v stave `UART_STOP`, nie je uložený, a pri `end_tick_i` už `start_edge_w` nebude 1. Výsledok:

```text
receiver sa vráti do IDLE, ale linka je už nízko,
falling edge už prebehol,
ďalší znak sa môže stratiť.
```

Toto je dôležité. Pri ideálnych testoch to nemusí vyliezť, ale pri dlhšom back-to-back streame a tolerancii baudov áno.

## Odporúčaná oprava RX STOP

Pridaj flag, že stop bit bol validne osamplovaný:

```systemverilog
logic stop_sample_ok_q;
logic pending_start_q;
```

V `UART_STOP`:

```systemverilog
if (half_tick_i) begin
  if (!rxd_sync_w) begin
    frame_err_q <= 1'b1;
  end else begin
    stop_sample_ok_q <= 1'b1;
  end
end

if (stop_sample_ok_q && start_edge_w) begin
  pending_start_q <= 1'b1;
end
```

A pri konci stop bitu:

```systemverilog
if (end_tick_i && stop_cnt_q == 2'd1) begin
  if (pending_start_q || start_edge_w) begin
    state_d = UART_START;
  end else begin
    state_d = UART_IDLE;
  end
end
```

Ešte lepšie: po validnom stop sample v polovici stop bitu môže RX prejsť do `UART_IDLE` už skôr a čakať na ďalší falling edge. To je bežnejší UART prístup a dáva väčšiu toleranciu.

---

# 6. Stále chýba per-byte error informácia

RX sticky flags sú užitočné:

```text
overrun_err
frame_err
parity_err
```

Ale prijatý byte ide von cez:

```systemverilog
data_o
valid_o
ready_i
```

bez informácie, či práve tento konkrétny byte mal frame/parity error.

To je pre knižnicu slabé.

Odporúčam rozšíriť RX stream:

```systemverilog
output logic rx_frame_err_o,
output logic rx_parity_err_o,
output logic rx_overrun_marker_o
```

alebo AXI-Stream štýlom:

```systemverilog
output logic [7:0] m_axis_tdata;
output logic       m_axis_tvalid;
input  logic       m_axis_tready;
output logic [1:0] m_axis_tuser;
```

Napríklad:

```text
tuser[0] = frame error
tuser[1] = parity error
```

Sticky flags nech zostanú, ale debug/stream vrstva potrebuje chybu priradenú ku konkrétnemu bajtu.

---

# 7. `uart.sv` wrapper

Wrapper je teraz čistejší.

Pozitíva:

```text
rounded PRESCALE
DATA_WIDTH == 8 assert
samostatný TX a RX baud generator
konfiguračný struct cfg_w
oddelené RX/TX cores
```

Toto by som ponechal.

## Čo by som ešte upravil

### 7.1 Odstrániť nepoužité tick porty

V RX aj TX core máš:

```systemverilog
input wire start_tick_i // unused
input wire half_tick_i  // TX unused
```

V komentároch píšeš, že sú ponechané kvôli kompatibilite. Pre knižničný core by som kompatibilitu so zlým rozhraním neriešil. Radšej čisté rozhranie:

TX core potrebuje iba:

```systemverilog
input wire bit_tick_i; // end tick
```

RX simple core potrebuje:

```systemverilog
input wire sample_tick_i;
input wire bit_tick_i;
```

Ak chceš ponechať starý wrapper kvôli migrácii, urob to takto:

```text
uart_core_rx_simple_v1_compat.sv
uart_core_rx.sv              čisté nové rozhranie
```

### 7.2 Pridať runtime prescale/config variant

Aktuálny `uart.sv` je compile-time konfigurovaný:

```systemverilog
parameter BAUD_RATE
parameter STOP2
parameter PARITY
parameter DBITS
```

To je dobré pre malý core.

Pre knižnicu však budeš chcieť aj:

```text
uart_axil.sv
```

kde sa dá nastaviť:

```text
BAUD divisor
CONF
ERR_CLEAR
STATUS
TXDATA
RXDATA
```

Tým vznikne plnohodnotná UART IP.

---

# 8. `uart_test_02_top.sv`

Top wrapper je dobrý krok:

```text
clk125 doména
reset sync-deassert
uart core
loopback/status
err_clear pripojený
```

## Kritický detail: PLL `locked` sa ignoruje

V generovanom `soc_top.sv` je:

```systemverilog
clkpll clkpll (
  .areset(~RESET_N),
  .c0(clkpll_c0),
  .inclk0(SYS_CLK),
  .locked()
);

uart_test_02_top uart_test_02_top (
  .clk_i(clkpll_c0),
  .rst_ni(reset_n),
  ...
);
```

`locked` je nepripojený.

To znamená, že `uart_test_02_top` môže uvoľniť reset po 2 taktoch `clkpll_c0`, aj keď PLL ešte nemusí byť stabilne locked.

Pre HW robustnosť treba:

```systemverilog
wire pll_locked_w;

clkpll clkpll (
  .areset(~RESET_N),
  .c0(clkpll_c0),
  .inclk0(SYS_CLK),
  .locked(pll_locked_w)
);

wire uart_rst_n = RESET_N & pll_locked_w;
```

a až to poslať do `uart_test_02_top.rst_ni`.

Toto je dôležité hlavne pri 125 MHz PLL clocku.

---

# 9. `uart_stream_loopback_status.sv`

Tento modul je dobrý demo helper. Elastic one-byte buffer je správny:

```systemverilog
assign rx_ready_o = !buffer_valid_q || tx_ready_i;
```

a simultaneous consume + receive je ošetrené:

```systemverilog
2'b11: begin
  buffer_q       <= rx_data_i;
  buffer_valid_q <= 1'b1;
end
```

## Čo by som zmenil

### 9.1 `err_clear_o = any_error_w` je na demo OK, ale nie na knižnicu

Teraz sa sticky UART chyby automaticky clearujú hneď, ako ich loopback uvidí:

```systemverilog
assign err_clear_o = any_error_w;
```

LED latch si chybu zachytí:

```systemverilog
if (any_error_w) error_latch_q <= 1'b1;
```

Pre demo je to použiteľné.

Pre knižnicu je lepšie:

```text
chyby clearovať explicitne cez register alebo tlačidlo
auto-clear nechať ako voliteľný parameter
```

Navrhujem parameter:

```systemverilog
parameter bit AUTO_CLEAR_ERRORS = 1'b1
```

a:

```systemverilog
assign err_clear_o = AUTO_CLEAR_ERRORS ? any_error_w : 1'b0;
```

### 9.2 LED error latch nemá clear

`error_latch_q` sa clearuje len resetom. Pre demo OK, ale pre board test by sa hodil vstup:

```systemverilog
input wire led_err_clear_i
```

alebo auto-clear po dlhom čase voliteľne.

---

# 10. `project.yaml` a build integrácia

`project.yaml` používa:

```yaml
clkpll -> clk125
uart_test_02_top na clk125
```

To je v poriadku.

Ale dve veci treba opraviť na úrovni generatora alebo projektu:

## 10.1 File order

Ako už vyššie: `build/hal/files.tcl` a `build/sim/files.f` sú zle.

Toto treba riešiť v socfw generátore. Ak IP artifact list uvedie package prvý, generátor to musí rešpektovať.

## 10.2 PLL locked reset

V `project.yaml` by bolo dobré vedieť vyjadriť:

```yaml
reset: "RESET_N & clkpll.locked"
```

alebo doplniť v top module. Kým generator nevie kombinovať reset s locked, robil by som to priamo v ručne písanom top wrapperi alebo v samostatnom reset module.

---

# 11. `soc_top.sdc`

Toto je lepšie než predtým:

```tcl
set_false_path -from [get_ports {RESET_N}]
set_false_path -to [get_ports {UART_TX}]
set_false_path -from [get_ports {UART_RX}]
```

UART RX je asynchrónny vstup, takže false path dáva zmysel.

## Čo by som doplnil

### 11.1 ASYNC_REG / synchronizer attributes

Do RX synchronizéra:

```systemverilog
(* async_reg = "true" *) logic rxd_r0_q;
(* async_reg = "true" *) logic rxd_r1_q;
```

Pre Intel/Quartus je vhodné zvážiť aj altera atribút podľa toho, čo Quartus rešpektuje:

```systemverilog
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
```

Podobne pre reset synchronizér v top-e.

### 11.2 Generated clock + SYS clock group

Máš:

```tcl
create_generated_clock -name CLK125 ...
set_clock_groups -asynchronous -group {CLK125} -group {SYS_CLK}
```

Keďže `CLK125` je generovaný z `SYS_CLK`, nie je to typicky „asynchronous“ vo fyzikálnom zmysle. Ak medzi SYS_CLK a CLK125 nie sú žiadne dátové cesty, prakticky to neublíži. Ale ako všeobecná timing filozofia by som bol opatrný. Generated clock by mal byť časovo príbuzný so zdrojovým clockom, pokiaľ vedome nechceš odrezať CDC cesty.

Pre tento projekt to nie je hlavný problém, len poznámka.

---

# 12. Testbench je stále slabý

`build/sim/tb_soc_top.sv` stále robí:

```systemverilog
UART_RX = 1'b0;
repeat(50000) @(posedge SYS_CLK);
$display("SIM OK");
```

UART idle má byť 1, nie 0.

Čiže testbench stále drží RX linku v stave start bit / break. To nie je validný UART idle stav.

Správne minimum:

```systemverilog
UART_RX = 1'b1;
```

Ale hlavne treba reálny UART BFM.

## Navrhované doplnenie `sim/`

Pridal by som:

```text
sim/
  tb_uart_baud_gen.sv
  tb_uart_core_tx.sv
  tb_uart_core_rx.sv
  tb_uart_loopback.sv
  uart_bfm.sv
  run.do alebo Makefile
```

### Minimálny BFM task

```systemverilog
task automatic uart_send_byte(input logic [7:0] data);
  UART_RX <= 1'b0; // start
  #(BIT_NS);

  for (int i = 0; i < 8; i++) begin
    UART_RX <= data[i];
    #(BIT_NS);
  end

  UART_RX <= 1'b1; // stop
  #(BIT_NS);
endtask
```

### Minimálny monitor

```systemverilog
task automatic uart_recv_byte(output logic [7:0] data);
  wait(UART_TX == 1'b0);     // start
  #(BIT_NS * 1.5);           // middle of bit0

  for (int i = 0; i < 8; i++) begin
    data[i] = UART_TX;
    #(BIT_NS);
  end

  if (UART_TX !== 1'b1)
    $fatal("UART stop bit error");
endtask
```

---

# 13. Testy, ktoré by som pridal okamžite

## `tb_uart_core_tx`

```text
TX idle high po resete
0x55 8N1 bitový priebeh
0x00
0xFF
odd parity
even parity
7-bit data
6-bit data
5-bit data
2 stop bits
back-to-back bytes
valid držané počas busy
```

## `tb_uart_core_rx`

```text
idle high bez dát
0x55 8N1
0x00
0xFF
7/6/5 data bits
odd/even parity OK
parity error
frame error: stop bit low
false start glitch
rx_ready low drží valid/data
overrun: druhý byte príde bez ready
back-to-back stream s malou baud odchýlkou
```

Ten posledný test je dôležitý kvôli STOP/START riziku.

## `tb_uart_loopback`

```text
pošli 1 byte -> očakávaj echo
pošli 16 bajtov s medzerami
pošli 16 bajtov back-to-back
porovnaj poradie
over LED pulses voliteľne
```

---

# 14. Čo ešte chýba pre knižničnú UART sadu

`uart_test_02` je stále example. Knižničná sada by mala mať vrstvy:

```text
rtl/uart/
  uart_pkg.sv
  uart_baud_gen.sv
  uart_core_rx_simple.sv
  uart_core_tx.sv
  uart_core.sv
  uart_fifo.sv
  uart_axil.sv
  uart_rx_oversample.sv      neskôr
  uart_bfm.sv                sim only
```

## `uart_fifo.sv`

Wrapper:

```text
RX core -> RX FIFO
TX FIFO -> TX core
```

Status:

```text
rx_fifo_level
tx_fifo_level
rx_fifo_overflow
tx_fifo_underflow
```

## `uart_axil.sv`

AXI-Lite register map:

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

## `uart_rx_oversample.sv`

Pre robustný RX:

```text
OVERSAMPLE = 16
start-bit qualification
majority vote sample 7/8/9
break detect
baud mismatch tolerancia
```

Toto by som robil ako `uart v2.0`, nie nutne hneď v `uart_test_02`.

---

# 15. Odporúčaný ďalší postup

## Fáza 2A — opraviť integračné nedostatky

Najprv:

```text
1. opraviť file order v build/hal/files.tcl a build/sim/files.f,
2. zapojiť PLL locked do resetu,
3. opraviť autogenerated tb idle UART_RX = 1,
4. presunúť deklaráciu txd_q pred always_ff,
5. pridať ASYNC_REG atribúty.
```

Toto sú malé, ale dôležité veci.

---

## Fáza 2B — doplniť reálne simulácie

Pridať unit testy:

```text
tb_uart_core_tx
tb_uart_core_rx
tb_uart_loopback
```

Bez toho by som nešiel na HW ako „overená knižnica“.

---

## Fáza 2C — opraviť RX STOP/back-to-back robustnosť

Buď:

```text
po validnom stop sample prejsť skôr do IDLE
```

alebo:

```text
pamätať pending_start počas STOP po stop sample
```

Toto je podľa mňa najdôležitejšia zostávajúca RTL vec v simple RX.

---

## Fáza 3 — HW test

Po simuláciách:

```bash
make synth
make program
```

Board test:

```text
115200 8N1 echo
burst paste textu
dlhší stream 1–10 kB
sledovať LED error latch
```

Použi Python test:

```bash
python3 tools/test_uart_loopback.py --port /dev/ttyUSB0 --baud 115200 --count 4096
```

Takýto tool by som do projektu pridal.

---

## Fáza 4 — knižničné rozšírenia

Až potom:

```text
uart_fifo.sv
uart_axil.sv
uart_rx_oversample.sv
```

---

# 16. Upravený status, ktorý by som zapísal

Aktuálne by som `UART_TEST_02_STATUS.md` upravil takto:

```text
Fáza 1 — RTL refactor: čiastočne uzavretá
  OK:
    RX held valid
    registered TXD
    rounded prescale
    reset sync-deassert v uart_test_02_top
    err_clear connected

  OPEN:
    generated filelist still places uart_pkg.sv after import users
    autogenerated tb does not test UART and holds UART_RX low
    PLL locked not used in reset
    RX back-to-back tolerance still weak
    no unit tests yet
```

Teda nie „všetky kritické nedostatky preklenuté“, ale:

```text
väčšina RTL nedostatkov opravená,
integračný generator/testbench a RX robustness ešte otvorené.
```

---

## Záver

`uart_test_02` je dobrý a správnym smerom refaktorovaný UART simple core. Najväčšie plusy:

```text
RX valid/ready je už korektný
TXD je registrovaný
reset wrapper je lepší
prescale je zaokrúhlený
err_clear cesta je zapojená
```

Najbližšie by som nerobil oversampling hneď. Najprv by som uzavrel simple v1.1:

```text
file order
PLL locked reset
reálny UART BFM testbench
RX STOP/back-to-back oprava
per-byte error/tuser alebo aspoň plán
```

Až potom by som išiel do `uart v2.0`:

```text
16x oversampling
majority vote
RX/TX FIFO
AXI-Lite wrapper
interrupty
break detect
```

Takto z `uart_test_02` vznikne pevný základ pre knižničnú UART IP sadu, nie iba board demo.
