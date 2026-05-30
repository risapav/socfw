Skontroloval som aktuálny `eth_test_03.zip`. Projekt je v dobrom stave ako knižnica po vrstvách, ale máš tam **dve rôzne témy**:

```text
1. Linter hlási: reference not found "eth_pkg"
2. Full echo path ešte neprechádza, hoci unit/regression testy v Makefile prechádzajú
```

## 1. Prečo linter hlási `reference not found "eth_pkg"`

`eth_pkg.sv` v ZIP-e existuje a je syntakticky v poriadku:

```systemverilog
package eth_pkg;
  ...
  typedef struct packed {
    logic [47:0] src_mac;
    logic [47:0] dst_mac;
    logic [31:0] src_ip;
    logic [31:0] dst_ip;
    logic [15:0] src_port;
    logic [15:0] dst_port;
    logic [15:0] payload_len;
  } udp_packet_meta_t;
endpackage
```

V Makefile je tiež väčšinou kompilovaný ako prvý:

```makefile
ETH_COMMON := \
	$(RTL)/eth_pkg.sv \
	$(RTL)/l2/eth_header_builder.sv
```

Preto Questa testy fungujú.

Takže problém nebude v samotnom `eth_pkg.sv`, ale v tom, že **tvoj linter pravdepodobne analyzuje jednotlivé súbory izolovane bez filelistu / compile orderu**. Súbory ako tieto používajú package-scoped typy:

```systemverilog
eth_pkg::udp_packet_meta_t
eth_pkg::eth_hdr_t
eth_pkg::ETH_BROADCAST_MAC
```

Ak linter nevidí `rtl/eth/eth_pkg.sv` pred týmito súbormi, zahlási:

```text
reference not found: eth_pkg
```

---

# 2. Správne riešenie: spoločný filelist

Urob si jeden centrálny filelist, napríklad:

```text
sim/eth_test_03.f
```

Obsah:

```text
../rtl/eth/eth_pkg.sv

../rtl/eth/mac/crc32_eth.sv
../rtl/eth/l2/eth_header_builder.sv
../rtl/eth/mac/gmii_tx_mac.sv
../rtl/eth/mac/gmii_rx_mac.sv

../rtl/eth/l2/eth_header_parser.sv
../rtl/eth/l3/ipv4_checksum.sv
../rtl/eth/l3/ipv4_header_parser.sv
../rtl/eth/l4/udp_header_parser.sv
../rtl/eth/l4/udp_rx_meta_assembler.sv
../rtl/eth/l4/udp_echo_app.sv
../rtl/eth/l4/udp_ipv4_tx_builder.sv
```

Dôležité je, že `eth_pkg.sv` musí byť prvý.

Potom používaj rovnaký filelist pre všetky nástroje:

```bash
vlog -sv -f sim/eth_test_03.f
verilator -sv --lint-only -f sim/eth_test_03.f
```

A do IDE/lintera nastav práve tento filelist.

---

# 3. Ak používaš VS Code / SV linter

Ak používaš `svls`, pridaj napríklad `.svls.toml` v koreni projektu:

```toml
[verilog]
include_paths = [
  "rtl/eth",
  "rtl/eth/mac",
  "rtl/eth/l2",
  "rtl/eth/l3",
  "rtl/eth/l4"
]

defines = []
```

Ale samotné include paths často nestačia, lebo `eth_pkg.sv` nie je includovaný, ale kompilovaný ako samostatná compilation unit. Preto je lepší filelist, ak ho tvoj linter podporuje.

Ak používaš Verible, použi:

```bash
verible-verilog-lint --file_list_path sim/eth_test_03.f
```

Ak používaš Quartus/SystemVerilog language server v editore, musíš mať `eth_pkg.sv` v project files pred modulmi, ktoré používajú `eth_pkg::`.

---

# 4. Nerob toto: `include "eth_pkg.sv"` do každého súboru

Toto by síce umlčalo niektoré jednoduché linters, ale nie je to dobré riešenie:

```systemverilog
`include "eth_pkg.sv"
```

Prečo nie:

```text
- package sa môže definovať viackrát
- rôzne nástroje sa môžu správať odlišne
- rozbiješ compile model
- neskôr to bude robiť problémy v Quartuse/Queste
```

Správny model je:

```text
eth_pkg.sv sa kompiluje raz, ako prvý
ostatné súbory používajú eth_pkg::...
```

---

# 5. Kde by som ešte pridal `import eth_pkg::*;`

Používanie `eth_pkg::typ` je formálne správne. Ale pre čitateľnosť a niektoré linters môže pomôcť pridať na začiatok modulov, ktoré intenzívne používajú package typy:

```systemverilog
import eth_pkg::*;
```

Napríklad v:

```text
udp_echo_app.sv
udp_rx_meta_assembler.sv
udp_ipv4_tx_builder.sv
eth_header_parser.sv
```

Potom môžeš písať:

```systemverilog
udp_packet_meta_t rx_meta_q;
```

namiesto:

```systemverilog
eth_pkg::udp_packet_meta_t rx_meta_q;
```

Ale pozor: aj pri `import eth_pkg::*;` musí linter stále vedieť, kde je `eth_pkg.sv`. Čiže `import` nie je náhrada filelistu, len zlepšenie čitateľnosti.

---

# 6. Aktuálny stav testov: status je čiastočne zavádzajúci

Status hovorí:

```text
11/11 testbenches ALL PASS
```

To sedí pre Makefile cieľ:

```makefile
all: crc32 gmii_tx gmii_rx mac_stream eth_hdr_builder eth_hdr_parser ipv4_checksum ipv4_hdr_parser udp_hdr_parser udp_tx_builder
```

Ale v ZIP-e je aj log:

```text
sim/logs/tb_echo_path.log
```

a ten hovorí:

```text
FAIL T1: no TX response received
T2 PASS: wrong dst_mac -> no echo
T3 PASS: wrong dst_ip -> no echo
FAIL: T4: frame1 echo payload = A1 A2 A3
FAIL: T4: frame2 echo payload = B1 B2 B3 B4
tb_echo_path: 3 FAILURES
```

Čiže presnejší stav je:

```text
Unit/layer tests: PASS
RX path integration: PASS
Full echo path: FAIL
```

Status by som upravil z:

```text
11/11 testbenches ALL PASS; zostáva full echo path test
```

na:

```text
11/11 unit/layer testov PASS.
RX path Verilator PASS.
Full echo path Verilator zatiaľ FAIL: bez TX odpovede pri validnom UDP requeste.
```

---

# 7. Hlavný funkčný problém: `echo_path` ešte nevie poslať odpoveď

`echo_path_top.sv` už prepája celý single-clock reťazec:

```text
gmii_rx_mac
 -> eth_header_parser
 -> ipv4_header_parser
 -> udp_header_parser
 -> udp_rx_meta_assembler
 -> udp_echo_app
 -> udp_ipv4_tx_builder
 -> gmii_tx_mac
```

To je správna architektúra.

Ale `tb_echo_path.log` ukazuje, že pri validnom UDP `HELLO` nevznikne TX frame.

Najpravdepodobnejšie miesto problému je handshake medzi:

```text
udp_header_parser
udp_rx_meta_assembler
udp_echo_app
```

Konkrétne toto rozhodnutie:

```systemverilog
udp_header_parser.hdr_pre_valid_o
```

je použité na metadata assembler:

```systemverilog
.udp_hdr_pre_valid_i(udp_hdr_pre_valid)
```

a `udp_echo_app` sa pokúša v `ST_IDLE` zachytiť metadata aj prvý payload byte naraz:

```systemverilog
assign s_axis_tready =
  (state_q == ST_RX) ||
  (state_q == ST_IDLE && rx_meta_valid_i);
```

Toto je krehká časová väzba. Môže fungovať, ale ak sa `rx_meta_valid_i` objaví o cyklus neskôr, prvý payload byte môže stáť na vstupe parsera cez backpressure. Ak sa niektorý valid/ready signál neprepojí presne podľa očakávania, echo app nikdy neprejde do TX fázy.

---

# 8. Odporúčaná oprava pre full echo path: zjednodušiť metadata timing

Namiesto `hdr_pre_valid_o` by som pre prvú robustnú verziu použil jednoduchší a bezpečnejší model:

```text
udp_header_parser:
  po prijatí UDP headera vystaví hdr_valid_o a drží metadata stabilné počas celého payloadu

udp_rx_meta_assembler:
  zachytí metadata pri hdr_valid_o && rx_meta_ready_i

udp_header_parser:
  prvý payload byte začne púšťať až keď downstream ready
```

Inými slovami, nesnažil by som sa optimalizovať o 1 cyklus pomocou `hdr_pre_valid_o`, kým full path neprejde.

## Praktická zmena

V `udp_rx_meta_assembler` by som pridal vstup:

```systemverilog
input wire logic udp_hdr_valid_i
```

a používal ho namiesto `udp_hdr_pre_valid_i`.

Prípadne nechaj oba:

```systemverilog
input wire logic udp_hdr_pre_valid_i,
input wire logic udp_hdr_valid_i,
```

a parameter:

```systemverilog
parameter bit USE_PRE_VALID = 1'b0;
```

Pre stabilný bring-up:

```text
USE_PRE_VALID = 0
```

Až keď testy prejdú, môžeš optimalizovať späť.

---

# 9. Dôležitý bug v `udp_header_parser`: zero-payload metadata

Aktuálne:

```systemverilog
assign hdr_pre_valid_o = (state_q == ST_HEADER) && s_axis_tvalid &&
                          (byte_cnt_q == 3'd7) && !drop_decision_w &&
                          (header_next_w[31:16] > 16'd8);
```

To znamená, že pre:

```text
udp_len == 8
```

teda nulový UDP payload, `hdr_pre_valid_o` nebude nikdy 1.

Unit test parsera hovorí, že zero-payload frame je OK, ale echo/full path by pri zero-payload odpovedi nedostal metadata.

To treba opraviť. Aj nulový UDP payload je platný packet a echo app má poslať prázdnu UDP odpoveď.

Zmeň:

```systemverilog
(header_next_w[31:16] > 16'd8)
```

na:

```systemverilog
(header_next_w[31:16] >= 16'd8)
```

Ale potom musí `udp_echo_app` zvládnuť `payload_len = 0`. Momentálne tam vidím riziko v `last_read_w`, lebo počíta `payload_len - 1`.

Preto odporúčam samostatný test:

```text
tb_udp_echo_app_zero_payload
tb_echo_path_zero_payload
```

---

# 10. Problém v `ethernet_test_03_top.sv`

Top ešte nie je pripravený. Má konkrétnu chybu:

```systemverilog
.m_axis_tuser(1'b0)
```

Toto je output z `gmii_rx_mac`, takže nesmie byť pripojený na konštantu.

Správne:

```systemverilog
logic rx_axis_tuser;

.m_axis_tuser(rx_axis_tuser)
```

Ďalej top stále obsahuje len stub:

```systemverilog
// 4. UDP Echo App (Aplikácia) - Tu by bolo napojenie na parsery
// ... implementácia UDP parsera a Echo App ...
```

a používa:

```systemverilog
eth_debug_leds u_leds
```

ale v ZIP-e nevidím `eth_debug_leds.sv`.

Takže top by som zatiaľ nepoužíval ako build cieľ. Najprv oprav `echo_path_top`, až potom prenes zapojenie do hardvérového topu.

---

# 11. Knižnica je teraz v dobrom stave, ale regression cieľ je neúplný

Aktuálny Makefile:

```makefile
regression: clean all
```

Ale `all` nezahŕňa:

```text
rx_path
echo_path
```

Preto sa môže stať, že napíšeš „regression PASS“, ale full echo path je rozbitý.

Navrhujem:

```makefile
unit: crc32 gmii_tx gmii_rx mac_stream eth_hdr_builder eth_hdr_parser ipv4_checksum ipv4_hdr_parser udp_hdr_parser udp_tx_builder

integration: rx_path echo_path

regression: clean unit integration
```

Ale kým `echo_path` failuje, daj ho napríklad do samostatného cieľa:

```makefile
known_fail: echo_path
```

alebo:

```makefile
integration: rx_path
full: echo_path
```

Status potom nebude mätúci.

---

# 12. Odporúčaný najbližší postup

## Krok 1 — opraviť linter `eth_pkg`

Pridaj:

```text
sim/eth_test_03.f
```

s `eth_pkg.sv` ako prvým súborom.

Potom nastav linter/IDE, aby používal tento filelist.

## Krok 2 — opraviť status

Uveď:

```text
Unit/layer tests PASS.
rx_path PASS.
echo_path FAIL.
```

Nie „všetko ALL PASS“, lebo `tb_echo_path.log` nie je PASS.

## Krok 3 — stabilizovať metadata handshake

Pre full echo path by som dočasne zrušil závislosť na `hdr_pre_valid_o` a použil jednoduchší `hdr_valid_o`.

Cieľ:

```text
metadata sa latchnú jednoznačne
prvý payload byte sa nestratí
echo_app prejde do ST_RX a potom ST_TX_META
```

## Krok 4 — pridať trace/debug výstupy do `echo_path_top`

Dočasne pridaj výstupy:

```systemverilog
output logic dbg_rx_meta_valid_o,
output logic dbg_rx_meta_ready_o,
output logic dbg_tx_meta_valid_o,
output logic dbg_tx_meta_ready_o,
output logic dbg_echo_tvalid_o,
output logic dbg_txb_tvalid_o,
output logic dbg_tx_start_o
```

Potom v C++ `tb_echo_path.cpp` pri zlyhaní vytlač:

```text
rx_meta_valid/ready
tx_meta_valid/ready
echo_tvalid
txb_tvalid/ready
tx_start
gmii_tx_en
```

Tak hneď zistíš, kde sa reťazec zastaví.

## Krok 5 — až potom opravovať `ethernet_test_03_top`

Keď `echo_path` prejde v single-clock Verilatore, prenes rovnaké zapojenie do `ethernet_test_03_top.sv`.

---

# 13. Krátky odborný verdikt

Projekt je architektonicky na dobrej ceste:

```text
MAC PASS
L2 PASS
L3 PASS
L4 RX PASS
TX builder PASS
RX integration PASS
```

Ale aktuálny hlavný blocker je:

```text
full echo path FAIL — validný UDP request zatiaľ nevygeneruje TX odpoveď
```

A hlásenie lintera:

```text
reference not found "eth_pkg"
```

je takmer určite problém **filelistu / compile orderu v linteri**, nie problém samotného package.

Najbližší správny krok: **zaviesť filelist pre linter a následne debugnúť `echo_path` handshake medzi UDP parserom, meta assemblerom a echo appkou**.
