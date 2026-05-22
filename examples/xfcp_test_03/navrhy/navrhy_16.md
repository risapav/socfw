Nižšie odpovedám priamo ako „externý expert“ na otázky z `EXPERT_BRIEF.md`. Najprv by som však opravil jeden vstupný predpoklad: v brief-e je uvedené **FT232R?**, ale ty si doplnil, že používaš **CP2102**. Preto by som hypotézu „FTDI EEPROM loopback“ znížil na nerelevantnú pre aktuálny HW, kým sa fyzicky nepotvrdí, že ide naozaj o FTDI čip.

---

# 9.1 Fyzická diagnostika

## 1. Ako rozlíšiť USB-UART loopback vs. PCB/TX→RX coupling bez osciloskopu?

Najlepšie bez osciloskopu je spraviť **izolačné experimenty**, nie ďalšie XFCP testy.

### Test A — čistý USB-UART adaptér bez FPGA

Odpoj adaptér od FPGA a na strane adaptéra nechaj len USB. Otvor port v Pythone a zapisuj dáta. Ak sa ti v receive bufferi objavia rovnaké dáta, máš echo/loopback na adaptéri alebo v driveri.

```python
import serial, time

ser = serial.Serial("/dev/ttyUSB0", 115200, timeout=0.1)
ser.reset_input_buffer()
ser.write(bytes([0x55, 0xAA, 0xFE, 0xFD]) * 100)
time.sleep(0.2)
data = ser.read(1000)
print(len(data), data[:32])
```

Očakávanie:

```text
0 bajtov → adaptér sám neecho-uje
>0 bajtov → adaptér/driver/loopback problém
```

### Test B — FPGA TX toggling bez PC TX aktivity

Sprav dočasný bitstream, ktorý **iba vysiela pattern na FPGA UART_TX_o** a zároveň počíta, či `axis_uart_rx` na FPGA strane zachytáva bajty alebo frame errors. PC počas toho neposiela nič.

Ak RX counter na FPGA rastie, keď FPGA iba vysiela, potom je väzba lokálna:

```text
FPGA_TX_o → FPGA_RX_i
```

Ak RX counter nerastie, coupling nie je potvrdený.

### Test C — fyzické odpojenie FPGA TX od USB-UART RX

Ak máš možnosť odpojiť iba vodič:

```text
FPGA_TX_o → USB-UART_RXD
```

a nechať:

```text
USB-UART_TXD → FPGA_RX_i
```

potom FPGA nebude môcť odpovedať PC, ale vieš testovať, či počas lokálne generovaného TX patternu pribúdajú RX frame errors v interných counteroch. Toto potrebuje alternatívny spôsob čítania counterov, napríklad SignalTap alebo LED/debug výstup.

### Test D — druhý USB-UART ako sniffer

Pripoj druhý adaptér iba ako monitor:

```text
sniffer RX ← FPGA_TX_o
sniffer RX ← PC_TXD
```

Nie naraz na jeden pin, ale postupne. Ak sniffer vidí korektné TX z FPGA, ale hlavný PC port dostáva 0B, problém nie je nutne FPGA TX.

**Môj názor:** pri CP2102 a krátkych cestách by som najprv neveril fyzickému coupling-u ako definitívnemu záveru. Najprv treba dokázať, že `FPGA_TX_o` spôsobí aktivitu na `FPGA_RX_i`, keď PC nič neposiela.

---

## 2. Ak by to bol FTDI loopback, ako ho vypnúť v Linuxe?

Pre aktuálny CP2102 to pravdepodobne neplatí. Ak by sa ukázalo, že adaptér je predsa FTDI, treba najprv potvrdiť typ:

```bash
lsusb
udevadm info -a -n /dev/ttyUSB0 | grep -iE "vendor|product|serial"
```

FTDI má oficiálny nástroj **FT_PROG** na úpravu EEPROM konfigurácie zariadení; FTDI ho opisuje ako EEPROM programming utility na úpravu device descriptorov a konfigurácie FTDI zariadení. ([FTDI][1])

Na Linuxe sa dá pracovať aj cez `libftdi`/`ftdi_eeprom` alebo PyFtdi `ftconf.py`; PyFtdi dokumentácia uvádza `ftconf.py` ako command-line nástroj na správu FTDI EEPROM. ([Eblot][2])

Ale pozor: neexistuje bežné štandardné nastavenie „echo TX späť do RX“ pre normálny UART režim. Ak vidíš echo, častejšie je to:

```text
- fyzicky prepojené TX/RX,
- softvérový testový loopback,
- nesprávny kábel/modul,
- bitbang alebo špeciálny režim,
- externá väzba na doske.
```

Pre CP2102 by som túto vetvu teraz neriešil.

---

## 3. RC filter 1 kΩ + 10 nF na UART_RX — je to realistické?

Nie, **1 kΩ + 10 nF by som pri 115200 baud nedal**.

Výpočet:

```text
baud = 115200
bit period = 1 / 115200 ≈ 8.68 µs
RC = 1 kΩ × 10 nF = 10 µs
```

Časová konštanta 10 µs je väčšia než jeden UART bit. To ti výrazne zaoblí hrany a môže samo spôsobovať frame errors.

Ako orientačné pravidlo by som chcel:

```text
RC << bit period
ideálne RC ≤ 0.5 µs až 1 µs pri 115200 baud
```

Praktickejšie hodnoty:

```text
1 kΩ + 100 pF  → 0.1 µs
1 kΩ + 220 pF  → 0.22 µs
1 kΩ + 470 pF  → 0.47 µs
1 kΩ + 1 nF    → 1.0 µs, horná hranica experimentu
```

Začal by som ešte jednoduchšie:

```text
- sériový odpor 100 Ω až 1 kΩ do FPGA_RX,
- bez kapacity,
- až potom 100–470 pF na zem.
```

Ak 1 kΩ + 470 pF zlepší výsledok, potom môže ísť o krátke špičky/edge coupling. Ak nepomôže, 10 nF to pravdepodobne len zhorší.

---

# 9.2 Protokol robustnosť

## 4. Je SEQ ID správna priorita? Pomôže, ak 50 % requestov vôbec nedorazí do parsera?

Áno, **SEQ ID je správna priorita**, ale treba presne vedieť, čo vyrieši a čo nie.

SEQ ID pomôže pri:

```text
- starej oneskorenej odpovedi,
- spurious odpovedi vygenerovanej garbage requestom,
- PC tools, ktoré si pomýlia starú response s aktuálnou,
- retry logike pre READ,
- diagnostike „odpoveď prišla, ale nepatrí tomuto requestu“.
```

SEQ ID nepomôže, ak:

```text
- request vôbec nedorazí do UART RX,
- stratí sa bajt v hlavičke,
- parser nikdy nevytvorí RX_HDR,
- FPGA vôbec nezačne odpoveď.
```

Čiže ak je naozaj pravda, že iba 29/60 requestov sa dekóduje ako header, SEQ ID samo nezvýši `rx_hdr` na 60/60. Ale veľmi pomôže zabrániť tomu, aby PC prijalo nesprávnu alebo spurious odpoveď ako platnú.

Moje odporúčanie:

```text
1. pridať SEQ ID,
2. tools nech zahadzujú response s nesprávnym SEQ a pokračujú v čítaní do timeoutu,
3. retry povoliť iba pre READ,
4. WRITE timeout označiť ako unknown-state, nie automaticky retry.
```

SEQ ID by som dal pred CRC, ale krátko po ňom musí nasledovať CRC.

---

## 5. Je lepšie implementovať RTS/CTS namiesto SEQ ID?

Nie ako náhradu. **RTS/CTS a SEQ ID riešia iný problém.**

RTS/CTS rieši prietok:

```text
„neposielaj mi ďalšie bajty, teraz nemám miesto“
```

SEQ ID rieši transakčnú identitu:

```text
„táto odpoveď patrí/nepatrí requestu číslo N“
```

pySerial podporuje hardvérové flow control cez parameter `rtscts=True`. Dokumentácia uvádza `rtscts` ako voľbu na zapnutie RTS/CTS flow control. ([pyserial.readthedocs.io][3])

Ale pre tvoj súčasný problém by som RTS/CTS nerobil ako prvé, pretože:

```text
- tvoje requesty sú krátke, typicky 8 alebo 12 bajtov,
- RX FIFO DEPTH=8 plus parser by to mal zvládnuť pri 115200,
- overrun podľa statusu často nie je hlavný príznak,
- RTS/CTS pridá ďalšie vodiče, polaritu, synchronizáciu a možnosť chyby.
```

RTS/CTS má zmysel neskôr, ak budeš robiť:

```text
- dlhé WRITE bursty,
- RAM loader,
- vyšší baud rate,
- USB-UART adaptéry s veľkou latenciou,
- streamovanie.
```

Teraz by som dal prioritu:

```text
1. SEQ ID,
2. RESP_ERROR,
3. CRC,
4. potom voliteľne RTS/CTS.
```

---

## 6. Malo by FPGA vracať RESP_ERROR pre neplatnú adresu?

Áno. Toto by som považoval za zásadné.

Momentálne invalid address alebo garbage request môže skončiť ako:

```text
- tichý drop,
- normálna odpoveď,
- timeout na PC,
- spurious response.
```

To je diagnosticky zlé. Pravidlo robustného protokolu by malo byť:

```text
Každý syntakticky validný request musí dostať response.
Ak request nie je vykonateľný, response musí byť RESP_ERROR.
```

Navrhol by som:

```text
RESP_ERROR = 0xFF

payload:
  status_code : 8 bit
  reserved    : 8 bit
  info        : 16 alebo 32 bit
```

Status kódy:

```text
0x01 BAD_OPCODE
0x02 BAD_COUNT
0x03 BAD_ADDRESS
0x04 SLAVE_TIMEOUT
0x05 SLAVE_ERROR
0x06 BUSY
0x07 INTERNAL_ERROR
```

Pre AXI-Lite mapovanie:

```text
OKAY   → RESP_READ / RESP_WRITE
SLVERR → RESP_ERROR(SLAVE_ERROR)
DECERR → RESP_ERROR(BAD_ADDRESS)
timeout → RESP_ERROR(SLAVE_TIMEOUT)
```

To pomôže aj scanneru: neplatný slot už nebude vyzerať ako „linka zlyhala“.

---

# 9.3 RTL architektúra

## 7. Vidím v RTL architektonickú chybu, ktorá by mohla prispievať k problému?

Z toho, čo som analyzoval v poslednom snapshot-e, hlavné predchádzajúce RTL chyby už boli opravené:

```text
xfcp_fifo:
  ramstyle="logic" je správne pre fall-through FIFO

xfcp_fabric_endpoint:
  invalid_req path je správny smer
  invalid WRITE drain je správny smer
  eng_resp_type je zapojený
  eng_busy sa nenastavuje pri invalid requeste

xfcp_axi_engine:
  ST_RD_WAIT = RVALID && RREADY je správne
  read FIFO backpressure je správne

xfcp_rx_parser:
  MAX_COUNT_BYTES=128 je lepší limit
  SOP recovery je potrebný pri UART byte stream-e bez TLAST
```

Ale vidím tri architektonické dlhy:

### A. Parser `S_DROP` bez TLAST je zvláštny stav

Keďže UART nikdy nemá TLAST, `S_DROP` reálne opustíš iba cez SOP recovery alebo watchdog/reset. To je použiteľné, ale musíš ho výborne diagnostikovať.

Doplnil by som countery:

```text
RX_DROP_ENTER_COUNT
RX_SOP_RECOVERY_COUNT
RX_BAD_HDR_COUNT
RX_WATCHDOG_COUNT
LAST_BAD_OPCODE
LAST_BAD_COUNT
```

### B. Response koniec cez `resp_done` hack nie je ideálny

Ak tam stále existuje logika typu:

```systemverilog
resp_done_mux = resp_start_pulse || resp_done_held_q;
```

je to krátkodobo akceptovateľné pri READ burst limite 32 slov, ale dlhodobo by som prešiel na:

```text
read_data
read_data_valid
read_data_ready
read_data_last
```

alebo na count-driven packetizer.

### C. Chýba error response path vo fabricu

Invalid request už nezničí slave 0, ale protokolovo by mal vzniknúť `RESP_ERROR`.

Takže moja odpoveď: **nevidím jednu zjavnú aktuálnu RTL chybu typu „toto vysvetľuje 67 % failov“**, ale chýba robustná error/SEQ/CRC vrstva a presnejšia diagnostika parser drop/recovery stavov.

---

## 8. `axis_uart_rx.sv` generuje TVALID iba ako 1-cycle pulse. Je to problém?

Áno, potenciálne to je porušenie klasickej AXI-Stream disciplíny.

Štandardný ready/valid princíp je:

```text
ak producer nastaví TVALID=1 a consumer nemá TREADY=1,
producer má držať TVALID a TDATA stabilné, kým nenastane handshake.
```

Ak `axis_uart_rx` dáva iba 1-taktový pulse bez ohľadu na `TREADY`, potom bajt môže zmiznúť, ak downstream práve nie je ready.

Vo vašom dizajne to čiastočne maskuje RX FIFO:

```text
axis_uart_rx → xfcp_fifo DEPTH=8 → parser
```

Ak je `xfcp_fifo.w_ready=1` skoro vždy, je to v praxi OK. Ale ak FIFO flush/gate alebo reset spôsobí `TREADY=0`, bajt sa stratí.

Pre robustnosť by som upravil `axis_uart_rx` na skid-buffer výstup:

```systemverilog
if (!out_valid_q || out_ready_i) begin
  if (byte_done) begin
    out_data_q  <= rx_byte;
    out_valid_q <= 1'b1;
  end else if (out_ready_i) begin
    out_valid_q <= 1'b0;
  end
end
```

Teda držať bajt, kým ho FIFO neprevezme.

Ak nechceš meniť UART core hneď, minimálne pridaj DIAG:

```text
UART_RX_BYTE_SEEN   = byte_done
UART_RX_BYTE_ACCEPT = TVALID && TREADY
UART_RX_BYTE_LOST   = TVALID && !TREADY
```

Ak `UART_RX_BYTE_LOST` ostáva 0, 1-cycle pulse nie je aktuálny problém. Ak rastie, našiel si príčinu.

---

# 9.4 Testovanie

## 9. Ako najlepšie izolovať coupling problém pre reprodukovateľné testy?

Navrhol by som takýto postup.

## Test 1 — statický baud sweep, nie runtime baud switch

Runtime baud switch používa tú istú nestabilnú linku, takže je zlý ako prvý diagnostický nástroj.

Sprav samostatné bitstreamy:

```text
115200: BAUD_DIV=434
57600:  BAUD_DIV=868
38400:  BAUD_DIV=1302
9600:   BAUD_DIV=5208
```

Pre každý bitstream PC otvorí port priamo na danej baud rate.

Interpretácia:

```text
úspešnosť výrazne rastie pri nižšom baud:
  problém je UART sampling/fyzika/timing

úspešnosť rovnaká pri všetkých baud:
  problém je skôr protokol/tools/parser/recovery, nie bitrate
```

## Test 2 — veľké pauzy medzi requestmi

Áno, vyskúšať 10 ms alebo 100 ms pauzu medzi requestmi má zmysel.

Ak 100 ms pauza zlepší výsledok, problém je pravdepodobne:

```text
- stale response,
- post-response recovery,
- parser v S_DROP,
- PC serial buffer timing,
- echo/coupling po TX.
```

Ak sa nič nezmení, problém sa deje už pri samotnom príjme jednotlivého requestu.

## Test 3 — rozdelenie podľa operácie

Testuj oddelene:

```text
READ SYSC.ID iba 1000×
READ DIAG iba 1000×
WRITE scratch iba 1000×
mixed scan
```

Ak zlyháva len mixed alebo WRITE, problém nie je fyzická linka všeobecne, ale transakčný/protokolový stav.

## Test 4 — FPGA RX-only test

Dočasný bitstream:

```text
PC posiela známy pattern 10 000 bajtov
FPGA iba počíta:
  byte_count
  frame_error_count
  expected_pattern_errors
```

Žiadne FPGA TX odpovede. Ak RX-only test ide 100 %, potom problém vzniká až vtedy, keď FPGA zároveň vysiela.

To je veľmi silný test.

## Test 5 — FPGA TX-only / local RX counter

Dočasný bitstream:

```text
FPGA vysiela UART pattern,
PC neposiela nič,
FPGA RX counter sleduje, či prijíma bajty/frame errors.
```

Ak RX counter rastie, máš potvrdený lokálny TX→RX coupling.

## Test 6 — iný USB-UART adaptér

Áno, určite. Ale keďže už máš CP2102, skúsil by som ešte:

```text
CH340
FT232RL
iný CP2102 modul
integrovaný UART na inom USB porte/kábli
```

Ak sa výsledky zásadne líšia, adaptér alebo jeho elektrické vlastnosti sú v hre.

## Test 7 — embedded C na FPGA?

Nie ako prvý krok. Embedded C na FPGA nepomôže izolovať UART linku, ak stále používaš tú istú fyzickú linku. Pomohlo by až pri CPU bring-upe.

Lepšie sú jednoduché RTL test bitstreamy:

```text
RX-only counter
TX-only generator
TX→RX self-observer
```

Tie sú presnejšie než CPU aplikácia.

---

# Moja celková expert odpoveď

Najviac by som teraz spochybnil záver:

```text
„RTL je správna a problém je jednoznačne fyzický coupling.“
```

Presnejšie by som povedal:

```text
RTL fabric/AXI časť vyzerá po refaktore výrazne lepšie a hlavné predchádzajúce chyby sú opravené. Dáta však zatiaľ dokazujú hlavne to, že veľká časť transakcií sa stratí pred alebo v parseri. To môže byť fyzický UART RX problém, ale stále to môže byť aj baud mismatch po neúspešnom runtime switchi, 1-cycle TVALID strata, parser S_DROP/recovery efekt, stale response bez SEQ, alebo tools timing.
```

Najbližší postup by som dal takto:

```text
1. Opraviť brief: CP2102, nie FT232R.
2. Pridať DIAG snapshot a RX seen/accept/lost/frame/recovery countery.
3. Pridať/overiť skid buffer na výstupe axis_uart_rx.
4. Spraviť RX-only a TX-only test bitstreamy.
5. Spraviť statický baud sweep cez rebuild, nie runtime switch.
6. Implementovať SEQ ID.
7. Implementovať RESP_ERROR.
8. Potom CRC16.
9. Až potom riešiť RTS/CTS alebo RC filter.
```

Ak by som mal vybrať iba jednu najbližšiu technickú úlohu, bola by to táto:

```text
Zistiť, či pri zlyhaní rastie UART_RX_BYTE_SEEN, UART_RX_BYTE_ACCEPT, RX_HDR, FAB_REQ, FAB_RESP a TX_BYTE.
```

To jediné definitívne povie, kde sa transakcia stratí.

[1]: https://ftdichip.com/wp-content/uploads/2020/07/AN_124_User_Guide_For_FT_PROG.pdf?utm_source=chatgpt.com "User Guide for FTDI FT_PROG Utility"
[2]: https://eblot.github.io/pyftdi/eeprom.html?utm_source=chatgpt.com "EEPROM management — PyFtdi documentation"
[3]: https://pyserial.readthedocs.io/en/latest/pyserial_api.html?utm_source=chatgpt.com "pySerial API"
