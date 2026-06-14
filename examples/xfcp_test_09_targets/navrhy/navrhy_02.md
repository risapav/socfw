Skontroloval som aktuálny `xfcp_test_08_caps(1).zip`.

```text
xfcp_test_08_caps(1).zip
SHA-256: 7ba457306012a00a2ea9d6315386fa590aa9093b8892e0f409af0c5210f41c87
```

## Verdikt

`xfcp_test_08_caps` je teraz **uzavretý míľnik**.

Máme splnené:

```text
Sim:        T01–T25 ALL PASS
Timing:     PASS, CLK125 WNS +0.355 ns
HW UART:    41/41 PASS
HW UDP:     41/41 PASS
DIAG:       bez chýb
Tag:        xfcp_lib_v1_2_caps_pass
```

Toto je presne stav, ktorý sme chceli pred ďalším väčším backendom. `GET_CAPS` už nie je iba simulovaný, ale reálne overený cez UART aj UDP.

---

# Čo je teraz hotové

Aktuálne máš stabilnú XFCP knižničnú líniu:

```text
xfcp_lib_v0_9_status_pass:
  UART + UDP + AXI-Lite + STATUS

xfcp_lib_v1_1_axis_pass:
  STREAM_WRITE / STREAM_READ
  AXI-Stream loopback
  256B stream cez UART aj UDP

xfcp_lib_v1_2_caps_pass:
  GET_CAPS
  capability flags
  max_stream_bytes
  axil/stream discovery
  HW UART + UDP regression PASS
```

`GET_CAPS` odpoveď je:

```text
proto_major       = 1
proto_minor       = 1
num_axil_slots    = 7
num_stream_slots  = 1
max_stream_bytes  = 256
stream_align      = 4
caps_flags        = 0x07  // HAS_AXIL | HAS_STREAM | HAS_CAPS
```

To znamená, že host už vie automaticky zistiť základné schopnosti FPGA dizajnu.

---

# Čo je dôležité z architektúry

`xfcp_test_08_caps` pridalo tretí backend do `xfcp_fabric_endpoint`:

```text
AXIL backend:
  READ / WRITE

AXIS backend:
  STREAM_WRITE / STREAM_READ

CAPS backend:
  GET_CAPS
```

To je stále v našej A-light architektúre. Funguje to, ale endpoint sa tým začína napĺňať:

```text
is_axis
is_caps
AXIL routing
AXIS routing
CAPS routing
order FIFO
response arbitration
packetizer mux
```

Pre ďalší veľký backend, najmä AXI-Full, by som už nedával ďalšiu vetvu priamo do endpointu bez rozmyslu. Ešte jeden backend by sa dal pridať, ale začína byť čas pripraviť čistejšiu vnútornú vrstvu.

---

# Čo ideme robiť ďalej

Máme dve rozumné možnosti. Moja odporúčaná cesta je **najprv krátky architektonický refaktor/specifikácia, potom AXI-Full**.

## Odporúčaný ďalší míľnik: `xfcp_test_09_target_table`

Pred AXI-Full by som spravil malý, ale veľmi dôležitý krok:

```text
GET_TARGET_TABLE alebo GET_TARGET_INFO
```

Prečo? Lebo `GET_CAPS` povie iba:

```text
mám 7 AXIL slotov
mám 1 stream slot
max stream je 256 B
```

Ale nepovie:

```text
aké sú tie sloty
aké majú base adresy
aké majú mená
aký majú typ
aké majú limity
či je slot AXIL / STREAM / budúci MEM
```

Pre AXI-Full a CPU bude toto veľmi užitočné.

---

## Návrh `GET_TARGET_TABLE`

Nový opcode:

```systemverilog
XFCP_OP_GET_TARGETS      = 8'h03;
XFCP_OP_RESP_GET_TARGETS = 8'h04;
```

Alebo jednoduchšie pre prvú verziu:

```systemverilog
XFCP_OP_GET_TARGET_INFO      = 8'h03;
XFCP_OP_RESP_GET_TARGET_INFO = 8'h04;
```

A request by používal `addr[7:0]` ako index targetu.

Príklad:

```text
GET_TARGET_INFO index=0 -> SYSC
GET_TARGET_INFO index=1 -> UART
GET_TARGET_INFO index=2 -> OUT_/LED
...
GET_TARGET_INFO index=7 -> STREAM0
```

Response payload napríklad 16 B:

```text
byte 0      target_type
byte 1      target_id
byte 2      flags
byte 3      reserved
byte 4..7   base_addr
byte 8..9   max_transfer
byte 10     align
byte 11     name_len alebo version
byte 12..15 4-char name
```

Typy:

```text
0x01 = AXIL
0x02 = STREAM
0x03 = AXI_FULL / MEM
0x04 = CPU_MAILBOX
```

Pre aktuálny projekt by tabuľka vrátila:

```text
0: AXIL   SYSC  base 0xFF000000
1: AXIL   UART  base 0xFF010000
2: AXIL   OUT_  base 0xFF020000
3: AXIL   OUT_  base 0xFF030000
4: AXIL   OUT_  base 0xFF040000
5: AXIL   SEG7  base 0xFF050000
6: AXIL   DIAG  base 0xFF060000
7: STREAM STR0  id 0, max 256, align 4
```

Toto by výrazne zlepšilo Python nástroje:

```bash
xfcp targets
xfcp read SYSC.ID
xfcp stream-write STR0 file.bin
```

---

# Alternatíva: ísť rovno na `xfcp_test_09_axifull`

Dá sa ísť aj priamo na AXI-Full. Ale potom budeš musieť hardcodovať v Pythone:

```text
existuje memory target
base address
max transfer
alignment
burst size
```

Preto by som radšej spravil target discovery predtým.

---

# Môj konkrétny návrh poradia

## Krok 1 — uzavrieť `xfcp_test_08_caps`

Už len administratíva:

```text
1. Commit aktuálny stav.
2. Tag:
   xfcp_lib_v1_2_caps_pass
3. Status už má dobrý obsah — len over, že obsahuje aj posledné dva HW regression runy.
4. Nechať túto vetvu stabilnú.
```

---

## Krok 2 — nový projekt `xfcp_test_09_targets`

Cieľ:

```text
GET_TARGET_INFO / GET_TARGET_TABLE
```

Nie AXI-Full ešte.

Minimálny rozsah:

```text
- nový opcode 0x03 / 0x04
- nový xfcp_target_info_adapter.sv
- statická tabuľka 8 targetov
- Python bus.get_target_info(index)
- Python bus.list_targets()
- sim testy cez UART aj UDP
- HW regression cez UART aj UDP
```

Testy:

```text
T26 GET_TARGET_INFO index 0 -> SYSC
T27 GET_TARGET_INFO index 6 -> DIAG
T28 GET_TARGET_INFO index 7 -> STREAM0
T29 GET_TARGET_INFO invalid index -> UNSUPPORTED alebo BAD_ADDRESS
T30 GET_CAPS + GET_TARGET_INFO + AXIL READ order check
```

HW test:

```text
UART:
  GET_CAPS
  GET_TARGET_INFO all
  AXIL R/W
  STREAM loopback
  DIAG clean

UDP:
  rovnaké
```

---

## Krok 3 — až potom `xfcp_test_10_axifull`

Po target discovery bude AXI-Full oveľa čistejší.

AXI-Full opcodes:

```systemverilog
XFCP_OP_MEM_READ       = 8'h30;
XFCP_OP_MEM_WRITE      = 8'h31;
XFCP_OP_RESP_MEM_READ  = 8'h32;
XFCP_OP_RESP_MEM_WRITE = 8'h33;
```

Prvý AXI-Full rozsah:

```text
single outstanding
aligned transfers
max 256 B alebo 512 B
burst INCR
AXI OKAY / SLVERR / DECERR -> XFCP STATUS
timeout watchdog
Python mem_read/mem_write
```

Ale toto by som nezačínal, kým nemáme aspoň jednoduchý target info mechanizmus.

---

# Prečo nie hneď CPU

CPU mailbox/debug by som dal až po AXI-Full.

Poradie podľa závislostí:

```text
1. STATUS
2. AXIS
3. CAPS
4. TARGET TABLE
5. AXI-Full memory
6. CPU mailbox
7. CPU debug/halt/step
```

CPU potrebuje discovery aj memory/register mechaniku, inak sa začne robiť príliš veľa naraz.

---

# Krátke hodnotenie aktuálneho stavu

```text
Funkčný stav:          výborný
Timing:                čistý
HW overenie:           čisté cez UART aj UDP
Knižničný smer:        správny
Ďalší arch. problém:   endpoint routing sa začína rozrastať
Najbližší krok:        target discovery
```

---

## Záver

`xfcp_test_08_caps` by som považoval za hotový a tagovaný míľnik.

Ďalej by som nerobil AXI-Full hneď. Najprv by som spravil:

```text
xfcp_test_09_targets
```

s jednoduchým `GET_TARGET_INFO`, aby host vedel objaviť konkrétne AXIL/STREAM/neskôr MEM/CPU targety.

Potom pôjdeme na:

```text
xfcp_test_10_axifull
```

Tým udržíme vývoj čistý: najprv discovery vrstva, potom nový dátový backend.
