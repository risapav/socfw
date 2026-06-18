Áno. Po kontrole ZIPu môžem potvrdiť, že `sdram_test_01.zip` je dobrý kandidát na samostatný mini projekt.

Checksum sedí:

```text
66ebf1c0e6f3e3426c84960c9664c75b97d7c0c1016d801287aed1bd02846088
```

Obsah má 37 položiek a štruktúra zodpovedá tomu, čo si uviedol.

## Rýchly verdikt

Toto **nie je iba jednoduchý sdram_test_01**. Je to už pomerne ambiciózny návrh:

```text
AXI 32-bit
 -> axi_gearbox
 -> command FIFO
 -> memory_scheduler
 -> timing_manager
 -> bank_machine
 -> write/read engine
 -> sdram_phy
 -> behavioral SDRAM model
```

To je dobrý základ pre knižnicu, ale ako prvý míľnik je to príliš veľa naraz.

Pre mini projekt by som to preto rozdelil takto:

```text
sdram_test_01_init_refresh      // iba init + refresh
sdram_test_02_phy_single_rw     // ručne riadený jeden write/read
sdram_test_03_scheduler_rw      // scheduler + bank_machine + timing
sdram_test_04_axi_single_rw     // AXI frontend, single outstanding
sdram_test_05_axi_burst_rw      // bursty
sdram_test_06_hw_bist           // FPGA smoke test
```

Aktuálny snapshot skôr zodpovedá niečomu ako:

```text
sdram_test_04_axi_single_rw / sdram_test_05_axi_burst_rw
```

nie úplne prvému testu.

---

## Čo je na návrhu dobré

Modulárne rozdelenie je správnym smerom:

```text
rtl/sdram/
  sdram_system_top.sv
  memory_scheduler.sv
  timing_manager.sv
  sdram_phy.sv
  write_engine.sv
  read_engine.sv
  bank_machine.sv
  refresh_manager.sv
  sdram_init.sv
  sdram_pkg.sv

rtl/axi/
  axi_frontend.sv
  axi_gearbox.sv

rtl/fifo/
  sync_fifo.sv

sim/model/
  sdram_model_pro.sv
  axil_slave_model.sv
```

Toto už vyzerá ako knižnica, nie ako jednorazový pokus.

Najsilnejšie časti sú:

```text
sdram_pkg.sv              // centrálne parametre, mapping, príkazy
sdram_init.sv             // samostatný INIT FSM
refresh_manager.sv        // refresh kredity
timing_manager.sv         // tRCD/tRP/tRAS/tRFC/tWR/tWTR
bank_machine.sv           // open-row tracking
sdram_model_pro.sv        // použiteľný behavioral model
tb_sdram_top.sv           // pokus o scoreboard + bursty
```

---

## Najväčší problém: projekt je príliš ďaleko na `test_01`

Aktuálny `tb_sdram_top.sv` už testuje:

```text
single write/read
row hit
row miss
multi-bank
burst LEN=3
refresh stress
boundary addresses
bank pipeline
```

To je na prvý míľnik veľa. Ak niečo zlyhá, nebude jasné, či je chyba v:

```text
AXI handshaku
gearboxe
scheduleri
write engine
read engine
PHY valid pipeline
SDRAM modeli
refresh logike
bank_machine
```

Preto by som v novom SDRAM chate nezačínal tým, že opravujeme celý `tb_sdram_top.sv`.

Začal by som zúženým cieľom:

```text
sdram_test_01_init_refresh:
  sdram_init
  refresh_manager
  sdram_phy command output
  sdram_model_pro timing check
  žiadne AXI
  žiadne read/write
```

---

## Konkrétne nájdené riziká v aktuálnom RTL

### 1. `read_engine` metadata môžu byť posunuté o jeden read

V `sdram_system_top.sv` sa pri `read_issue` najprv latcheuje:

```systemverilog
issue_last_lat <= fifo_cmd.last;
issue_id_lat   <= fifo_cmd.id;
```

ale `read_engine` dostáva v tom istom cykle:

```systemverilog
.read_issue(read_issue),
.issue_id(issue_id_lat),
.issue_last(issue_last_lat),
```

To znamená, že FIFO v `read_engine` môže pri `read_issue` zachytiť **staré ID/last**, nie aktuálne `fifo_cmd.id/last`.

Bezpečnejšie riešenie:

```systemverilog
.issue_id   (fifo_cmd.id),
.issue_last (fifo_cmd.last)
```

alebo oneskoriť `read_issue` spolu s už zaregistrovanými meta dátami.

Toto je dôležité hlavne pre:

```text
AXI RID
AXI RLAST
burst read
viac transakcií po sebe
```

---

### 2. `read_engine` nemá plnú AXI backpressure ochranu

Aktuálne:

```systemverilog
if (s_axi_rready) s_axi_rvalid <= 1'b0;

if (phy_rdata_valid) begin
  ...
  s_axi_rvalid <= 1'b1;
end
```

Ak `s_axi_rready == 0` a z PHY príde ďalší read beat, môže dôjsť k prepísaniu `s_axi_rdata`.

Testbench má síce:

```systemverilog
s_axi_rready = 1'b1;
```

takže sa to nemusí prejaviť, ale pre knižnicu to nestačí.

Pre knižničnú verziu treba buď:

```text
R skid buffer
alebo zastaviteľný read datapath
alebo FIFO medzi PHY read gearboxom a AXI R kanálom
```

---

### 3. `write_engine` dáva AXI B response príliš skoro

`BVALID` sa generuje na základe dokončenia gearbox fázy:

```systemverilog
if (gb_phase1_done && gb_last_latch)
  s_axi_bvalid <= 1'b1;
```

To znamená: response prichádza po prijatí zápisu do vnútornej command/data FIFO logiky, nie nevyhnutne po reálnom SDRAM WRITE na zbernici.

Pre jednoduchý single-outstanding controller sa to dá tolerovať ako „accepted by controller“, ale pre robustnú AXI knižnicu by bolo čistejšie generovať `BVALID` až po skutočnom vydaní posledného SDRAM write halfwordu.

---

### 4. `memory_scheduler` má deklarovanú bank-pipeline optimalizáciu, ale bez reálneho FIFO lookaheadu

Komentár hovorí, že počas `ST_ACT_WAIT` vie scheduler pozrieť ďalší príkaz z FIFO a aktivovať inú banku.

Lenže rozhranie scheduleru má iba:

```systemverilog
in_cmd
in_valid
in_ready
```

To je bežný FIFO head, nie lookahead na ďalší prvok. Kým nie je `in_ready`, FIFO head ostáva stále ten istý príkaz.

Preto podmienka typu:

```systemverilog
in_cmd.addr.bank != bank_latched
```

pravdepodobne nikdy neuvidí „ďalší“ príkaz, ale stále ten istý head command.

Záver:

```text
bank pipeline optimalizácia je zatiaľ skôr návrhový zámer než spoľahlivo funkčná vlastnosť
```

Pre prvé míľniky by som ju vypol alebo ignoroval.

---

### 5. `sdram_model_pro.sv` je dobrý základ, ale nie je ešte „pravý rozhodca“

Model kontroluje veľa dôležitých vecí:

```text
tRCD
tRP
tRAS
tWR
tRFC
open-bank stav
read/write na zatvorenú banku
refresh s otvorenou bankou
CAS pipeline
```

Ale pre knižničné overenie by som doplnil:

```text
MRS decode/check
init sequence check
refresh interval/tREFI watchdog
DQ contention check
uninitialized read policy
DQM/byte mask support
fatal_on_error parameter
command trace export
```

Aktuálne je vhodný na prvé simulácie, ale môže dať falošné PASS pri niektorých chybách init/refresh režimu.

---

## Chýbajúce veci pre samostatný mini projekt

V ZIPe som nenašiel:

```text
STATUS.md
README.md
project.yaml
samostatný sim Makefile
jednoznačný filelist
```

Aktuálny `Makefile` obsahuje iba:

```make
include ../../Makefile.common
```

To znamená, že snapshot ešte nie je úplne prenosný samostatný podprojekt. Pre nový mini chat by som ako prvú praktickú úlohu spravil:

```text
examples/sdram_test_01/
  STATUS.md
  README.md
  project.yaml
  Makefile
  sim/filelist.f
  sim/tb_init_refresh.sv
```

---

## Odporúčaný najbližší míľnik

Najbližší správny míľnik nie je „opraviť celý AXI testbench“.

Najbližší míľnik má byť:

```text
sdram_test_01_init_refresh
```

### Cieľ

```text
Overiť iba:
  200 us init wait
  PRECHARGE ALL
  AUTO REFRESH x8
  MODE REGISTER SET
  init_done
  periodický refresh po init_done
```

### Použiť moduly

```text
sdram_pkg.sv
sdram_init.sv
refresh_manager.sv
sdram_phy.sv
sdram_model_pro.sv
sdram_cmd_trace.sv
```

### Nepoužiť zatiaľ

```text
axi_frontend.sv
axi_gearbox.sv
write_engine.sv
read_engine.sv
memory_scheduler.sv s bank pipeline
```

### Definition of done

```text
sim PASS:
  žiadne timing error z modelu
  command trace:
    NOP počas init wait
    PRE ALL
    REF x8
    MRS
    init_done
    periodic REF
  refresh interval sedí
  žiadne READ/WRITE
```

---

## Navrhovaný `STATUS.md` pre nový SDRAM mini projekt

Použil by som toto ako prvý obsah:

```text
# sdram_test_01 — SDRAM library bring-up

## Goal

Create a reusable SDR SDRAM controller library for socfw.
This mini project is independent from XFCP.

Target hardware:
- Board: QMTECH EP4CE55F23C8
- SDRAM: Winbond W9825G6KH-6
- Data width: 16-bit
- Initial clock target: 125 MHz

## Scope

This project focuses only on SDRAM controller development:
- init sequence
- timing manager
- refresh
- bank machine
- read/write engine
- AXI frontend
- simulation model
- hardware BIST smoke test

Out of scope:
- XFCP integration
- UDP transport
- mailbox
- CLI

## Snapshot

Input archive:

sdram_test_01.zip

SHA-256:

66ebf1c0e6f3e3426c84960c9664c75b97d7c0c1016d801287aed1bd02846088

## Current structure

RTL:
- rtl/sdram/sdram_system_top.sv
- rtl/sdram/memory_scheduler.sv
- rtl/sdram/timing_manager.sv
- rtl/sdram/sdram_phy.sv
- rtl/sdram/write_engine.sv
- rtl/sdram/read_engine.sv
- rtl/sdram/bank_machine.sv
- rtl/sdram/refresh_manager.sv
- rtl/sdram/sdram_init.sv
- rtl/sdram/sdram_pkg.sv

AXI:
- rtl/axi/axi_frontend.sv
- rtl/axi/axi_gearbox.sv

Simulation:
- sim/model/sdram_model_pro.sv
- sim/model/axil_slave_model.sv
- sim/tb_sdram_top.sv
- sim/sdram_cmd_trace.sv

## Milestones

### sdram_test_01_init_refresh

Status: TODO

Goal:
- verify init sequence and periodic refresh only

Pass criteria:
- PRECHARGE ALL observed
- AUTO REFRESH x8 observed
- MRS observed
- init_done asserted
- periodic refresh observed
- no timing violations from model

### sdram_test_02_single_rw

Status: TODO

Goal:
- one write and one read at fixed address without AXI complexity

### sdram_test_03_scheduler_rw

Status: TODO

Goal:
- scheduler, timing manager and bank machine verified with simple commands

### sdram_test_04_axi_single_rw

Status: TODO

Goal:
- AXI 32-bit single write/read through 16-bit SDRAM

### sdram_test_05_axi_burst_rw

Status: TODO

Goal:
- AXI burst write/read, RLAST/BVALID correctness, backpressure

### sdram_test_06_hw_bist

Status: TODO

Goal:
- FPGA smoke test with internal BIST and LED/error counter

## Known issues from initial static review

- read_engine metadata path may capture stale issue_id/issue_last
- read_engine does not yet safely handle AXI R backpressure
- write_engine BVALID may be generated before physical SDRAM write completion
- memory_scheduler bank-pipeline optimization needs real FIFO lookahead or removal
- sdram_model_pro needs stronger init/MRS/refresh validation
- project lacks standalone STATUS.md, README.md, project.yaml and sim Makefile

## Next step

Create tb_init_refresh.sv and reduce first milestone to init + refresh only.
```

---

## Môj odporúčaný ďalší krok

V novom chate by som začal presne týmto:

```text
Začíname mini projekt sdram_lib zo snapshotu sdram_test_01.zip.

Prvá úloha:
Nerob ešte AXI read/write.
Vytvor sdram_test_01_init_refresh:
- STATUS.md
- jednoduchý tb_init_refresh.sv
- sim filelist
- command trace
- overenie init sekvencie a periodického refreshu proti sdram_model_pro

Cieľ:
sim PASS bez timing violation.
```

Hlavný záver: **áno, oddeliť SDRAM do samostatného mini projektu je správne**. Tento ZIP má dobrý základ, ale treba ho vrátiť o krok späť na malé overiteľné míľniky. Teraz by som nezačínal opravou celého AXI topu, ale izolovaným `init_refresh` testom.
