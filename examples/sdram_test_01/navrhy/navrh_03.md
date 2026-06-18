Skontroloval som nový `sdram_test_01.zip`.

## Verdikt

Vývoj SDRAM knižnice sa posunul správnym smerom. Už to nie je iba prvotný snapshot — pribudol reálny mini-projektový rámec:

```text
STATUS.md
sim/Makefile
sim/tb_init_refresh.sv
sim/tb_phy_single_rw.sv
sim/logs/tb_init_refresh.log
sim/logs/tb_phy_single_rw.log
```

Aktuálny stav podľa snapshotu:

```text
sdram_test_01_init_refresh  PASS
sdram_test_02_single_rw     PASS
sdram_test_03_scheduler_rw  ďalší krok
```

Nový SHA-256 ZIPu je:

```text
42a7fa8e72583d541b324e6a8a795cc21c77177ce383e114b8fa2466b6a22440
```

Čiže snapshot je iný ako pôvodný `66eb...`.

---

## Čo je preukázateľne PASS

### 1. `sdram_test_01_init_refresh`

Podľa logu:

```text
PRE_ALL=1
REF=19
MRS=1
ACT=0
RD=0
WR=0
Errors: 0, Warnings: 0
*** PASS ***
```

Toto je dobrý prvý míľnik. Overuje sa:

```text
200 us init wait
PRECHARGE ALL
8x AUTO REFRESH
MRS
init_done
periodický refresh
bez READ/WRITE počas init/refresh testu
```

Dôležité: oprava `PRE_ALL` na `A10=1`, teda `13'h0400`, je správna. Toto bola presne chyba, ktorú by reálny SDRAM chip nemusel odpustiť.

---

### 2. `sdram_test_02_single_rw`

Podľa logu:

```text
ACT=2
WR=1
RD=1
PRE=2
Write=0xa5c3
Read=0xa5c3
valid=1
Errors: 0, Warnings: 0
*** PASS ***
```

Toto je tiež dobrý míľnik, ale presnejšie by som ho pomenoval:

```text
sdram_test_02_phy_single_rw
```

pretože ešte nejde cez scheduler ani AXI. Testbench ručne riadi PHY po init sekvencii.

---

## Čo je najväčší pozitívny posun

Projekt už dodržiava filozofiu, ktorú sme chceli:

```text
malý míľnik
STATUS.md
samostatný sim Makefile
logy
definition of done
PASS/FAIL výstup
```

Toto je presne správny štýl. Hlavne `STATUS.md` je už použiteľný ako handoff medzi chatmi.

---

## Čo ešte nie je hotové

Napriek PASS výsledkom ešte nemáme hotovú SDRAM knižnicu. Máme hotové iba spodné vrstvy:

```text
sdram_init      overené
sdram_phy       čiastočne overené
sdram_model     použiteľný na základné timing checky
refresh_manager použitý v init_refresh teste
```

Ešte nie je overené:

```text
memory_scheduler
timing_manager v reálnom toku
bank_machine
read_engine
write_engine
axi_gearbox
axi_frontend
sdram_system_top
AXI read/write
burst
backpressure
refresh under load
Quartus timing
HW BIST
```

Takže stav by som označil:

```text
SDRAM low-level bring-up: dobrý progres
SDRAM controller library: ešte nie pripravená na XFCP integráciu
```

---

## Kritické riziká, ktoré stále vidím

### 1. `read_engine` metadata bug je stále prítomný

V `sdram_system_top.sv` stále vidím:

```systemverilog
always_ff @(posedge clk or negedge rstn) begin
  ...
  else if (read_issue) begin
    issue_last_lat <= fifo_cmd.last;
    issue_id_lat   <= fifo_cmd.id;
  end
end
```

a potom:

```systemverilog
.issue_id(issue_id_lat),
.issue_last(issue_last_lat),
```

To znamená, že `read_engine` pri `read_issue` môže dostať staré `id/last`.

Pred míľnikom `sdram_test_04_axi_single_rw` by som to opravil. Najjednoduchšie:

```systemverilog
.issue_id   (fifo_cmd.id),
.issue_last (fifo_cmd.last),
```

alebo zaregistrovať aj `read_issue` o jeden cyklus neskôr spolu s meta dátami.

---

### 2. `read_engine` stále nemá AXI R backpressure ochranu

Stále platí problém:

```systemverilog
if (s_axi_rready) s_axi_rvalid <= 1'b0;

if (phy_rdata_valid) begin
  ...
  s_axi_rvalid <= 1'b1;
end
```

Ak `RREADY=0` a príde ďalší `phy_rdata_valid`, môže sa prepísať `RDATA`.

Pre knižnicu treba pred AXI R kanál dať aspoň malý skid/FIFO buffer.

---

### 3. `write_engine` stále generuje `BVALID` priskoro

Aktuálne `BVALID` vzniká po dokončení gearbox fázy:

```systemverilog
if (gb_phase1_done && gb_last_latch) begin
  s_axi_bvalid <= 1'b1;
end
```

To znamená, že AXI write response môže prísť po prijatí dát do vnútornej logiky, nie po skutočnom dokončení SDRAM zápisu.

Na jednoduchý single-outstanding test sa to dá dočasne tolerovať, ale pre čistý AXI backend by bolo lepšie generovať `BVALID` až po poslednom reálnom `CMD_WR`.

---

### 4. `memory_scheduler` bank pipeline je stále podozrivý

Komentár hovorí o FIFO lookahead, ale rozhranie má iba jeden FIFO head:

```systemverilog
in_cmd
in_valid
in_ready
```

To stále nie je skutočný lookahead. Navyše `pipe_cmd` sa síce latchuje, ale následné spracovanie sa spolieha na to, že FIFO head bude korešpondovať so slotom B.

Pre ďalší míľnik odporúčam bank pipeline **vypnúť alebo odložiť**.

Pre `sdram_test_03_scheduler_rw` má byť cieľ jednoduchý:

```text
bez bank pipeline
bez AXI
jeden command stream
ACT -> WR -> PRE -> ACT -> RD -> PRE
```

---

### 5. `sdram_phy.sv` má syntézne riziko pre Cyclone IV

V komentári je cieľová doska Cyclone IV E, ale `altddio_out` má:

```systemverilog
.intended_device_family ("Cyclone V")
```

Pre QMTECH EP4CE55F23C8 by som to zmenil na:

```systemverilog
.intended_device_family ("Cyclone IV E")
```

alebo parametrizoval.

Toto sa netýka simulácie, ale môže to vyskočiť v Quartuse.

---

### 6. V ZIPe sú simulačné pracovné adresáre

Snapshot obsahuje aj:

```text
sim/work/
sim/transcript
sim/logs/
```

Logy sú užitočné pre audit, ale `sim/work/` a `sim/transcript` by som do repozitára nedával.

Odporúčané:

```text
commitnúť:
  sim/logs/*.log          voliteľne áno, ak ich chceš ako dôkaz PASS
  STATUS.md              áno
  sim/Makefile           áno
  tb_*.sv                áno

necommitnúť:
  sim/work/
  sim/transcript
  *.qdb
  *.qpg
  *.qtl
```

Pridať `.gitignore`:

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

---

## Môj odporúčaný ďalší míľnik

Teraz nerob ešte AXI.

Ďalší správny míľnik je:

```text
sdram_test_03_scheduler_rw
```

Ale definoval by som ho úzko:

```text
Cieľ:
  overiť memory_scheduler + timing_manager + bank_machine
  bez AXI
  bez write_engine/read_engine
  bez bank pipeline optimalizácie
```

Testbench by mal priamo posielať `sdram_cmd_t` do schedulera:

```text
cmd_fifo-like driver
  WRITE bank0 row0 col8 data A5C3
  READ  bank0 row0 col8
```

Očakávaný command trace:

```text
ACT B0 row
WR  B0 col
PRE B0
ACT B0 row
RD  B0 col
PRE B0
```

Definition of done:

```text
sdram_model_pro: Errors=0, Warnings=0
readback == written data
scheduler nevydá RD/WR pred tRCD
scheduler nevydá PRE pred tRAS/tWR/tRDL
refresh zatiaľ buď vypnutý, alebo kontrolovane mimo transakcie
```

Až potom:

```text
sdram_test_04_axi_single_rw
```

---

## Odporúčaný update `STATUS.md`

Aktuálny `STATUS.md` je dobrý. Doplnil by som tam ešte krátku sekciu:

```text
## Repo hygiene

Do not commit:
- sim/work/
- sim/transcript
- Quartus db/
- output_files/
- incremental_db/

Commit:
- RTL
- testbenches
- sim/Makefile
- STATUS.md
- selected PASS logs
```

A pri `sdram_test_03_scheduler_rw` by som doplnil:

```text
Constraint:
- bank pipeline disabled for first scheduler milestone
- no AXI
- direct command driver
```

---

## Záver

Progres je dobrý a disciplinovaný.

Reálne dosiahnuté:

```text
[PASS] init + refresh
[PASS] PHY-level single write/read
[READY] projektový rámec so STATUS.md a sim/Makefile
```

Ešte nie je pripravené:

```text
[TODO] scheduler_rw
[TODO] AXI single read/write
[TODO] AXI burst/backpressure
[TODO] HW BIST
[TODO] Quartus timing
[TODO] XFCP integrácia
```

Najbližší správny krok: **neísť do XFCP ani AXI**, ale uzavrieť `sdram_test_03_scheduler_rw` s jednoduchým direct-command testbenchom.
