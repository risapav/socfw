Analyzoval som najnovší `xfcp_test_03.zip`. Toto je už veľmi užitočný stav, lebo máš v jednom balíku: aktuálny `XFCP3_STATUS.md`, RTL, tools, sim logy aj Quartus výstupy.

## Krátky verdikt

Projekt je v lepšom stave než predtým, ale aktuálnu interpretáciu v statuse by som upravil:

```text
Pôvodný veľký RTL bug: xfcp_fifo ramstyle → OPRAVENÉ
Fabric invalid WRITE / resp_type / ST_RD_WAIT → OPRAVENÉ
Tools refactor → začatý a užitočný
Quartus/timing → PASS
HW stabilita → stále otvorená
Aktuálna hypotéza „fyzický TX→RX coupling“ → už nie je dostatočne podložená
```

Najdôležitejšie: vo Fáze 2C status uvádza, že po teste bolo:

```text
overrun=False
frame=False
parity=False
```

To znamená, že **UART RX nevidel klasické chybové príznaky fyzického rušenia**. Pri CP2102 a extrémne krátkych cestách by som preto fyzický coupling už nedával ako hlavnú príčinu. Skôr by som ho presunul medzi vedľajšie hypotézy.

---

# Čo je v aktuálnom stave dobré

## 1. `xfcp_fifo.sv` je opravený správne

Aktuálne:

```systemverilog
(* ramstyle = "logic" *)
logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
```

Toto je správne, pretože FIFO používa fall-through čítanie:

```systemverilog
assign r_data = mem[rd_ptr_q];
```

Tým si odstránil veľmi pravdepodobný hlavný HW root cause pôvodných `0B response`.

---

## 2. `xfcp_rx_parser.sv` má lepší limit COUNT

V aktuálnom parseri už vidím:

```systemverilog
localparam int MAX_COUNT_BYTES = 128;
```

To je lepšie než predchádzajúcich 256, pretože to sedí s `xfcp_axi_engine` read FIFO depth 32 slov:

```text
32 slov × 4 bajty = 128 bajtov
```

Toto je správna bezpečnostná brzda.

---

## 3. `ST_RD_WAIT` je opravený

V `xfcp_axi_engine.sv` už je:

```systemverilog
ST_RD_WAIT: begin
  if (m_axil.RVALID && m_axil.RREADY) state_n = ST_NEXT;
end
```

To je správne. Predchádzajúce `RVALID` bez `RREADY` by bolo AXI chybné pri plnom read FIFO.

---

## 4. Fabric už má opravené predchádzajúce kritické problémy

V `xfcp_fabric_endpoint.sv` už je:

```systemverilog
assign invalid_req  = req_valid && !dec_valid;

assign req_ready    = invalid_req ? 1'b1 :
                      dec_valid && !eng_busy[dec_sel]
                      && eng_req_ready[dec_sel] && ofifo_wready;

assign ofifo_wvalid = req_fire && !invalid_req;
```

a invalid WRITE drain:

```systemverilog
wire drain_wdata = drop_wdata_q ||
                   (invalid_req && req_hdr.opcode == XFCP_OP_WRITE);

assign wdata_valid = wdata_valid_raw && !drain_wdata;
assign wdata_ready = drain_wdata ? 1'b1 : eng_wdata_ready[wdata_sel];
```

Teda pôvodný problém:

```text
invalid WRITE → payload do slave 0
```

je už riešený.

Aj `eng_busy` je chránený:

```systemverilog
if (req_valid && req_ready && !invalid_req && dec_sel == SEL_W'(i))
  eng_busy[i] <= 1'b1;
```

A `resp_type` z engine sa už používa:

```systemverilog
resp_type_q <= xfcp_op_e'(eng_resp_type[ofifo_rdata.sel]);
```

To sú dobré opravy.

---

## 5. Quartus/timing je čistý

Aktuálny build:

```text
Flow Status: Successful
Device: EP4CE55F23C8
Logic elements: 16,931 / 55,856 = 30 %
Registers: 13,549
Memory bits: 0
Setup slack SYS_CLK: +4.827 ns
Hold slack SYS_CLK:  +0.448 ns
```

Z pohľadu syntézy a timing closure je to v poriadku.

---

# Čo mi v aktuálnom stave nesedí

## 1. Top stále obsahuje coupling mitigáciu, hoci posledný test coupling nepotvrdzuje

V `xfcp_uart_mmio_top.sv` je stále:

```systemverilog
localparam int POST_TX_HOLD_CYCLES = UART_DEFAULT_BAUD_DIV * 10;

wire post_tx_hold_w = tx_status_w.tx_busy || (post_tx_cnt_r > 0);
wire fifo_flush_w   = post_tx_hold_w;
wire rx_gate_w      = post_tx_hold_w;
```

a RX FIFO:

```systemverilog
.flush  (fifo_flush_w),
...
.r_ready(xfcp_rx_s.TREADY && !rx_gate_w)
```

Toto znamená:

```text
počas TX a ešte 1 bajtovú periódu po TX sa RX FIFO flushuje
```

Ak by bol fyzický echo/coupling, dáva to zmysel ako experiment. Ale ak UART status ukazuje:

```text
overrun=False
frame=False
parity=False
```

potom táto mitigácia môže byť skôr zdrojom problémov než riešením.

Najmä ak ďalší request príde počas tohto okna, prvé bajty requestu sa zahodia. V `hw_diag.py` máš `pre_delay=0.2 s`, tam by to nemalo vadiť. Ale v bežných tools a v budúcom CPU loaderi nechceš mať v RTL skryté okno, kde sa RX zahadzuje.

Odporúčanie: spraviť z toho parameter a predvolene ho vypnúť:

```systemverilog
parameter bit ENABLE_POST_TX_FLUSH = 1'b0,
parameter int POST_TX_HOLD_CYCLES  = 0
```

A otestovať tri konfigurácie:

```text
A: flush OFF
B: flush 2000 cyklov
C: flush UART_DEFAULT_BAUD_DIV*10
```

Podľa statusu už teraz vyzerá:

```text
2000 cyklov: 14/30
4340 cyklov: 10/30
```

Čiže dlhší hold-off zhoršil výsledok. To je silný signál, že flush/hold-off nie je správna finálna cesta.

---

## 2. Fyzický coupling by som už nebral ako hlavnú príčinu

Status stále hovorí o fyzickom coupling ako o príčine. Ale aktuálne dáta hovoria niečo iné:

```text
Fáza 2C:
HW 10/30
UART STATUS: overrun=False, frame=False, parity=False
```

Ak by do RX počas TX masívne prenikali bajty, očakával by som aspoň občas:

```text
frame_err
overrun
bad byte / partial RX
```

Nie je to absolútny dôkaz, ale pri CP2102 a krátkych cestách by som teraz hlavné vyšetrovanie presunul do:

```text
1. transakčný timing tools ↔ FPGA
2. TX packetizer / UART TX štart
3. parser/fabric stav po timeoutoch
4. chýbajúci SEQ/CRC/RESP_ERROR
5. absencia HW diagnostických counterov
```

---

## 3. `hw_diag.py` zatiaľ ešte nehovorí, kde sa request stratil

`hw_diag.py` už loguje raw TX/RX a klasifikuje:

```text
0B
partial
bad SOP
OK
```

To je dobré. Ale stále nevieš, či pri `0B`:

```text
- request vôbec prišiel do FPGA RX
- parser ho prijal
- header sa dostal do fabricu
- engine dokončil AXI transakciu
- packetizer sa spustil
- UART TX začal vysielať
```

Preto sa stále pohybujeme medzi hypotézami.

Tu by som už nepridával ďalšie heuristiky typu hold-off. Potrebuješ **diagnostické countery v RTL** alebo Signal Tap.

---

# Moja aktuálna hlavná hypotéza

Po tomto ZIPe by som povedal:

```text
Zvyšné HW zlyhania už pravdepodobne nie sú jeden veľký statický RTL bug typu ramstyle.
Vyzerá to ako stratová alebo rozladená transakcia v pipeline UART RX → parser → fabric → packetizer → UART TX,
ktorú bez interných counterov nevieme lokalizovať.
```

Konkrétne najpodozrivejšie sú teraz:

## A. RX flush/hold-off môže zahadzovať legitímne bajty

Toto je reálne, lebo je to priamo implementované v top-level.

Aj keď `hw_diag.py` používa delay, normálne tools nemusia. A aj pri delay môže byť problém po chybovej transakcii, ak sa flush/read/write časovo prekryjú inak, než čakáš.

Preto by som teraz otestoval **flush úplne vypnutý**.

---

## B. Tools čítajú odpoveď príliš striktne od prvého bajtu

V `tools/xfcp/protocol.py` dekóder očakáva:

```python
raw[0] == SOP_RESP
```

a `SerialTransport.read(n)` číta presne `n` bajtov od aktuálnej pozície.

To je krehké. Robustnejší prijímač by nemal očakávať, že prvý prijatý bajt je vždy `0xFD`. Mal by robiť resynchronizáciu:

```text
čítaj bajty, kým nenájdeš SOP_RESP=0xFD
potom dočítaj zvyšok response
ak príde garbage pred SOP_RESP, zahodiť a započítať
```

Toto by som doplnil do tools ešte pred CRC/SEQ.

Napríklad:

```python
def read_packet(self, expected_len: int) -> bytes:
    deadline = time.monotonic() + self._timeouts.response_s
    buf = bytearray()

    while time.monotonic() < deadline:
        b = self._ser.read(1)
        if not b:
            continue

        if b[0] != proto.SOP_RESP:
            continue

        buf = bytearray(b)
        remaining = expected_len - 1
        while remaining > 0 and time.monotonic() < deadline:
            chunk = self._ser.read(remaining)
            if not chunk:
                continue
            buf.extend(chunk)
            remaining -= len(chunk)

        if len(buf) == expected_len:
            return bytes(buf)

    return bytes(buf)
```

Bez SEQ/CRC to nie je dokonalé, ale je to lepšie než fixné `read(expected)`.

---

## C. Chýbajú RTL countery

Toto je teraz najväčší blokátor debugovania. Potrebuješ vedieť, kde skončila transakcia.

Minimálne countery:

```text
rx_uart_byte_count
rx_parser_sop_count
rx_parser_hdr_count
rx_parser_error_count
fabric_req_count
fabric_invalid_req_count
fabric_resp_start_count
engine_timeout_count
tx_packet_start_count
tx_uart_byte_count
last_opcode
last_addr
last_count
last_error
last_parser_state
last_fabric_state
```

A potom pri každom `0B` vieš urobiť:

```text
pred testom prečítaj counters
po zlyhaní prečítaj counters
porovnaj delta
```

Príklad interpretácie:

```text
rx_uart_byte_count +8
rx_parser_hdr_count +1
fabric_req_count +1
fabric_resp_start_count +0
→ problém fabric/engine

rx_uart_byte_count +8
rx_parser_hdr_count +0
→ parser request nerozpoznal

fabric_resp_start_count +1
tx_uart_byte_count +0
→ packetizer/UART TX problém
```

Toto je oveľa lepšie než ďalšie odhady.

---

# Simulácie

Status hovorí `ALL PASSED`, a logy to v zásade podporujú. Ale pozor: niektoré logy obsahujú `Errors: N`, hoci zároveň obsahujú `ALL PASSED`.

Vidím napríklad:

```text
tb_xfcp_rx_parser.log: ALL PASSED, Errors: 4
tb_xfcp_axi_engine.log: ALL PASSED, Errors: 1
tb_xfcp_fabric_endpoint.log: ALL PASSED, Errors: 1
tb_xfcp_uart_mmio_top.log: ALL PASSED, Errors: 29
```

Zrejme ide o očakávané `$error` v negatívnych testoch alebo transcript agregáciu, ale pre CI je to nečisté.

Odporúčanie:

```text
- očakávané chyby logovať cez $warning alebo $display
- $error/$fatal nechať iba na neočakávané zlyhanie
- regression nech kontroluje FAIL/FATAL, nie len ALL PASSED
```

Nie je to hlavný HW problém, ale neskôr ťa to bude miasť.

---

# Čo by som urobil teraz

## Krok 1 — vypnúť post-TX flush a spraviť porovnávací HW test

V `xfcp_uart_mmio_top.sv` dočasne:

```systemverilog
wire fifo_flush_w = 1'b0;
wire rx_gate_w    = 1'b0;
```

Alebo parametricky:

```systemverilog
parameter bit ENABLE_POST_TX_FLUSH = 1'b0;

wire post_tx_hold_w = ENABLE_POST_TX_FLUSH
                    ? (tx_status_w.tx_busy || (post_tx_cnt_r > 0))
                    : 1'b0;
```

Potom test:

```bash
python3 tools/hw_diag.py /dev/ttyUSB0 10
```

Teda 60 readov.

Porovnaj:

```text
flush OFF
flush 2000
flush 4340
```

Ak flush OFF vyjde lepšie, coupling hypotézu môžeš prakticky zahodiť.

---

## Krok 2 — doplniť read resync v tools

Namiesto:

```python
resp = self._transport.read(expected)
```

spraviť:

```python
resp = self._transport.read_packet(expected, sop=proto.SOP_RESP)
```

Cieľ:

```text
garbage pred 0xFD nezničí transakciu
partial response sa lepšie diagnostikuje
bad leading byte sa zahodí
```

Toto je lacná a užitočná robustnosť.

---

## Krok 3 — pridať RTL diagnostické registre

Nemusí to byť hneď elegantné. Stačí dočasný debug slave alebo rozšírenie `sys_ctrl`.

Odporúčaná mapa napríklad:

```text
0xFF000040 RX_BYTE_COUNT
0xFF000044 RX_SOP_COUNT
0xFF000048 RX_HDR_COUNT
0xFF00004C RX_ERROR_COUNT
0xFF000050 FABRIC_REQ_COUNT
0xFF000054 FABRIC_RESP_START_COUNT
0xFF000058 TX_PACKET_COUNT
0xFF00005C TX_BYTE_COUNT
0xFF000060 LAST_OPCODE_ADDR
0xFF000064 LAST_COUNT_ERROR
```

Potom `hw_diag.py` nech po každom zlyhaní vypíše delta counterov.

---

## Krok 4 — až potom Signal Tap

Signal Tap by som použil cielene, nie naslepo. Po counteroch budeš vedieť, kam zamerať trace.

Ak counters ukážu:

```text
fabric_resp_start_count +1, tx_byte_count +0
```

trace packetizer/TX.

Ak ukážu:

```text
rx_byte_count +8, rx_hdr_count +0
```

trace parser/RX.

Ak ukážu:

```text
fabric_req_count +1, fabric_resp_start_count +0
```

trace fabric/engine.

---

# Priorita ďalšieho vývoja

Teraz by som nemenil hneď celý protokol na SEQ/CRC. Najprv treba lokalizovať 0B fail.

Moja odporúčaná priorita:

```text
1. Porovnať HW bez post_tx_flush.
2. Pridať SOP_RESP resync čítanie v tools.
3. Pridať RTL diagnostické countery.
4. Urobiť 60–300 opakovaní hw_diag a vyhodnotiť delta counterov.
5. Až potom implementovať SEQ ID.
6. Potom RESP_ERROR.
7. Potom CRC16.
```

---

# Záver

Aktuálny kód je technicky oveľa lepší než predchádzajúce verzie. Hlavné RTL chyby, ktoré sme predtým označili, sú už väčšinou opravené.

Najväčší problém aktuálne vidím v tom, že projekt stále reaguje na hypotézu TX→RX coupling pomocou `post_tx_hold`/`fifo_flush`, ale posledné dáta ju už nepotvrdzujú. Pri CP2102 a krátkych cestách by som preto túto mitigáciu vypol alebo parametrizoval a začal merať vnútorné countery.

Najbližší cieľ by mal byť odpovedať na jednu otázku:

```text
Keď PC dostane 0B response, dostal sa request aspoň do parsera/fabricu?
```

Bez tejto odpovede budú ďalšie RTL úpravy skôr hádanie.
