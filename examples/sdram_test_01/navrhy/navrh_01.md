Áno — toto je presne moment, kde sa oplatí spraviť **mini projekt / podprojekt**, inak sa hlavný XFCP chat začne miešať so SDRAM problémami a stratíme prehľad.

Priložený snapshot viem použiť ako štart:

```text
sdram_test_01.zip
SHA-256: 66ebf1c0e6f3e3426c84960c9664c75b97d7c0c1016d801287aed1bd02846088
Obsah: 37 položiek
```

Vidím tam už samostatnú štruktúru:

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

sim/model/
  sdram_model_pro.sv
  axil_slave_model.sv
```

To je dobrý základ na samostatný SDRAM podprojekt.

---

# Ako by som to celé rozdelil

Hlavný projekt nech zostane:

```text
XFCP knižnica:
  transport
  protocol
  AXIL
  STREAM
  MEM
  mailbox
  CLI
```

Nový mini projekt nech je:

```text
SDRAM knižnica:
  SDRAM init
  timing manager
  refresh
  bank machine
  read/write engine
  AXI/AXIL frontend
  sim model
  FPGA smoke test
```

A až potom sa spraví integračný projekt:

```text
XFCP + SDRAM:
  XFCP MEM_READ/MEM_WRITE
  -> AXI-Full
  -> SDRAM controller
  -> SDRAM chip
```

Teda nie rovno všetko do jedného chatu.

---

# Navrhovaná organizácia chatov

## Chat 1 — hlavný XFCP chat

Tento chat by som nechal ako **architektonický a integračný denník**.

Používať ho na:

```text
roadmap
tagy
rozhodnutia
prechod XFCP <-> SDRAM
výber ďalšieho míľnika
stav knižnice
```

Nepoužívať ho na detailné debugovanie každého SDRAM FSM signálu.

---

## Chat 2 — mini projekt: SDRAM controller

Nový chat by som pomenoval napríklad:

```text
socfw SDRAM library — sdram_test_01
```

Účel:

```text
vyčistiť a overiť SDRAM knižnicu nezávisle od XFCP
```

V tomto chate by sme riešili iba:

```text
SDRAM init sequence
refresh
activate/read/write/precharge
bank/row/col mapping
CAS latency
burst length
DQ tri-state
simulation against sdram_model_pro
timing na CLK100/CLK125
```

Výstup z chatu by bol tag:

```text
sdram_lib_v0_1_sim_pass
sdram_lib_v0_2_hw_smoke_pass
sdram_lib_v0_3_axi_pass
```

---

## Chat 3 — integrácia XFCP + SDRAM

Až keď bude SDRAM samostatne overená, otvoril by som tretí mini chat:

```text
socfw XFCP SDRAM integration
```

Účel:

```text
pripojiť XFCP MEM backend na SDRAM cez AXI-Full/AXI-like rozhranie
```

Výstup:

```text
xfcp_sdram_test_01
host mem-write -> SDRAM -> host mem-read
UART+UDP PASS
timing PASS
```

---

# Ako zabrániť nabaľovaniu chatu

Najlepšie funguje pravidlo **handoff dokumentu**.

Na začiatku každého mini chatu vložíš krátky „project handoff“, nie celú históriu. Napríklad:

```text
Projekt: sdram_lib
Board: QMTECH EP4CE55F23C8
Chip: Winbond W9825G6KH-6, 16-bit SDRAM
Clock target: 100 MHz alebo 125 MHz
Cieľ fázy: samostatne overiť SDRAM controller v simulácii
Vstupný ZIP: sdram_test_01.zip, SHA-256 ...
Neriešiť: XFCP, UDP, CLI, CPU mailbox
Definition of done:
  sim PASS
  timing PASS
  status.md aktualizovaný
```

Takto nový chat nebude potrebovať 100 strán histórie.

---

# Filozofia vývoja, ktorú by som zachoval

Presne tú istú disciplínu ako pri XFCP:

```text
1. malý míľnik
2. jasný STATUS.md
3. sim PASS
4. timing PASS
5. HW PASS, ak sa dá
6. tag
7. až potom ďalší krok
```

Žiadne „asi to funguje“.

Pre SDRAM by som navrhol tieto míľniky:

---

## `sdram_test_01_init_refresh`

Cieľ:

```text
iba INIT + REFRESH + NOP timing
```

Overiť:

```text
power-up wait
PRECHARGE ALL
AUTO REFRESH x2
MODE REGISTER SET
periodický refresh
```

Definition of done:

```text
sim model nehlási timing violation
command trace sedí
refresh interval sedí
žiadne READ/WRITE ešte neriešiť
```

---

## `sdram_test_02_single_rw`

Cieľ:

```text
jeden zápis a jedno čítanie na fixnú adresu
```

Overiť:

```text
ACTIVATE
WRITE
PRECHARGE
ACTIVATE
READ
CAS latency
DQ tri-state
read data == written data
```

Definition of done:

```text
sim PASS: 32-bit alebo 16-bit pattern write/read
```

---

## `sdram_test_03_burst_rw`

Cieľ:

```text
burst length 4/8
```

Overiť:

```text
sequential write burst
sequential read burst
byte/word ordering
row/column increment
```

---

## `sdram_test_04_refresh_under_load`

Cieľ:

```text
refresh sa správne vkladá medzi transakcie
```

Overiť:

```text
refresh_pending
no command collision
read/write nezničí refresh timing
```

---

## `sdram_test_05_axi_frontend`

Cieľ:

```text
AXI-like alebo AXI-Full frontend pred SDRAM
```

Overiť:

```text
AXI write burst -> SDRAM write
AXI read burst -> SDRAM read
backpressure
aligned transfer
```

---

## `sdram_test_06_hw_smoke`

Cieľ:

```text
FPGA smoke test bez XFCP alebo s minimálnym UART/LED diagnostickým testom
```

Napríklad:

```text
interný BIST:
  fill pattern
  readback
  error counter
  LED PASS/FAIL
```

---

## `xfcp_sdram_test_01`

Až potom:

```text
XFCP MEM_READ/MEM_WRITE -> SDRAM
```

Toto bude integračný míľnik, nie SDRAM debugging míľnik.

---

# Čo má byť v každom mini projekte

Odporúčaná štruktúra:

```text
examples/sdram_test_01/
  STATUS.md
  project.yaml
  Makefile
  rtl/
  sim/
  ip/
  tools/
  README.md
```

A `STATUS.md` musí mať vždy:

```text
Cieľ
Aktuálny stav
Čo je PASS
Čo je FAIL
Timing
Sim výsledky
HW výsledky
Known issues
Ďalší krok
```

Toto je to, čo nám pri XFCP veľmi pomohlo.

---

# Ako prepojiť mini chaty

Na konci SDRAM mini chatu treba vytvoriť krátky výstup:

```text
SDRAM handoff summary
```

Napríklad:

```text
SDRAM_LIB v0.3
Tag: sdram_lib_v0_3_axi_pass
Clock: 100 MHz
Data width: 16-bit SDRAM, AXI side 32-bit
Max burst: 256 B
Address mapping:
  bank = addr[...]
  row  = addr[...]
  col  = addr[...]
Known limits:
  aligned only
  single outstanding
  no unaligned byte writes yet
Integration recommendation:
  connect XFCP MEM adapter to SDRAM AXI frontend
```

Potom tento krátky handoff vložíš do hlavného XFCP/SDRAM integration chatu. Nie celú históriu.

---

# Čo by som spravil teraz s `sdram_test_01.zip`

Nešiel by som rovno na XFCP integráciu.

Najprv by som otvoril samostatný mini chat:

```text
SDRAM library — analysis of sdram_test_01
```

Prvá úloha v ňom:

```text
Analyzuj sdram_test_01.zip:
- štruktúru RTL
- či je návrh monolit alebo modulárny
- sim testy
- command timing
- model sdram_model_pro
- čo je najbližší overiteľný míľnik
- čo treba vyhodiť/upratať pred knižnicou
```

A do úvodnej správy vlož:

```text
Cieľ: vytvoriť SDRAM knižnicu kompatibilnú so socfw a neskôr ju pripojiť na XFCP MEM backend.
Nerieš teraz XFCP integráciu, iba SDRAM controller.
```

---

# Môj odporúčaný konkrétny štartovací prompt pre nový chat

Môžeš použiť toto:

```text
Začíname samostatný mini projekt: sdram_lib.

Cieľ:
Vytvoriť znovupoužiteľnú SDRAM knižnicu pre socfw, neskôr pripojiteľnú k XFCP MEM backendu.

Hardvér:
QMTECH EP4CE55F23C8, SDRAM Winbond W9825G6KH-6, 16-bit data bus.

Filozofia vývoja:
Rovnako ako pri XFCP: malé míľniky, STATUS.md, sim PASS, timing PASS, HW PASS, až potom tag. Nechcem miešať SDRAM debug do hlavného XFCP chatu.

Vstupný snapshot:
sdram_test_01.zip
SHA-256: 66ebf1c0e6f3e3426c84960c9664c75b97d7c0c1016d801287aed1bd02846088

Úloha:
Analyzuj aktuálnu štruktúru SDRAM projektu, urč najbližší malý míľnik, rozdeľ controller na knižničné bloky a navrhni postup overenia v simulácii. Zatiaľ nerieš XFCP integráciu.
```

---

# Ako často sa vracať do hlavného chatu

Do hlavného chatu by si nosil len výsledky typu:

```text
sdram_test_01_init_refresh PASS
sdram_test_02_single_rw PASS
sdram_test_03_axi_frontend PASS
```

A keď bude SDRAM pripravená:

```text
Mám sdram_lib_v0_3_axi_pass, chcem ju pripojiť k XFCP MEM backendu.
```

Vtedy tu otvoríme integračný plán.

---

## Záver

Áno, sprav SDRAM ako samostatný mini projekt.

Najlepší smer:

```text
1. nový chat: SDRAM knižnica
2. analyzovať sdram_test_01.zip
3. uzavrieť SDRAM sim/HW míľniky
4. až potom nový integračný chat: XFCP + SDRAM
```

Tým zachováme filozofiu XFCP vývoja, ale chat sa nebude nabaľovať detailmi refresh FSM, CAS latency a DQ timing, ktoré patria do samostatného SDRAM kontextu.
