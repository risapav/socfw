Analyzoval som `xfcp_test_03.zip`. Toto už nie je len drobný refaktor `xfcp_test_02`; je to nový vývojový snapshot, kde sa podarilo nájsť veľmi pravdepodobnú hlavnú príčinu pôvodných HW timeoutov.

## Aktuálny stav projektu

Projekt `xfcp_test_03` je teraz v stave:

```text
RTL:        výrazne stabilizovaný
Simulácie: 13/13 PASS podľa logov
Quartus:   PASS
Timing:    PASS
HW:        zlepšenie z 2/12 OK na 7/12 OK podľa XFCP3_STATUS.md
```

Quartus report v ZIPe ukazuje:

```text
Flow Status: Successful
Device: EP4CE55F23C8
Logic elements: 16,879 / 55,856 = 30 %
Registers: 13,567
Memory bits: 0
Setup slack SYS_CLK: +3.990 ns
Hold slack SYS_CLK:  +0.448 ns
```

Časovanie je teda v poriadku pre 50 MHz.

---

# Najdôležitejší posun: root cause `xfcp_fifo`

Toto je veľmi dobrý nález.

V `rtl/xfcp/xfcp_fifo.sv` je teraz:

```systemverilog
(* ramstyle = "logic" *)
logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
```

Predtým bolo riziko, že Quartus z `no_rw_check` urobí synchrónnu RAM, hoci FIFO očakáva fall-through čítanie:

```systemverilog
assign r_data = mem[rd_ptr_q];
```

Toto veľmi dobre vysvetľuje pôvodný HW jav:

```text
order FIFO má r_valid ihneď,
ale r_data je v HW oneskorené/stale,
arbiter vyberie zlý slave,
čaká na eng_done od nesprávneho enginu,
packetizer sa nespustí,
UART TX pošle 0 bajtov.
```

Tento fix považujem za **zásadný a správny**.

Vedľajší efekt: všetky `xfcp_fifo` sú teraz v logike, nie v blokovej RAM. To je pre malé FIFO v XFCP dobré. Ale ak neskôr pridáš veľké memory/burst FIFO, treba vytvoriť samostatný typ FIFO pre synchrónnu RAM.

---

# Druhý veľký posun: odlíšený response SOP

V aktuálnom `xfcp_pkg.sv` už je:

```systemverilog
localparam logic [7:0] XFCP_SOP_REQ  = 8'hFE;
localparam logic [7:0] XFCP_SOP_RESP = 8'hFD;
```

A `xfcp_tx_packetizer.sv` už používa:

```systemverilog
hdr_vec[0 +: 8] = XFCP_SOP_RESP;
```

Aj Python driver v `tools/bus/xfcp.py` už očakáva:

```python
SOP      = 0xFE
SOP_RESP = 0xFD
```

To je správny krok. Ak existovalo fyzické alebo FTDI TX→RX presluchovanie, odpoveď začínajúca `0xFE` mohla parseru vyzerať ako nový request. Teraz response začína `0xFD`, takže parser na to nereaguje ako na request SOP.

Pozor: `XFCP3_STATUS.md` ešte hovorí, že definitívny fix `XFCP_SOP_RESP != XFCP_SOP_REQ` je plánovaný, ale v kóde už implementovaný je. Odporúčam status aktualizovať, aby nebol zavádzajúci.

---

# Stav predtým kritických RTL problémov

## 1. Invalid WRITE path

Toto je v aktuálnom `xfcp_fabric_endpoint.sv` už podstatne lepšie.

Vidím tam:

```systemverilog
assign invalid_req  = req_valid && !dec_valid;
assign req_ready    = invalid_req ? 1'b1 :
                      dec_valid && !eng_busy[dec_sel]
                      && eng_req_ready[dec_sel] && ofifo_wready;

assign ofifo_wvalid = req_fire && !invalid_req;
```

A tiež drain logiku:

```systemverilog
wire drain_wdata = drop_wdata_q ||
                   (invalid_req && req_hdr.opcode == XFCP_OP_WRITE);

assign wdata_valid = wdata_valid_raw && !drain_wdata;
assign wdata_ready = drain_wdata ? 1'b1 : eng_wdata_ready[wdata_sel];
```

To znamená, že pôvodný Problem F je už v zásade opravený:

```text
invalid header sa odoberie,
nepridá sa do order FIFO,
write payload sa nepošle do slave 0,
payload sa odčerpá.
```

Toto je dobrý stav.

Ešte tam však chýba vyššia protokolová vec: invalid request zatiaľ nedostane `RESP_ERROR`. Teraz sa hlavne zabráni deadlocku. To je dobré ako RTL stabilizácia, ale pre robustný protokol bude treba error response.

---

## 2. `eng_busy` pri invalid requeste

Toto je tiež opravené.

Aktuálne:

```systemverilog
if (req_valid && req_ready && !invalid_req && dec_sel == SEL_W'(i))
  eng_busy[i] <= 1'b1;
```

Tým sa zabráni tomu, aby invalid request omylom nastavil `eng_busy[0]`.

---

## 3. `resp_type` z engine do fabricu

Toto je už tiež opravené.

Vo fabricu je:

```systemverilog
logic [7:0] eng_resp_type [NUM_SLAVES];
```

a engine výstup je zapojený:

```systemverilog
.resp_type(eng_resp_type[gi])
```

Pri štarte odpovede fabric zachytí:

```systemverilog
resp_type_q <= xfcp_op_e'(eng_resp_type[ofifo_rdata.sel]);
```

Toto rieši predchádzajúci problém, kde READ timeout v engine chcel poslať `RESP_WRITE`, ale fabric by z neho nasilu urobil `RESP_READ`.

---

# Dôležitý zvyškový problém: READ burst väčší ako FIFO depth

Toto je najväčší technický problém, ktorý som v aktuálnom RTL ešte našiel.

V `xfcp_axi_engine.sv` má read FIFO:

```systemverilog
parameter int FIFO_DEPTH = 32
```

a read buffer:

```systemverilog
xfcp_fifo #(.DATA_WIDTH(AXI_DATA_WIDTH), .DEPTH(FIFO_DEPTH)) i_read_buffer
```

Fabric však spúšťa packetizer až keď engine dokončí celú READ transakciu. To znamená:

```text
engine musí najprv načítať všetky READ slová do read FIFO,
až potom sa spustí packetizer.
```

To funguje pre `read_block <= 32 slov`.

Ale pre väčší READ burst:

```text
read FIFO sa naplní,
RREADY klesne,
engine čaká,
packetizer ešte nebeží, lebo engine ešte nie je done,
nikto FIFO nevyprázdňuje,
systém sa môže zablokovať.
```

Navyše v `ST_RD_WAIT` je ešte toto:

```systemverilog
if (m_axil.RVALID) state_n = ST_NEXT;
```

Správnejšie by malo byť:

```systemverilog
if (m_axil.RVALID && m_axil.RREADY) state_n = ST_NEXT;
```

Pre malé READy sa to neprejaví, lebo `RREADY` je väčšinou 1. Ale pri plnom read FIFO je to chyba.

## Odporúčaná okamžitá oprava

Minimálne:

```systemverilog
ST_RD_WAIT: begin
  if (m_axil.RVALID && m_axil.RREADY)
    state_n = ST_NEXT;
end
```

A do tools pridať limit:

```python
MAX_READ_WORDS = 32
```

alebo automatické chunkovanie:

```python
def read_block(addr, num_words):
    result = []
    while num_words:
        n = min(num_words, 32)
        result.extend(self._read_block_once(addr, n))
        addr += n * 4
        num_words -= n
    return result
```

Toto bude dôležité pre CPU aplikácie, RAM dump, memory verify a loader.

---

# Packetizer multi-word READ

Aktuálny packetizer je oproti predchádzajúcej verzii výrazne prepracovaný. Má dual-slot buffer a guard:

```systemverilog
if (hs && byte_cnt_q[1] && byte_cnt_q[0] && done_flag && !slot1_valid_q)
  state_n = ST_DONE;
```

Logika je postavená na predpoklade:

```text
keď packetizer začne payload,
engine už dokončil celý READ
a všetky read slová sú v read FIFO.
```

Pre READ do veľkosti FIFO depth to môže fungovať. Preto aj simulácie prechádzajú.

Ale architektonicky je to stále limitované. Dlhodobo by bolo čistejšie pridať do read dátovej cesty `last` bit alebo preniesť `count` do packetizera. Napríklad:

```systemverilog
read_data
read_data_valid
read_data_ready
read_data_last
```

Potom packetizer nemusí hádať koniec cez `resp_done_i` a stav slotov.

Krátkodobo však aktuálne riešenie môže zostať, ak tools budú robiť burst chunking na max. 32 slov.

---

# Simulácie: PASS, ale logy obsahujú `$error`

Podľa logov testy končia ako:

```text
ALL PASSED
```

ale niektoré logy obsahujú:

```text
Errors: 1
Errors: 3
```

Napríklad:

```text
tb_xfcp_axi_engine.log: Errors: 1
tb_xfcp_fabric_endpoint.log: Errors: 1
tb_xfcp_rx_parser.log: Errors: 3
```

Vyzerá to, že tieto `$error` sú očakávané chyby v negatívnych testoch, napríklad watchdog timeout alebo protocol error. Testbench ich považuje za očakávané, ale simulátor ich stále počíta ako errors.

To je riziko pre CI/regression. Ak neskôr Makefile alebo CI začne kontrolovať `Errors: 0`, regression začne padať, hoci funkčne prešla.

Odporúčanie:

```text
- očakávané chyby v DUT nelogovať cez $error
- použiť $warning alebo $display
- alebo pridať parameter ENABLE_ERROR_LOGS / EXPECT_ERRORS
- skutočné assert/fatal nechať len na neočakávané porušenia
```

---

# Tools stav

`tools/bus/xfcp.py` je stále jednoduchý monolit, ale už obsahuje dôležité opravy:

```python
self.ser.reset_input_buffer()
```

pred transakciou a po partial read.

Má aj retry pre READ:

```python
self.retries = retries
```

a WRITE sa správne neretryuje:

```python
resp = self._transact(pkt, total, retries=0)
```

To je správne, pretože opakovať write do pulse registra môže byť nebezpečné.

Čo ešte chýba:

```text
- oddelené timeouty: byte / response / module / recovery
- výnimky namiesto None/False
- recovery manager
- sequence ID
- CRC
- RESP_ERROR dekódovanie
- chunking pre read_block/write_block
- diagnostické dumpy pri chybe
```

Najbližšia praktická úprava tools by mala byť práve chunking:

```text
read_block nad 32 slov rozdeliť na viac XFCP READ requestov.
```

---

# HW stav

Podľa `XFCP3_STATUS.md` bol stav:

```text
pred fifo fixom: 2/12 OK = 17 %
po fifo fixe:    7/12 OK = 58 %
```

Aktuálny kód v ZIPe už má navyše aj `SOP_RESP=0xFD`. V ZIPe však nevidím jednoznačný nový HW výsledok po tejto zmene.

Preto by som aktuálny HW stav formuloval takto:

```text
Root cause #1 potvrdený: xfcp_fifo ramstyle.
Root cause #2 pravdepodobný: TX→RX coupling cez rovnaký SOP 0xFE.
Fix #2 je už implementovaný v RTL aj tools.
Treba urobiť nový HW test s aktuálnym SOF.
```

---

# Odporúčaný ďalší postup

## Krok 1 — urobiť nový HW test aktuálneho snapshotu

Najprv by som overil, či `SOP_RESP=0xFD` odstránil zvyšné timeouty:

```bash
make program
python tools/hw_diag.py /dev/ttyUSB0
python tools/main.py scan
```

Očakávanie:

```text
ak bola hypotéza TX→RX coupling správna:
  výsledok by mal ísť blízko 12/12 OK
```

Ak nie, potom treba sledovať UART STATUS:

```text
overrun
frame
parity
```

a prípadne pridať SignalTap.

---

## Krok 2 — opraviť `ST_RD_WAIT`

V `xfcp_axi_engine.sv`:

```systemverilog
ST_RD_WAIT: begin
  if (m_axil.RVALID && m_axil.RREADY)
    state_n = ST_NEXT;
end
```

Toto je malá, ale správna AXI oprava.

---

## Krok 3 — zaviesť burst limit/chunking v tools

Do `XFCPBus.read_block()`:

```python
MAX_BURST_WORDS = 32
```

a automaticky rozdeliť dlhé čítania.

Pre WRITE by som tiež zaviedol limit, minimálne podľa FIFO a RX stability. Napríklad:

```python
MAX_WRITE_WORDS = 16 alebo 32
```

---

## Krok 4 — zosúladiť dokumentáciu

`XFCP3_STATUS.md` treba aktualizovať:

```text
XFCP_SOP_RESP=0xFD už implementované
tools/bus/xfcp.py už očakáva SOP_RESP=0xFD
treba doplniť výsledok HW testu po tejto zmene
```

---

## Krok 5 — upratať sim logy

Očakávané chyby by nemali generovať `$error`, ak celkový test má byť PASS.

Odporúčam:

```text
$warning pre očakávaný watchdog/protocol error
$fatal iba pre skutočný bug
```

---

# Celkové hodnotenie

Tento snapshot je výrazný posun dopredu.

Najväčšie plusy:

```text
- nájdený veľmi pravdepodobný root cause pôvodného 17 % HW správania
- xfcp_fifo opravený cez ramstyle="logic"
- invalid WRITE path vo fabricu je už riešený
- eng_busy invalid bug je opravený
- resp_type z engine sa prenáša do fabricu
- RX/TX SOP sú už oddelené: request 0xFE, response 0xFD
- tools už očakávajú response SOP 0xFD
- Quartus a timing sú PASS
```

Najväčšie otvorené veci:

```text
- treba potvrdiť HW test po SOP_RESP=0xFD
- ST_RD_WAIT má používať RVALID && RREADY
- READ burst > 32 slov môže zablokovať architektúru
- tools ešte nemajú robustný recovery/error model
- protokol ešte nemá SEQ, CRC, RESP_ERROR
- sim logy obsahujú očakávané $error hlásenia
```

Moje odporúčanie: **najprv otestovať aktuálny bitstream s `SOP_RESP=0xFD`; potom opraviť `ST_RD_WAIT` a pridať chunking do tools.** Až potom by som začal väčší refaktor tools na `transport/protocol/bus/recovery/drivers`.
