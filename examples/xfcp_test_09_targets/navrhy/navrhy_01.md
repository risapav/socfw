Skontroloval som aktuálny `xfcp_test_08_caps.zip`.

```text
xfcp_test_08_caps.zip
SHA-256: 7019419909cb450bff7d3af67de6da2e4ccd55c13679d3a42d9459086b2ef411
```

## Verdikt

`xfcp_test_08_caps` je **veľmi dobrý posun architektúry**, ale podľa archívu ešte nie je uzavretý ako HW míľnik.

Stav podľa archívu:

```text
Sim:       T01–T25 ALL PASS
Timing:    PASS, CLK125 WNS +0.355 ns
HW:        zatiaľ overené iba ARP + ICMP podľa make hw-test
GET_CAPS:  overené v simulácii cez UART aj ETH-UDP
```

Tvoj výpis `make hw-test` potvrdzuje iba sieťovú dostupnosť FPGA:

```text
ARP:  4/4 PASS
ICMP: 4/4 PASS
```

Ale aktuálny `Makefile` pre `xfcp_test_08_caps` má `hw-test` zatiaľ len ako ARP + ping test. Nevolá Python XFCP testy, nečíta `GET_CAPS`, netestuje AXIL, STREAM ani DIAG. Čiže hardvérovo ešte nemáme potvrdené samotné `GET_CAPS`.

---

# 1. Čo je hotové dobre

## 1.1 GET_CAPS protokol je zavedený čisto

V `xfcp_pkg.sv` pribudlo:

```systemverilog
XFCP_OP_GET_CAPS      = 8'h01;
XFCP_OP_RESP_GET_CAPS = 8'h02;
```

Response formát je správne zdokumentovaný:

```text
FD 02 seq status [8B caps payload] 00
```

Caps payload:

```text
proto_major       = 1
proto_minor       = 1
num_axil_slots    = 7
num_stream_slots  = 1
max_stream_bytes  = 256
stream_align      = 4
caps_flags        = 0x07  // AXIL | STREAM | CAPS
```

To je presne smer, ktorý sme chceli pred AXI-Full/CPU: host sa už nemusí spoliehať len na hardcoded znalosti.

---

## 1.2 `xfcp_caps_adapter.sv` je jednoduchý a vhodný pre prvú verziu

Adapter má statickú 8-bajtovú odpoveď cez 2×32-bit slová:

```systemverilog
CAPS_WORD0 = { proto_major, proto_minor, num_axil_slots, num_stream_slots }
CAPS_WORD1 = { max_stream_hi, max_stream_lo, stream_align, caps_flags }
```

To je dobré pre `xfcp_test_08_caps`. Netreba hneď robiť plnú target tabuľku.

---

## 1.3 Fabric endpoint má A-light rozšírenie pre CAPS

`xfcp_fabric_endpoint.sv` už má tretí backend popri AXIL a AXIS:

```text
AXIL: op 0x10/0x11
AXIS: op 0x20/0x21
CAPS: op 0x01
```

Rozšírenie je v súlade s naším plánom:

```text
order_entry_t má is_caps
caps_done_cnt_q analogicky k axis_done_cnt_q
rdata mux vie vybrať caps_rdata
packetizer vie poslať RESP_GET_CAPS payload
```

To je dobrý smer, hoci do budúcna už bude vhodné vytiahnuť routing do samostatného routera.

---

## 1.4 Simulácia je výborná

Sim log končí:

```text
ALL PASSED (0 failures)
```

Status uvádza:

```text
T01–T25 ALL PASS
```

Dôležité nové testy:

```text
T23 GET_CAPS cez UART
T24 GET_CAPS cez ETH-UDP
T25 GET_CAPS + AXIL READ interleaved
```

Toto je presne testovacia sada, ktorú sme potrebovali. T25 je obzvlášť dobrý, lebo overuje, že nový `is_caps` routing nerozbil in-order odpovede.

---

## 1.5 Timing je čistý

Aktuálny STA:

```text
Slow 85C CLK125 setup:   +0.355 ns
Slow 85C ETH_RXC setup:  +0.575 ns
Slow 85C CLK125 hold:    +0.427 ns
Fast 0C CLK125 setup:    +2.981 ns
TNS:                     0.000
```

Resource usage:

```text
Logic elements: 26,258 / 55,856  (47 %)
Registers:      20,617
Memory bits:    44,544           (2 %)
PLLs:           1 / 4
```

CAPS vrstva teda nepriniesla problém v timing ani zdrojoch.

---

# 2. Čo nie je v súlade s názvom `hw-test`

Tu je hlavný nesúlad.

Status dokument hovorí:

```text
Faza C — HW test [PLANOVANA]
```

a checklist obsahuje:

```text
Python tools: GET_CAPS cez UART + UDP overenie
AXIL READ/WRITE cez UART + UDP
STREAM loopback cez UART + UDP
DIAG snapshot
```

Ale `Makefile` má:

```makefile
hw-test: arp-setup
	arping ...
	ping ...
```

Teda aktuálny `make hw-test` nie je „full HW test“. Je to iba:

```text
ARP + ICMP link sanity test
```

Preto by som aktuálny HW stav zapísal takto:

```text
HW link sanity: PASS
HW XFCP regression: ešte neoverené v tomto archíve
```

---

# 3. Najväčší praktický problém

V archíve je adresár:

```text
tools/xfcp/
```

ale je prázdny. Nenašiel som Python súbory typu:

```text
tools/xfcp/protocol.py
tools/xfcp/bus.py
tools/test_hw.py
```

To znamená, že `xfcp_test_08_caps` zatiaľ nemá priložený HW klient, ktorý by reálne vedel poslať:

```text
GET_CAPS cez UART
GET_CAPS cez UDP
AXIL READ/WRITE
STREAM WRITE/READ
DIAG snapshot
```

Simulácia to overuje, ale HW regression infra pre tento example ešte nie je prenesená z `xfcp_test_07_axis`.

---

# 4. Čo treba doplniť hneď

## 4.1 Preniesť Python nástroje z `xfcp_test_07_axis`

Do `tools/xfcp/` doplniť minimálne:

```text
protocol.py
bus.py
transport_uart.py
transport_udp.py
errors.py
```

a top-level test:

```text
tools/test_hw.py
```

alebo jednoduchšie:

```text
tools/test_caps_hw.py
```

---

## 4.2 Pridať `get_caps()` do Python bus API

Signatúra:

```python
def get_caps(self) -> dict:
    ...
```

Očakávaná odpoveď:

```text
op      = RESP_GET_CAPS, 0x02
status  = OK
payload = 8 bytes
```

Dekódovanie:

```python
caps = {
    "proto_major": payload[0],
    "proto_minor": payload[1],
    "num_axil_slots": payload[2],
    "num_stream_slots": payload[3],
    "max_stream_bytes": (payload[4] << 8) | payload[5],
    "stream_align": payload[6],
    "caps_flags": payload[7],
}
```

Očakávané hodnoty:

```text
proto_major       1
proto_minor       1
num_axil_slots    7
num_stream_slots  1
max_stream_bytes  256
stream_align      4
caps_flags        0x07
```

---

## 4.3 Rozšíriť Makefile

Navrhujem rozdeliť testy:

```makefile
hw-link-test:
	$(MAKE) arp-setup
	arping -I $(PC_IFACE) -c 4 $(FPGA_IP)
	ping -I $(PC_IFACE) -c 4 $(FPGA_IP)

test-uart:
	cd tools && python3 test_hw.py --uart $(UART_PORT) --baud $(UART_BAUD) --caps --rw --stream --diag --repeat $(TEST_REPEAT)

test-udp:
	cd tools && python3 test_hw.py --udp $(FPGA_IP) --port $(XFCP_UDP_PORT) --caps --rw --stream --diag --repeat $(TEST_REPEAT)

hw-regression: hw-link-test test-uart test-udp

hw-test: hw-regression
```

Alebo ak chceš zachovať `hw-test` ako rýchly test, premenuj súčasný na:

```text
hw-link-test
```

a plný test nech je:

```text
hw-regression
```

Teraz názov „full“ zavádza.

---

# 5. Drobné návrhové poznámky

## 5.1 `GET_CAPS` count validácia

Aktuálny parser povoľuje `GET_CAPS` opcode. Treba ešte výslovne garantovať:

```text
GET_CAPS musí mať count == 0
```

V sim to asi testujete validným paketom. Do budúcna by som pridal error test:

```text
GET_CAPS count != 0 -> BAD_LENGTH
```

Teraz to nie je blocker, ale patrí do robustného protokolu.

---

## 5.2 `xfcp_resp_for_op()` default

V `xfcp_pkg.sv` je:

```systemverilog
default: return XFCP_OP_RESP_WRITE;
```

Pre debug je to trochu nešťastné. Pri neznámom opcode by bolo čistejšie mať buď:

```systemverilog
XFCP_OP_RESP_ERROR
```

alebo defaultovať na `RESP_GET_CAPS`/`RESP_WRITE` len tam, kde sa tá funkcia nikdy nevolá s invalid op.

Nie je to urgentné, ale pre knižnicu by som časom pridal explicitný:

```text
XFCP_OP_RESP_ERROR = 0x7F
```

---

## 5.3 Status dokument je treba aktualizovať po tvojom link teste

Do `XFCP_TEST_08_CAPS_STATUS.md` by som doplnil:

```text
Faza C — HW link sanity [PASS]
  ARP 4/4 PASS
  ICMP 4/4 PASS

Faza D — HW XFCP regression [ČAKÁ]
  GET_CAPS UART/UDP
  AXIL UART/UDP
  STREAM UART/UDP
  DIAG
```

Lebo teraz Fáza C v statuse čaká, ale časť ARP/ICMP už prešla.

---

# 6. Klasifikácia aktuálneho stavu

```text
xfcp_test_08_caps:
  architektúra:      správna
  sim verifikácia:   veľmi dobrá, T01–T25 PASS
  timing:            PASS
  HW link:           PASS
  HW XFCP/caps:      zatiaľ nedoložené
```

Čiže ešte by som netagoval ako:

```text
xfcp_lib_v1_2_caps_pass
```

Skôr:

```text
xfcp_test_08_caps_sim_timing_pass
```

alebo:

```text
xfcp_lib_v1_2_caps_rc0
```

Po doplnení Python HW regression a úspechu cez UART + UDP by som tagoval:

```text
xfcp_lib_v1_2_caps_pass
```

---

# 7. Odporúčaný ďalší postup

Presne v tomto poradí:

```text
1. Premenovať aktuálny hw-test na hw-link-test alebo ho rozšíriť.
2. Preniesť/doplniť Python XFCP nástroje.
3. Implementovať bus.get_caps().
4. Pridať HW test:
     UART GET_CAPS
     UDP GET_CAPS
     AXIL READ/WRITE
     STREAM 4/64/256
     DIAG clean
5. Spustiť:
     make hw-regression
6. Aktualizovať status.
7. Tagovať xfcp_lib_v1_2_caps_pass.
```

Potom bude `xfcp_test_08_caps` splnený ako caps/discovery míľnik.

---

## Záver

Projekt ide správnym smerom. `GET_CAPS` vrstva je navrhnutá dobre, simulácia aj timing sú čisté. Tvoj aktuálny `make hw-test` však zatiaľ overil iba ARP/ICMP, nie XFCP samotné.

Najbližší konkrétny cieľ:

```text
doplniť plnú HW regresiu pre GET_CAPS cez UART aj UDP.
```

Keď tá prejde spolu s AXIL/STREAM/DIAG testami, `xfcp_test_08_caps` môžeme považovať za uzavretý míľnik a ďalší krok môže byť `xfcp_test_09_axifull`.
