Áno, plán potvrdzujem. Je to správny ďalší krok po `xfcp_test_06`, ale pred implementáciou by som upravil niekoľko detailov, aby sa `xfcp_test_07_axis` nestal slepou odbočkou a zostal použiteľný ako základ pre budúcu XFCP knižnicu.

Najdôležitejšie odporúčanie:

```text
Pokračuj s A-light:
  routing podľa opcode triedy vo fabric_endpoint,
  ale AXI-Stream správanie drž v samostatnom xfcp_axis_adapter.sv.
```

Nie B ani C teraz. B je čistejšia architektúra do budúcnosti, ale príliš veľký refaktor stabilného `xfcp_test_06`. C by zbytočne duplikovalo XFCP kanály a komplikovalo response routing.

---

# 1. Plán je správny, ale opravil by som názvy response opcode

Navrhuješ:

```systemverilog
XFCP_OP_STREAM_WRITE      = 0x20
XFCP_OP_STREAM_READ       = 0x21
XFCP_OP_RESP_STREAM_WRITE = 0x22
XFCP_OP_RESP_STREAM_READ  = 0x23
```

Súhlasím. Len by som si dal pozor na konzistentnosť názvov s existujúcimi:

```systemverilog
XFCP_OP_READ
XFCP_OP_WRITE
XFCP_OP_RESP_READ
XFCP_OP_RESP_WRITE
```

Takže buď:

```systemverilog
XFCP_OP_STREAM_WRITE
XFCP_OP_STREAM_READ
XFCP_OP_RESP_STREAM_WRITE
XFCP_OP_RESP_STREAM_READ
```

alebo kratšie:

```systemverilog
XFCP_OP_AXIS_WRITE
XFCP_OP_AXIS_READ
XFCP_OP_RESP_AXIS_WRITE
XFCP_OP_RESP_AXIS_READ
```

Ja by som nechal **STREAM**, lebo XFCP protokol nemusí byť navždy viazaný iba na AXI-Stream. AXI-Stream je backend implementácia, ale protokolová operácia je všeobecne „stream“.

---

# 2. `count % 4 == 0` je dobré pre prvý test, ale zdokumentuj to ako dočasný limit

Keďže parser už akumuluje payload do 32-bit slov, je rozumné v `xfcp_test_07` zaviesť:

```text
STREAM_WRITE count musí byť násobok 4.
STREAM_READ count musí byť násobok 4.
```

Ale veľmi dôležité: nech to nie je tvárené ako konečný protokolový limit.

Do `known_limits` alebo priamo do statusu daj:

```text
xfcp_test_07_axis v1:
  stream payload length must be 32-bit aligned.
  Byte-granular stream length will be added later using byte_count/TKEEP handling.
```

Pre prvé overenie je to správne. Pre knižnicu neskôr budeme chcieť aj 1B, 2B, 3B, 5B atď.

Tvoje sim testy potom uprav:

```text
T02 STREAM_WRITE + READ 4B
T03 STREAM_WRITE + READ 64B
T04 STREAM_WRITE + READ 128B
```

Nedávaj zatiaľ 1B test, ak nebudeš riešiť byte remainder.

---

# 3. `axis_fifo_sync` s `TLAST=1'b1` nepoužiť — správne

Toto je dobrý nález. Ak má existujúci `axis_fifo_sync`:

```systemverilog
assign m_axis.TLAST = 1'b1;
```

tak nie je vhodný ako reálny AXI-Stream loopback FIFO. Použiť `xfcp_fifo` s 9-bit šírkou je OK:

```text
DATA_WIDTH = 9
data = {tlast, tdata[7:0]}
```

Ale pozor: `xfcp_fifo` je fall-through FIFO. V tomto mieste je to menej rizikové než vo fabric endpointe, ale pre knižničný stream FIFO by som neskôr radšej vytvoril:

```text
axis_fifo_sync_tlast.sv
```

alebo:

```text
xfcp_axis_fifo.sv
```

Pre `xfcp_test_07` je `xfcp_fifo #(DATA_WIDTH=9, DEPTH=256)` akceptovateľný.

---

# 4. Najväčšia architektonická vec: order FIFO `is_axis` nestačí bez status/type latchingu

Tvoj návrh:

```systemverilog
typedef struct packed {
  logic    is_axis;
  logic [SEL_W-1:0] sel;
  xfcp_op_e         op;
  logic [7:0]       seq;
} order_entry_t;
```

Je dobrý základ, ale odporúčam doplniť aj explicitný response opcode alebo aspoň pomocnú funkciu.

Prečo? Lebo pri AXIS budeš mať štyri opcodes:

```text
STREAM_WRITE      -> RESP_STREAM_WRITE
STREAM_READ       -> RESP_STREAM_READ
WRITE             -> RESP_WRITE
READ              -> RESP_READ
```

Nechceš mať túto mapovaciu logiku roztrúsenú po FSM.

Doplň do `xfcp_pkg.sv`:

```systemverilog
function automatic xfcp_op_e xfcp_resp_for_op(input xfcp_op_e op);
  unique case (op)
    XFCP_OP_READ:         return XFCP_OP_RESP_READ;
    XFCP_OP_WRITE:        return XFCP_OP_RESP_WRITE;
    XFCP_OP_STREAM_READ:  return XFCP_OP_RESP_STREAM_READ;
    XFCP_OP_STREAM_WRITE: return XFCP_OP_RESP_STREAM_WRITE;
    default:              return XFCP_OP_RESP_WRITE; // alebo error response type
  endcase
endfunction
```

Potom order entry môže byť:

```systemverilog
typedef struct packed {
  logic            is_axis;
  logic [SEL_W-1:0] sel;
  xfcp_op_e        req_op;
  xfcp_op_e        resp_op;
  logic [7:0]      seq;
} order_entry_t;
```

Nie je to nevyhnutné, ale pomôže to udržať packetizer čistý.

---

# 5. Pozor na `SEL_W`, keď máš AXIL aj AXIS sloty

Ak `SEL_W` je odvodený z `NUM_SLAVES`, teda AXI-Lite slotov, a AXIS má zatiaľ iba jeden slot, je to OK. Ale pre čistotu by som rozlíšil:

```systemverilog
localparam int AXIL_SEL_W = (NUM_SLAVES <= 1) ? 1 : $clog2(NUM_SLAVES);
localparam int AXIS_SEL_W = (NUM_AXIS_SLOTS <= 1) ? 1 : $clog2(NUM_AXIS_SLOTS);
```

Pre `order_entry_t` môžeš použiť širší z nich:

```systemverilog
localparam int ROUTE_SEL_W =
  (AXIL_SEL_W > AXIS_SEL_W) ? AXIL_SEL_W : AXIS_SEL_W;
```

Pre test_07 to nie je kritické, ale ak použiješ rovnaký `SEL_W`, minimálne to jasne okomentuj:

```text
For xfcp_test_07 there is one AXIS slot, so order_entry.sel uses AXIL SEL_W.
```

---

# 6. `STREAM_READ empty FIFO -> TIMEOUT` je dobrý test, ale musí byť deterministický

T07 je veľmi dobrý test. Ale pozor: ak predtým urobíš loopback write/read, FIFO môže obsahovať zvyšky, ak test zlyhá alebo read nevyčerpá všetko.

Pred T07 sprav buď:

```text
stream FIFO flush/reset
```

alebo použi nový čistý reset testbench fázy.

Do adaptéru by som tiež pridal interný `flush_i` alebo reset cez top, ale pre testbench stačí reset medzi testami.

---

# 7. `STREAM_WRITE` FSM musí odpovedať až po skutočnom odoslaní všetkých bajtov

V popise máš:

```text
ST_WRITE_DRAIN:
  wdata_valid → serialize 4 bajty na m_axis → resp_done
```

Dôležité pravidlo:

```text
resp_done nesmie prísť, kým posledný byte neprešiel handshake:
m_axis_valid && m_axis_ready
```

Nie keď ho len nastavíš na `m_axis_data`.

Teda posledný byte:

```systemverilog
if (m_axis_valid && m_axis_ready && byte_is_last) begin
  resp_done <= 1'b1;
end
```

Toto je dôležité, aby host nedostal OK skôr, než stream sink skutočne prijal payload.

---

# 8. `STREAM_READ` FSM musí držať `axis_rdata_valid_i`, kým packetizer neprevezme slovo

Pri read ceste budeš baliť 4 bajty do 32-bit `axis_rdata_i`.

Pravidlo:

```text
axis_rdata_valid_i musí byť held-valid.
Nesmie byť pulz, ktorý zmizne, keď endpoint/packetizer nie je ready.
```

Čiže adapter potrebuje malý output register/FIFO:

```text
read_pack_data_r
read_pack_valid_r
read_pack_last_r alebo count tracking
```

a endpoint dá:

```text
axis_rdata_ready_o
```

až keď paketizér vie prijímať payload.

Inak riskuješ presne ten typ problému, ktorý sme riešili v UART a vo fabric timing closure.

---

# 9. `axis_resp_done_i` musí byť oddelené od dostupnosti payloadu

Pre AXI-Lite READ dnes engine typicky signalizuje `resp_done` po dokončení transakcie a read data sú potom dostupné packetizeru.

Pri STREAM_READ je to trochu iné: response payload je samotný nazbieraný stream. Preto definuj jasne:

```text
axis_resp_done_i = adapter má hotový celý response frame alebo vie posielať response payload
```

Pre jednoduchší návrh odporúčam:

```text
STREAM_READ adapter najprv nazbiera celý requested count do interného response FIFO,
potom dá resp_done.
Packetizer potom číta response FIFO.
```

Tým sa vyhneš zložitému live streamingu do packetizeru.

Limit:

```text
MAX_STREAM_BYTES = 256
```

je v poriadku.

Pre `STREAM_WRITE` response payload nie je, takže `resp_done` môže byť po odoslaní posledného byte.

---

# 10. Interný buffer v `xfcp_axis_adapter`

Pre STREAM_READ potrebuješ buffer na response payload. Odporúčam:

```text
read response FIFO:
  DATA_WIDTH = 32
  DEPTH = MAX_STREAM_BYTES / 4
```

Adapter číta 8-bit `s_axis`, skladá 4 bajty do 32-bit wordov a pushuje do FIFO.

Endpoint/packetizer číta 32-bit slová cez:

```text
axis_rdata_i
axis_rdata_valid_i
axis_rdata_ready_o
```

To sedí na existujúci `rdata` model.

Pre STREAM_WRITE buffer nepotrebuješ, ak payload prichádza z parsera cez `wdata` a serializuješ ho priamo. Ale ak nechceš blokovať parser pri backpressure, môžeš mať malý FIFO. Pre prvý test stačí priamy serializer s watchdogom.

---

# 11. BAD_LENGTH pravidlá presne

Pre `xfcp_test_07` by som definoval:

```text
STREAM_WRITE:
  count == 0              -> BAD_LENGTH
  count > MAX_STREAM_BYTES -> BAD_LENGTH
  count[1:0] != 0         -> BAD_LENGTH

STREAM_READ:
  count == 0              -> BAD_LENGTH
  count > MAX_STREAM_BYTES -> BAD_LENGTH
  count[1:0] != 0         -> BAD_LENGTH
```

Ak `STREAM_WRITE` má BAD_LENGTH, treba riešiť payload:

```text
ak count != 0 a opcode je STREAM_WRITE, parser očakáva payload.
endpoint/adaptér musí payload drainnúť, aby sa stream nezasekol.
```

Pre `count[1:0] != 0` je to nepríjemné, lebo parser môže už payload posielať po 32-bit slovách. Pre prvú verziu odporúčam:

```text
parser akceptuje count len násobok 4 pre STREAM_WRITE.
ak nie, parser/fabric vráti BAD_LENGTH a odčerpá ceil(count/4) slov, alebo celý frame podľa parserovej dĺžky.
```

Tu treba byť opatrný. Ak parser interné `dec_words` ráta `ceil(count/4)`, vieš payload korektne drainnúť.

---

# 12. `UNSUPPORTED stream_id=1`

Súhlasím. Pre test_07:

```text
addr[7:0] == 0 -> supported
inak -> UNSUPPORTED
```

Aj pri `STREAM_WRITE stream_id=1` s payloadom musíš payload drainnúť, inak sa parser/fabric rozíde.

---

# 13. TIMEOUT pravidlá

`TIMEOUT_CYCLES=1024` je dobrý začiatok, ale pri 125 MHz je to iba:

```text
1024 / 125 MHz ≈ 8.2 us
```

Pre AXIS loopback FIFO je to OK. Pre reálne stream source/sink môže byť málo.

Pre test_07 nechaj default 1024, ale parameterizuj:

```systemverilog
parameter int TIMEOUT_CYCLES = 1024
```

a v docs napíš:

```text
TIMEOUT_CYCLES is intentionally short for test_07.
Production stream adapters should use larger timeout or configurable timeout register.
```

---

# 14. Response payload pri STREAM_READ

Keďže používaš existujúci packetizer s 32-bit `rdata`, response payload bude count bajtov, ale interne po 32-bit slovách.

Pre test_07 s `count%4==0` je to čisté.

Over v Python decoderi:

```text
STREAM_READ response:
  raw[0] = 0xFD
  raw[1] = 0x23
  raw[2] = seq
  raw[3] = status
  raw[4:4+count] = data
  raw[-1] = trailer
```

Teda pre `count=64` očakávaš:

```text
len(raw) = 4 + 64 + 1 = 69
```

---

# 15. Sim test T01: AXIL musí zostať prvý

Súhlasím, že T01 má byť AXIL READ/WRITE. Toto je regresná poistka. Pri integrácii AXIS do endpointu je najväčšie riziko, že rozbiješ existujúce AXIL cesty.

T01 by mal overiť:

```text
READ SYSC ID
WRITE LED
READ LED
STATUS OK
```

Až potom stream testy.

---

# 16. Doplň ešte jeden test: zmiešaný AXIL/STREAM order

Pridal by som T08 alebo T09:

```text
T08 mixed order:
  STREAM_WRITE 16B
  AXIL READ SYSC
  STREAM_READ 16B
  AXIL WRITE LED
```

Prečo? Lebo pridávaš `is_axis` do order FIFO. Treba overiť, že odpovede sa routujú správne aj keď sa striedajú typy.

Ak je systém stále single outstanding kvôli endpointu, aspoň ich pošli sekvenčne a skontroluj, že po stream operácii AXIL stále funguje.

---

# 17. Top-level loopback FIFO backpressure

Pre test timeoutu `STREAM_WRITE backpressure` neskôr budeš potrebovať možnosť vypnúť `m_axis_ready`.

Ak loopback FIFO má normálne `w_ready`, pri plnom FIFO vznikne backpressure. Pre T07 zatiaľ stačí `STREAM_READ empty`.

Ale do debug topu by som doplnil parameter alebo signál:

```text
axis_loopback_enable
axis_loopback_flush
axis_sink_force_not_ready
```

Nemusíš hneď vyvádzať do registra, ale v sim TB sa to hodí.

---

# 18. Python API — doplniť count alignment check

V `bus.py`:

```python
def stream_write(self, stream_id: int, data: bytes):
    if len(data) == 0:
        raise ValueError("stream_write data must not be empty")
    if len(data) % 4 != 0:
        raise ValueError("stream_write length must be 4-byte aligned in xfcp_test_07")
```

Pre `stream_read`:

```python
if count == 0:
    raise ValueError(...)
if count % 4 != 0:
    raise ValueError(...)
```

Ale pre test BAD_LENGTH musíš mať možnosť poslať zlý request. Takže pridaj nízkoúrovňový helper:

```python
stream_write_raw(stream_id, data, count_override=None)
stream_read_raw(stream_id, count)
```

alebo v testoch použi `protocol.build_request()` priamo.

---

# 19. Doplň status dokument hneď od začiatku

Vytvor:

```text
XFCP_TEST_07_AXIS_STATUS.md
```

S úvodom:

```text
Cieľ:
  Prvý AXI-Stream backend nad XFCP STATUS protokolom.

Obmedzenia:
  - 1 AXIS slot
  - 8-bit AXIS data
  - count musí byť násobok 4
  - addr[7:0] = stream_id
  - single outstanding stream request
  - STREAM_READ vracia presne count bajtov
```

Toto ti zabráni neskoršiemu chaosu.

---

# 20. Moje konečné potvrdenie

Plán potvrdzujem s týmito úpravami:

```text
1. Áno, A-light.
2. count%4==0 je OK, ale označiť ako dočasný limit.
3. Použiť 8-bit AXIS a 9-bit loopback FIFO {TLAST,TDATA}.
4. STREAM_WRITE odpovedať až po poslednom m_axis handshake.
5. STREAM_READ najprv nazbierať celý response do interného FIFO, potom resp_done.
6. Zaviesť BAD_LENGTH pre count=0, count>MAX, count%4!=0.
7. stream_id = addr[7:0], podporovaný iba 0, inak UNSUPPORTED.
8. Pri BAD_LENGTH/UNSUPPORTED pre STREAM_WRITE drainnúť payload.
9. Pridať mixed AXIL/STREAM regresný test.
10. Vytvoriť status MD hneď na začiatku.
```

Teda:

```text
Pokračuj s implementáciou.
```

Najbližší cieľ nie je dokonalý univerzálny stream router. Najbližší cieľ je úzky, overiteľný míľnik:

```text
xfcp_test_07_axis:
  UART/UDP XFCP STATUS protokol
  1× AXI-Stream loopback slot
  STREAM_WRITE/STREAM_READ
  sim PASS
  HW UART + UDP PASS
  timing PASS
```

Ak toto prejde, potom už máš pevný základ pre ďalšie kroky: `xfcp_test_08_axifull` a neskôr CPU/mailbox.
