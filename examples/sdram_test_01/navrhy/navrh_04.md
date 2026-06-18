Máš pravdu — moja predchádzajúca kontrola bola chybná. Teraz som spravil hash a analýzu nanovo priamo z aktuálne nahraného súboru `/mnt/data/sdram_test_01.zip`.

## Overený hash aktuálneho ZIPu

```text
SHA-256:
6c968431fc47d337b01859ac7b3335f2df3065e9e8b6afa5e1129f143827b6db
```

ZIP existuje, má veľkosť približne `516 859 B` a obsahuje:

```text
131 položiek
```

Teda **nie je to pôvodný 37-položkový snapshot**. Je to nový aktuálny stav s rozšíreným mini-projektom.

---

# Opravený verdikt

Aktuálny stav projektu je:

```text
[PASS] sdram_test_01_init_refresh
[PASS] sdram_test_02_phy_single_rw
[PASS] sdram_test_03_scheduler_rw
[TODO] sdram_test_04_axi_single_rw
```

Toto je reálny progres oproti predchádzajúcemu stavu.

V ZIPe sú už prítomné:

```text
STATUS.md
.gitignore
sim/Makefile
sim/tb_init_refresh.sv
sim/tb_phy_single_rw.sv
sim/tb_scheduler_rw.sv
sim/logs/tb_init_refresh.log
sim/logs/tb_phy_single_rw.log
sim/logs/tb_scheduler_rw.log
```

Čiže `scheduler_rw` míľnik je už doložený logom a testbenchom.

---

# PASS dôkazy zo sim logov

## `sdram_test_01_init_refresh`

Log potvrdzuje:

```text
PRE_ALL=1
REF=19
MRS=1
ACT=0
RD=0
WR=0
*** PASS ***
Errors: 0, Warnings: 0
```

Toto sedí s cieľom:

```text
200 us init wait
PRECHARGE ALL
8x AUTO REFRESH
MRS
init_done
periodický refresh
bez READ/WRITE
```

---

## `sdram_test_02_phy_single_rw`

Log potvrdzuje:

```text
ACT=2
WR=1
RD=1
PRE=2
Write=0xa5c3
Read=0xa5c3
valid=1
*** PASS ***
Errors: 0, Warnings: 0
```

Toto je čistý PHY-level single write/read test bez schedulera a AXI.

---

## `sdram_test_03_scheduler_rw`

Log potvrdzuje:

```text
ACT=1
WR=1
RD=1
PRE=0
Write=0xa5c3
Read=0xa5c3
valid=1
*** PASS ***
Errors: 0, Warnings: 0
```

Toto je dôležitý posun. Už sa testuje:

```text
memory_scheduler
timing_manager
bank_machine
sdram_phy
sdram_model_pro
```

bez AXI, bez FIFO, bez read/write engine.

Aktuálny `STATUS.md` správne uvádza:

```text
IN PROGRESS — sdram_test_04_axi_single_rw
(init_refresh + phy_single_rw + scheduler_rw PASS)
```

---

# Čo je dôležité pochopiť pri `scheduler_rw` PASS

`scheduler_rw` je PASS, ale je to ešte **zúžený scheduler test**.

Podľa `STATUS.md` a logu:

```text
refresh_req = 1'b0
single-bank test
WRITE -> READ row-hit
bank pipeline disabled / prakticky nepokrytý
PRE nie je použitý
```

Trace ukazuje:

```text
ACT
WR
RD
```

bez `PRE`.

To znamená:

```text
scheduler vie:
  otvoriť banku
  dodržať tRCD pred WR/RD
  spraviť row-hit WRITE -> READ
  dostať správne dáta späť

scheduler ešte nedokazuje:
  row miss
  explicit PRE
  refresh počas záťaže
  multi-bank
  bank pipeline
  command FIFO tok
```

Preto je `sdram_test_03_scheduler_rw PASS` legitímny, ale je to **scheduler basic row-hit PASS**, nie kompletný scheduler coverage.

---

# Dobré zmeny v projekte

## 1. `sim/Makefile` je už použiteľný

Obsahuje:

```make
init_refresh
phy_single_rw
scheduler_rw
regression
clean
```

A `regression` zahŕňa všetky tri:

```make
regression: init_refresh phy_single_rw scheduler_rw
```

Toto je správne.

---

## 2. `STATUS.md` je výrazne lepší

Je tam jasný míľnikový stav:

```text
sdram_test_01_init_refresh  PASS 2026-06-17
sdram_test_02_single_rw     PASS 2026-06-17
sdram_test_03_scheduler_rw  PASS 2026-06-18
sdram_test_04_axi_single_rw TODO
```

Toto už je použiteľný handoff dokument pre ďalší chat alebo ďalší commit.

---

## 3. `.gitignore` pribudol

Obsahuje:

```gitignore
sim/work/
sim/transcript
*.wlf
*.vcd
*.fst
*.qdb
*.qpg
*.qtl
*.log.tmp
output_files/
db/
incremental_db/
```

To je správny smer.

Pozor: samotný ZIP stále obsahuje `sim/work/`, `sim/transcript`, `.qdb`, `.qpg`, `.qtl`. Čiže `.gitignore` je už dobrý, ale export ZIPu ešte zobral aj pracovné simulačné artefakty.

---

# Stále otvorené riziká pred AXI míľnikom

## 1. `read_engine` má síce FIFO na metadata, ale problém v `sdram_system_top` stále ostáva

V `read_engine.sv` je už zmena:

```systemverilog
// Meta pipeline — sync_fifo pre (id, last)
assign meta_s_data = {issue_id, issue_last};
...
.s_valid(read_issue)
```

To je dobrý smer.

Ale v `sdram_system_top.sv` stále ostáva:

```systemverilog
else if (read_issue) begin
  issue_last_lat <= fifo_cmd.last;
  issue_id_lat   <= fifo_cmd.id;
end
```

a potom:

```systemverilog
.read_issue(read_issue),
.issue_id(issue_id_lat),
.issue_last(issue_last_lat),
```

Teda pri tom istom `read_issue` môže `read_engine` stále dostať staré `issue_id_lat/issue_last_lat`.

Pre `sdram_test_04_axi_single_rw` by som to opravil pred testom.

Najjednoduchší fix:

```systemverilog
.issue_id   (fifo_cmd.id),
.issue_last (fifo_cmd.last),
```

alebo spraviť registrovaný `read_issue_d` a až ten poslať do `read_engine` spolu s už zaregistrovanými `issue_id_lat/issue_last_lat`.

---

## 2. `read_engine` stále nemá bezpečný AXI R backpressure

V `read_engine.sv` je stále:

```systemverilog
if (s_axi_rready) s_axi_rvalid <= 1'b0;

if (phy_rdata_valid) begin
  ...
  s_axi_rvalid <= 1'b1;
end
```

Ak `s_axi_rready == 0` a príde ďalší druhý halfword z PHY, `s_axi_rdata` sa môže prepísať.

Na `sdram_test_04_axi_single_rw` sa to dá dočasne testovať s `RREADY=1`, ale do knižnice treba doplniť aspoň:

```text
1-entry skid buffer
alebo malý R FIFO
```

---

## 3. `write_engine` stále generuje `BVALID` skoro

V `write_engine.sv`:

```systemverilog
if (gb_phase1_done && gb_last_latch) begin
  s_axi_bvalid <= 1'b1;
  s_axi_bid    <= m_cmd.id;
end
```

To znamená, že `BVALID` vzniká po dokončení gearbox vstupu, nie po reálnom SDRAM write issue.

Pre úplne prvý AXI single smoke test sa to dá tolerovať ako „controller accepted write“, ale pre korektný memory backend by bolo lepšie mať B response po fyzickom dokončení posledného WR.

---

## 4. `memory_scheduler` má pokročilú bank-pipeline logiku, ale aktuálny test ju nekryje

V `memory_scheduler.sv` už vidím stavy:

```systemverilog
ST_ACT_WAIT_PIPE
```

a SVA/cover logiku okolo pipeline.

Ale aktuálny `tb_scheduler_rw` je single-bank row-hit:

```text
ACT=1
WR=1
RD=1
PRE=0
```

Teda pipeline zatiaľ nie je reálne preukázaná.

To nie je chyba pre aktuálny míľnik, ale treba to explicitne držať ako budúci test:

```text
sdram_test_03b_scheduler_row_miss
sdram_test_03c_scheduler_refresh
sdram_test_03d_scheduler_multibank_pipeline
```

---

## 5. Quartus projekt stále nie je samostatný

`soc_top.qsf` stále obsahuje:

```tcl
source build/hal/files.tcl
source build/hal/board.tcl
```

Tieto súbory v ZIPe nevidím ako súčasť snapshotu. Takže FPGA/Quartus časť ešte nie je samostatne reprodukovateľná.

Stav:

```text
Simulation mini-project: dobrý
Quartus/HW mini-project: zatiaľ neuzavreté
```

---

# Odporúčaný ďalší krok

Teraz je správne ísť na:

```text
sdram_test_04_axi_single_rw
```

Ale odporúčam ho spraviť veľmi úzko.

## Cieľ

```text
AXI 32-bit single write/read
jedna adresa
AWLEN=0
ARLEN=0
RREADY=1
BREADY=1
bez burstov
bez backpressure
bez refresh under load
```

## Test

```text
AXI write:
  AW addr = bank0,row0x0010,col0x008
  W data  = 32'h1234_A5C3
  WLAST=1
  očakávať 2x SDRAM WR halfword

AXI read:
  AR same addr
  očakávať 2x SDRAM RD halfword
  RDATA == 32'h1234_A5C3
  RLAST=1
```

## Predtým opraviť

Minimálne pred týmto testom:

```text
fix read_issue metadata v sdram_system_top
```

Backpressure a skoré BVALID môžeš zatiaľ označiť ako known limitation, ale netestovať ich v `test_04`.

---

# Upravený stav projektu

Takto by som teraz projekt zapísal:

```text
sdram_lib / sdram_test_01

PASS:
  01 init_refresh
  02 phy_single_rw
  03 scheduler_rw basic row-hit

IN PROGRESS:
  04 axi_single_rw

KNOWN LIMITATIONS:
  read_engine metadata path in top needs fix
  read_engine lacks R backpressure protection
  write_engine BVALID is early
  scheduler pipeline not covered
  refresh under load not covered
  Quartus project not standalone
```

---

# Záver

Po novej kontrole: **progres je lepší, než som predtým nesprávne vyhodnotil**.

Správny aktuálny verdikt:

```text
SDRAM mini projekt je zdravý.
Tri sim míľniky sú doložené PASS logmi.
Projekt je pripravený začať AXI single RW míľnik, ale ešte nie XFCP integráciu.
```

Najbližší technický krok:

```text
opraviť read_issue metadata path v sdram_system_top
potom pridať tb_axi_single_rw.sv
potom make axi_single_rw
potom regression: 4/4 PASS
```
