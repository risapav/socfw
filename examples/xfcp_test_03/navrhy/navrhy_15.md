Áno. Prešiel som aktuálny `xfcp_test_03.zip`, doplnkové chýbajúce RTL z `xfcp_test.zip`, plus `EXPERT_BRIEF.md` a `XFCP3_STATUS.md`.

Môj záver: **projekt je po refaktore výrazne lepší, ale ďalší postup by som mierne zmenil.** Teraz by som už nešiel primárne cestou ďalších domnienok o fyzickom coupling-u. Najprv by som stabilizoval meranie, runtime baud switch a transakčný protokol. Bez toho sa bude ťažko rozlíšovať, či reálne zlyháva UART fyzika, PC tools, alebo parser/fabric pipeline.

---

# 1. Stav projektu po refaktore

## Čo je už dobré

Aktuálny kód má viacero správnych opráv:

```text
xfcp_fifo.sv
  - ramstyle="logic"
  - fall-through FIFO už nie je ohrozený syntézou do synchrónnej RAM

xfcp_fabric_endpoint.sv
  - invalid_req path doplnený
  - invalid WRITE payload drain doplnený
  - eng_busy sa nenastavuje pri invalid requeste
  - eng_resp_type sa prenáša z engine do fabricu
  - endpoint_busy_o už nie je zavádzajúci full-busy signál, ale TX-phase/debug signál

xfcp_axi_engine.sv
  - WRITE štartuje až pri req_valid && req_ready
  - ST_RD_WAIT čaká na RVALID && RREADY
  - READ FIFO má backpressure cez RREADY
  - timeout vie vrátiť RESP_WRITE namiesto deadlocknutého RESP_READ

xfcp_rx_parser.sv
  - MAX_COUNT_BYTES=128
  - watchdog sa resetuje aj pri SOP recovery
  - WRITE s COUNT=0 sa zahodí
  - header-first pipeline pre WRITE je zachovaná

xfcp_uart_mmio_top.sv
  - ENABLE_POST_TX_FLUSH defaultne 0
  - DIAG slot pridaný na 0xFF060000
  - TX_PKT_COUNT je napojený na dbg_resp_w, nie na UART tx_busy edge

tools/
  - rozdelenie na transport/protocol/bus/errors/timeouts
  - read_packet() robí SOP_RESP resync
  - read_block/write_block chunkujú na 32 slov
  - data_bits mapping v uart_diag.py opravený
  - pending/commit baud switch implementovaný v RTL aj tools
```

Toto je dobrý základ. Už to nie je ad-hoc UART bridge, ale začína to byť reálna debug infraštruktúra.

---

# 2. Kľúčový problém v dokumentoch: záver o fyzickej chybe je príliš silný

`EXPERT_BRIEF.md` a `XFCP3_STATUS.md` teraz tvrdia, že problém je jednoznačne fyzická UART RX vrstva / TX→RX coupling. Ja by som to formuloval opatrnejšie.

Áno, niektoré namerané dáta tomu zodpovedajú:

```text
frame_err=True
rx_bytes výrazne viac než očakávané request bajty
fab_resp > počet testovacích requestov
spurious requesty/odpovede
```

Ale zároveň sú tu protiargumenty:

```text
- používaš CP2102 a veľmi krátke cesty
- najlepší výsledok bol s ENABLE_POST_TX_FLUSH=0
- dlhší flush výsledok zhoršil
- niektoré predchádzajúce testy mali overrun/frame/parity=False
- DIAG countery sa čítajú cez tú istú chybnú linku a samy menia countery
- runtime baud testy sú zatiaľ metodicky nečisté, lebo baud switch môže čiastočne zlyhať a nechať PC/FPGA v rôznych stavoch
```

Preto by som do statusu zmenil záver z:

```text
Problém je jednoznačne fyzický coupling.
```

na:

```text
Najsilnejšia aktuálna hypotéza je problém pred parserom v UART RX vrstve alebo v transakčnej synchronizácii PC↔FPGA. DIAG ukazuje, že mnoho requestov sa nedostane ako kompletný header do parsera, ale presná príčina ešte nie je definitívne oddelená medzi fyzikou, baud mismatch stavmi, stale/spurious odpoveďami a tools recovery.
```

---

# 3. Najväčší aktuálny problém: runtime baud switch je stále metodicky nebezpečný

Pending/commit RTL mechanizmus je správny smer, ale súčasné tools majú jeden zásadný problém.

Aktuálne:

```python
if not self.write32(0xFF010004, new_div):
    return False

if not self.write32(0xFF01001C, 1):
    return False

time.sleep(0.15)
self._transport.set_baudrate(new_baud)
return self.ping()
```

Toto je nebezpečné pri `BAUD_COMMIT`.

## Problém

Ak commit WRITE odpoveď timeoutne, tools predpokladajú:

```text
commit neprebehol
FPGA ostáva na starej baud
PC ostáva na starej baud
```

Ale v skutočnosti sa mohlo stať:

```text
1. FPGA prijalo BAUD_COMMIT
2. FPGA pošle ACK, ale ACK sa stratí alebo tools ho nezachytia
3. tools vyhodnotia write32 ako False
4. FPGA po countdown prepne baud
5. PC ostane na starej baud
6. linka je rozbitá baud mismatchom
```

To je veľmi pravdepodobný dôvod, prečo sweep pôsobí chaoticky. Pri commit registri nesmieš brať chýbajúce ACK ako dôkaz, že commit neprebehol.

## Oprava tools

`set_baudrate()` musí byť napísané ako „commit may have happened“ flow:

```text
1. nastav BAUD_PENDING a snaž sa ho potvrdiť
2. pošli BAUD_COMMIT
3. bez ohľadu na to, či ACK prišlo, počkaj na switch window
4. prepni PC na nový baud
5. pingni nový baud
6. ak nový baud nefunguje, prepni späť na starý baud a pingni starý
7. až potom rozhodni, kde FPGA reálne je
```

Pseudo-kód:

```python
def set_baudrate_safe(self, new_baud: int, clk_hz: int = 50_000_000) -> bool:
    old_baud = self._transport.baudrate
    new_div = round(clk_hz / new_baud)

    # 1. Pokús sa zapísať pending. Toto ešte nemení baud.
    pending_ok = False
    for _ in range(5):
        if self.write32(0xFF010004, new_div):
            pending_ok = True
            break
        self._transport.drain()

    if not pending_ok:
        return False

    # 2. Pošli commit. ACK je užitočný, ale nespoľahlivý ako rozhodnutie.
    try:
        self.write32(0xFF01001C, 1)
    except Exception:
        pass

    # 3. Commit mohol prebehnúť aj keď ACK neprišlo.
    time.sleep(0.20)

    # 4. Skús nový baud.
    self._transport.set_baudrate(new_baud)
    if self.ping():
        return True

    # 5. Fallback: commit možno neprebehol.
    self._transport.set_baudrate(old_baud)
    if self.ping():
        return False

    # 6. Linka je v neznámom stave.
    raise XfcpRecoveryError(
        f"Cannot determine UART baud after switch attempt {old_baud}->{new_baud}"
    )
```

Do `SerialTransport` by som pridal property:

```python
@property
def baudrate(self) -> int:
    return self._baudrate
```

Toto je podľa mňa **najbližšia praktická oprava**, ak chceš ešte testovať runtime baud bez rebuildov.

---

# 4. Pre baud sweep by som teraz nepoužil runtime switch

Kým je linka nestabilná, runtime baud switch je zlá metóda na diagnostiku UART adaptéra, pretože switch samotný používa tú istú nestabilnú linku.

Na vylúčenie chyby CP2102/baud fyziky je lepší tento postup:

```text
1. Vytvoriť samostatný bitstream pre 115200.
2. Vytvoriť samostatný bitstream pre 57600.
3. Vytvoriť samostatný bitstream pre 38400.
4. Voliteľne 9600.
5. Pri každom teste PC otvorí port priamo na danej baud.
6. Nepoužiť runtime BAUD_COMMIT.
```

Teda rebuild s:

```systemverilog
UART_DEFAULT_BAUD_DIV = 434   // 115200
UART_DEFAULT_BAUD_DIV = 868   // 57600
UART_DEFAULT_BAUD_DIV = 1302  // 38400
UART_DEFAULT_BAUD_DIV = 5208  // 9600
```

alebo cez YAML/IP parameter.

Ak statické bitstreamy ukážu:

```text
115200: 40 %
57600:  40 %
38400:  40 %
9600:   40 %
```

baud rate nie je hlavná príčina.

Ak ukážu:

```text
115200: 40 %
57600:  80 %
38400:  95 %
9600:   100 %
```

potom je problém v UART sampling/timing/fyzike alebo časovaní PC/FPGA.

Toto bude oveľa čistejší experiment než aktuálny runtime sweep.

---

# 5. DIAG countery sú dobré, ale ich interpretácia zatiaľ nie je úplne čistá

DIAG slot je veľmi užitočný, ale má metodický problém: **čítanie DIAG registrov samo generuje XFCP requesty a odpovede**, teda mení merané countery.

Príklad:

```text
po teste zavoláš diag_read_all()
read DIAG_RX_BYTES
  - tento READ sám zvýši RX_BYTE_COUNT, RX_SOP_COUNT, RX_HDR_COUNT, FAB_REQ_COUNT...
read DIAG_RX_SOP
  - countery sú už o ďalšiu transakciu vyššie
...
```

Výsledkom je, že každé čítané DIAG pole je z trochu iného času. Pri nestabilnej linke to ešte viac skresľuje interpretáciu.

## Odporúčaná oprava: DIAG snapshot

Pridať register:

```text
0x28 DIAG_SNAPSHOT  PULSE
```

Po zápise sa aktuálne countery skopírujú do shadow registrov:

```systemverilog
rx_byte_snap_r  <= rx_byte_cnt_r;
rx_sop_snap_r   <= rx_sop_cnt_r;
rx_hdr_snap_r   <= rx_hdr_cnt_r;
...
```

A čítanie `0x04..0x20` by vracalo snapshot, nie live countery.

Workflow:

```text
1. DIAG_RESET
2. test N requestov
3. DIAG_SNAPSHOT
4. read snapshot registers
```

Áno, samotný `DIAG_SNAPSHOT` write pridá jednu transakciu, ale tá sa dá odrátať alebo spraviť tak, že snapshot sa vykoná pred inkrementom daného requestu. Aj keby nie, výsledky budú konzistentné v jednom čase.

Alternatívne pridať separátne shadow okno:

```text
0x40..0x5C snapshot hodnoty
```

---

# 6. DIAG countery by som rozšíril

Aktuálne máš:

```text
RX_BYTE_COUNT
RX_SOP_COUNT
RX_HDR_COUNT
RX_DROP_COUNT
FAB_REQ_COUNT
FAB_RESP_COUNT
TX_BYTE_COUNT
TX_PKT_COUNT
```

Doplnil by som tieto:

```text
RX_ACCEPT_COUNT      uart_rx_raw_s.TVALID && uart_rx_raw_s.TREADY
RX_LOST_COUNT        uart_rx_raw_s.TVALID && !uart_rx_raw_s.TREADY
RX_FRAME_COUNT       pulse pri frame error evente
RX_OVERRUN_COUNT     pulse pri overrun evente
RX_PARITY_COUNT      pulse pri parity error evente
RX_IGNORED_COUNT     bajt v S_IDLE, ktorý nebol SOP_REQ
RX_RECOVERY_COUNT    sop_recovery
RX_BAD_HDR_COUNT     S_DECODE && !dec_valid
RX_STATE             aktuálny parser state
LAST_HDR             posledné decodované opcode/count/addr, aspoň split
LAST_ERROR_CODE      bad_count, bad_opcode, watchdog, frame, overrun...
```

Najdôležitejšie sú:

```text
RX_BYTE_COUNT vs RX_ACCEPT_COUNT vs RX_LOST_COUNT
```

Lebo dnes vieš, že UART core niečo vyprodukoval, ale nie vždy jasne vidíš, či to FIFO prijalo, zahodilo kvôli flushu, alebo parser nebol pripravený.

---

# 7. Pozor na `S_DROP` v parseri

`xfcp_rx_parser.sv` pri chybnom pakete ide do `S_DROP`. Keďže UART stream má `TLAST=0`, zo `S_DROP` sa nedostane cez TLAST, iba cez ďalší `SOP_REQ=0xFE` vďaka `sop_recovery`.

To je zámerná recovery logika, ale má dôsledok:

```text
ak príde garbage header a parser vojde do S_DROP,
nasledujúci legitímny request SOP ho síce zachráni,
ale všetky bajty pred týmto SOP sú ignorované.
```

To je v poriadku. Ale v DIAG by som to chcel vidieť explicitne:

```text
RX_DROP_COUNT
RX_RECOVERY_COUNT
RX_BAD_HDR_COUNT
LAST_BAD_OPCODE
LAST_BAD_COUNT
```

Bez toho sa `rx_hdr < počet requestov` interpretuje veľmi ťažko.

---

# 8. `SEQ ID` je správna ďalšia protokolová fáza, ale treba chápať, čo vyrieši

Súhlasím, že `SEQ ID` je ďalší veľký krok. Ale neopraví všetko.

## SEQ ID vyrieši

```text
- staré oneskorené odpovede
- spurious odpovede z náhodných requestov
- tools confusion, keď príde 0xFD response, ale nie na aktuálnu transakciu
- bezpečnejší retry pri READ
- diagnostiku: vieme povedať "response seq mismatch"
```

## SEQ ID nevyrieši

```text
- ak pôvodný request vôbec nepríde do parsera
- ak sa stratí byte vo fyzickom UART RX
- ak parser ostane v S_DROP a ďalší request sa použije len na resync
- ak PC/FPGA sú v baud mismatch stave
```

Preto by som ho implementoval, ale nečakal by som zázračných 100 % len zo SEQ.

## Minimálna kompatibilná verzia

Aktuálny request:

```text
SOP, OP, COUNT[15:8], COUNT[7:0], ADDR[31:0], PAYLOAD
```

Navrhujem:

```text
SOP, OP, SEQ, COUNT[15:8], COUNT[7:0], ADDR[31:0], PAYLOAD
```

Tým sa header zväčší z 8 na 9 bajtov.

Response:

```text
SOP_RESP, RESP_OP, SEQ, DEV_TYPE[15:8], DEV_TYPE[7:0], DEV_STR[16], PAYLOAD, 0x00
```

Tools potom pri čítaní robia:

```text
scan for SOP_RESP
read response
if seq != expected_seq:
    discard and continue scanning until timeout
```

Toto je dôležité: pri SEQ mismatch nemá transakcia hneď zlyhať. Má pokračovať v čítaní, lebo správna odpoveď môže prísť o pár bajtov neskôr.

---

# 9. `RESP_ERROR` by mal nasledovať hneď po SEQ

Teraz invalid request často znamená:

```text
drop bez odpovede
```

alebo pri timeoutoch rôzne náhradné správanie.

Dlhodobo by malo platiť:

```text
každý syntakticky prijatý request dostane response
```

Pridať:

```text
OP_RESP_ERROR = 0x14 alebo 0xFF
```

Payload napríklad:

```text
status_code[31:24]
detail[23:0]
```

Status kódy:

```text
0x00 OK
0x01 BAD_OPCODE
0x02 BAD_COUNT
0x03 BAD_ADDRESS
0x04 SLAVE_TIMEOUT
0x05 PROTOCOL_ERROR
0x06 BUSY
0x07 INTERNAL_ERROR
```

Pre začiatok stačí:

```text
BAD_ADDRESS
SLAVE_TIMEOUT
BAD_OPCODE/BAD_COUNT
```

Pri invalid address by fabric nemal iba zahodiť request. Mal by vrátiť:

```text
RESP_ERROR(seq, BAD_ADDRESS, addr)
```

Toto výrazne zlepší tools a scanner.

---

# 10. Baud switch: RTL je skoro dobrý, ale doplnil by som busy guard

V `axil_uart_adapter.sv` sa po countdown prepne:

```systemverilog
baud_active_q <= baud_pending_q;
```

Doplnil by som podmienku:

```systemverilog
if (!tx_busy_i && !rx_busy_i) begin
  baud_active_q <= baud_pending_q;
  baud_switch_pending_q <= 1'b0;
end
```

Teda:

```systemverilog
if (baud_switch_cnt_q != 32'h0) begin
  baud_switch_cnt_q <= baud_switch_cnt_q - 32'd1;
end else if (!tx_busy_i && !rx_busy_i) begin
  baud_active_q         <= baud_pending_q;
  baud_switch_pending_q <= 1'b0;
end
```

Prečo: ak sa z akéhokoľvek dôvodu RX alebo TX ešte hýbe, nech sa baud nemení uprostred rámca.

Tiež by som pridal RO status bit:

```text
0x24 BAUD_STATUS
  bit0 switch_pending
  bit1 tx_busy
  bit2 rx_busy
```

Potom tools vie po prepnutí čítať stav, keď je linka stabilná.

---

# 11. Chyba v `EXPERT_BRIEF.md`: hardware identifikácia

`EXPERT_BRIEF.md` stále hovorí:

```text
USB-UART bridge: Pravdepodobne FT232R
```

Ale ty si doplnil, že ide o **CP2102**. Toto treba opraviť, lebo veľká časť fyzickej hypotézy je postavená na FTDI echo / EEPROM konfigurácii.

Odporúčam upraviť:

```text
USB-UART bridge: CP2102
FTDI EEPROM echo hypotéza: odstránená / neaktuálna
```

Potom zostávajú reálne hypotézy:

```text
- UART baud/timing/sampling
- PC serial buffering/stale bytes
- parser resync/drop správanie
- spurious requesty z linky alebo tools
- fyzická väzba na doske/kábli, ale menej pravdepodobná než pri FTDI
```

---

# 12. ZIP snapshot je stále závislý od symlinkov

`xfcp_test_03.zip` obsahuje `rtl/axi`, `rtl/axil`, `rtl/axis`, `rtl/uart`, `rtl/segment`, `rtl/buffer` ako symlinky na tvoju lokálnu cestu:

```text
/home/palo/Projekty/socfw/examples/xfcp_test/rtl/...
```

Pre mňa bolo nutné použiť aj `xfcp_test.zip`, aby som videl `axil_uart_adapter.sv`, `axil_diag_ctrl.sv`, UART core atď.

Pre ďalší vývoj odporúčam jeden z týchto variantov:

```text
A. export ZIP s dereference symlinks
   zip -r --symlinks nie; radšej cp -L alebo tar --dereference

B. mať shared RTL ako explicitný submodul/dependency

C. do expert/debug balíka vždy pribaliť aj xfcp_test.zip
```

Najpraktickejšie:

```bash
cp -aL examples/xfcp_test_03 /tmp/xfcp_test_03_export
zip -r xfcp_test_03_export.zip /tmp/xfcp_test_03_export
```

---

# 13. Odporúčaný ďalší postup

## Fáza A — opraviť meranie a baud test metodiku

Toto by som spravil ako prvé.

### A1. Upraviť status a expert brief

Zmeniť formuláciu:

```text
coupling jednoznačne potvrdený
```

na:

```text
UART RX / transakčná synchronizácia pred parserom je najpravdepodobnejšia oblasť problému; presná príčina ešte nie je definitívne izolovaná.
```

A opraviť FT232R → CP2102.

### A2. Pridať DIAG snapshot

Pridať:

```text
DIAG_SNAPSHOT
snapshot registre
```

A zmeniť `hw_diag.py`, aby čítal snapshot, nie live countery.

### A3. Pridať RX accept/lost/error countery

Minimálne:

```text
RX_SEEN
RX_ACCEPT
RX_LOST
RX_FRAME
RX_OVERRUN
RX_SOP
RX_HDR
RX_BAD_HDR
RX_RECOVERY
```

### A4. Opraviť `set_baudrate_safe()`

Commit timeout nesmie automaticky znamenať „commit neprebehol“. Po commit pokuse treba otestovať nový aj starý baud.

### A5. Spraviť statické baud bitstreamy

Nepoužívať runtime switch na prvý čistý baud sweep.

---

## Fáza B — transakčná robustnosť

### B1. Implementovať SEQ ID

Toto je podľa mňa ďalšia najdôležitejšia protokolová zmena.

Tools flow:

```text
send seq=N
scan responses until:
  - response seq=N → OK
  - timeout → fail/retry
  - response seq!=N → discard + count stale/spurious
```

Pridať counters:

```text
SEQ_MISMATCH_COUNT
STALE_RESP_COUNT v tools
```

### B2. Retry iba pre READ

READ môžeš bezpečne retryovať.

WRITE nie, pokiaľ nezavedieš idempotentné pravidlá alebo write transaction ID cache.

```text
READ timeout → retry seq=N+1
WRITE timeout → unknown state, require recover/ping
```

### B3. RESP_ERROR

Po SEQ ID pridať:

```text
RESP_ERROR(seq, status, addr/info)
```

---

## Fáza C — RTL diagnostika / SignalTap

Ak po Fáze A a B stále zostane 30–60 % úspešnosť, až potom by som išiel do SignalTapu.

Trigger profily:

```text
1. RX path:
   uart_rx_raw_s.TVALID
   uart_rx_raw_s.TDATA
   uart_rx_raw_s.TREADY
   rx_status_w.frame_err
   rx_status_w.overrun_err
   dbg_sop_w
   dbg_hdr_w
   dbg_drop_w

2. Fabric path:
   req_valid
   req_ready
   req_hdr.opcode/count/addr
   invalid_req
   dbg_req_w
   dbg_resp_w
   eng_done_rdy
   resp_start_pulse

3. TX path:
   resp_start_q
   xfcp_tx_s.TVALID
   xfcp_tx_s.TREADY
   xfcp_tx_s.TDATA
   uart_tx_o
   tx_status_w.tx_busy
```

Najdôležitejšia otázka:

```text
Pri zlyhaní 0B:
- prišiel request byte stream do FPGA?
- vznikol dbg_hdr?
- vznikol dbg_req?
- vznikol dbg_resp?
- išli TX bajty?
```

---

## Fáza D — až potom CPU/app vývoj

Keď bude XFCP stabilné:

```text
1. ID ROM / discovery per slave
2. memory window
3. cpu_ctrl: reset, halt/run, status, exit_code
4. RAM loader
5. module drivers
6. HW regression tests
```

---

# 14. Konkrétne najbližšie úlohy

Dal by som ich v tomto poradí:

```text
1. Opraviť EXPERT_BRIEF.md:
   - CP2102 namiesto FT232R
   - coupling ako hypotéza, nie definitívny dôkaz

2. Pridať DIAG_SNAPSHOT:
   - aby čítanie DIAG nedeformovalo výsledky

3. Pridať RX_ACCEPT / RX_LOST / RX_FRAME_COUNT / RX_RECOVERY_COUNT:
   - aby sme videli, či bajty miznú pred FIFO, vo FIFO, alebo v parseri

4. Opraviť set_baudrate_safe():
   - commit may have happened
   - ping new baud
   - fallback old baud

5. Spraviť statický baud sweep s rebuildom:
   - 115200, 57600, 38400, 9600

6. Implementovať SEQ ID:
   - request/response
   - tools discard seq mismatch
   - counter seq_mismatch

7. Implementovať RESP_ERROR:
   - invalid address
   - slave timeout
   - bad opcode/count

8. Potom zopakovať HW test:
   - 300 až 1000 READ transakcií
   - oddelene READ-only, WRITE-only, mixed
```

---

# Záver

Refaktor je dobrý. Najväčšie RTL chyby, ktoré sme riešili v predchádzajúcich iteráciách, sú už opravené. Najslabšie miesto teraz nie je fabric ani AXI engine, ale **diagnostická a transakčná vrstva**.

Najbližší cieľ by mal byť:

```text
prestať merať nestabilnú linku cez live countery a nejednoznačné odpovede
```

Preto by som najprv pridal **DIAG snapshot + presnejšie RX countery**, opravil **safe baud switch fallback**, a potom implementoval **SEQ ID**. Až potom budeš mať dosť dobré dáta na definitívne rozhodnutie, či je zvyšok problém fyzický, UART timing, alebo ešte niekde v protokole/tools.
