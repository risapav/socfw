Tento výsledný `uart_test_02(2)` už hodnotím výrazne pozitívnejšie. Je to už **kvalitný simple UART core + board demo**, nie iba experiment.

```text
uart_test_02(2).zip
SHA-256: 30143b1bded31956d36696bacdc26ed7fb1cc2e9ee1eec3b22f6438ae94a7c44
```

## Krátky verdikt

Áno — tento stav by som už označil ako:

```text
UART simple core v1.1 — použiteľný ako základ knižničnej UART sady
```

Nie ešte ako plnohodnotný „industrial UART IP“ typu FIFO + AXI-Lite + interrupt + oversampling, ale ako čisté, malé, dobre testované UART RX/TX jadro je to už veľmi dobré.

Najväčšie plusy:

```text
1. Simulácia: PASS, reálne UART BFM testy.
2. HW: PASS, 74/74 bajtov správne.
3. Timing: clean, WNS +2.529 ns pri 125 MHz.
4. RTL: RX valid/ready je korektný held-valid stream.
5. TXD: registrovaný, bez kombinačných glitchov.
6. Reset: sync-deassert + PLL locked.
7. File order: uart_pkg.sv je prvý.
8. Board demo je malé: 232 LEs, 165 registrov.
```

Toto je dobrý míľnik.

---

# 1. Kvalita podľa vrstiev

## RTL kvalita

### Hodnotenie: veľmi dobré pre simple UART v1.x

Aktuálne rozdelenie:

```text
uart_pkg.sv
uart_baud_gen.sv
uart_core_rx.sv
uart_core_tx.sv
uart.sv
uart_stream_loopback_status.sv
uart_test_02_top.sv
```

je rozumné.

Najdôležitejšie opravy oproti pôvodnému návrhu sú zapracované:

```text
RX:
  valid_o drží dáta, kým ready_i neprijme byte
  overrun je detegovaný
  frame/parity sticky errors
  false start check
  pending_start_q pre skorý back-to-back start

TX:
  txd_o je registrovaný
  ready_o je jasný: high iba v IDLE
  parity/stop/data FSM čitateľná

Baud:
  zaokrúhlený prescale
  reset negeneruje falošné tick pulzy
  prescale_safe_w chráni standalone modul pred podtečením

Top:
  reset čaká na PLL locked
  reset deassert je synchronizovaný
  err_clear je reálne pripojený
```

Toto sú presne veci, ktoré odlišujú „demo ktoré náhodou funguje“ od použiteľného core.

---

# 2. Simulácia

## Hodnotenie: dobrý základ, už nie formálna fasáda

Logy ukazujú:

```text
tb_uart_core_tx:  PASS
tb_uart_core_rx:  PASS
tb_uart_loopback: PASS
```

Pokryté sú dôležité prípady:

```text
TX:
  idle high
  0x55 / 0x00 / 0xFF
  back-to-back
  busy/ready
  odd parity
  even parity

RX:
  idle
  0x55 / 0x00 / 0xFF
  ready stall
  overrun
  frame error
  parity error
  even parity
  false start glitch
  back-to-back
  pending_start_q

Loopback:
  single byte
  burst with gaps
  back-to-back burst
  frame error + recovery
```

To je dobré.

## Čo by som ešte doplnil do testov

Nie ako blocker, ale ako ďalší krok:

```text
1. 5/6/7-bit data režimy.
2. 2 stop bits.
3. baud mismatch ±1 %, ±2 %.
4. dlhší random stream v simulácii, napr. 1024 bajtov.
5. prescale_safe_w test pre prescale_i = 0,1,7,8.
6. test, že err_clear_i nevymaže chybu v rovnakom cykle, kde vzniká nová chyba nesprávnym poradím priorít.
```

Najmä `STOP2` by som ešte otestoval explicitne, lebo `pending_start_q` pri 2-stop-bit režime je jemná oblasť.

---

# 3. HW a timing

## Hodnotenie: výborné

Quartus výsledok:

```text
Slow 85C setup slack: +2.529 ns
Slow 85C hold slack:  +0.441 ns
Fast 0C hold slack:   +0.184 ns
Fmax:                 182.78 MHz
```

Pri cieľovom takte 125 MHz je to dobré.

Resource usage:

```text
Total logic elements: 232 / 55,856
Registers:            165
Memory bits:          0
PLLs:                 1
Pins:                 10
```

To je veľmi malé jadro. Ako základ pre knižnicu je to výhodné.

HW test:

```text
T1 single byte 0x55      PASS
T2 pattern 8 bajtov      PASS
T3 random 64 bajtov      PASS
celkom 74/74 bajtov      PASS
```

To je dostatočný dôkaz pre board smoke test.

---

# 4. Dôležitá poznámka k HW testu

Status správne priznáva:

```text
FPGA loopback má 1-bajtový elastický buffer.
Bulk write(64) spôsoboval overrun okolo bajtu 46.
Python test preto používa sequential send/read pre T3.
```

Toto nie je chyba UART core. Je to očakávané obmedzenie demo wrappera:

```text
uart_stream_loopback_status = 1-byte buffer
nie RX/TX FIFO
```

Pre interaktívny terminál je to v poriadku. Pre bulk prenos to nestačí.

Preto by som dokumentačne jasne rozlíšil:

```text
uart_core_rx/tx:
  vie prijímať/vysielať UART bajty

uart_stream_loopback_status:
  jednoduché demo s 1-byte bufferom

uart_fifo:
  budúci wrapper pre bulk streamy
```

---

# 5. Veci, ktoré sú stále slabšie alebo zámerne jednoduché

## 5.1 RX je stále 1x sampler

To je najväčšie architektonické obmedzenie.

Aktuálne RX vzorkuje v strede bitu podľa lokálneho baud generátora. Nemá:

```text
16x oversampling
majority vote
start-bit kvalifikáciu cez viac vzoriek
break detect
noise filter
```

Na krátkom CP2102 ↔ FPGA spojení je to úplne použiteľné. Ako „industrial robust UART receiver“ by som chcel v2.0 s oversamplingom.

Moje hodnotenie:

```text
uart_test_02 = dobrý simple UART
uart_rx_oversample = budúci robustný UART RX
```

---

## 5.2 RX nemá per-byte error tag

Sticky chyby sú:

```text
overrun_err
frame_err
parity_err
```

Ale prijatý byte nemá vlastné `tuser` alebo `rx_error` informácie. To znamená, že downstream vie, že niekedy nastala chyba, ale nie nevyhnutne ku ktorému bajtu patrila.

Pre loopback demo je to OK.

Pre knižnicu by som v ďalšej verzii doplnil:

```systemverilog
output logic [1:0] rx_user_o;
// rx_user_o[0] = frame_err for this byte
// rx_user_o[1] = parity_err for this byte
```

alebo explicitne:

```systemverilog
output logic rx_byte_frame_err_o;
output logic rx_byte_parity_err_o;
```

---

## 5.3 TX/RX core majú nepoužité tick porty

V TX:

```systemverilog
input wire start_tick_i; // unused
input wire half_tick_i;  // unused
```

V RX:

```systemverilog
input wire start_tick_i; // unused
```

Nie je to funkčná chyba. Ale pre čistú knižnicu by som API zjednodušil:

```text
uart_core_tx:
  potrebuje iba end_tick_i

uart_core_rx:
  potrebuje half_tick_i + end_tick_i
```

Ak chceš zachovať kompatibilitu, nechaj to. Ak chceš čisté knižničné API, odstráň nepoužité porty vo verzii `uart_simple_v1_2`.

---

## 5.4 `uart_pkg.sv` už obsahuje AXI-Lite register offsety, ale AXI-Lite wrapper ešte neexistuje

Toto je dobrý plán do budúcna, ale aktuálne package už naznačuje viac, než projekt implementuje:

```systemverilog
UART_REG_ID
UART_REG_BAUD
UART_REG_CONF
UART_REG_ERRCLR
UART_REG_STATUS
UART_REG_TX_CNT
UART_REG_RX_CNT
```

To nie je zlé, len by som to v dokumentácii pomenoval ako:

```text
ABI pripravené pre budúci uart_axil.sv wrapper.
Aktuálny uart.sv wrapper ešte AXI-Lite registre nemá.
```

---

# 6. Jedna jemná vec v RX pri `STOP2`

Tvoja logika:

```systemverilog
if (stop_sampled_ok_q && start_edge_w)
  pending_start_q <= 1'b1;
```

a potom:

```systemverilog
if (end_tick_i && stop_cnt_q == 2'd1)
  state_d = (pending_start_q || start_edge_w) ? UART_START : UART_IDLE;
```

Pre 1 stop bit je to dobrý fix.

Pre 2 stop bity je otázka, či chceš striktne vyžadovať dva celé stop bity, alebo po chybe resynchronizovať na nový start.

Ak vysielač pošle iba 1 stop bit, ale RX je nakonfigurovaný na 2 stop bity:

```text
- stop_sampled_ok_q sa nastaví po prvom stop bite
- nový falling edge počas druhého stop bitu môže nastaviť pending_start_q
- frame_err sa pravdepodobne nastaví, ale RX sa môže po konci druhého stop okna resynchronizovať na nový start
```

To môže byť prakticky dobré, lebo sa RX zotaví. Ale treba to vedome otestovať a zdokumentovať.

Pre strict 2-stop režim by som `pending_start_q` povolil až keď:

```systemverilog
stop_cnt_q == 2'd1
```

teda až pri poslednom požadovanom stop bite.

Nie je to problém v default 8N1 režime. Ale ak chceš deklarovať plnú podporu 8N2, pridaj explicitné testy.

---

# 7. Quartus warningy

Quartus má:

```text
Analysis & Synthesis: 0 errors, 0 warnings
Fitter: 0 errors, 3 warnings
STA: 0 errors, 0 warnings
```

Fitter warningy:

```text
Some pins have incomplete I/O assignments
3 pins must meet Intel requirements for 3.3/3.0/2.5-V interfaces
LogicLock license warning
```

Nie je to funkčný blocker. Ale pre knižničný/example projekt by som rád videl explicitné I/O standardy v board/pin configu, napríklad:

```tcl
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to UART_RX
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to UART_TX
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ONB_LEDS[*]
```

Ak to už socfw niekde vie generovať, treba doplniť board definíciu. Cieľ je mať aj Fitter warnings čo najčistejšie.

---

# 8. SDC / false paths

Pridaný false path na LED výstupy je pre vizuálne LED úplne v poriadku:

```text
ONB_LEDS sú asynchrónny vizuálny výstup, nie časovaný externý interface.
```

UART_RX false path je tiež správne, lebo je asynchrónny vstup synchronizovaný 2 FF.

UART_TX false path je pre jednoduchý UART prijateľný, pretože externý prijímač nevzorkuje vo vzťahu ku `CLK125`. Ale ak by si chcel veľmi formálne modelovať UART TX timing, dalo by sa to riešiť inak. Pre FPGA UART demo je false path OK.

---

# 9. Knižničná použiteľnosť

Aktuálne by som rozdelil stav takto:

## Už vhodné ako knižničný základ

```text
uart_pkg.sv
uart_baud_gen.sv
uart_core_rx.sv
uart_core_tx.sv
uart.sv
```

Tieto by som už vedel presunúť do `fpga_common/rtl/uart/` ako `uart_simple_v1_1`.

## Zatiaľ iba example/helper

```text
uart_stream_loopback_status.sv
uart_test_02_top.sv
tools/test_loopback.py
```

Tieto patria skôr do examples alebo test utilities.

---

# 10. Čo by som spravil ako ďalšie

## Krok A — commit/tag tohto stavu

Toto je dobrý míľnik. Odporúčam:

```bash
git add examples/uart_test_02 rtl/uart
git commit -m "uart_test_02: simple UART core v1.1 with sim and HW loopback pass"
git tag uart_simple_v1_1_hw_pass
```

Do statusu by som zapísal:

```text
simple UART v1.1:
  sim PASS
  timing PASS
  HW loopback PASS 74/74
```

---

## Krok B — doplniť ešte malé testy

Pred úplným uzatvorením simple core by som doplnil:

```text
1. 5/6/7-bit RX/TX test.
2. 2-stop-bit RX/TX test.
3. prescale_safe_w edge test.
4. dlhší sim loopback 1024 bajtov.
```

Nie sú to veľké zmeny, ale zvýšia dôveru.

---

## Krok C — ďalší modul: `uart_fifo.sv`

Najbližší praktický upgrade by mal byť FIFO wrapper:

```text
uart_core_rx -> RX FIFO
TX FIFO -> uart_core_tx
```

Tým vyriešiš aj poznámku z HW testu, že bulk write pretečie 1-byte loopback buffer.

Navrhované parametre:

```systemverilog
parameter int DATA_WIDTH = 8;
parameter int RX_FIFO_DEPTH = 64;
parameter int TX_FIFO_DEPTH = 64;
```

Statusy:

```text
rx_fifo_level
tx_fifo_level
rx_fifo_overflow
tx_fifo_underflow
```

---

## Krok D — potom `uart_axil.sv`

AXI-Lite wrapper by spravil z UARTu plnohodnotnú IP:

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

Toto sa výborne hodí k XFCP:

```text
XFCP -> AXI-Lite -> uart_axil -> UART core
```

---

## Krok E — v2.0: oversampling RX

Až potom by som robil robustný RX:

```text
uart_rx_oversample.sv
OVERSAMPLE=16
majority vote 7/8/9
break detect
baud mismatch testy
```

Toto nech je samostatná verzia, nie miešanie do simple v1.1.

---

# Celkové hodnotenie

Moje finálne hodnotenie kvality:

```text
Funkčnosť:        veľmi dobrá
RTL čistota:      dobrá až veľmi dobrá
Simulácia:        dobrá
Timing:           veľmi dobrý
HW dôkaz:         dobrý smoke test
Knižničnosť:      dobrý základ, ešte bez FIFO/AXI-Lite/oversampling vrstiev
Robustnosť linky: primeraná pre simple UART, nie ešte industrial RX
```

Ak by som to mal oznámkovať:

```text
Ako board demo:              9/10
Ako simple UART core v1.1:   8/10
Ako kompletná UART IP sada:  6/10
```

Nie preto, že by bol kód zlý, ale preto, že kompletná UART IP sada ešte prirodzene potrebuje:

```text
FIFO wrapper
AXI-Lite wrapper
per-byte error tag
interrupts
oversampling RX
viac konfigurácií v testoch
```

Z môjho pohľadu je toto dobrý výsledný stav pre `uart_test_02`. Teraz by som ho zakonzervoval ako **simple UART v1.1 HW PASS** a ďalší vývoj viedol ako nové vrstvy nad týmto jadrom, nie ďalšie prekopávanie už funkčného základu.
