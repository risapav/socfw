Skontroloval som aktuálny `xfcp_test_09_targets(2).zip`.

```text
xfcp_test_09_targets(2).zip
SHA-256: 1f1fe9cdefb62c4e16af5624dfd7f99d03a897962326c4ffef46f0171589d240
```

## Verdikt

Tento stav už môžeme považovať za **uzavretý míľnik `xfcp_test_09_targets`**.

Oproti predchádzajúcemu snapshotu sa vyriešil posledný blocker: timing. Pôvodne bol stav funkčne dobrý, ale s `CLK125 WNS -0.150 ns`. Teraz je po seed sweep-e použitý `SEED 12` a STA je čisté:

```text
Slow 85C CLK125 WNS:   +0.237 ns
Slow 85C ETH_RXC WNS:  +0.843 ns
TNS:                   0.000 ns
SEED:                  12
Fmax CLK125:           128.82 MHz
```

A zároveň sú potvrdené:

```text
Sim:       ALL PASSED, 142 checks, 0 failures
HW UART:   66/66 PASS
HW UDP:    66/66 PASS
DIAG:      bez chýb
Tag:       xfcp_lib_v1_3_targets_pass
```

Čiže teraz máme splnené všetky kritériá: **sim + timing + HW UART/UDP + čisté DIAG**.

---

# Čo je teraz hotové

Aktuálna línia XFCP je veľmi slušne vystavaná:

```text
v0.9 STATUS:
  UART + UDP + AXI-Lite + STATUS

v1.1 AXIS:
  STREAM_WRITE / STREAM_READ
  AXI-Stream loopback
  256B payload cez UART aj UDP

v1.2 CAPS:
  GET_CAPS
  proto/caps discovery

v1.3 TARGETS:
  GET_TARGET_INFO
  target discovery tabuľka
```

`GET_TARGET_INFO` teraz v hardvéri overuje:

```text
0: AXIL   SYSC  0xFF000000  max 128B  align 4
1: AXIL   UART  0xFF010000  max 128B  align 4
2: AXIL   OUT_  0xFF020000  max 128B  align 4
3: AXIL   OUT_  0xFF030000  max 128B  align 4
4: AXIL   OUT_  0xFF040000  max 128B  align 4
5: AXIL   SEG7  0xFF050000  max 128B  align 4
6: AXIL   DIAG  0xFF060000  max 128B  align 4
7: STREAM STR0  0x00000000  max 256B  align 4
8+: BAD_ADDRESS
```

`GET_CAPS` je tiež posunutý:

```text
proto=1.2
caps_flags=0x0F
HAS_AXIL | HAS_STREAM | HAS_CAPS | HAS_TARGETS
```

Toto je presne základ, ktorý potrebujeme pred AXI-Full.

---

# Resource stav

Použitie zdrojov je stále bezpečné:

```text
Logic elements: 26,330 / 55,856  (47 %)
Registers:      20,686
Memory bits:    44,544 / 2,396,160  (2 %)
Pins:           66 / 325  (20 %)
PLLs:           1 / 4
```

Čiže ani po CAPS + TARGETS nie sme blízko limitu čipu. Pre ďalší backend máme dosť priestoru.

---

# Čo je ešte vhodné upratať

Nie je to blocker pre tag, ale pred ďalšou väčšou vetvou by som si poznačil warningy:

```text
1. ASYNC_REG atribút Quartus ignoruje.
2. xfcp_out.TKEEP/TUSER/TID/TDEST sú bez drivera.
3. xfcp_rx_parser má nepoužité dec_addr/dec_opcode_ok/dec_count_ok.
4. xfcp_axi_engine má case warning pri BRESP/RRESP.
5. ALTDDIO input packing warningy na ETH RX ceste pretrvávajú.
```

Tieto warningy nebránia funkcii ani timingu, ale ak sa z toho má stať knižničný základ, postupne by som ich vyčistil. Najľahšie rýchle upratanie je doplniť default assigny pre AXIS sideband signály:

```systemverilog
assign xfcp_out.TKEEP = '1;
assign xfcp_out.TUSER = '0;
assign xfcp_out.TID   = '0;
assign xfcp_out.TDEST = '0;
```

A `dec_*` signály v parseri buď zapojiť do error path, alebo odstrániť.

---

# Čo ďalej?

Teraz už **môžeme ísť na ďalší backend**. Najlogickejší ďalší projekt:

```text
xfcp_test_10_axifull
```

Cieľ: pridať pamäťový/MEM backend cez AXI-Full alebo minimálne AXI-like memory window.

---

## Odporúčaný rozsah `xfcp_test_10_axifull`

Nerobil by som hneď plný generický AXI-Full master so všetkými možnosťami. Prvá verzia nech je konzervatívna:

```text
- single outstanding transaction
- aligned transfers
- INCR burst only
- max transfer 256 B alebo 512 B
- DATA_WIDTH 32 bit
- ADDR_WIDTH 32 bit
- AXI OKAY/SLVERR/DECERR -> XFCP STATUS
- timeout watchdog
```

Nové opcodes:

```systemverilog
XFCP_OP_MEM_READ        = 8'h30;
XFCP_OP_MEM_WRITE       = 8'h31;
XFCP_OP_RESP_MEM_READ   = 8'h32;
XFCP_OP_RESP_MEM_WRITE  = 8'h33;
```

Status mapovanie:

```text
OK              -> transfer dokončený
BAD_LENGTH      -> count=0, count%4!=0, count>MAX
BAD_ADDRESS     -> mimo povoleného memory window
AXI_SLVERR      -> RRESP/BRESP SLVERR
AXI_DECERR      -> RRESP/BRESP DECERR
TIMEOUT         -> AXI kanál sa zasekol
BUSY            -> adaptér obsadený
```

---

## Čo bude target discovery vracať po pridaní MEM

V `GET_CAPS` pribudne nový flag:

```text
HAS_MEM / HAS_AXIFULL
```

Napríklad:

```text
caps_flags = 0x1F
bit0 HAS_AXIL
bit1 HAS_STREAM
bit2 HAS_CAPS
bit3 HAS_TARGETS
bit4 HAS_MEM
```

`GET_TARGET_INFO` pribudne nový index:

```text
8: MEM   MEM0  base 0x00000000  max 256B/512B  align 4
```

Typ:

```text
target_type = 0x03  // MEM / AXI_FULL
```

Tým sa krásne využije práca z `xfcp_test_09_targets`.

---

# Dôležitá architektonická poznámka

`xfcp_fabric_endpoint` už má viac vetiev:

```text
AXIL
AXIS
CAPS
TARGET_INFO
```

Pre `MEM/AXI-Full` sa ešte dá pokračovať A-light prístupom, ale toto je posledný moment, kde by som to dovolil bez refaktoru. Pri MEM backende si už daj pozor, aby si do endpointu nepridal priveľa špecifickej logiky.

Odporúčanie:

```text
xfcp_fabric_endpoint iba rozhodne:
  opcode class -> backend

xfcp_mem_adapter rieši:
  MEM_READ/MEM_WRITE FSM
  AXI-Full kanály
  bursty
  response payload
  status
```

Teda rovnaký štýl ako `xfcp_axis_adapter` a `xfcp_target_info_adapter`.

---

# Pred začatím `xfcp_test_10_axifull`

Spravil by som ešte jednu krátku stabilizačnú vec:

```text
1. Commit/tag aktuálny stav:
   xfcp_lib_v1_3_targets_pass

2. Uložiť HW log a timing summary do statusu.

3. Vytvoriť nový projekt kopírovaním z xfcp_test_09_targets:
   xfcp_test_10_axifull

4. Až tam pridávať MEM/AXI-Full.
```

Do aktuálnej vetvy by som už nepridával ďalšie feature.

---

## Moja odpoveď na „čo ďalej“

Áno, teraz ideme ďalej na:

```text
xfcp_test_10_axifull
```

Ale s úzkym cieľom:

```text
prvý MEM backend nad XFCP:
  MEM_READ / MEM_WRITE
  single outstanding AXI-Full
  aligned 32-bit transfers
  max 256B alebo 512B
  STATUS-aware error handling
  target discovery cez GET_TARGET_INFO
```

Toto je prirodzený ďalší krok po `GET_TARGET_INFO`. Potom až po ňom by dával zmysel CPU mailbox, lebo CPU bude tiež potrebovať target discovery a pamäťové/register prístupy.
