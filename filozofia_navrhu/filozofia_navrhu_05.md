Toto je veľmi užitočný set vstupov. Z týchto troch príkladov je už celkom jasné, **čo má byť shared board descriptor** a **čo má byť projektová konfigurácia**.

Môj záver je:
tvoj nový `board_qmtech_ep4ce55.yaml` je **správny smer** a mal by sa stať základom nového `BoardPlugin/BoardDescriptor` modelu, lebo oddeľuje hardvérové fakty dosky od projektového intentu. To presne zodpovedá aj filozofii, ktorú tam máš napísanú: board YAML = hardvérové fakty, project config = čo je zapnuté a ako sa to použije.

Zároveň ale na projektových YAML je vidno, že dnes sa miešajú minimálne štyri vrstvy naraz:

* identita projektu a build paths,
* aktivácia board features,
* inštancovanie modulov/IP,
* clock/timing/toolchain detaily.

Nižšie ti navrhnem konkrétny split.

---

## 1. Čo by som určite ponechal v `board.yaml`

Tvoj board descriptor už dnes obsahuje presne ten typ údajov, ktoré majú byť **zdieľané medzi všetkými projektmi na rovnakom kite**:

* device identitu FPGA (`family`, `part`, package, speed),
* systémový clock a reset vrátane pinu, polarity a electrical štandardu,
* onboard periférie ako fyzické zdroje dosky: LED, seg, dig, buttons, UART, VGA…, vrátane pin mapy, šírky a smeru,
* defaultné názvy top-level portov ako hardware-facing defaults (`soc_top_name`),
* voliteľné názvy výstupných board artefaktov (`output_files`).

To všetko by som v novom frameworku ponechal.

### Ale jednu vec by som z board YAML odstránil alebo aspoň degradoval

`enabled_var` je dnes viazaný na starý TCL chain a generated config štýl. To je skôr **legacy toolchain detail**, nie hardvérový fakt dosky. V board deskriptore by som ho nedržal ako primárny koncept. Môže existovať len ako voliteľná metadata pre Quartus emitter, ale nie ako centrálna semantika board modelu.

Inými slovami:

* `pin`, `width`, `dir`, `standard` = board fact
* `enabled_var` = emitter/toolchain compatibility metadata

---

## 2. Čo do `board.yaml` nepatrí

Do shared board opisu by som **nedával**:

* ktoré bloky sú v projekte zapnuté,
* ktoré PMOD moduly chce projekt použiť,
* aký IP modul sa pripája na LED alebo SDRAM,
* aké clock domains si projekt odvádza z PLL,
* SDC constraints špecifické pre konkrétny dizajn.

Napríklad v SDRAM projekte je správne, že samotný board vie, že SDRAM piny fyzicky existujú, ale **nepatrí do board.yaml**, že dizajn používa PLL 100 MHz a phase-shifted SDRAM clock. To je už projektová a timingová vec.

---

## 3. Čo ukazujú tvoje tri projekty

### Blink test 01

Je to minimálny standalone projekt:

* board reference,
* zapnuté onboard LEDs,
* jeden modul `blink_test`,
* fixed 50 MHz system clock cez `soc.clock_freq`.

To je pekný príklad, že projekt potrebuje vedieť:

* **čo chce robiť**,
* **ktoré board features aktivuje**,
* **aké moduly inštancuje**.

### Blink test 02 s PLL

Tu sa ukazuje už zložitejší prípad:

* `clkpll` ako standalone IP,
* viac inštancií blink testu,
* rôzne clock domains (`clk_100mhz`, `sys_clk`),
* port overrides vrátane rename, width adaptation a padding.

Toto je veľmi dôležité, lebo ukazuje, že nový systém musí mať explicitnú vrstvu pre:

* **clock domain graph**,
* **external port binding**,
* **width adapters/pad policies**.

### SDRAM projekt

Tu už vidno:

* board feature enable (`sdram`, `leds`, `buttons`),
* PLL so špeciálnym clock tree,
* timing config s generated clocks, phase shiftom, false path politikou a IO delays,
* IP plugin paths.

To znamená, že projektový YAML v2 musí vedieť modelovať:

* build environment / plugin registry sources,
* elaborované clocky,
* závislosti medzi modulmi a doménami,
* timing policy a overrides.

---

## 4. Odporúčaný split: shared board vs project

Ja by som to rozdelil takto.

### A. `board/<board>.yaml`

Toto je zdieľaný, read-only board descriptor.

Obsah:

* `board.id`
* `fpga.device`
* `system.clock`
* `system.reset`
* `resources.onboard.*`
* `resources.connectors.*`
* `resources.memory_devices.*`
* `constraints.defaults`
* voliteľne `toolchains.quartus`

Čiže skôr:
**čo doska fyzicky má**.

### B. `project.yaml`

Toto je design intent.

Obsah:

* `project`
* `imports/plugins`
* `board.ref`
* `features.enable`
* `design.modules`
* `design.bindings`
* `clocks`
* `timing`
* `artifacts`

Čiže:
**čo chce konkrétny projekt použiť a ako**.

---

## 5. Ako by som upravil tvoj board descriptor

Tvoj aktuálny board návrh by som upravil približne takto:

```yaml
version: 2
kind: board

board:
  id: qmtech_ep4ce55
  vendor: QMTech
  title: QMTech EP4CE55F23C8

fpga:
  family: "Cyclone IV E"
  part: EP4CE55F23C8
  package: FBGA
  pins: 484
  speed: 8
  hdl_default: SystemVerilog_2005

system:
  clock:
    name: sys_clk
    top_name: SYS_CLK
    pin: T2
    io_standard: "3.3-V LVTTL"
    frequency_hz: 50000000
    period_ns: 20.0

  reset:
    name: sys_reset_n
    top_name: RESET_N
    pin: W13
    io_standard: "3.3-V LVTTL"
    active_low: true

resources:
  onboard:
    leds:
      top_name: ONB_LEDS
      direction: output
      width: 6
      io_standard: "3.3-V LVTTL"
      pins:
        5: A6
        4: B7
        3: A7
        2: B8
        1: A8
        0: E4

    seg:
      top_name: ONB_SEG
      direction: output
      width: 8
      io_standard: "3.3-V LVTTL"
      pins:
        7: A4
        6: B1
        5: B4
        4: A5
        3: C3
        2: A3
        1: B2
        0: C4

    uart:
      io_standard: "3.3-V LVTTL"
      signals:
        rx:
          top_name: UART_RX
          direction: input
          pin: J2
        tx:
          top_name: UART_TX
          direction: output
          pin: J1

    sdram:
      type: sdram
      io_standard: "3.3-V SSTL-2 Class I"
      signal_groups:
        addr:
          top_name: SDRAM_ADDR
          direction: output
          width: 13
          pins: ...
        dq:
          top_name: SDRAM_DQ
          direction: inout
          width: 16
          pins: ...
        # ...
  connectors:
    pmod:
      J10:
        pins:
          1: H1
          2: F1
          3: E1
          4: C1
          7: H2
          8: F2
          9: D2
          10: C2
      J11:
        pins:
          1: R1
          2: P1
          3: N1
          4: M1
          7: R2
          8: P2
          9: N2
          10: M2
```

Toto je podľa mňa čistejšie než držať `enabled_var` ako kľúčový atribút.

---

## 6. Odporúčaný `project.yaml` v2

Na základe tvojich troch príkladov by som projektovú konfiguráciu zjednotil asi takto:

```yaml
version: 2
kind: project

project:
  name: blink_test_02
  mode: standalone
  board: qmtech_ep4ce55
  board_file: ../../../config/board_qmtech_ep4ce55.yaml
  output_dir: build/gen
  debug: true

plugins:
  ip_search_paths:
    - cores
    - ../../../src/ip

features:
  onboard:
    leds: true
  connectors:
    pmod:
      J10: led8
      J11: led8

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk

  generated:
    - domain: clk_100mhz
      source:
        instance: clkpll
        output: c0
      frequency_hz: 100000000
      reset:
        sync_from: sys_clk
        sync_stages: 2

modules:
  - instance: clkpll
    type: clkpll
    clocks:
      inclk0: sys_clk

  - instance: blink_01
    type: blink_test
    clocks:
      SYS_CLK: clk_100mhz
    params:
      CLK_FREQ: 100000000
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds

  - instance: blink_02
    type: blink_test
    clocks:
      SYS_CLK: clk_100mhz
    params:
      CLK_FREQ: 100000000
    bind:
      ports:
        ONB_LEDS:
          target: board:connector.J10
          top_name: PMOD_J10
          width: 8
          adapt: replicate

  - instance: blink_03
    type: blink_test
    clocks:
      SYS_CLK: sys_clk
    params:
      CLK_FREQ: 50000000
    bind:
      ports:
        ONB_LEDS:
          target: board:connector.J11
          top_name: PMOD_J11
          width: 8
          adapt: zero

timing:
  file: timing_config.yaml

artifacts:
  emit: [rtl, timing, board, docs]
```

Toto zjednocuje:

* starý `modules`,
* `port_overrides`,
* `onboard`,
* clock mappings,
* board usage.

---

## 7. Čo je v tvojich príkladoch trochu problémové

Vidím niekoľko konkrétnych miest, kde by som nový formát sprísnil.

### Nejednotnosť kľúčov

V jednom projekte používaš `plugins.ip`, v inom `paths.ip_plugins`. To by sa malo zjednotiť na jednu sekciu.

### Nejednotnosť modulu

V `blink_test_01` máš modul definovaný cez `module: blink_test`, v ďalších cez `type: blink_test`. Aj toto by malo byť len jedno. Ja by som nechal `type`.

### Board enable vs explicitné bindingy

`onboard.leds: true` je dobré ako feature activation, ale samotné mapovanie modulu na board resource by malo byť explicitné cez binding. Inak sa systém príliš spolieha na implicitné názvy portov.

### PMOD ako feature alias

`pmod_j10_led8: true` a `pmod_j11_led8: true` je praktické, ale architektonicky je to len alias pre:

* connector J10 activated,
* bound resource class `led8`.

Lepšie by bolo mať to explicitne v sekcii connector usage.

### `soc.clock_freq`

V minimálnom blink teste je to vlastne clock policy, nie SoC definícia. Pri v2 by som to presunul do `clocks.primary.frequency_hz` alebo jednoducho nechal brať z boardu, ak projekt nepotrebuje override.

---

## 8. SDRAM a timing: čo patrí kde

Tvoj SDRAM timing config je dobrý príklad toho, čo by som nechal mimo board YAML a mimo hlavného project YAML ako samostatnú, ale referencovanú vrstvu. Obsahuje totiž:

* source board clock,
* PLL generated clocks,
* clock groups,
* IO delay overrides pre konkrétny dizajn, nie pre všetky projekty na doske.

To znamená:

### Do board YAML:

* že doska má SDRAM resource a aké má piny/štandardy.

### Do project YAML:

* že projekt chce SDRAM použiť.

### Do timing YAML:

* že tento konkrétny dizajn používa PLL 2×, phase shift a špecifické IO delays.

To je správny trojvrstvový split.

---

## 9. PLL IP a clock-output IP model

`clkpll.ip.yaml` ukazuje ďalší dôležitý pattern: IP, ktoré negeneruje bus/registers, ale generuje interné clock outputs a status signály. To je presne dôvod, prečo v novom modeli potrebuješ **prvotriedny clock/output interface typ**, nie len všeobecný ext port mechanizmus.

Odporúčam, aby v IP registry existovali explicitné typy rozhraní:

* `external_port`
* `clock_input`
* `clock_output`
* `reset_input`
* `reset_output`
* `stream_interface`
* `memory_interface`
* `bus_slave`
* `bus_master`

Tým sa vyhneš tomu, že clock output bude len „ďalší wire s menom“.

---

## 10. Čo by som spravil so starým `tcl.py`

Starý `tcl.py` má dnes hardcodovanú BSP pin databázu priamo v kóde. Po novom by som ju úplne presunul do board descriptor/pluginu a `tcl.py` by sa stal len emitterom z `BoardIR`. To je priamo v súlade s tvojím novým board YAML návrhom.

To znamená:

* `_ONB_PINS`, `_PMOD_PINS`, `_ONB_IO_STD` už nebudú v generátore,
* ale v board plugine/deskriptore,
* emitter ich len vyrenderuje do Quartus TCL.

---

## 11. Konkrétny odporúčaný model: tri input súbory

Na základe toho, čo si poslal, by som pre nový framework odporučil stabilný model troch vstupov:

### 1. Shared board descriptor

`boards/qmtech_ep4ce55.board.yaml`

Obsahuje:

* hardware facts,
* connectors,
* onboard resources,
* electrical defaults.

### 2. Project descriptor

`projects/blink_test_02.project.yaml`

Obsahuje:

* modules,
* bindings,
* features,
* artifacts,
* plugin search paths,
* board reference.

### 3. Timing descriptor

`projects/blink_test_02.timing.yaml`

Obsahuje:

* clock derivations,
* generated clocks,
* groups,
* false paths,
* IO delays,
* multicycles.

To sedí aj na tvoje existujúce rozdelenie `project_config.yaml` + `timing_config.yaml`, len by som ho zjednotil a sprísnil.

---

## 12. Môj odporúčaný finálny split

Stručne:

### Ponechať v board YAML

* FPGA device
* system clock/reset pins
* onboard resources
* connector resources
* memory device pinout
* electrical standards
* default top-level port names

### Presunúť z board YAML preč

* enabled flags
* project feature toggles
* generated_config/TCL control variables ako hlavný koncept

### Ponechať v project YAML

* design name/mode
* board reference
* plugin/ip paths
* feature enablement
* module instances
* clock bindings
* external port bindings
* artifact selection

### Ponechať v timing YAML

* generated clocks
* PLL relationships
* clock groups
* IO delay overrides
* false paths
* multicycle rules

---

## 13. Môj praktický verdict k tvojmu board návrhu

Tvoj board návrh by som hodnotil takto:

* **veľmi dobrý smer** ako shared hardware descriptor,
* vhodný kandidát na nový `BoardPlugin` source of truth,
* lepší než dnešná hardcoded BSP databáza v `tcl.py`,
* ešte by som ho viac očistil od legacy/generated-config semantiky,
* a premenil by som ho z „board + trochu toolchain metadata“ na čisté „board resources model“.

Najväčšia hodnota tvojho board YAML je, že už prirodzene zavádza koncept:
**board resource ako objekt s vlastnosťami**, nie len tabuľku pinov.
To je presne to, čo nový framework potrebuje.

Ak chceš, v ďalšom kroku ti môžem rovno pripraviť:
**finálny návrh troch konkrétnych YAML v2 súborov** pre tieto tvoje prípady:

1. `qmtech_ep4ce55.board.yaml`
2. `blink_test_01.project.yaml`
3. `blink_test_02.project.yaml`
4. `sdram_test.project.yaml` + `sdram_test.timing.yaml`
