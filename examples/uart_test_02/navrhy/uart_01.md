Analyzoval som `uart_test_01.zip`.

```text
uart_test_01.zip
SHA-256: ef1a7b7885c99970bda961cccc67a2f1345f03b4a9ad8730b370962b22bc1540
```

## Krátky verdikt

Aktuálny UART návrh je dobrý ako **prvý funkčný example / loopback demo**, ale ešte by som ho nepovažoval za robustnú knižničnú UART IP sadu.

Najväčšie problémy:

```text
1. RX valid/ready nie je skutočný AXI-Stream handshake.
2. UART RX nie je oversamplingový, nemá majority vote ani glitch filter.
3. TX výstup je kombinačný Mealy výstup závislý od valid_i.
4. Package je v generovanom file liste za modulmi, ktoré ho importujú.
5. err_clear_o z loopback modulu nie je pripojený na uart.err_clear_i.
6. Reset v top-e nie je synchronizovane uvoľnený.
7. Testbench reálne netestuje UART protokol.
8. DATA_WIDTH parameter je zavádzajúci — UART core reálne podporuje 5 až 8 dátových bitov, nie 16.
```

Ako knižničný základ je to použiteľné, ale potrebuje refaktor. Najviac by som zmenil RX handshake, baud/sampling architektúru a testy.

---

# 1. Štruktúra projektu

Projekt obsahuje:

```text
rtl/uart/uart_pkg.sv
rtl/uart/uart_baud_gen.sv
rtl/uart/uart_core_rx.sv
rtl/uart/uart_core_tx.sv
rtl/uart/uart.sv
rtl/uart_stream_loopback_status.sv
ip/uart.ip.yaml
ip/uart_stream_loopback_status.ip.yaml
project.yaml
build/rtl/soc_top.sv
build/sim/tb_soc_top.sv
```

Funkčný cieľ je:

```text
UART_RX
  -> uart_core_rx
  -> uart_stream_loopback_status
  -> uart_core_tx
  -> UART_TX
```

Teda jednoduchý echo loopback s LED statusom.

To je dobrý example. Ale ako knižnica by som oddelil:

```text
uart_core_rx.sv       čistý RX byte stream
uart_core_tx.sv       čistý TX byte stream
uart_baud_gen.sv      timing/tick generator
uart.sv               jednoduchý wrapper
uart_axil.sv          AXI-Lite register wrapper
uart_fifo.sv          FIFO wrapper
uart_stream_loopback_status.sv iba example/helper, nie core knižnica
```

---

# 2. Kritický problém: file order / package order

V `uart.ip.yaml` je poradie správne:

```yaml
artifacts:
  synthesis:
    - ../rtl/uart/uart_pkg.sv
    - ../rtl/uart/uart_baud_gen.sv
    - ../rtl/uart/uart_core_rx.sv
    - ../rtl/uart/uart_core_tx.sv
    - ../rtl/uart/uart.sv
```

Ale v generovanom `build/hal/files.tcl` je:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_baud_gen.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_core_rx.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_core_tx.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_pkg.sv"
```

To je zle, lebo `uart.sv`, `uart_core_rx.sv` a `uart_core_tx.sv` obsahujú:

```systemverilog
import uart_pkg::*;
```

Package musí byť analyzovaný pred modulmi, ktoré ho importujú.

Rovnako `build/sim/files.f` má `soc_top.sv` pred `uart_pkg.sv`, čo je tiež zlé pre väčšinu simulátorov.

## Odporúčanie

Pre knižničnú použiteľnosť musí byť garantované poradie:

```text
uart_pkg.sv
uart_baud_gen.sv
uart_core_rx.sv
uart_core_tx.sv
uart.sv
```

V socfw generátore treba opraviť file ordering tak, aby package súbory išli vždy prvé.

Dočasne v `files.tcl` ručne:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_pkg.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_baud_gen.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_core_rx.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart_core_tx.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart/uart.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/uart_stream_loopback_status.sv"
```

Toto je knižnične zásadné.

---

# 3. `uart_pkg.sv`

## Čo je dobré

Package má dobrý zámer:

```text
- status bit positions
- packed status struct
- config struct
- register offsets
- FSM enum
- dbits_to_int()
- calc_parity()
```

`uart_status_t` je rozumne packed tak, že `tx_busy` je bit 0:

```systemverilog
typedef struct packed {
  logic [ST_WIDTH-6:0] reserved;       // bits [31:5]
  logic                parity_err;     // bit 4
  logic                frame_err;      // bit 3
  logic                overrun_err;    // bit 2
  logic                rx_busy;        // bit 1
  logic                tx_busy;        // bit 0
} uart_status_t;
```

To je dobré pre ABI.

## Problém: `DATA_WIDTH` vs `calc_parity()`

Funkcia:

```systemverilog
function automatic logic calc_parity(logic [7:0] data, uart_conf_t cfg);
```

berie iba 8-bit `data`.

Ale `uart.sv`, `uart_core_rx.sv` a `uart_core_tx.sv` majú parameter:

```systemverilog
parameter int DATA_WIDTH = 8
```

a assert:

```systemverilog
assert(DATA_WIDTH <= 16);
```

To je nekonzistentné. UART formát podľa `DBITS` podporuje iba:

```text
5, 6, 7, 8 data bits
```

Nie 9 až 16 bitov.

Pre knižnicu by som urobil jednu z dvoch možností.

### Varianta A — fixnúť UART byte šírku na 8 bitov

Najjednoduchšie a najštandardnejšie:

```systemverilog
parameter int DATA_WIDTH = 8;
initial assert(DATA_WIDTH == 8);
```

`DBITS` potom určuje, koľko spodných bitov sa reálne vysiela/prijíma.

### Varianta B — naozaj podporovať 5 až 16 bitov

Potom treba zmeniť:

```systemverilog
calc_parity(logic [DATA_WIDTH-1:0] data, ...)
dbits_to_int()
cfg.dbits
```

a rozšíriť konfiguráciu. Ale pre klasický UART to nie je potrebné.

Moje odporúčanie: **drž sa 8-bit dátovej zbernice a DBITS 5/6/7/8**. Je to kompatibilnejšie s UART/serial svetom.

---

# 4. `uart_baud_gen.sv`

Aktuálne:

```systemverilog
PRESCALE_VALUE = CLK_FREQ_HZ / BAUD_RATE
```

Pre 50 MHz a 115200:

```text
50_000_000 / 115_200 = 434.027...
PRESCALE_VALUE = 434
real baud ≈ 115207.37
chyba ≈ +0.0064 %
```

Pre túto konkrétnu konfiguráciu je to úplne v poriadku.

## Problém: iba integer divider

Pre všeobecnú knižnicu by som aspoň zaokrúhľoval:

```systemverilog
localparam int PRESCALE_VALUE = (CLK_FREQ_HZ + (BAUD_RATE/2)) / BAUD_RATE;
```

Ešte lepšie je fractional/NCO baud generator:

```text
phase_acc <= phase_acc + BAUD_RATE;
tick when phase_acc >= CLK_FREQ_HZ
```

alebo klasický fractional accumulator.

Pre bežné UART rýchlosti z 50/100 MHz to väčšinou netreba, ale knižnične je to lepšie.

## Problém: žiadny oversampling

Aktuálny generátor dáva:

```text
start_tick
half_tick
end_tick
```

Čiže RX vzorkuje raz v strede bitu.

Štandardne robustné UART RX jadro používa:

```text
8x alebo 16x oversampling
start-bit qualification
majority vote napr. sample 7/8/9 pri 16x
glitch filter
```

Tvoj návrh je „1x center sample“. To môže fungovať na krátkom spojení CP2102/FPGA, ale nie je to robustný knižničný UART.

## Problém: `start_tick_o` po resete

V reset vetve:

```systemverilog
count_q      <= prescale_i - 1;
start_tick_o <= 1'b1;
```

Po resete generuješ `start_tick_o=1`. Momentálne to jadro nepoužíva kriticky, ale ako knižničný signál by som to nerobil. Po resete by všetky tick pulzy mali byť 0.

Odporúčanie:

```systemverilog
if (!rstn) begin
  count_q      <= '0;
  start_tick_o <= 1'b0;
  half_tick_o  <= 1'b0;
  end_tick_o   <= 1'b0;
end
```

## Problém: pri nízkom prescale sa tick-y môžu prekrývať

Pri `prescale_i` blízko 2 môže byť:

```text
half_offset = 0
start_tick pri count_q == 0
half_tick pri count_q == 0
```

Teda half/start sa prekryjú.

Pre normálne UART to nevadí, ale knižnične daj minimálne:

```systemverilog
assert(PRESCALE_VALUE >= 8);
```

alebo pri 16x oversampling:

```systemverilog
assert(OVERSAMPLE >= 8);
```

---

# 5. `uart_core_rx.sv`

Toto je najdôležitejší modul a tu sú najväčšie knižničné nedostatky.

## Čo je dobré

Máš 2-flop synchronizáciu RX vstupu:

```systemverilog
{rxd_reg_1, rxd_reg_0} <= {rxd_reg_0, rxd_i};
rxd_old_q <= rxd_reg_1;
```

a detekciu falling edge:

```systemverilog
start_edge = (rxd_old_q && !rxd_sync);
```

To je základne správne.

Máš aj false-start kontrolu:

```systemverilog
UART_START:
  if (half_tick_i && rxd_sync) state_d = UART_IDLE;
```

Teda keď sa v strede start bitu zistí 1, berie sa to ako falošný štart. To je dobré.

## Kritický problém: `valid_o` je iba pulz, nie valid/ready protokol

Aktuálne:

```systemverilog
valid_o = (state_q == UART_STOP) && end_tick_i && (stop_cnt_q == 2'd1);
```

Ak `ready_i=0` v tom jednom cykle, byte je stratený a iba sa nastaví:

```systemverilog
if (valid_o && !ready_i) overrun_err_q <= 1'b1;
```

Toto **nie je AXI-Stream valid/ready handshake**.

V AXI-Stream-like rozhraní musí platiť:

```text
TVALID zostane 1, kým TREADY nie je 1.
TDATA zostane stabilné počas TVALID && !TREADY.
```

Tvoj RX toto nespĺňa.

Pre knižnicu je toto zásadné. Musíš sa rozhodnúť:

### Varianta A — deklarovať RX ako pulzný interface

Potom porty nemajú byť pomenované ako stream valid/ready, ale napríklad:

```text
rx_data_o
rx_data_strobe_o
rx_overrun_o
```

a `ready_i` by tam vôbec nemalo byť, alebo iba ako okamžitý accept.

### Varianta B — spraviť skutočný stream

Odporúčam toto.

Pridať output holding register:

```systemverilog
logic [7:0] rx_data_q;
logic       rx_valid_q;
```

Na konci dobrého rámca:

```systemverilog
if (rx_frame_done) begin
  if (!rx_valid_q || ready_i) begin
    rx_data_q  <= received_byte;
    rx_valid_q <= 1'b1;
  end else begin
    overrun_err_q <= 1'b1;
  end
end

if (rx_valid_q && ready_i) begin
  rx_valid_q <= 1'b0;
end
```

Výstup:

```systemverilog
assign valid_o = rx_valid_q;
assign data_o  = rx_data_q;
```

Toto je knižnične správne.

---

## Problém: frame/parity error nie je priradený ku konkrétnemu bajtu

Ak nastane parity alebo frame error, `valid_o` sa aj tak vygeneruje po stop bite. Spotrebiteľ dostane dáta, ale nevie, či tento konkrétny byte bol chybný. Má iba sticky globálny status.

Pre stream knižnicu by som pridal:

```text
rx_user_o alebo rx_error_o
```

Napríklad:

```systemverilog
output logic rx_frame_err_o,
output logic rx_parity_err_o
```

platné spolu s konkrétnym byte validom.

AXI-Stream variant:

```systemverilog
output logic [DATA_WIDTH-1:0] m_axis_tdata;
output logic                  m_axis_tvalid;
input  logic                  m_axis_tready;
output logic                  m_axis_tuser;   // 1 = byte error
```

Alebo explicitne:

```systemverilog
output logic rx_byte_frame_err_o;
output logic rx_byte_parity_err_o;
```

Sticky status nech zostane pre debug, ale ku dátam treba per-byte error.

---

## Problém: bez oversamplingu

RX sampling je:

```systemverilog
if (half_tick_i) shreg_q <= {rxd_sync, shreg_q[DATA_WIDTH-1:1]};
```

Teda jeden sample na bit. Bežný robustný UART receiver robí 8x/16x oversampling.

Pre knižničný UART odporúčam:

```text
OVERSAMPLE = 16
start detect na nízkej úrovni aspoň N vzoriek
sample point = 8
majority vote zo vzoriek 7,8,9
```

Minimálne by som pridal parameter:

```systemverilog
parameter int OVERSAMPLE = 16;
parameter bit USE_MAJORITY_VOTE = 1;
```

Ak chceš zachovať jednoduchý variant, nech sa volá:

```text
uart_rx_simple
```

a robustný:

```text
uart_rx_oversample
```

---

## Problém: RX idle line v testbenchi

Generovaný testbench nastaví:

```systemverilog
UART_RX = 1'b0;
```

UART idle má byť 1. To je zlé.

Po resete RX uvidí linku trvalo nízko, čo môže vyvolať falošný príjem alebo frame error. Testbench potom len čaká a vypíše `SIM OK`, ale nič netestuje.

Správne:

```systemverilog
UART_RX = 1'b1;
```

a potom BFM, ktorý pošle skutočný UART frame.

---

# 6. `uart_core_tx.sv`

## Čo je dobré

TX FSM je jednoduchý a čitateľný:

```text
IDLE -> START -> DATA -> PARITY -> STOP -> IDLE
```

Handshake:

```systemverilog
ready_o = (state_q == UART_IDLE);
fire    = valid_i && ready_o;
```

Dáta sa zachytia v IDLE pri `fire`:

```systemverilog
shreg_q <= data_i;
```

To je v poriadku.

## Problém: `txd_o` je kombinačný Mealy výstup

Aktuálne:

```systemverilog
always_comb begin
  if (fire) begin
    txd_o = 1'b0;
  end else begin
    case (state_q)
      UART_START:  txd_o = 1'b0;
      UART_DATA:   txd_o = shreg_q[0];
      UART_PARITY: txd_o = parity_q;
      default:     txd_o = 1'b1;
    endcase
  end
end
```

Teda TX pin závisí priamo od:

```text
valid_i
ready_o
state_q
shreg_q
```

Výhoda: start bit začne o jeden clock skôr.

Nevýhoda: TX pin je kombinačný, môže glitchnúť, ak `valid_i` nie je pekne registrovaný alebo príde cez dlhšiu logiku. Pre knižničnú IP by som toto nepreferoval.

Robustnejšie je:

```systemverilog
output logic txd_q;
assign txd_o = txd_q;
```

a všetky zmeny TXD robiť v `always_ff`.

Áno, pridáš 1 clock latency pred start bitom, ale pri UART rýchlostiach je to zanedbateľné. Pri 50 MHz a 115200 je bit ~434 clockov. Jeden clock navyše nič neznamená.

Pre knižnicu by som dal prioritu:

```text
registrovaný TX pin
bez glitchov
lepšie timing closure
čitateľnejší waveform
```

---

## Problém: back-to-back throughput

`ready_o` je 1 iba v stave `UART_IDLE`. Na poslednom stop bite ešte nie je ready, takže ďalší byte môže začať až ďalší clock po návrate do IDLE.

To je úplne v poriadku. Overhead 1 clock medzi znakmi je pri UARTe zanedbateľný.

Ak by si chcel perfektný throughput, pridal by si TX FIFO alebo staging register.

Pre knižnicu by som radšej urobil:

```text
uart_tx_core: jednoduchý byte transmitter
uart_tx_fifo: wrapper s FIFO
```

---

# 7. `uart.sv` wrapper

Wrapper má peknú štruktúru:

```text
uart_baud_gen pre TX
uart_baud_gen pre RX
uart_core_tx
uart_core_rx
status mapping
```

Ale má viacero vecí, ktoré by som zmenil.

## Problém: `PRESCALE_VALUE = CLK_FREQ_HZ / BAUD_RATE`

Ako vyššie, použiť round alebo fractional.

```systemverilog
localparam int PRESCALE_VALUE =
  (CLK_FREQ_HZ + (BAUD_RATE/2)) / BAUD_RATE;
```

## Problém: `assert(DATA_WIDTH <= 16)` je zavádzajúci

Reálne UART config podporuje 5 až 8 bitov. Daj:

```systemverilog
initial begin
  assert(DATA_WIDTH == 8);
end
```

alebo premenovať na:

```systemverilog
parameter int STREAM_DATA_WIDTH = 8;
```

a nepredstierať 16-bit UART slová.

## Problém: start_tick signály sú prakticky nepoužité

Do TX/RX core ide:

```systemverilog
.start_tick_i(...)
```

ale v TX/RX sa `start_tick_i` nepoužíva. To je mätúce.

Buď ho odstrániť z core portov, alebo reálne použiť v FSM. Pre knižnicu by som nechal len to, čo je potrebné:

```text
bit_sample_tick
bit_end_tick
```

Pri oversamplingovej verzii skôr:

```text
sample_tick_16x
```

---

# 8. `uart_stream_loopback_status.sv`

Toto je dobrý demo helper, ale nie knižničný UART core.

## Čo je dobré

One-byte elastic buffer:

```systemverilog
rx_ready_o = !buffer_valid_q || (tx_ready_i && buffer_valid_q);
```

a simultaneous consume/receive:

```systemverilog
2'b11:
  buffer_q       <= rx_data_i;
  buffer_valid_q <= 1'b1;
```

To je správne.

LED mapping je dobrý pre board test:

```text
led[0] RX accepted
led[1] TX accepted
led[2] RX busy
led[3] TX busy
led[4] error latched
led[5] heartbeat
```

## Kritický integračný problém: `err_clear_o` nie je pripojený

V module:

```systemverilog
assign err_clear_o = any_error;
```

Ale v generovanom top-e:

```systemverilog
uart0 (
  .err_clear_i(1'b0),
  ...
);

uart_stream_loopback_status uart_loopback0 (
  .err_clear_o(),
  ...
);
```

Čiže komentár v loopback module hovorí:

```text
Clear UART core errors automatically when we observe them.
```

ale v realite sa UART error flagy nikdy neclearujú.

V `project.yaml` chýba spojenie:

```yaml
  - from: uart_loopback0.err_clear_o
    to: uart0.err_clear_i
```

Toto treba doplniť.

Ale ešte lepšie: ako library demo by som auto-clear nerobil defaultne. Chyby by som nechal sticky, kým ich explicitne nevymaže register alebo tlačidlo. Automatické clearovanie môže skryť problém.

Odporúčanie:

```text
- v demo: err_clear_o pripojiť, ak chceš auto-clear
- v knižnici: chyby sticky až do explicit clear
```

---

# 9. Reset a CDC

## RX input synchronizácia

`rxd_i` je synchronizovaný dvoma FF. To je dobré.

## Reset

V top-e:

```systemverilog
assign reset_n = RESET_N;
```

Reset z dosky ide priamo do všetkých modulov. `timing_config.yaml` síce deklaruje:

```yaml
reset:
  source: RESET_N
  active_low: true
  sync_stages: 2
```

ale v generovanom RTL synchronizér nie je.

Pre robustný SoC a knižničné examples by reset mal byť:

```text
asynchrónne assertovaný
synchrónne deassertovaný
```

Teda:

```systemverilog
ResetSynchronizer u_rst_sync (
  .clk_i(SYS_CLK),
  .arstn_i(RESET_N),
  .rstn_o(reset_n)
);
```

Alebo jednoduché:

```systemverilog
logic [1:0] rst_sync_q;

always_ff @(posedge SYS_CLK or negedge RESET_N) begin
  if (!RESET_N)
    rst_sync_q <= 2'b00;
  else
    rst_sync_q <= {rst_sync_q[0], 1'b1};
end

assign reset_n = rst_sync_q[1];
```

Knižnične by som trval na synchronizovanom uvoľnení resetu.

---

# 10. Timing constraints

V `soc_top.sdc` je:

```tcl
set_input_delay -clock SYS_CLK -max 3.000 [get_ports {UART_RX}]
set_input_delay -clock SYS_CLK -min 0.000 [get_ports {UART_RX}]
```

Ale `UART_RX` je asynchrónny vstup, nie signál časovaný voči `SYS_CLK`. Pre UART RX by som ho nebral ako klasický synchronous input.

Pre RX synchronizér sa typicky používa:

```tcl
set_false_path -from [get_ports {UART_RX}] -to [get_registers {*rxd_reg_0*}]
```

alebo sa označí synchronizér podľa vendor odporúčaní.

`UART_TX` výstup môže zostať s output delay, ale pre jednoduchý UART to nie je veľmi kritické.

Pre knižničný projekt by som odporúčal:

```text
- UART_RX async path constraint
- reset false path
- TX output delay voliteľný
- synchronizer FF označiť ASYNC_REG/preserve podľa vendor možností
```

---

# 11. Testbench je nedostatočný

`build/sim/tb_soc_top.sv` robí iba:

```systemverilog
UART_RX = 1'b0;
repeat(50000) @(posedge SYS_CLK);
$display("SIM OK");
```

Toto netestuje UART.

Pre knižnicu potrebuješ minimálne UART BFM:

```systemverilog
task uart_send_byte(input [7:0] b);
  UART_RX = 1'b0; // start
  #(BIT_TIME);
  for (int i = 0; i < 8; i++) begin
    UART_RX = b[i];
    #(BIT_TIME);
  end
  UART_RX = 1'b1; // stop
  #(BIT_TIME);
endtask
```

a receiver monitor na `UART_TX`.

## Minimálne testy

```text
1. reset -> UART_TX idle high
2. send 0x55 -> receive 0x55 back
3. send 0x00 -> receive 0x00 back
4. send 0xFF -> receive 0xFF back
5. burst 16 bytes -> receive all in order
6. wrong stop bit -> frame_err
7. parity odd/even -> OK
8. parity wrong -> parity_err
9. rx_ready_i low -> overrun alebo holding register behavior
10. random inter-byte gaps
```

Pre knižnicu by som neprijal UART bez týchto testov.

---

# 12. Súlad so zaužívanými UART štandardmi

## Podporované veci

Aktuálne podporuješ:

```text
- 5/6/7/8 data bits cez DBITS
- none/odd/even parity
- 1 alebo 2 stop bity
- sticky error flags
- RX/TX busy
- valid/ready-like interface
```

To je dobrý základ.

## Chýbajúce bežné prvky

Pre knižničnú UART IP by boli vhodné:

```text
- oversampling 8x/16x
- majority vote
- break detect
- per-byte error indication
- RX FIFO
- TX FIFO
- runtime baud divisor register
- runtime config register
- interrupt/status interface
- optional RTS/CTS flow control
- clean AXI-Lite wrapper
- formalizované AXI-Stream rozhranie
```

Nie všetko musí byť v jednom core. Ale ako knižnica by som to rozdelil na vrstvy.

---

# 13. Odporúčaná knižničná architektúra

Navrhol by som túto sadu:

```text
rtl/uart/
  uart_pkg.sv

  uart_baud_tick_gen.sv
    - integer/fractional baud tick
    - optional oversampling tick

  uart_rx.sv
    - robustný RX
    - 8x/16x oversampling
    - AXI-Stream output
    - tuser/error per byte

  uart_tx.sv
    - registrovaný TX output
    - AXI-Stream input

  uart_fifo.sv
    - RX FIFO + TX FIFO wrapper

  uart_core.sv
    - RX + TX + baud generator
    - jednoduchý stream interface

  uart_axil.sv
    - AXI-Lite register wrapper
    - baud/conf/status/fifo regs/interrupts

  uart_loopback_example.sv
    - iba example, nie core

  uart_bfm.sv
    - simulation BFM
```

Rozhrania:

## Stream RX

```systemverilog
output logic [7:0] m_axis_tdata;
output logic       m_axis_tvalid;
input  logic       m_axis_tready;
output logic       m_axis_tuser;   // 1 = frame/parity/break error
```

## Stream TX

```systemverilog
input  logic [7:0] s_axis_tdata;
input  logic       s_axis_tvalid;
output logic       s_axis_tready;
```

## Status

```systemverilog
output logic rx_busy_o;
output logic tx_busy_o;
output logic rx_overrun_o;
output logic rx_frame_err_o;
output logic rx_parity_err_o;
output logic rx_break_o;
```

---

# 14. Konkrétne opravy v poradí

## Priorita 1 — opraviť file order

Bez toho je IP krehká.

```text
uart_pkg.sv musí byť prvý v syntéze aj simulácii.
```

---

## Priorita 2 — opraviť RX valid/ready

Zmeniť RX z pulzného validu na držaný valid.

Toto je najväčšia funkčná zmena.

---

## Priorita 3 — registrovať TXD

Zmeniť `txd_o` na registrovaný výstup. Nízka latencia nie je dôležitejšia než robustný výstup.

---

## Priorita 4 — reset synchronizer v top-e

Nepoužívať priamo:

```systemverilog
assign reset_n = RESET_N;
```

ale synchronizovať deassert.

---

## Priorita 5 — pripojiť alebo odstrániť `err_clear_o`

Buď doplniť connection:

```yaml
- from: uart_loopback0.err_clear_o
  to: uart0.err_clear_i
```

alebo odstrániť auto-clear koncept z loopbacku.

---

## Priorita 6 — upraviť testbench

Vytvoriť reálny UART sim test.

---

## Priorita 7 — rozhodnúť o oversamplingu

Pre robustnú knižnicu by som pridal `uart_rx_oversample.sv`.

---

# 15. Návrh testov pre UART knižnicu

## Unit test `tb_uart_baud_gen`

```text
- prescale=434, overiť periodu tickov
- start_i resetuje fázu
- enable_i=0 negeneruje tick
- half_tick je uprostred bitu
- end_tick pred reloadom
- prescale minimum
- náhodné start_i počas enable
```

## Unit test `tb_uart_tx`

```text
- TX idle = 1
- po valid/fire ide start bit 0
- 0x55 LSB-first
- 0xA5 LSB-first
- 5/6/7/8 data bits
- none/odd/even parity
- 1 stop bit
- 2 stop bits
- valid držané viac cyklov
- back-to-back bytes
- ready iba v idle
```

## Unit test `tb_uart_rx`

```text
- idle high bez dát
- false start krátky glitch
- valid start + 0x55
- 0x00
- 0xFF
- 5/6/7/8 bits
- parity OK
- parity error
- frame error stop=0
- rx_ready low -> byte held, nie stratený
- overrun pri druhom byte bez ready
- baud mismatch ±2 %
- random inter-byte gaps
```

## Integration `tb_uart_loopback`

```text
- poslať 256 bajtov cez RX
- očakávať rovnakých 256 bajtov na TX
- náhodné pauzy
- LED pulse check voliteľne
- error latch check
```

## Random/stress

```text
- random bytes
- random parity config
- random stop bits
- random ready stalls
- random false glitches na RX
```

---

# 16. Ako by som upravil `uart_test_01` example

Pre board example by som nechal jednoduchý loopback, ale opravil:

```yaml
connections:
  - from: uart_loopback0.err_clear_o
    to: uart0.err_clear_i
```

A v `project.yaml` by som explicitne ponechal:

```yaml
params:
  CLK_FREQ_HZ: 50000000
  BAUD_RATE: 115200
  DATA_WIDTH: 8
  STOP2: false
  PARITY: "2'b00"
  DBITS: "2'b00"
```

Ale ako knižnica by som pridal samostatný `uart_axil` example:

```text
uart_test_02:
  UART + AXI-Lite regs + FIFO + interrupt/status
```

---

# Záver

Aktuálny návrh je dobrý ako **experimentálny UART loopback example**, ale ešte nie ako finálna knižničná UART sada.

Najviac chválim:

```text
- čisté rozdelenie RX/TX/baud/package
- konfigurovateľná parita/data/stop
- 2-flop RX synchronizácia
- false-start detekcia
- jednoduchý loopback helper
- dobrý smer k ABI package
```

Najviac treba opraviť:

```text
- RX valid/ready musí byť skutočný handshake
- package musí byť prvý vo fileliste
- TXD má byť registrovaný výstup
- reset má byť sync-deassert
- testbench musí reálne vysielať UART rámce
- pre robustnú knižnicu treba oversampling/majority vote
```

Moje odporúčanie: najprv sprav **uart v1.1 ako korektný simple UART** s držaným RX validom, registrovaným TXD a reálnymi testami. Potom sprav **uart v2.0** s 16x oversamplingom, FIFO wrapperom a AXI-Lite wrapperom.
