Súhlasím — pri **CP2102 a extrémne krátkych cestách** by som už fyzický TX→RX coupling nedával ako hlavnú hypotézu. Nie je nemožný, ale pravdepodobnejšie je, že zvyšné timeouty vznikajú ešte v **RTL/protokolovej synchronizácii alebo v tools**, nie v samotnom HW vedení.

Po tejto informácii by som zmenil prioritu vyšetrovania takto:

```text
1. nie fyzický coupling ako hlavná príčina
2. skontrolovať RX parser resync a garbage handling
3. skontrolovať TX/RX byte framing v Python tools
4. overiť, či DUT niekedy nedostane vlastnú odpoveď ako request
5. overiť, či parser po chybnom pakete korektne obnoví stav
6. overiť, či AXI/fabric po neplatnom alebo poškodenom pakete vždy uvoľní cestu
```

## Čo by mohlo stále vyzerať ako „echo“, ale nie je HW problém

Aj keď CP2102 fyzicky neecho-uje TX na RX, podobný efekt môže vzniknúť softvérovo alebo protokolovo.

### 1. Stale bytes v PC input bufferi

Ak v PC zostanú staré bajty z predchádzajúcej odpovede, ďalšia transakcia ich môže čítať ako začiatok novej odpovede.

Ty už robíš `reset_input_buffer()`, ale treba si dať pozor na moment:

```text
PC odošle request
FPGA začne odpovedať
PC timeoutne alebo číta len časť odpovede
zvyšok odpovede príde neskôr
ďalšia transakcia začne príliš skoro
```

Potom `reset_input_buffer()` pred transakciou môže pomôcť, ale nie vždy, ak staré bajty dorazia až **po flushi**.

Preto je dôležitý **sequence ID**. Bez neho PC nevie, či odpoveď patrí aktuálnej alebo starej transakcii.

### 2. Parser môže prijať náhodný `0xFE` po chybe

Aj bez HW couplingu môže vzniknúť `0xFE` v dátach:

```text
- payload obsahuje 0xFE
- staré bajty po partial response
- nesprávne zarovnaný packet
- bug v tools pri čítaní response
- reset počas prenosu
```

Ak parser pri každom `0xFE` robí resync, je to dobré pre recovery, ale môže to tiež maskovať chyby, ak nie je CRC a dĺžková validácia dostatočná.

### 3. Response SOP `0xFD` znižuje riziko, ale nerieši všetko

Oddelenie:

```text
request SOP  = 0xFE
response SOP = 0xFD
```

je dobrá zmena, ale bez CRC/SEQ stále ostáva problém:

```text
PC môže prijať starú odpoveď ako novú
FPGA parser môže prijať garbage request
tools nemajú jednoznačné potvrdenie identity transakcie
```

---

# Čo by som teraz overil ako prvé

## 1. Vypnúť RX parser počas TX odpovede — testovacia hypotéza

Keďže neveríš na fyzický coupling, spravil by som jednoduchý RTL experiment:

```text
Počas TX response ignoruj RX vstup do parsera.
```

Nie ako finálne riešenie, ale ako diagnostický test.

Napríklad v `xfcp_uart_mmio_top.sv` alebo tesne pred RX FIFO:

```systemverilog
assign rx_fifo_s_valid = uart_rx_valid && !tx_busy;
```

alebo mäkšie:

```systemverilog
assign parser_s_valid = rx_fifo_valid && !tx_active;
```

Ak sa HW spoľahlivosť výrazne zlepší, znamená to:

```text
niečo počas TX fázy vstupuje do RX/parser cesty
```

Nemusí to byť fyzický coupling. Môže to byť:

```text
- PC/tools pošlú ďalší request príliš skoro
- stale byte timing
- UART adapter/driver správanie
- parser/fabric prijme nečakaný request počas odpovede
```

Ak sa nezlepší, problém je inde.

## 2. Pridať counters do RTL

Bez SignalTapu by som pridal lacné diagnostické registre:

```text
rx_byte_count
rx_packet_count
rx_bad_sop_count
rx_bad_len_count
rx_bad_opcode_count
rx_bad_count_count
rx_resync_count
tx_packet_count
fabric_invalid_req_count
fabric_timeout_count
fabric_drop_write_count
last_rx_state
last_fabric_state
last_opcode
last_addr
last_count
```

Potom po timeout teste vieš cez XFCP alebo jednoduchý debug výstup zistiť:

```text
Dostal FPGA vôbec request?
Parser ho prijal?
Zahodil ho?
Fabric ho odoslal do engine?
Engine timeoutol?
Packetizer začal TX?
```

Momentálne pri `0B response` nevieš, či problém nastal v:

```text
UART RX → parser → fabric → AXI engine → packetizer → UART TX → PC read
```

## 3. Presne logovať bajty v Python tools

Do tools by som pridal raw log:

```text
TX: FE ...
RX: FD ...
timeout after N bytes
partial RX: ...
```

Pri chybe je veľmi dôležité vedieť, či je to:

```text
0 bajtov úplne
1–3 bajty headeru
FD prišlo neskoro
zlý SOP
správny SOP, ale krátky packet
správny packet, ale zlý payload
```

Ak je problém naozaj „0B“, teda PC nedostane ani `0xFD`, tak problém je pred alebo v TX packetizer/UART TX.

Ak dostane čiastočný packet, je to iný typ chyby.

---

# Moja nová hlavná hypotéza

Po tvojej informácii by som za najpravdepodobnejšie považoval toto:

## Hypotéza A: transakčný protokol nemá SEQ/CRC, takže recovery po jednej chybe je nejednoznačné

Aj keď už máš `reset_input_buffer()`, stále môže vzniknúť situácia:

```text
1. transakcia A timeoutne
2. odpoveď A príde neskoro
3. tools už začnú transakciu B
4. PC prečíta zvyšok A alebo časť A/B
5. systém sa rozíde
```

Bez sequence ID nevieš starú odpoveď zahodiť.

Preto by som dal `SEQ ID` veľmi vysoko v poradí.

Minimálny formát:

```text
REQ:
SOP_REQ, OP, SEQ, ADDR, COUNT, PAYLOAD

RESP:
SOP_RESP, RESP_OP, SEQ, COUNT, PAYLOAD
```

Tools potom robia:

```python
if resp.seq != req.seq:
    discard_and_continue_until_timeout()
```

## Hypotéza B: parser/fabric po zlom alebo neúplnom requeste nevygeneruje jasnú error response

Invalid request sa už nedostane do slave 0, čo je dobré. Ale ak sa request zahodí bez odpovede, PC vidí len timeout.

To je presne typ problému, ktorý sa v HW javí ako náhodné `0B response`.

Pre robustný systém by malo platiť:

```text
valid SOP + valid header + invalid address → RESP_ERROR
valid SOP + valid header + bad count       → RESP_ERROR
valid SOP + invalid header                 → error counter + resync
```

Momentálne časť chýb zrejme končí tichým dropom.

## Hypotéza C: packetizer/UART TX niekedy nedostane start alebo done v správnom takte

`resp_done_mux = resp_start_pulse || resp_done_held_q` je stále architektonicky citlivé miesto.

Ak packetizer začne v zlom takte, alebo dostane `done` príliš skoro/neskoro, môže vzniknúť:

```text
- krátka odpoveď
- žiadna odpoveď
- zablokovaný packetizer
```

Toto by som overil cez interné countery:

```text
resp_start_count
tx_packet_start_count
tx_packet_done_count
tx_packetizer_state
```

---

# Čo by som urobil pred ďalším väčším refaktorom

## Krok 1: pridať hardvérové diagnostické countery

Nie veľa logiky, len jednoduché registre.

Minimálne:

```text
RX_BYTES
RX_PACKETS
RX_DROPS
RX_BAD_OPCODE
RX_BAD_COUNT
RX_RESYNC
FABRIC_REQ
FABRIC_INVALID
FABRIC_RESP_START
FABRIC_TIMEOUT
TX_PACKETS
TX_BYTES
LAST_ADDR
LAST_OPCODE
LAST_COUNT
LAST_ERROR
```

Potom pri každom timeout teste zistíš, kde to končí.

## Krok 2: rozšíriť `hw_diag.py`

Nech pri chybe vypíše:

```text
raw TX packet
raw RX bytes
timeout phase
UART status
XFCP diagnostic counters
```

Napríklad:

```text
TEST read SYSC.ID
TX: FE 01 ...
RX: <empty>
DIAG:
  rx_bytes = +8
  rx_packets = +1
  fabric_req = +1
  fabric_resp_start = +0
  tx_packets = +0
```

To by hneď povedalo: request prišiel, fabric ho prijal, ale odpoveď sa nespustila.

Alebo:

```text
rx_bytes = +0
```

Potom request vôbec neprišiel do FPGA.

## Krok 3: dočasný „single transaction lock“

Na dobu testu by som zakázal, aby parser prijal nový request, kým predchádzajúca odpoveď nie je odoslaná.

Teda:

```text
ak endpoint_busy=1:
  parser_tready=0 alebo drop incoming bytes
```

Pre jednoduchý UART debug protokol je to úplne legitímne. XFCP nemusí zatiaľ podporovať pipelining z PC.

To zjednoduší model:

```text
1 request in flight
1 response
žiadne prekrývanie
```

A výrazne zníži riziko rozídenia stavu.

---

# Dôležitá poznámka

Ak máš CP2102 a krátke cesty, fyzický problém by som už nebral ako dominantnú príčinu. Skôr by som to formuloval takto:

```text
Fyzický coupling je málo pravdepodobný.
Zvyšný problém pravdepodobne vzniká tým, že protokol ešte nemá jednoznačnú transakčnú identitu, error response a dostatočnú diagnostiku.
```

Teda nie:

```text
hľadajme problém vo vodičoch
```

ale:

```text
zistime presne, v ktorom stave sa stratí transakcia
```

---

# Konkrétny ďalší návrh

Najbližší patch by som smeroval na **diagnostiku a single-flight režim**, nie hneď na CRC.

Poradie:

```text
1. pridať endpoint_busy / one-request-at-a-time guard
2. pridať diagnostické countery
3. rozšíriť hw_diag.py o raw RX/TX log
4. znížiť MAX_COUNT_BYTES na 128
5. otestovať 100–1000 opakovaných read32/write32
6. až potom pridať SEQ ID
7. potom CRC
8. potom RESP_ERROR
```

Pre vývoj teraz najviac pomôže odpovedať na otázku:

```text
Keď PC dostane 0B response, prešiel request až do fabricu alebo nie?
```

Kým toto nevieme, každá ďalšia hypotéza je trochu naslepo.
