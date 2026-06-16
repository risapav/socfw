Skontroloval som aktuálny `xfcp_test_10_axifull.zip`.

```text
xfcp_test_10_axifull.zip
SHA-256: 377e3b7eb30e3519c3f9edc4da4b75920189c6ca4694610b49a9c8355562e179
```

## Verdikt

Progres je **veľký a správnym smerom**: `MEM_READ/MEM_WRITE` backend je RTLovo implementovaný a simulácia prešla. Ale projekt ešte **nie je uzavretý míľnik**, lebo:

```text
Sim:       PASS, T01–T37
Build cfg: OK, už smeruje na xfcp_test_10_axifull_top
Timing:    FAIL, CLK125 WNS -2.101 ns
HW:        zatiaľ nie je MEM regresia
Python:    MEM opcodes/tools ešte nie sú doplnené
```

Čiže aktuálny stav by som označil ako:

```text
xfcp_test_10_axifull_sim_pass_timing_open
```

Nie ešte ako `xfcp_lib_v1_4_mem_pass`.

---

# Čo je hotové dobre

## 1. Projekt je už správne preklopený na test 10

Toto je oproti predchádzajúcemu `xfcp_test_09_targets` problému v poriadku.

`project.yaml` už instancuje:

```yaml
- instance: xfcp_test_10_axifull_top
  type: xfcp_test_10_axifull_top
```

IP YAML je tiež správne:

```yaml
ip:
  name: xfcp_test_10_axifull_top
  module: xfcp_test_10_axifull_top
```

A `build/hal/files.tcl` obsahuje:

```text
rtl/xfcp/xfcp_mem_adapter.sv
rtl/axifull_sram.sv
rtl/xfcp_test_10_axifull_top.sv
```

Čiže integračná chyba typu „sim testuje nový top, Quartus starý top“ tu už nie je.

---

## 2. MEM opcodes sú v RTL

V `xfcp_pkg.sv` sú doplnené:

```systemverilog
XFCP_OP_MEM_READ       = 8'h30;
XFCP_OP_MEM_WRITE      = 8'h31;
XFCP_OP_RESP_MEM_READ  = 8'h32;
XFCP_OP_RESP_MEM_WRITE = 8'h33;
```

A `xfcp_fabric_endpoint.sv` už má MEM vetvu:

```text
AXIL
AXIS
CAPS
TARGET_INFO
MEM
```

Toto sedí s naším plánom.

---

## 3. `xfcp_mem_adapter.sv` existuje a simulačne funguje

Status hovorí:

```text
MEM_READ  -> AXI AR + R burst
MEM_WRITE -> AXI AW + W burst
MAX_BYTES = 256
DATA_WIDTH = 32
single outstanding
timeout watchdog
```

A sim log končí:

```text
ALL PASSED (0 failures)
```

T37 dokonca overuje:

```text
MEM_WRITE + AXIL READ interleaved
```

To je dobrý regression test, lebo MEM backend už je ďalší zdroj odpovedí v order/response routing systéme.

---

## 4. Opravy v sim fáze boli správne

Status dokument uvádza 4 reálne bugy, a všetky dávajú zmysel:

```text
Bug 1: arbiter nepovažoval MEM_WRITE za write-like packet
Bug 2: MEM_WRITE wdata tiekla aj do AXIL write bufferu
Bug 3: rfifo deadlock pri burst > 2 beaty
Bug 4: timeout bežal aj pri čakaní na UART payload
```

Toto sú presne typy chýb, ktoré by sa pri MEM backende dali čakať. Dobré je, že ich testbench zachytil ešte pred HW.

---

# Hlavný problém: timing

Aktuálny STA:

```text
Slow 85C CLK125 setup:
  WNS = -2.101 ns
  TNS = -471.034 ns

Slow 0C CLK125 setup:
  WNS = -1.659 ns
  TNS = -105.091 ns

ETH_RXC:
  PASS
```

Najhoršia cesta je v `axifull_sram`:

```text
From:
  axifull_sram.u_sram.rd_addr_q[*]

To:
  axifull_sram.u_sram.rd_data_q[*]

Slack:
  -2.101 ns
```

Interpretácia:

```text
rd_addr_q
  -> veľký kombinačný read mux SRAM poľa
  -> rd_data_q
```

Čiže problém nie je primárne `xfcp_mem_adapter`, parser alebo fabric endpoint. Problém je v tom, že testovací `axifull_sram` je pravdepodobne implementovaný ako veľké pole registrov s kombinačným čítaním, ktoré Quartus namapoval cez LUT muxy. To je veľmi podobný problém ako pri starom fall-through FIFO.

Resource narástol výrazne:

```text
Logic elements: 36,773 / 55,856  (66 %)
Registers:      29,201
Memory bits:    46,592
```

Oproti `xfcp_test_09_targets` to je veľký skok. To naznačuje, že SRAM nie je mapovaná efektívne do RAM blokov, ale veľmi pravdepodobne do logiky/registerov.

---

# Najbližší fix: opraviť `axifull_sram`

Toto by som riešil pred všetkým ostatným.

## Cieľ

Zmeniť testovací AXI-Full SRAM tak, aby read path nebola:

```text
rd_addr_q -> veľký async mux -> rd_data_q
```

ale:

```text
rd_addr_q -> synchronná RAM -> rd_data_q o 1 cyklus neskôr
```

Inými slovami: **registrovaný synchronous read memory**.

---

## Odporúčané riešenie

V `axifull_sram.sv` použiť RAM štýl vhodný pre Intel/Quartus.

Napríklad:

```systemverilog
(* ramstyle = "M9K" *) logic [31:0] mem [0:DEPTH-1];

always_ff @(posedge clk) begin
  if (wr_en) begin
    mem[wr_addr] <= wr_data;
  end

  rd_data_q <= mem[rd_addr_q];
end
```

Dôležité je, aby `mem[rd_addr]` bolo čítané v clocked bloku, nie cez kombinatorický `assign`.

Ak teraz máš niečo ako:

```systemverilog
rd_data_q <= mem[rd_addr_q];
```

ale stále to mapuje do logiky, problém môže byť v tom, že máš príliš veľa resetovaných registrov, neštandardné čítanie, alebo paralelné/viacportové prístupy. Potom treba RAM štruktúru zjednodušiť.

Pre testovací MEM backend by som spravil čo najjednoduchšie:

```text
1 write port
1 read port
synchronous read
no reset memory contents
no clear loop
no async read
```

---

## Ak chceš najrýchlejší timing fix

Zníž `axifull_sram` depth pre prvý HW test.

Aktuálne status hovorí:

```text
axifull_sram: 256x32b = 1 KiB
```

To by nemalo byť veľa, ale ak je zle mapovaná do logiky, vie to bolieť.

Dočasne môžeš dať:

```text
DEPTH = 64 words = 256 B
```

Tým sa mux zmenší. Ale lepšie je opraviť RAM inference.

---

# Druhý problém: Python MEM tools ešte nie sú hotové

V `tools/xfcp/protocol.py` vidím opcodes iba do target/caps/stream. MEM opcodes tam chýbajú.

Chýbajú teda:

```python
OP_MEM_READ = 0x30
OP_MEM_WRITE = 0x31
OP_RESP_MEM_READ = 0x32
OP_RESP_MEM_WRITE = 0x33

encode_mem_read()
encode_mem_write()
decode_mem_read_response()
decode_mem_write_response()
resp_len_mem_read()
resp_len_mem_write()
```

V `tools/xfcp/bus.py` chýba:

```python
mem_read(addr, count)
mem_write(addr, data)
```

A `tools/test_hw.py` zatiaľ netestuje MEM; stále je to prakticky test z `xfcp_test_09_targets`.

Makefile tiež spúšťa:

```text
--caps --targets --rw --stream --diag
```

ale nie:

```text
--mem
```

Čiže HW regresia pre MEM zatiaľ nie je pripravená.

---

# Tretí problém: `hw-test` stále len ARP/ICMP

Rovnako ako predtým, `hw-test` je stále iba link sanity:

```makefile
hw-test:
  arping
  ping
```

Skutočná regresia je `hw-regression`, ale aj tá zatiaľ neobsahuje MEM test.

Pre test 10 by malo byť:

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

# Súlad s roadmap

Stav voči roadmap:

```text
v1.3 targets:  uzavreté
v1.4 MEM:      RTL + sim PASS
               timing FAIL
               Python/HW TODO
```

Teda progres je dobrý, ale sme v strede míľnika.

---

# Čo robiť ďalej

## Krok 1 — nechať funkcie tak, riešiť timing SRAM

Najbližší krok nie je Python ani HW. Najprv treba dostať compile do timing PASS.

Presný cieľ:

```text
axifull_sram read path timing clean
CLK125 WNS >= 0
TNS = 0
```

Odporúčanie:

```text
1. Upraviť axifull_sram na jednoznačný synchronous RAM style.
2. Skontrolovať, či Quartus mapuje pamäť do RAM, nie do 8000+ registrov/LUT muxu.
3. Rerun compile.
```

Ak sa resource usage výrazne zníži, si na dobrej ceste.

---

## Krok 2 — až potom Python MEM tools

Po timing PASS doplniť:

```text
tools/xfcp/protocol.py:
  MEM opcodes + encode/decode

tools/xfcp/bus.py:
  mem_read()
  mem_write()

tools/test_hw.py:
  --mem
```

MEM testy:

```text
MEM_WRITE 4B -> MEM_READ 4B
MEM_WRITE 16B -> MEM_READ 16B
MEM_WRITE 64B -> MEM_READ 64B
MEM_WRITE 256B -> MEM_READ 256B
boundary test pri addr 0x300 alebo podľa SRAM okna
bad length count=0 / count%4 != 0
bad address mimo 1 KiB window
```

---

## Krok 3 — HW regresia

Po Python MEM podpore:

```bash
make program
make hw-regression
```

Cieľ:

```text
UART: PASS vrátane MEM
UDP:  PASS vrátane MEM
DIAG: bez chýb
```

---

# Čo zatiaľ nerobiť

Zatiaľ neriešiť:

```text
CPU mailbox
AXI-Full multi-outstanding
unaligned MEM transfery
MEM transfery >256 B
cache/DMA režim
GET_TARGET_TABLE rozširovanie nad rámec MEM0
```

Najprv musí byť `MEM0` jednoduchý a čistý.

---

# Moje odporúčané poradie

```text
1. Fix axifull_sram RAM inference / timing.
2. Rerun sim T01–T37, aby sa nič nerozbilo.
3. Rerun Quartus, cieľ WNS >= 0.
4. Doplniť Python MEM protocol/bus/test_hw.
5. Spustiť HW UART + UDP MEM regresiu.
6. Až potom tagovať:
   xfcp_lib_v1_4_mem_pass
```

---

## Záver

Progres je výborný na úrovni architektúry:

```text
MEM backend existuje
AXI-Full SRAM existuje
sim T01–T37 PASS
bugs v MEM_WRITE/MEM_READ zachytené a opravené
```

Ale aktuálny blocker je jasný:

```text
axifull_sram timing FAIL:
rd_addr_q -> rd_data_q
WNS -2.101 ns
```

Najbližšie teda neriešime nové funkcie. Najbližšie opravujeme **testovací AXI-Full SRAM tak, aby bol skutočne synchronný RAM blok a timing-clean**. Potom doplníme Python `mem_read/mem_write` a spustíme HW regresiu.
