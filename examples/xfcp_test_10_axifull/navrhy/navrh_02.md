Skontroloval som aktuálny `xfcp_test_10_axifull(1).zip`.

```text
xfcp_test_10_axifull(1).zip
SHA-256: 24913d4b2d242100b2c687cc9720078d2f5195e87030c47b5a2ec07c3d5a1532
```

## Verdikt

Toto je výrazný progres. Posledný veľký technický blocker — timing v `axifull_sram` — je vyriešený.

Aktuálny stav:

```text
Sim:       PASS, T01–T37
Timing:    PASS, CLK125 WNS +0.327 ns
ETH_RXC:   PASS, WNS +0.870 ns
HW MEM:    ešte čaká
Python:    MEM nástroje ešte čakajú
```

Čiže projekt je teraz v stave:

```text
xfcp_test_10_axifull = RTL + sim + timing PASS, HW MEM regression pending
```

Nie je ešte finálny `xfcp_lib_v1_4_mem_pass`, ale už sme cez najťažšiu FPGA časť.

---

# Čo sa zlepšilo oproti minulému stavu

Predtým:

```text
CLK125 WNS = -2.101 ns
Fmax ≈ 99 MHz
kritická cesta: axifull_sram rd_addr_q -> rd_data_q
```

Teraz:

```text
CLK125 WNS = +0.327 ns
Fmax CLK125 = 130.33 MHz
TNS = 0.000
SEED = 10
```

To je veľmi dobré. SRAM timing fix zabral.

---

# 1. `axifull_sram` fix je správny

Status dokument popisuje root cause veľmi dobre:

```text
pôvodne:
  logic [31:0] mem_q [0:DEPTH-1]
  podmienené čítanie v rovnakom always_ff ako FSM
  Quartus z toho spravil LUT mux / registre

oprava:
  4 samostatné byte-lane M9K polia
  dedicated always_ff pre zápis
  dedicated always_ff pre čítanie
  bez resetu pamäťových polí
```

Výsledok:

```text
Logic cells: 48 661 -> 34 763
Fmax:        99 MHz -> 127+ MHz
```

Aktuálny resource report:

```text
Logic elements: 26,868 / 55,856  (48 %)
Registers:      20,977
Memory bits:    54,784 / 2,396,160  (2 %)
PLLs:           1 / 4
```

To je zásadne lepšie než predchádzajúci stav. MEM backend už nie je extrémne drahý v logike.

---

# 2. Timing je čistý

STA summary:

```text
Slow 85C CLK125 setup:   +0.327 ns
Slow 85C ETH_RXC setup:  +0.870 ns
Slow 85C CLK125 hold:    +0.428 ns
Slow 85C ETH_RXC hold:   +0.448 ns

Slow 0C CLK125 setup:    +0.736 ns
Fast 0C CLK125 setup:    +3.059 ns
TNS:                     0.000
```

Toto je release-kvalitný timing stav pre tento míľnik.

Kritická cesta už nie je nový MEM SRAM, ale existujúca UDP TX infraštruktúra:

```text
udp_xfcp_server resp_buf -> axis_skid_buffer
```

To znamená, že MEM timing problém je vyriešený a návrh sa vrátil do známej oblasti.

---

# 3. Simulácia je čistá

Sim log končí:

```text
ALL PASSED (0 failures)
```

Status uvádza:

```text
T01–T37 PASS
```

Nové MEM testy:

```text
T31 MEM_WRITE 4B + MEM_READ 4B
T32 MEM_WRITE 16B + MEM_READ 16B
T33 MEM_WRITE 64B + MEM_READ 64B
T34 MEM_WRITE 256B + MEM_READ 256B
T35 GET_TARGET_INFO index=8 -> MEM0
T36 GET_CAPS HAS_MEM
T37 MEM_WRITE + AXIL READ interleaved
```

Toto je dobrý rozsah. Overuje nielen samotný MEM loopback, ale aj:

```text
target discovery pre MEM0
caps flag HAS_MEM
order routing medzi MEM a AXIL
```

---

# 4. `GET_CAPS` a `GET_TARGET_INFO` sú rozšírené správne

`GET_CAPS` teraz ukazuje MEM podporu:

```text
proto_major = 1
proto_minor = 3
caps_flags  = 0x1F
```

Teda:

```text
HAS_AXIL
HAS_STREAM
HAS_CAPS
HAS_TARGETS
HAS_MEM
```

Target table pribudla:

```text
8: MEM MEM0
   type = 0x03
   base = 0x00000000
   max_transfer = 256 B
   align = 4
```

Toto je presne dôvod, prečo sme pred AXI-Full spravili `GET_TARGET_INFO`. Teraz host vie, že existuje `MEM0`, a vie jeho limity.

---

# 5. Čo ešte chýba

## 5.1 Python MEM nástroje ešte nie sú doplnené

V `tools/xfcp/protocol.py` zatiaľ chýbajú MEM opcodes:

```python
OP_MEM_READ
OP_MEM_WRITE
OP_RESP_MEM_READ
OP_RESP_MEM_WRITE
```

A chýbajú encode/decode funkcie:

```python
encode_mem_read()
encode_mem_write()
decode_mem_read_response()
decode_mem_write_response()
```

V `tools/xfcp/bus.py` chýba:

```python
mem_read(addr, count)
mem_write(addr, data)
```

V `tools/test_hw.py` chýba:

```text
--mem
```

Takže HW regression zatiaľ stále testuje len:

```text
--caps --targets --rw --stream --diag
```

nie MEM.

---

## 5.2 `Makefile` ešte nespúšťa MEM regresiu

Aktuálne:

```makefile
test-uart:
	cd tools && python3 test_hw.py \
	  --uart $(UART_PORT) --baud $(UART_BAUD) \
	  --caps --targets --rw --stream --diag --repeat $(TEST_REPEAT)

test-udp:
	cd tools && python3 test_hw.py \
	  --udp $(FPGA_IP):$(XFCP_UDP_PORT) \
	  --caps --targets --rw --stream --diag --repeat $(TEST_REPEAT)
```

Pre tento projekt má byť:

```makefile
--caps --targets --rw --stream --mem --diag
```

---

## 5.3 `hw-test` je stále iba ARP/ICMP

Nie je to chyba, ale názov je zavádzajúci. Skutočný full test by mal byť `hw-regression`.

Pre `xfcp_test_10_axifull` by som nechal:

```text
hw-link-test = ARP/ICMP
hw-regression = UART+UDP XFCP vrátane MEM
```

---

# 6. Čo robiť ďalej

Teraz už neriešiť RTL ani timing, ale doplniť host tooling a HW regresiu.

## Krok 1 — doplniť MEM opcodes do Python protokolu

Do `tools/xfcp/protocol.py`:

```python
OP_MEM_READ       = 0x30
OP_MEM_WRITE      = 0x31
OP_RESP_MEM_READ  = 0x32
OP_RESP_MEM_WRITE = 0x33
```

Response lengths:

```python
def resp_len_mem_write() -> int:
    return RESP_HEADER + RESP_TRAILER

def resp_len_mem_read(count: int) -> int:
    return RESP_HEADER + count + RESP_TRAILER
```

Encodery:

```python
def encode_mem_write(addr: int, data: bytes, seq: int = 0) -> bytes:
    return (
        bytes([SOP_REQ, OP_MEM_WRITE, seq & 0xFF])
        + struct.pack(">H", len(data))
        + struct.pack(">I", addr)
        + bytes(data)
    )

def encode_mem_read(addr: int, count: int, seq: int = 0) -> bytes:
    return (
        bytes([SOP_REQ, OP_MEM_READ, seq & 0xFF])
        + struct.pack(">H", count)
        + struct.pack(">I", addr)
    )
```

Decodery:

```python
def decode_mem_write_response(raw: bytes, expected_seq: int = None) -> None:
    ...

def decode_mem_read_response(raw: bytes, count: int, expected_seq: int = None) -> bytes:
    ...
```

---

## Krok 2 — doplniť `bus.mem_read/mem_write`

Do `tools/xfcp/bus.py`:

```python
def mem_write(self, addr: int, data: bytes) -> None:
    if len(data) == 0:
        raise ValueError("mem_write data must not be empty")
    if len(data) % 4:
        raise ValueError("mem_write length must be 4-byte aligned")
    if len(data) > 256:
        raise ValueError("mem_write length exceeds max 256B")
    ...

def mem_read(self, addr: int, count: int) -> bytes:
    if count == 0:
        raise ValueError("mem_read count must not be zero")
    if count % 4:
        raise ValueError("mem_read count must be 4-byte aligned")
    if count > 256:
        raise ValueError("mem_read count exceeds max 256B")
    ...
```

---

## Krok 3 — doplniť `--mem` do `test_hw.py`

Testy:

```text
MEM_WRITE 4B  -> MEM_READ 4B
MEM_WRITE 16B -> MEM_READ 16B
MEM_WRITE 64B -> MEM_READ 64B
MEM_WRITE 256B -> MEM_READ 256B
```

Pridať aj pár hraničných testov neskôr:

```text
bad length count=0
bad length count%4 != 0
bad address mimo 1 KiB window
```

Pre prvý HW pass stačia validné 4/16/64/256 B.

---

## Krok 4 — doplniť `--mem` do Makefile

```makefile
test-uart:
	cd tools && python3 test_hw.py \
	  --uart $(UART_PORT) --baud $(UART_BAUD) \
	  --caps --targets --rw --stream --mem --diag --repeat $(TEST_REPEAT)

test-udp:
	cd tools && python3 test_hw.py \
	  --udp $(FPGA_IP):$(XFCP_UDP_PORT) \
	  --caps --targets --rw --stream --mem --diag --repeat $(TEST_REPEAT)
```

---

## Krok 5 — HW regression

Po doplnení Pythonu:

```bash
make program
make hw-regression
```

Očakávaný cieľ:

```text
UART:
  caps PASS
  targets PASS
  axil rw PASS
  stream PASS
  mem PASS
  diag clean

UDP:
  caps PASS
  targets PASS
  axil rw PASS
  stream PASS
  mem PASS
  diag clean
```

Až potom by som tagoval:

```text
xfcp_lib_v1_4_mem_pass
```

---

# 7. Čo by som zatiaľ nerobil

Zatiaľ nie:

```text
CPU mailbox
unaligned MEM transfery
MEM >256 B
multi-outstanding AXI
AXI IDs
burst wrap/fixed
DMA/stream-to-memory
```

Aktuálny MEM backend nech zostane jednoduchý a stabilný:

```text
single outstanding
INCR bursts
aligned 32-bit
max 256 B
1 KiB SRAM test window
```

To je presne správny rozsah pre prvý AXI-Full míľnik.

---

## Záver

Tento snapshot je veľmi dobrý. RTL, sim aj timing sú teraz v stave, ktorý sme chceli:

```text
MEM backend: implementovaný
AXI-Full SRAM: M9K timing-clean
Sim: PASS
Timing: PASS
```

Posledná vec pred uzavretím míľnika je už len host/HW vrstva:

```text
Python mem_read/mem_write + make hw-regression s --mem
```

Po úspešnom UART+UDP HW teste s MEM môžeme tento projekt tagovať ako:

```text
xfcp_lib_v1_4_mem_pass
```
