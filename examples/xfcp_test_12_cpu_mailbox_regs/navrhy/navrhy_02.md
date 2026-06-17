Skontroloval som `xfcp_test_12_cpu_mailbox_regs.zip`.

```text id="d39rk6"
xfcp_test_12_cpu_mailbox_regs.zip
SHA-256: f950ff57f6708eed9155f11d2d42e66cad2a81e0b8ab9b2914761945abf21538
```

## Verdikt experta

`xfcp_test_12_cpu_mailbox_regs` je **architektonicky správny krok**, ale **nie je pripravený na tag**.

Aktuálny stav podľa ZIP-u:

```text id="kybjm1"
Sim:        PASS, T01–T44
Timing:     FAIL, CLK125 Slow 85C WNS -0.220 ns
HW:         PENDING
Nové RTL:   axil_cpu_mailbox.sv
Problém:    timing path z MEM RFIFO do endpoint rdata_r
```

Najdôležitejšia vec: problém v `STATUS.md` je pomenovaný približne správne, ale navrhované riešenia tam idú zlým smerom. Toto nie je problém, ktorý by som riešil akceptovaním záporného slacku alebo len seed sweepom.

---

# Čo je dobré

## 1. Smer `xfcp_test_12` je správny

Toto je presne to, čo malo nasledovať po `xfcp_test_11`:

```text id="v2feam"
CPU0 stream_id=1 už nie je len loopback,
ale je napojený na axil_cpu_mailbox.
```

Pribudlo AXI-Lite rozhranie:

```text id="dca884"
slot 7 @ 0xFF070000 = CPUM
GET_TARGET_INFO index 10 = CPUM AXIL
NUM_SLAVES = 8
NUM_TARGETS = 11
```

Register mapa je rozumná:

```text id="my2ixc"
0x00 ID          "CPUM"
0x04 CTRL        rx_flush / tx_flush
0x08 STATUS      rx_not_empty/rx_full/tx_not_empty/tx_full
0x10 RX_LEVEL
0x14 TX_LEVEL
0x18 RX_POP_DATA
0x1C TX_PUSH_DATA
```

Toto je prvý reálny CPU-facing mailbox model. Doteraz `CPU0` bol iba druhý stream loopback.

---

## 2. Simulácia prešla

Status uvádza:

```text id="zbqa4e"
integration T01–T44 PASS
REGRESSION PASSED 2026-06-16
```

A log potvrdzuje:

```text id="vzzbz9"
ALL PASSED (0 failures)
```

Nové testy:

```text id="ak8uso"
T43 CPUM ID/STATUS/LEVEL read
T44 RX flush
```

To je dobrý začiatok. Simulačne je mailbox register block použiteľný.

---

## 3. `axil_cpu_mailbox.sv` je koncepčne dobrý

Modul má jasné rozdelenie:

```text id="8oa8p0"
host -> CPU RX FIFO:
  s_axis -> RX FIFO -> AXI-Lite RX_POP_DATA

CPU -> host TX FIFO:
  AXI-Lite TX_PUSH_DATA -> TX FIFO -> m_axis
```

Použitie 9-bit slova `{tlast, data[7:0]}` je správne a prirodzené pre tvoj stream model.

---

# Hlavný problém v STATUS.md

Status hovorí:

```text id="d12rfi"
Root cause: Quartus generuje read-during-write pass-through bypass mux
Warning 276020
kritická cesta: rfifo_data_q_rtl_0 portb_address_reg0 -> endpoint rdata_r[26]
```

Toto je čiastočne správne, ale treba to presnejšie pomenovať:

## Skutočný problém nie je `axil_cpu_mailbox`

Najhoršia cesta ide z:

```text id="e9dyef"
xfcp_mem_adapter.u_mem_adapter.rfifo_data_q_rtl_0
```

do:

```text id="qvp1jn"
xfcp_fabric_endpoint.u_endpoint.rdata_r[26]
```

Čiže problém je stále v **MEM_READ výstupnej ceste**, konkrétne v internom read FIFO v `xfcp_mem_adapter`, nie v novom `axil_cpu_mailbox`.

Nový mailbox iba zvýšil celkový tlak na routing/fitter a odhalil starú krehkosť.

---

# Prečo sú návrhy v STATUS.md slabé

V statuse sú navrhnuté tri smery:

```text id="ixq0lx"
1. ďalší seed sweep
2. RTL pipeline register na vstupe mem_rdata_i v endpoint
3. akceptovať -0.220 ns
```

Moje hodnotenie:

## 1. Seed sweep — iba dočasná náplasť

Seed sweep môže prejsť, ale nerieši root cause. Už teraz je TNS:

```text id="u6g5u3"
TNS = -2.747 ns
```

To nie je jeden kozmetický path. Sú minimálne viaceré bity `rdata_r`, napríklad `rdata_r[26]` a `rdata_r[25]`.

Seed sweep by som použil až po RTL oprave, nie ako hlavné riešenie.

---

## 2. Pipeline register až v `xfcp_fabric_endpoint` — môže pomôcť, ale nie je najčistejší fix

Ak dáš register na `mem_rdata_i` v endpointe, síce rozdelíš cestu, ale:

```text id="p4wbh9"
RAM/bypass mux -> endpoint input register
```

stále ostáva jedna dlhá cesta. Lepšie je prerezať ju ešte v `xfcp_mem_adapter`, kde vzniká.

---

## 3. Akceptovať -0.220 ns — nie

Toto by som pri knižnici nerobil.

Pre interný experiment by sa dalo povedať „na stole to asi pôjde“, ale cieľ je knižnica. Pri knižnici je záporný slack release blocker.

```text id="3s6it6"
WNS -0.220 ns = netagovať ako PASS.
```

---

# Správny technický fix

V `xfcp_mem_adapter.sv` je problém v tomto modeli:

```systemverilog id="0j4zq1"
logic [DATA_WIDTH-1:0] rfifo_data_q [0:BEATS_MAX-1];

assign mem_rdata_valid_o = (state_q == ST_DATA) && !rfifo_empty_w;
assign mem_rdata_o       = rfifo_data_q[rfifo_rd_ptr_q];
```

Toto je prakticky **fall-through/combinational read FIFO**. Quartus z toho inferuje RAM s pass-through logikou a potom vzniká cesta:

```text id="xfihdp"
RAM address/output/bypass -> endpoint rdata_r
```

Pritom už máš hotový modul na riešenie presne tohto problému:

```text id="mwzmgw"
xfcp_fifo_reg.sv
```

Ten má registrovaný výstup.

## Odporúčaná oprava

V `xfcp_mem_adapter` zahoď ručne písané `rfifo_data_q/rfifo_last_q/ptr/cnt` a nahraď to jedným FIFO:

```systemverilog id="y4bsku"
xfcp_fifo_reg #(
  .DATA_WIDTH(DATA_WIDTH + 1),
  .DEPTH(BEATS_MAX)
) u_rdata_fifo (
  .clk    (clk),
  .rst_n  (rst_n),
  .flush  (rfifo_flush_w),

  .w_data ({m_axi_rlast, m_axi_rdata}),
  .w_valid(rfifo_push_w),
  .w_ready(rfifo_w_ready_w),

  .r_data ({rfifo_last_w, mem_rdata_fifo_w}),
  .r_valid(rfifo_r_valid_w),
  .r_ready(rfifo_r_ready_w)
);
```

Potom:

```systemverilog id="unuscd"
assign m_axi_rready       = (state_q == ST_R) && rfifo_w_ready_w && !timeout_w;

assign mem_rdata_o        = mem_rdata_fifo_w;
assign mem_rdata_valid_o  = (state_q == ST_DATA) && rfifo_r_valid_w;
assign rfifo_r_ready_w    = (state_q == ST_DATA) && mem_rdata_ready_i;
```

A ukončenie `ST_DATA`:

```systemverilog id="lzwjfz"
if (rfifo_r_valid_w && mem_rdata_ready_i && rfifo_last_w)
  state_q <= ST_IDLE;
```

Toto je najčistejšie, lebo:

```text id="sk6p0m"
1. rušíš custom fall-through RFIFO,
2. odstraňuješ priamu RAM -> endpoint cestu,
3. pridáš registrovaný FIFO výstup,
4. zachováš celý burst buffering,
5. nezmeníš externý protokol.
```

Áno, pridá sa 1–2 cykly latencie pri MEM_READ odpovedi. To je úplne v poriadku.

---

# Pozor: Warning 276020 zostane aj inde

ZIP ukazuje Warning 276020 aj na iných FIFO:

```text id="rzlpkr"
xfcp_axis_adapter STR0 i_rfifo
xfcp_axis_adapter CPU0 i_rfifo
u_lb_str0
axil_cpu_mailbox u_tx_fifo
axil_cpu_mailbox u_rx_fifo
```

Ale najhoršia timing cesta je teraz len z:

```text id="hzbwlq"
xfcp_mem_adapter rfifo_data_q_rtl_0
```

Takže netreba hneď panikáriť zo všetkých 276020. Priorita je iba tá cesta, ktorá porušuje timing.

Po nahradení MEM RFIFO cez `xfcp_fifo_reg` treba znova pozrieť STA. Ak sa ďalší najhorší path presunie do `xfcp_axis_adapter` alebo `axil_cpu_mailbox` FIFO, potom bude treba použiť rovnaký princíp aj tam.

---

# Druhý vážny integračný problém: IP YAML je stale

V ZIP-e je `project.yaml` správne:

```text id="qyo4jq"
project name: xfcp_test_12_cpu_mailbox_regs
module type: xfcp_test_12_cpu_mailbox_regs_top
```

Ale v adresári `ip/` je stále iba:

```text id="kqoky0"
ip/xfcp_test_11_cpu_mailbox_top.ip.yaml
```

a v ňom:

```text id="h3zpvu"
name:   xfcp_test_11_cpu_mailbox_top
module: xfcp_test_11_cpu_mailbox_top
Top-level: ../rtl/xfcp_test_11_cpu_mailbox_top.sv
```

To je zle pre knižničný workflow.

Aj keď `build/hal/files.tcl` teraz obsahuje:

```text id="jvp4tw"
rtl/axil_cpu_mailbox.sv
rtl/xfcp_test_12_cpu_mailbox_regs_top.sv
```

to môže byť stale alebo ručne upravený build výstup. Ak projekt pregeneruješ čistým socfw flow, môže nastať problém, že registry nevie nájsť `xfcp_test_12_cpu_mailbox_regs_top`, alebo použije starý IP popis.

## Oprava

Vytvoriť:

```text id="82ps76"
ip/xfcp_test_12_cpu_mailbox_regs_top.ip.yaml
```

s:

```yaml id="ccqxl8"
ip:
  name: xfcp_test_12_cpu_mailbox_regs_top
  module: xfcp_test_12_cpu_mailbox_regs_top
```

A v artifacts:

```text id="pfh8b6"
../rtl/axil_cpu_mailbox.sv
../rtl/xfcp/xfcp_stream_mux.sv
../rtl/xfcp/xfcp_mem_adapter.sv
../rtl/xfcp_test_12_cpu_mailbox_regs_top.sv
```

Odstrániť starý top:

```text id="vksl5t"
../rtl/xfcp_test_11_cpu_mailbox_top.sv
```

A `provides.modules` má obsahovať:

```text id="ls6o1o"
xfcp_test_12_cpu_mailbox_regs_top
axil_cpu_mailbox
```

Toto treba opraviť ešte pred ďalším oficiálnym buildom.

---

# Tretí problém: názvy skriptov a Makefile sú stále test_11

Nie je to funkčný blocker, ale pre knižnicu je to šum.

V ZIP-e sú ešte texty:

```text id="n2kfzd"
Makefile: xfcp_test_11_cpu_mailbox
tools/test_hw.py: xfcp_test_11_cpu_mailbox
tools/hw_regression.sh: xfcp_test_11_cpu_mailbox
```

Pre `xfcp_test_12_cpu_mailbox_regs` to treba premenovať. Inak sa v logoch bude miešať, či testuješ v1.5 alebo v1.6.

---

# Štvrtý problém: `axil_cpu_mailbox` write overflow správanie

`TX_PUSH_DATA` teraz robí:

```text id="rp5vug"
AXI write prijmeš a vrátiš OKAY,
aj keď tx_w_ready_w môže byť 0.
```

Čiže ak CPU zapíše do plného TX FIFO, write môže byť potichu zahodený.

Pre prvý sim test to nevadí, ale pre knižnicu je to problém. Máš dve možnosti:

## Jednoduchá možnosť

Pridať overflow bit do statusu alebo error flag:

```text id="i3s6c2"
STATUS[4] = rx_underflow_seen
STATUS[5] = tx_overflow_seen
```

A pri `TX_PUSH_DATA` keď `!tx_w_ready_w`:

```text id="jdhbh4"
tx_overflow_seen <= 1
```

Write stále môže vracať OKAY.

## Prísnejšia možnosť

Pri zápise do plného TX FIFO vrátiť:

```text id="nucn0o"
BRESP = SLVERR
```

To je čistejšie, ale zložitejšie na host/CPU-side software.

Pre aktuálnu fázu by som dal najprv status flag.

---

# Čo robiť teraz — konkrétny postup

## Krok 1 — opraviť IP YAML

Bez toho by som nepokračoval.

```text id="to043o"
ip/xfcp_test_12_cpu_mailbox_regs_top.ip.yaml
```

s korektnými súbormi a provides.

Potom čistý regen:

```bash id="l2vb9t"
rm -rf build
socfw build project.yaml
grep -R "xfcp_test_12_cpu_mailbox_regs_top" build/hal/files.tcl build/rtl/soc_top.sv
grep -R "axil_cpu_mailbox" build/hal/files.tcl
```

---

## Krok 2 — opraviť `xfcp_mem_adapter` RFIFO

Nahradiť custom `rfifo_data_q/rfifo_last_q` implementáciu cez `xfcp_fifo_reg #(DATA_WIDTH=33)`.

Potom:

```bash id="ukjyrf"
make sim
make compile
```

Cieľ:

```text id="tabqu4"
Slow 85C CLK125 WNS >= 0
TNS = 0
```

Ak bude WNS aspoň:

```text id="i23i9u"
+0.1 ns
```

výborne.

---

## Krok 3 — doplniť mailbox unit/integration testy

Teraz máš T43–T44. Pred HW by som ešte doplnil:

```text id="o5mxh6"
T45 TX_PUSH_DATA -> STREAM_READ sid=1
T46 STREAM_WRITE sid=1 -> RX_POP_DATA byte-by-byte
T47 TLAST propagation cez RX_POP_DATA[8]
T48 TX FIFO full / overflow flag
T49 RX FIFO flush + TX FIFO flush
```

Najmä T45/T46 sú dôležité, lebo teraz CPU mailbox nesmie byť len „číta ID a flushuje RX“. Musí byť overený celý bidirectional flow:

```text id="sfmio5"
host -> CPU
CPU -> host
```

---

## Krok 4 — HW regression

Až po timing PASS:

```bash id="cx4b86"
make hw-regression
```

Ale test_hw.py musí pre test_12 obsahovať aj CPUM register test, nielen `--cpu0` stream loopback.

Pridať napríklad:

```text id="ewpjaa"
--cpum
```

Testy:

```text id="7oa9um"
CPUM ID == 0x4350554D
STATUS sane
STREAM_WRITE sid=1 payload
read RX_LEVEL
RX_POP_DATA over AXIL
TX_PUSH_DATA cez AXIL
STREAM_READ sid=1 payload
flush RX/TX
DIAG clean
```

Až potom bude `xfcp_test_12` skutočne mailbox register míľnik.

---

# Ako hodnotím stav pre knižnicu

Aktuálne:

```text id="72b2y8"
v1.4 MEM:        uzavreté
v1.5 CPU0 stream: uzavreté
v1.6 CPUM regs:   sim čiastočne PASS, timing FAIL, HW pending
```

Nevolal by som to zatiaľ `xfcp_lib_v1_6_mailbox_regs_pass`.

Presné označenie aktuálneho stavu:

```text id="e3ijnd"
xfcp_test_12_cpu_mailbox_regs_sim_pass_timing_open
```

Ale architektonicky je smer správny.

---

## Záver

Ako expert by som problém v `STATUS.md` zhrnul takto:

```text id="4iwcu1"
Nie je to problém nového axil_cpu_mailbox.
Je to starý slabý bod v MEM_READ výstupnej RFIFO ceste xfcp_mem_adaptera.
Custom fall-through RFIFO v mem_adapteri musí byť nahradené registrovaným FIFO/skid výstupom.
Seed sweep ani akceptovanie záporného slacku nie je vhodné pre knižnicu.
```

Najbližší postup:

```text id="yhgtnb"
1. Opraviť stale IP YAML na test_12.
2. V xfcp_mem_adapter nahradiť RFIFO za xfcp_fifo_reg DATA_WIDTH=33.
3. Rerun sim + timing.
4. Doplniť reálne CPUM register HW testy.
5. Až po UART+UDP PASS tagovať v1.6.
```

Tým udržíš knižnicu v stave, kde každý míľnik znamená: **sim PASS + timing PASS + HW PASS + čistá integrácia**.
