Áno, bolo by veľmi dobré mať aj **AXI-Lite slave model s definovanou latenciou**. Aktuálny `axil_slave_model.sv` je skôr „fast/simple memory slave“. Je vhodný na základné overenie funkčnosti, ale nie je ideálny na testovanie robustnosti AXI-Lite mastera.

## Aktuálna latencia modelu

Podľa správania, ktoré sme analyzovali, model funguje približne takto:

### READ

Ak master dá `ARVALID=1` a slave má `ARREADY=1`, adresa sa prijme na hrane hodinového signálu.

Potom model nastaví `RVALID` a `RDATA` registrovane, takže najrýchlejší prípad je:

```text
cyklus N:
  ARVALID && ARREADY  → prijatie read adresy

cyklus N+1:
  RVALID=1, RDATA platné

cyklus N+2:
  ak RREADY=1, response sa odoberie na hrane
```

Z pohľadu mastera je teda read dátová odpoveď dostupná približne **1 cyklus po AR handshaku**.

---

### WRITE

Pri WRITE sa `AW` a `W` môžu prijať nezávisle.

Ak `AWVALID` aj `WVALID` prídu v rovnakom cykle:

```text
cyklus N:
  AWVALID && AWREADY
  WVALID  && WREADY
  → model si uloží adresu aj dáta ako pending

cyklus N+1:
  model vykoná zápis do RAM
  nastaví BVALID

cyklus N+2:
  ak BREADY=1, write response sa odoberie
```

Čiže minimálna write response latencia je približne **2 cykly od spoločného AW/W prijatia po odobratie B response**.

Ak `AW` a `W` prídu v rôznych cykloch, response sa oneskorí podľa toho, kedy príde druhý kanál.

---

# Prečo je dobré mať model s definovanou latenciou

Reálne AXI-Lite slave periférie nie vždy odpovedajú okamžite. Niektoré majú:

```text
- oneskorené AWREADY,
- oneskorené WREADY,
- oneskorené BVALID,
- oneskorené ARREADY,
- oneskorené RVALID,
- rôznu latenciu pre rôzne adresy,
- občasné backpressure.
```

Ak master testuješ iba proti rýchlemu slave modelu, môže sa stať, že neodhalíš chyby typu:

```text
- master nedrží AWADDR stabilné pri AWVALID && !AWREADY,
- master nedrží WDATA/WSTRB stabilné pri WVALID && !WREADY,
- master očakáva RVALID hneď ďalší cyklus,
- master nezvládne BVALID oneskorený o viac cyklov,
- master sa zasekne, keď WREADY príde skôr než AWREADY,
- master nevie spracovať ARREADY=0 niekoľko taktov.
```

Pre XFCP je toto dôležité hlavne pre `xfcp_axi_engine`, lebo ten musí správne zvládnuť pomalého alebo zaseknutého AXI-Lite slave.

---

# Odporúčané dva modely

Navrhol by som mať v sim knižnici dva samostatné modely:

```text
axil_slave_model.sv
  - jednoduchý, rýchly memory slave
  - vhodný pre základné testy

axil_latency_slave_model.sv
  - deterministický latency/backpressure model
  - vhodný pre overenie robustnosti mastera
```

Alternatívne môžeš mať jeden modul s parametrami, ale oddelené moduly budú čitateľnejšie.

---

# Návrh parametrov pre latency model

Použil by som niečo takéto:

```systemverilog
module axil_latency_slave_model #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned MEM_DEPTH  = 1024,

  // Latencia prijatia request kanálov
  parameter int unsigned AWREADY_DELAY = 0,
  parameter int unsigned WREADY_DELAY  = 0,
  parameter int unsigned ARREADY_DELAY = 0,

  // Latencia odpovedí po prijatí requestu
  parameter int unsigned BVALID_DELAY  = 0,
  parameter int unsigned RVALID_DELAY  = 0,

  // Správanie pamäte
  parameter bit CLEAR_MEM_ON_RESET = 1'b1,
  parameter bit ERROR_ON_OOR       = 1'b1,
  parameter string INIT_FILE       = ""
)(
  input  logic       clk_i,
  input  logic       rst_ni,
  axi4lite_if.slave  s_axil
);
```

Význam:

```text
AWREADY_DELAY:
  počet cyklov, počas ktorých slave drží AWREADY=0 pred prijatím AW

WREADY_DELAY:
  počet cyklov, počas ktorých slave drží WREADY=0 pred prijatím W

ARREADY_DELAY:
  počet cyklov, počas ktorých slave drží ARREADY=0 pred prijatím AR

BVALID_DELAY:
  počet cyklov medzi kompletným WRITE requestom a BVALID

RVALID_DELAY:
  počet cyklov medzi AR handshake a RVALID
```

---

# Príklad správania s latenciou

Napríklad:

```systemverilog
.AWREADY_DELAY(3),
.WREADY_DELAY (5),
.BVALID_DELAY (8),
.ARREADY_DELAY(2),
.RVALID_DELAY (6)
```

WRITE priebeh:

```text
cyklus N:
  master nastaví AWVALID/WVALID

cyklus N+3:
  slave dovolí AW handshake

cyklus N+5:
  slave dovolí W handshake

cyklus N+13:
  BVALID=1
```

READ priebeh:

```text
cyklus N:
  master nastaví ARVALID

cyklus N+2:
  ARVALID && ARREADY

cyklus N+8:
  RVALID=1, RDATA platné
```

Takýto model veľmi dobre preverí, či master korektne drží signály.

---

# Ešte lepšie: režimy latencie

Model by mohol mať parameter:

```systemverilog
parameter string LATENCY_MODE = "FIXED";
```

Podporované režimy:

```text
"ZERO"
  všetko odpovedá najrýchlejšie

"FIXED"
  použijú sa AWREADY_DELAY, WREADY_DELAY, ...

"RANDOM"
  oneskorenia sa náhodne menia v rozsahu 0..MAX_DELAY

"PATTERN"
  oneskorenia idú podľa pevného vzoru, napr. 0, 1, 5, 0, 10...
```

Pre začiatok stačí `FIXED`.

Neskôr by som pridal:

```systemverilog
parameter bit RANDOM_STALL = 1'b0;
parameter int unsigned MAX_RANDOM_DELAY = 16;
```

---

# Odporúčané testovacie profily pre XFCP

Pre `xfcp_axi_engine` by som testoval tieto konfigurácie:

## Profil 1 — ideálny slave

```systemverilog
AWREADY_DELAY = 0
WREADY_DELAY  = 0
BVALID_DELAY  = 0
ARREADY_DELAY = 0
RVALID_DELAY  = 0
```

Overí základnú funkčnosť.

---

## Profil 2 — oneskorený READ

```systemverilog
ARREADY_DELAY = 3
RVALID_DELAY  = 20
```

Overí, či `xfcp_axi_engine` čaká na read response a nestratí stav.

---

## Profil 3 — oneskorený WRITE response

```systemverilog
AWREADY_DELAY = 0
WREADY_DELAY  = 0
BVALID_DELAY  = 20
```

Overí, či engine korektne čaká na `BVALID`.

---

## Profil 4 — W pred AW

```systemverilog
AWREADY_DELAY = 10
WREADY_DELAY  = 0
```

Overí, či master zvládne, že dátový kanál sa prijme skôr než adresový.

---

## Profil 5 — AW pred W

```systemverilog
AWREADY_DELAY = 0
WREADY_DELAY  = 10
```

Overí opačný prípad.

---

## Profil 6 — timeout

```systemverilog
RVALID_DELAY = 100000
```

alebo špeciálny parameter:

```systemverilog
parameter bit NEVER_RESPOND_READ = 1'b1;
```

Overí, či `xfcp_axi_engine` vráti timeout/error a nezasekne fabric.

---

# Čo by som ponechal v jednoduchom modeli

Aktuálny `axil_slave_model.sv` by som nezahadzoval. Nechal by som ho ako rýchly RAM model:

```text
axil_slave_model.sv
  - simple
  - fast
  - minimum latency
  - vhodný pre smoke testy
```

A pridal nový:

```text
axil_latency_slave_model.sv
  - fixed/random latency
  - error responses
  - timeout test support
  - vhodný pre robustné testy masterov
```

---

# Dôležitá poznámka k AXI-Lite latencii

Pri AXI-Lite treba oddeliť dve latencie:

```text
1. request acceptance latency
   AWREADY/WREADY/ARREADY

2. response latency
   BVALID/RVALID
```

Napríklad slave môže hneď prijať adresu, ale odpovedať neskoro:

```text
ARREADY=1 hneď
RVALID až o 20 cyklov
```

Alebo môže dlho neprijať adresu:

```text
ARREADY=0 20 cyklov
potom ARREADY=1
RVALID hneď ďalší cyklus
```

Pre mastera sú to odlišné situácie. Dobrý model by mal vedieť testovať obe.

---

# Odporúčaná knižničná štruktúra

Do `sim/models` alebo `rtl/sim` by som dal:

```text
sim/models/
├── axil_slave_model.sv
├── axil_latency_slave_model.sv
├── sdram_model_pro.sv
└── uart_line_model.sv
```

V IP YAML by to malo byť označené ako simulation-only:

```yaml
simulation:
  sources:
    - sim/models/axil_slave_model.sv
    - sim/models/axil_latency_slave_model.sv
```

Nie ako syntetizovateľný RTL zdroj.

---

# Záver

Áno, určite by som pridal model s definovanou latenciou.

Aktuálny `axil_slave_model.sv` má približne:

```text
READ:
  AR handshake → RVALID asi o 1 cyklus

WRITE:
  AW/W handshake → BVALID približne o 1 ďalší cyklus,
  B response odobratá typicky o 2 cykly od AW/W handshaku
```

To je dobré na základné testy, ale nestačí na seriózne overenie mastera.

Odporúčam vytvoriť:

```text
axil_latency_slave_model.sv
```

s parametrami:

```text
AWREADY_DELAY
WREADY_DELAY
ARREADY_DELAY
BVALID_DELAY
RVALID_DELAY
ERROR_ON_OOR
NEVER_RESPOND_READ/WRITE alebo TIMEOUT_TEST_MODE
```

Tým budeš vedieť veľmi dobre overiť, či tvoje AXI-Lite mastery, hlavne `xfcp_axi_engine`, zvládajú reálne oneskorenia a backpressure.
