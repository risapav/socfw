Skontroloval som aktuálny `sdram_test_01.zip` nanovo.

## Overenie ZIPu

```text
SHA-256: 37c1d763de3432a20839f956896aa322df3a04eea7d78a12c6f9398e96b84ea6
Veľkosť: 664 937 B
Počet položiek: 134
```

Toto je nový snapshot, nie pôvodný ani predchádzajúci.

---

## Aktuálny verdikt

Projekt sa posunul o ďalší míľnik.

Aktuálny stav je:

```text
[PASS] sdram_test_01_init_refresh
[PASS] sdram_test_02_phy_single_rw
[PASS] sdram_test_03_scheduler_rw
[PASS] sdram_test_04_axi_single_rw
[TODO] sdram_test_05_axi_burst_rw
[TODO] sdram_test_06_hw_bist
```

`STATUS.md` správne uvádza:

```text
IN PROGRESS — sdram_test_05_axi_burst_rw (M1–M4 PASS)
```

Teda už máme **AXI single read/write PASS cez celý stack**.

---

## Nový dôležitý progres

Pribudol:

```text
sim/tb_axi_single_rw.sv
sim/logs/tb_axi_single_rw.log
```

A `sim/Makefile` už obsahuje:

```make
axi_single_rw
regression: init_refresh phy_single_rw scheduler_rw axi_single_rw
```

To znamená, že simulácia má teraz 4 uzavreté míľniky.

---

## Dôkaz z `tb_axi_single_rw.log`

Log pre AXI single RW končí úspešne:

```text
ACT=1 WR=2 RD=2 PRE=0
Write=0x1234a5c3  Read=0x1234a5c3  rlast=1  rid=0x5
*** PASS ***
Errors: 0, Warnings: 0
```

Toto je veľmi dobrý výsledok, pretože už prešlo:

```text
AXI AW/W
write_engine
axi_gearbox
cmd FIFO cesta
memory_scheduler
timing_manager
bank_machine
sdram_phy
sdram_model_pro
read_engine
AXI R
RLAST
RID
```

Test je zatiaľ úzko definovaný:

```text
AWLEN=0
ARLEN=0
RREADY=1
BREADY=1
bez burstov
bez backpressure
bez refresh under load
```

Ale ako míľnik `sdram_test_04_axi_single_rw` je to legitímny PASS.

---

## Opravené problémy

### 1. `read_issue` metadata bug je opravený

Predtým bol problém, že `read_engine` dostával registrované `issue_id_lat/issue_last_lat`, ktoré mohli byť staré.

Teraz v `sdram_system_top.sv` vidím:

```systemverilog
.read_issue(read_issue),
.issue_id(fifo_cmd.id),
.issue_last(fifo_cmd.last),
```

Toto je správny fix pre M4.

---

### 2. `axi_gearbox` RLAST fix je prítomný

V `axi_gearbox.sv` je pre read mód:

```systemverilog
m_cmd.last = WRITE_MODE
             ? (last_latch && (gear_state == GS_PHASE1))
             : ((gear_state == GS_PHASE1) && (aw_burst_cnt == '0));
```

To sedí s tým, čo `STATUS.md` opisuje: predtým `last_latch` v read móde nefungoval, teraz RLAST vychádza správne.

---

### 3. `read_engine` metadata FIFO push je zúžený na poslednú fázu

V `read_engine.sv`:

```systemverilog
.s_valid(read_issue && issue_last)
```

To je správne pre aktuálny 32-bit AXI beat zložený z dvoch 16-bit SDRAM read príkazov. Metadata sa pushnú len pre druhú fázu, keď má vzniknúť jeden AXI R beat.

---

### 4. Cyclone IV device family je opravená

V `sdram_phy.sv` už je:

```systemverilog
.intended_device_family ("Cyclone IV E")
```

Toto je správne pre QMTECH EP4CE55F23C8.

---

## Čo ešte nie je hotové

### 1. `read_engine` stále nemá R backpressure ochranu

Stále platí:

```systemverilog
if (s_axi_rready) s_axi_rvalid <= 1'b0;

if (phy_rdata_valid) begin
  ...
  s_axi_rvalid <= 1'b1;
end
```

Ak `RREADY=0` a príde ďalší read beat, `RDATA` sa môže prepísať.

Pre M4 je to v poriadku, lebo test má `RREADY=1`. Pre M5/MEM backend to už treba opraviť.

Odporúčanie pre M5:

```text
pridať 1-entry alebo 2-entry R skid buffer / FIFO
potom otestovať RREADY stall
```

---

### 2. `write_engine` stále dáva `BVALID` skoro

V `write_engine.sv`:

```systemverilog
if (gb_phase1_done && gb_last_latch) begin
  s_axi_bvalid <= 1'b1;
end
```

To znamená, že `BVALID` vzniká po dokončení gearbox fázy, nie po skutočnom dokončení SDRAM zápisu na fyzickej strane.

Pre M4 smoke test je to akceptovateľné. Pre knižnicu by som to časom presunul na „write committed“ signál zo schedulera/write datapathu.

---

### 3. M5 ešte nie je reálne začaté

Snapshot neobsahuje dôkaz pre:

```text
tb_axi_burst_rw.sv
tb_axi_backpressure.sv
tb_refresh_under_load.sv
```

Aktuálny stav `sdram_test_05_axi_burst_rw` je teda správne `TODO`.

---

### 4. ZIP stále obsahuje simulačné pracovné artefakty

Aj keď `.gitignore` už existuje, ZIP stále obsahuje:

```text
sim/work/
sim/transcript
*.qdb
*.qpg
*.qtl
```

Do čistého exportu/repa by som ich nedával. Nie je to funkčný problém, len hygiene problém.

---

## Odporúčaný ďalší míľnik

Ďalší správny krok je:

```text
sdram_test_05_axi_burst_rw
```

Ale rozdelil by som ho na malé podtesty:

```text
M5a: AXI burst write/read, AWLEN=1 alebo 3, RREADY=1, BREADY=1
M5b: RREADY stall test
M5c: BREADY stall test
M5d: row crossing / row miss
M5e: refresh under load
```

Ako prvý M5 test by som nerobil všetko naraz. Začni:

```text
tb_axi_burst_rw.sv
AWLEN=1
ARLEN=1
2 AXI beaty = 4 SDRAM halfwordy
RREADY=1
BREADY=1
bez refresh stress
```

Definition of done:

```text
WR=4
RD=4
2x RVALID
posledný RLAST=1
prvý RLAST=0
readback == written burst data
Errors=0, Warnings=0
```

---

## Krátke hodnotenie progresu

```text
Architektúra:        dobrá
Sim disciplína:      dobrá
STATUS.md:           dobrý, ale Known issues sekciu treba aktualizovať
M1 init/refresh:     PASS
M2 PHY single RW:    PASS
M3 scheduler RW:     PASS
M4 AXI single RW:    PASS
M5 burst/backpress:  ďalší krok
HW BIST:             zatiaľ nie
XFCP integrácia:     zatiaľ nie
```

Záver: **projekt SDRAM knižnice je teraz v zdravom stave a spravil významný posun — full AXI single RW už prešiel.** Ešte by som nešiel do XFCP integrácie; najprv uzavrieť M5 burst + backpressure.
