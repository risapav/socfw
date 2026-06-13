Áno, **možnosť A je správny ďalší krok**, ale upravil by som ju tak, aby sa z nej nestal slepý hack do `xfcp_fabric_endpoint`.

Tvoj plán je dobrý, len by som ho doplnil o jednu dôležitú zásadu:

```text
xfcp_test_07_axis nemá ešte riešiť plne generický target router.
Má overiť prvý AXI-Stream backend pri minimálnej zmene stabilného xfcp_test_06.
```

Čiže: **A áno**, ale s jasne definovanými hranicami, aby sme si nezablokovali budúcu knižničnú architektúru.

---

# 1. Potvrdenie stavu `xfcp_test_06`

Ak je tag:

```text
xfcp_lib_v0_9_status_pass @ 14b534d
```

a stav:

```text
Sim:     12/12 PASS
HW:      ARP 4/4, ICMP 4/4, UART 21/21, UDP 21/21 PASS
Timing:  SEED 5, WNS +0.124 ns
```

tak to je správny míľnik.

Ja by som ho klasifikoval takto:

```text
xfcp_lib_v0_9_status_pass:
  prvý timing-clean dual-transport XFCP s STATUS odpoveďami
  UART + UDP + AXI-Lite backend
  pripravené ako základ pre prvý non-AXIL backend
```

Dôležité: toto je už dosť stabilný základ na `xfcp_test_07_axis`.

---

# 2. Tvoj plán pre `xfcp_test_07_axis` je správny

Navrhnuté opcodes sú dobré:

```systemverilog
XFCP_OP_STREAM_WRITE      = 8'h20;  // XFCP -> AXIS sink
XFCP_OP_STREAM_READ       = 8'h21;  // AXIS source -> XFCP
XFCP_OP_RESP_STREAM_WRITE = 8'h22;
XFCP_OP_RESP_STREAM_READ  = 8'h23;
```

Toto je logické oddelenie od register prístupov:

```text
0x10/0x11 = register / AXI-Lite
0x20/0x21 = stream / AXI-Stream
```

Aj `xfcp_axis_adapter.sv` ako nový modul je správny smer.

---

# 3. Dôležitá úprava: `STREAM_WRITE` a `STREAM_READ` nemajú byť jeden monolit

Pre prvú verziu môže byť jeden súbor `xfcp_axis_adapter.sv`, ale vnútri by som to rozdelil na dve nezávislé časti:

```text
xfcp_axis_sink_path:
  STREAM_WRITE -> M_AXIS

xfcp_axis_source_path:
  S_AXIS -> STREAM_READ response
```

Prečo? Lebo tieto dva smery majú úplne iné problémy.

## STREAM_WRITE

Host posiela payload do FPGA:

```text
XFCP STREAM_WRITE
  -> payload FIFO / stage
  -> M_AXIS_TDATA/TVALID/TLAST
```

Typické chyby:

```text
AXIS sink nedáva TREADY
payload príliš dlhý
adaptér busy
FIFO overflow
```

## STREAM_READ

FPGA posiela stream späť hostu:

```text
S_AXIS_TDATA/TVALID/TLAST
  -> capture buffer / response payload
  -> XFCP STREAM_READ response
```

Typické chyby:

```text
source nič neposiela
frame je dlhší než max response
timeout
truncated frame
```

Preto by som už v návrhu pomenoval vnútorné bloky:

```text
axis_sink_adapter
axis_source_adapter
```

Aj keď ich zatiaľ necháš v jednom RTL súbore.

---

# 4. Najväčšie riziko tvojho plánu: routing priamo v `xfcp_fabric_endpoint`

Možnosť A je dobrá ako testovací krok, ale pozor: `xfcp_fabric_endpoint` už teraz nesie veľa zodpovednosti:

```text
decode
slot select
AXI-Lite engine dispatch
order FIFO
response arbitration
packetizer
read/write data staging
```

Ak tam priamo pridáš aj AXI-Stream logiku, môže sa z neho stať monolit.

Preto by som zvolil **A-light**, nie plnú A.

---

# 5. Odporúčaná verzia možnosti A

Nerobil by som:

```text
xfcp_fabric_endpoint priamo obsahuje všetku STREAM_WRITE/READ logiku
```

ale:

```text
xfcp_fabric_endpoint
  rozpozná opcode class
  pre AXIL pošle request do existujúceho AXI engine
  pre AXIS pošle request do samostatného xfcp_axis_adapter
```

Čiže endpoint iba multiplexuje requesty a odpovede, ale **AXIS správanie je mimo neho**.

Architektonicky:

```text
xfcp_rx_parser
  -> xfcp_fabric_endpoint
       -> AXIL engines[0..N-1]
       -> AXIS adapter[0]
  -> xfcp_tx_packetizer
```

Pre `xfcp_test_07` stačí jeden AXIS slot:

```text
AXIL slots: existujúce 0..6
AXIS slot: 0
```

---

# 6. Slot type model treba zaviesť už teraz

Aj keď nepôjdeme do plného target routera, zaviedol by som jednoduchý slot typ:

```systemverilog
typedef enum logic [1:0] {
  XFCP_SLOT_AXIL = 2'd0,
  XFCP_SLOT_AXIS = 2'd1
} xfcp_slot_type_e;
```

A v top/fabric parametre napríklad:

```systemverilog
parameter int NUM_AXIL_SLOTS = 7,
parameter int NUM_AXIS_SLOTS = 1
```

Pre `xfcp_test_07` by som nemiešal AXIL a AXIS do jednej `NUM_SLAVES` tabuľky. Lepšie je:

```text
AXIL decode podľa addr
AXIS opcode/target podľa addr alebo target_id
```

Keďže súčasný paket ešte nemá `target_id`, musíš rozhodnúť, ako vybrať AXIS slot.

---

# 7. Ako vybrať AXIS slot v `xfcp_test_07`

Máš dve možnosti.

## Možnosť 1 — použiť `addr` ako stream target id

Pre `STREAM_WRITE/READ` interpretovať `addr[7:0]` ako stream slot:

```text
addr[7:0] = axis_target_id
count     = počet bajtov
```

Príklad:

```text
STREAM_WRITE addr=0x00000000 count=64 -> AXIS slot 0
STREAM_READ  addr=0x00000000 count=64 -> AXIS slot 0
```

Výhoda: netreba meniť request header.

Nevýhoda: `addr` pri streamoch nie je skutočná adresa.

Toto je podľa mňa najlepšie pre `xfcp_test_07`.

## Možnosť 2 — rozšíriť header o target_type/target_id

To je čistejšie pre knižnicu, ale väčší zásah do protokolu. Nerobil by som to hneď v `xfcp_test_07`.

Odporúčanie:

```text
xfcp_test_07:
  addr[7:0] = stream_id

xfcp_lib_v1.1+:
  zaviesť target_type/target_id alebo GET_TARGET_TABLE
```

---

# 8. Definuj presne payload granularitu

Dnes AXI-Lite pracuje s 32-bit slovami. AXI-Stream môže byť 8-bit alebo 32-bit.

Pre prvú verziu odporúčam:

```text
XFCP stream payload je byte-oriented.
AXI-Stream TDATA je 8-bit.
TLAST = posledný byte payloadu.
```

Teda:

```systemverilog
parameter int AXIS_DATA_WIDTH = 8;
```

Prečo 8-bit? Lebo:

```text
UART/UDP payload je prirodzene byte stream
packetizer/parser už pracuje po bajtoch
jednoduchý loopback test
žiadne TKEEP komplikácie
```

32-bit AXIS nech príde až neskôr.

---

# 9. STATUS mapovanie pre AXI-Stream

Doplň do návrhu, že `xfcp_axis_adapter` musí používať existujúci STATUS model.

Minimálne:

```text
STREAM_WRITE:
  OK           — celý payload odoslaný na M_AXIS
  BUSY         — adaptér už obsluhuje predošlú operáciu
  TIMEOUT      — M_AXIS_TREADY neprišlo v limite
  BAD_LENGTH   — count=0 alebo count > MAX_STREAM_BYTES
  OVERFLOW     — interný buffer/FIFO plný

STREAM_READ:
  OK           — prečítaných count bajtov alebo frame do TLAST
  TIMEOUT      — S_AXIS_TVALID neprišlo v limite
  OVERFLOW     — frame dlhší než response buffer
  BAD_LENGTH   — count=0 alebo count > MAX_STREAM_BYTES
  BUSY         — adaptér obsadený
```

Doplnil by som ešte:

```text
UNSUPPORTED — ak stream_id neexistuje
```

---

# 10. `STREAM_READ`: rozhodni, či čítať presne count alebo do TLAST

Toto treba explicitne určiť hneď.

Navrhujem pre `xfcp_test_07`:

```text
STREAM_READ count=N:
  čítaj najviac N bajtov zo S_AXIS
  skonči, keď:
    A) prečítaných N bajtov, alebo
    B) príde TLAST
```

Response:

```text
payload = skutočne prečítané bajty
STATUS = OK, ak aspoň 1 byte a nebol timeout/overflow
```

Ale host musí vedieť, či TLAST prišiel. Keďže response header zatiaľ nemá flags, máš dve možnosti:

## Jednoduchá možnosť pre test_07

Ignorovať TLAST význam a loopback FIFO nech generuje TLAST presne po N bajtoch.

To je jednoduché pre prvý test.

## Lepšia možnosť

Do `STREAM_READ` response payload dať prvý meta byte:

```text
payload[0] = flags
payload[1..] = data
```

Flags:

```text
bit0 = TLAST_SEEN
bit1 = TRUNCATED
bit2 = TIMEOUT_PARTIAL
```

Ale to komplikuje Python.

Pre `xfcp_test_07` by som zvolil jednoduché:

```text
STREAM_READ vracia presne count bajtov, TLAST sa používa iba interne v test loopbacku.
```

Neskôr pridáme stream flags.

---

# 11. `STREAM_WRITE` response payload

Pre `STREAM_WRITE` response by som neposielal žiadny payload, iba status:

```text
SOP, RESP_STREAM_WRITE, SEQ, STATUS, trailer
```

Ale do budúcnosti môže byť užitočné vrátiť počet prijatých bajtov. Pre test_07 to nie je nutné.

Ak chceš byť presnejší:

```text
response payload:
  bytes_written[15:0]
```

Ale držal by som to jednoduché:

```text
STATUS OK znamená count bajtov prijatých.
```

---

# 12. Axis loopback v top-e

Tvoj návrh:

```text
xfcp_axis_adapter + loopback axis_fifo_sync
```

je dobrý.

Ja by som spravil takýto testovací blok:

```text
STREAM_WRITE -> axis sink FIFO
axis sink FIFO -> axis source FIFO / alebo rovno source path
STREAM_READ <- axis source FIFO
```

Najjednoduchšie:

```text
M_AXIS z adaptera
  -> axis_fifo_sync
  -> S_AXIS do adaptera
```

Teda host:

```text
stream_write(data)
stream_read(len(data))
compare
```

Toto je dobrý prvý end-to-end test.

Pozor: FIFO musí zachovať TLAST. Ak používaš 8-bit stream, FIFO šírka by mala byť:

```text
{tlast, tdata[7:0]} = 9 bitov
```

---

# 13. Sim plán doplniť

Tvoj sim plán „write N slov → read N slov“ je dobrý, ale doplnil by som tieto testy:

```text
T01 STREAM_WRITE 1 byte, STREAM_READ 1 byte
T02 STREAM_WRITE 16 bytes, READ 16
T03 STREAM_WRITE 64 bytes, READ 64
T04 STREAM_WRITE count=0 -> BAD_LENGTH
T05 STREAM_READ count=0 -> BAD_LENGTH
T06 STREAM_READ empty source -> TIMEOUT
T07 STREAM_WRITE when sink backpressured -> TIMEOUT alebo BUSY
T08 unknown stream id -> UNSUPPORTED
T09 AXIL READ stále funguje po STREAM ops
T10 UART transport STREAM_WRITE/READ
T11 UDP transport STREAM_WRITE/READ
```

Pre prvú fázu stačí T01–T05, ale minimálne timeout test by som pridal hneď, lebo AXI-Stream bez timeoutu je nebezpečný.

---

# 14. Python API doplnenie

Navrhnuté:

```python
bus.stream_write()
bus.stream_read()
```

Áno. Doplnil by som signatúru:

```python
def stream_write(self, stream_id: int, data: bytes, timeout: float = 1.0) -> None:
    ...

def stream_read(self, stream_id: int, count: int, timeout: float = 1.0) -> bytes:
    ...
```

Interné mapovanie:

```text
addr = stream_id
count = len(data)
opcode = STREAM_WRITE / STREAM_READ
```

A status exceptions:

```text
XfcpStatusError(OVERFLOW)
XfcpStatusError(BUSY)
XfcpStatusError(TIMEOUT)
XfcpStatusError(BAD_LENGTH)
XfcpStatusError(UNSUPPORTED)
```

---

# 15. Knižničná hranica: neprepisovať hneď `xfcp_fabric_endpoint` na generický router

Možnosť B je čistejšia do budúcnosti:

```text
xfcp_opcode_router pred fabric_endpoint
```

ale teraz by som ju nerobil.

Prečo? Lebo `xfcp_test_06` je stabilný a timing-clean. Ak hneď prekopeme front-end router, riskujeme veľa regresie naraz.

Správne poradie:

```text
xfcp_test_07:
  možnosť A-light, jeden AXIS slot vedľa AXIL engines

xfcp_test_08 alebo refaktor:
  vytiahnuť opcode routing do samostatného xfcp_opcode_router
```

Čiže odpoveď na tvoju otázku:

```text
Pokračuj s možnosťou A,
ale implementuj ju ako minimálnu bridge vrstvu, nie ako trvalý monolit.
```

---

# 16. Konkrétne doplnený plán `xfcp_test_07_axis`

## Fáza 1 — package

Doplniť:

```systemverilog
XFCP_OP_STREAM_WRITE      = 8'h20;
XFCP_OP_STREAM_READ       = 8'h21;
XFCP_OP_RESP_STREAM_WRITE = 8'h22;
XFCP_OP_RESP_STREAM_READ  = 8'h23;
```

Možno doplniť helper funkcie:

```systemverilog
function automatic logic xfcp_op_is_reg(input xfcp_op_e op);
function automatic logic xfcp_op_is_stream(input xfcp_op_e op);
function automatic xfcp_op_e xfcp_resp_for_op(input xfcp_op_e op);
```

---

## Fáza 2 — `xfcp_axis_adapter.sv`

Parametre:

```systemverilog
parameter int DATA_WIDTH = 8;
parameter int MAX_STREAM_BYTES = 256;
parameter int TIMEOUT_CYCLES = 1024;
```

XFCP-side:

```text
req_valid/ready
req_opcode
req_seq
req_addr       // stream_id
req_count
req_payload_valid/ready/data/last

resp_valid/ready
resp_opcode
resp_seq
resp_status
resp_payload_valid/ready/data/last
```

AXIS-side:

```text
m_axis_* for STREAM_WRITE
s_axis_* for STREAM_READ
```

---

## Fáza 3 — endpoint integration

V `xfcp_fabric_endpoint`:

```text
if opcode == READ/WRITE:
  existujúca AXIL cesta

if opcode == STREAM_WRITE/STREAM_READ:
  axis_adapter cesta
```

Pre test_07:

```text
NUM_AXIS_SLOTS = 1
stream_id = addr[7:0]
valid stream_id only 0
else UNSUPPORTED
```

---

## Fáza 4 — top

```text
xfcp_axis_adapter.m_axis
  -> axis_fifo_sync
  -> xfcp_axis_adapter.s_axis
```

LED/diag doplniť:

```text
stream_write_count
stream_read_count
stream_error_count
last_stream_status
```

---

## Fáza 5 — Python

```python
stream_write(stream_id, data)
stream_read(stream_id, count)
```

Test:

```python
data = bytes(range(64))
bus.stream_write(0, data)
got = bus.stream_read(0, 64)
assert got == data
```

---

## Fáza 6 — sim

Začať s:

```text
T01 AXIL READ stále funguje
T02 STREAM_WRITE/READ 1B
T03 STREAM_WRITE/READ 16B
T04 STREAM_WRITE/READ 64B
T05 BAD_LENGTH
T06 UNSUPPORTED stream_id
T07 TIMEOUT read empty
```

---

## Fáza 7 — HW

Po timing PASS:

```bash
make program
python3 tools/test_hw.py --uart --stream-loopback
python3 tools/test_hw.py --udp  --stream-loopback
```

Alebo nové targety:

```makefile
make test-stream-uart
make test-stream-udp
make hw-regression
```

---

# 17. Kritické pravidlá pre AXI-Stream adaptér

Tieto pravidlá by som dal priamo do komentára v RTL:

```text
1. STREAM_WRITE request musí byť odpovedaný vždy:
   OK / BAD_LENGTH / TIMEOUT / BUSY / UNSUPPORTED.

2. STREAM_READ request musí byť odpovedaný vždy:
   OK / BAD_LENGTH / TIMEOUT / OVERFLOW / UNSUPPORTED.

3. AXIS TREADY/TVALID nesmie vytvoriť nekonečné čakanie bez watchdogu.

4. Jeden adaptér v test_07 podporuje iba single outstanding stream request.

5. count je počet bajtov, nie počet 32-bit slov.

6. addr[7:0] je stream_id pre test_07.
```

---

# 18. Konečné odporúčanie

Áno, pokračuj s možnosťou A.

Ale presnejšie:

```text
Pokračuj s možnosťou A-light:
  routing podľa opcode triedy v existujúcom fabric_endpoint,
  ale samotné AXI-Stream správanie drž v novom xfcp_axis_adapter.sv.
```

Nerobil by som ešte možnosť B, lebo by to bol väčší refaktor stabilného systému. Nerobil by som ani C, lebo by si duplikoval XFCP kanály a komplikoval response routing.

Najbližší cieľ má byť:

```text
xfcp_test_07_axis:
  jeden AXIS loopback slot,
  STREAM_WRITE/STREAM_READ,
  status-aware odpovede,
  UART aj UDP test,
  timing clean.
```

Až po úspešnom `xfcp_test_07` by som sa vrátil ku knižničnému refaktoru:

```text
xfcp_opcode_router
xfcp_target_table
generic stream arbiter
AXI-Full adapter
CPU mailbox
```

Takto bude vývoj postupný a nebudeš naraz rozbíjať stabilný `xfcp_test_06`.
