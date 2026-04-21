Super, toto doplnenie pomáha dotiahnuť návrh do realistickej finálnej podoby.

Z tvojich vstupov už vychádza pomerne jasný cieľový model:

* **board YAML** je shared hardware descriptor pre kit, nie projektový config, čo presne sedí s tvojím návrhom board súboru.
* **project YAML** má niesť design intent: ktoré moduly sa inštancujú, ktoré board resources sa používajú a ako sa bindujú. To vidno na `blink_test_01`, `blink_test_02` aj `sdram_test`.
* **timing YAML** má zostať samostatný pre dizajnovo-špecifické generated clocks, phase shift a IO constraints. To je jasne vidieť na SDRAM timing configu.
* **vendor-generated IP** ako `clkpll` a `sdram_fifo` nemajú byť modelované ako obyčajné „cores“, ale ako IP descriptors s `origin`, `artifacts` a planner-visible semantikou.

Nižšie je moja odporúčaná **finálna YAML v2 sada** pre tvoje prípady.

---

# 1. `qmtech_ep4ce55.board.yaml`

Toto by som použil ako shared board descriptor pre všetky projekty na tej istej doske.

```yaml
version: 2
kind: board

board:
  id: qmtech_ep4ce55
  vendor: QMTech
  title: QMTech EP4CE55F23C8 Development Board

fpga:
  family: "Cyclone IV E"
  part: EP4CE55F23C8
  package: FBGA
  pins: 484
  speed: 8
  hdl_default: SystemVerilog_2005

toolchains:
  quartus:
    family: "Cyclone IV E"
    device: EP4CE55F23C8

system:
  clock:
    id: sys_clk
    top_name: SYS_CLK
    pin: T2
    io_standard: "3.3-V LVTTL"
    frequency_hz: 50000000
    period_ns: 20.0

  reset:
    id: sys_reset_n
    top_name: RESET_N
    pin: W13
    io_standard: "3.3-V LVTTL"
    active_low: true
    weak_pull_up: true

resources:
  onboard:
    leds:
      kind: gpio_out
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
      kind: seg7_segments
      top_name: ONB_SEG
      direction: output
      width: 8
      io_standard: "3.3-V LVTTL"
      comment: "7-segment PGFEDCBA, dot not wired"
      pins:
        7: A4
        6: B1
        5: B4
        4: A5
        3: C3
        2: A3
        1: B2
        0: C4

    dig:
      kind: seg7_digit_select
      top_name: ONB_DIG
      direction: output
      width: 3
      io_standard: "3.3-V LVTTL"
      pins:
        2: B6
        1: B3
        0: B5

    buttons:
      kind: gpio_in
      top_name: ONB_BUTTON
      direction: input
      width: 6
      io_standard: "3.3-V LVTTL"
      weak_pull_up: true
      pins:
        5: B9
        4: A9
        3: B10
        2: A10
        1: AA13
        0: Y13

    uart:
      kind: uart
      io_standard: "3.3-V LVTTL"
      signals:
        rx:
          top_name: UART_RX
          direction: input
          pin: J2
          weak_pull_up: true
        tx:
          top_name: UART_TX
          direction: output
          pin: J1

    sdram:
      kind: sdram
      model: "W9825G6KH-6 compatible"
      io_standard: "3.3-V SSTL-2 Class I"
      signals:
        clk:   { top_name: SDRAM_CLK,   direction: output, pin: Y6 }
        cke:   { top_name: SDRAM_CKE,   direction: output, pin: W6 }
        cs_n:  { top_name: SDRAM_CS_N,  direction: output, pin: AA3 }
        ras_n: { top_name: SDRAM_RAS_N, direction: output, pin: AB3 }
        cas_n: { top_name: SDRAM_CAS_N, direction: output, pin: AA4 }
        we_n:  { top_name: SDRAM_WE_N,  direction: output, pin: AB4 }
      groups:
        dqm:
          top_name: SDRAM_DQM
          direction: output
          width: 2
          pins:
            1: W7
            0: AA5
        dq:
          top_name: SDRAM_DQ
          direction: inout
          width: 16
          pins:
            15: V11
            14: W10
            13: Y10
            12: V10
            11: V9
            10: Y8
            9: W8
            8: Y7
            7: AB5
            6: AA7
            5: AB7
            4: AA8
            3: AB8
            2: AA9
            1: AB9
            0: AA10
        addr:
          top_name: SDRAM_ADDR
          direction: output
          width: 13
          pins:
            12: V6
            11: Y4
            10: W1
            9: V5
            8: Y3
            7: AA1
            6: Y2
            5: V4
            4: V3
            3: U1
            2: U2
            1: V1
            0: V2
        ba:
          top_name: SDRAM_BA
          direction: output
          width: 2
          pins:
            1: W2
            0: Y1

  connectors:
    pmod:
      J10:
        roles:
          led8:
            top_name: PMOD_J10
            direction: output
            width: 8
            io_standard: "3.3-V LVTTL"
            pins:
              7: H1
              6: H2
              5: F1
              4: F2
              3: E1
              2: D2
              1: C1
              0: C2

      J11:
        roles:
          led8:
            top_name: PMOD_J11
            direction: output
            width: 8
            io_standard: "3.3-V LVTTL"
            pins:
              7: R1
              6: R2
              5: P1
              4: P2
              3: N1
              2: N2
              1: M1
              0: M2
```

Toto je prirodzený vývoj tvojho board návrhu: shared hardware facts, bez toho, aby bol board descriptor previazaný na legacy `enabled_var` ako centrálny koncept. Pritom vychádza priamo z tvojho board súboru a dnešnej BSP pin databázy.

---

# 2. `blink_test_01.project.yaml`

Z tvojho minimálneho projektu je vidno, že ide len o jednoduchý standalone modul s LED resource a 50 MHz board clockom.

```yaml
version: 2
kind: project

project:
  name: blink_test_01
  mode: standalone
  board: qmtech_ep4ce55
  board_file: ../../../board/qmtech_ep4ce55.board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - ../../../src/ip

features:
  use:
    - board:onboard.leds

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk

modules:
  - instance: blink_test
    type: blink_test
    clocks:
      SYS_CLK: sys_clk
    params:
      CLK_FREQ: 50000000
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds

artifacts:
  emit: [rtl, board, docs]
```

Týmto sa odstránia staré nejednotnosti ako `paths.ip_plugins`, `soc.clock_freq` a `module:` namiesto `type:`.

---

# 3. `blink_test_02.project.yaml`

Toto je dobrý referenčný príklad pre:

* vendor-generated PLL IP,
* viac modulových inštancií,
* clock domain binding,
* port adaptation na 8-bit PMOD.

```yaml
version: 2
kind: project

project:
  name: blink_test_02
  mode: standalone
  board: qmtech_ep4ce55
  board_file: ../../../config/qmtech_ep4ce55.board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - cores
    - ../../../src/ip

features:
  use:
    - board:onboard.leds
    - board:connector.pmod.J10.role.led8
    - board:connector.pmod.J11.role.led8

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
          target: board:connector.pmod.J10.role.led8
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
          target: board:connector.pmod.J11.role.led8
          top_name: PMOD_J11
          width: 8
          adapt: zero

timing:
  file: timing_config.yaml

artifacts:
  emit: [rtl, timing, board, docs]
```

Tu je dôležité, že pôvodné `port_overrides` sa menia na explicitné `bind.ports.*`, čo sa oveľa lepšie validuje aj reportuje. Pritom význam zostáva ten istý ako v tvojom pôvodnom súbore.

---

# 4. `sdram_test.project.yaml`

Tvoj SDRAM projekt ukazuje zložitejší clock/timing setup, vendor PLL IP a board resource enablement pre SDRAM, LEDs, buttons a PMOD debug výstupy.

```yaml
version: 2
kind: project

project:
  name: sdram_test
  mode: standalone
  board: qmtech_ep4ce55
  board_file: ../../../config/qmtech_ep4ce55.board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - ../cores
    - ../rtl
    - ../../../src/ip

features:
  use:
    - board:onboard.sdram
    - board:onboard.leds
    - board:onboard.buttons
    - board:connector.pmod.J10.role.led8
    - board:connector.pmod.J11.role.led8

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

    - domain: clk_100mhz_sh
      source:
        instance: clkpll
        output: c1
      frequency_hz: 100000000
      reset:
        none: true

modules:
  - instance: clkpll
    type: clkpll
    clocks:
      inclk0: sys_clk

  - instance: sdram_rtl_test
    type: sdram_rtl_test
    clocks:
      clk_i: clk_100mhz
      clk_i_sh:
        domain: clk_100mhz_sh
        no_reset: true
    params:
      TEST_WORDS: 256
      BLINK_DIV: 50000000
      SLOW_DIV: 25000000
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds
        ONB_BUTTON:
          target: board:onboard.buttons
        SDRAM:
          target: board:onboard.sdram
        PMOD_J10:
          target: board:connector.pmod.J10.role.led8
        PMOD_J11:
          target: board:connector.pmod.J11.role.led8

timing:
  file: sdram_test.timing.yaml

artifacts:
  emit: [rtl, timing, board, docs]
```

Tu by framework už mal vedieť, že `board:onboard.sdram` je komplexný resource bundle a rozvinie ho na `SDRAM_CLK`, `SDRAM_ADDR[*]`, `SDRAM_DQ[*]`, `SDRAM_BA[*]` atď. To prirodzene vychádza z tvojho board deskriptora.

---

# 5. `sdram_test.timing.yaml`

Zachoval by som samostatný timing súbor, lebo PLL-generated clocks, exclusive groups a SDRAM IO overrides sú jasne dizajnovo-špecifické.

```yaml
version: 2
kind: timing

timing:
  derive_uncertainty: true

  clocks:
    - name: sys_clk
      source: board:sys_clk
      period_ns: 20.0
      uncertainty_ns: 0.1
      reset:
        source: board:sys_reset_n
        active_low: true
        sync_stages: 2

  generated_clocks:
    - name: clk_100mhz
      source:
        instance: clkpll
        output: c0
      multiply_by: 2
      divide_by: 1
      reset:
        sync_from: sys_clk
        sync_stages: 2

    - name: clk_100mhz_sh
      source:
        instance: clkpll
        output: c1
      multiply_by: 2
      divide_by: 1
      phase_shift_ps: -3000

  clock_groups:
    - type: exclusive
      groups:
        - [sys_clk]
        - [clk_100mhz, clk_100mhz_sh]

  io_delays:
    auto: false
    overrides:
      - port: "SDRAM_ADDR[*]"
        direction: output
        clock: clk_100mhz_sh
        max_ns: 1.5
        min_ns: -0.8

      - port: "SDRAM_BA[*]"
        direction: output
        clock: clk_100mhz_sh
        max_ns: 1.5
        min_ns: -0.8

      - port: SDRAM_RAS_N
        direction: output
        clock: clk_100mhz_sh
        max_ns: 1.5
        min_ns: -0.8

      - port: SDRAM_CAS_N
        direction: output
        clock: clk_100mhz_sh
        max_ns: 1.5
        min_ns: -0.8

      - port: SDRAM_WE_N
        direction: output
        clock: clk_100mhz_sh
        max_ns: 1.5
        min_ns: -0.8

      - port: "SDRAM_DQ[*]"
        direction: output
        clock: clk_100mhz_sh
        max_ns: 1.5
        min_ns: -0.8

      - port: "SDRAM_DQ[*]"
        direction: input
        clock: clk_100mhz
        max_ns: 5.8
        min_ns: 2.2
```

Semanticky je to ten istý obsah ako tvoj dnešný timing config, len je pomenovaný konzistentnejšie a odviazaný od implicitného Quartus pin-path komentára v YAML. Quartus-specific pin path môže dopočítať planner/emitter z IP metadata.

---

# 6. `clkpll.ip.yaml` v2

Tvoj `clkpll` descriptor už dnes správne hovorí, že ide o vendor-generated Quartus IP, s `clk_output` semantikou, active-high resetom a tým, že reset sync sa má obísť.

Vo v2 by som ho zapísal takto:

```yaml
version: 2
kind: ip

ip:
  name: clkpll
  module: clkpll
  category: standalone

origin:
  kind: vendor_generated
  tool: quartus
  packaging: qip

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true

reset:
  port: areset
  active_high: true
  bypass_sync: true

clocking:
  primary_input:
    port: inclk0

  outputs:
    - port: c0
      kind: generated_clock
      default_domain: clk_100mhz
      comment: "100 MHz logic/fifo clock"

    - port: c1
      kind: generated_clock
      default_domain: clk_100mhz_sh
      comment: "100 MHz shifted SDRAM clock"

    - port: locked
      kind: status
      signal: pll_locked

artifacts:
  synthesis:
    - clkpll.qip
  simulation:
    - clkpll.v
    - clkpll_bb.v
  metadata:
    - clkpll.ppf
```

Toto je čistejší tvar než dnešný mix `files`, `port_map`, `interfaces` a komentárov, ale zachováva rovnakú informáciu.

---

# 7. `sdram_fifo.ip.yaml` v2

`Sdram_fifo` je iný typ prípadu: vendor-generated asset bundle, ale nie top-level priamo instantiate-nutý projektom. Tvoj komentár to hovorí celkom jasne.

```yaml
version: 2
kind: ip

ip:
  name: sdram_fifo
  module: sdram_fifo
  category: internal_dependency

origin:
  kind: vendor_generated
  tool: quartus
  packaging: qip

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: false
  dependency_only: true

reset:
  port: aclr
  active_high: true
  optional: true
  asynchronous: true

clocking:
  primary_input:
    port: wrclk

  additional_inputs:
    - port: rdclk
      kind: clock_input

artifacts:
  synthesis:
    - sdram_fifo.qip
  simulation:
    - sdram_fifo.v
    - sdram_fifo_bb.v

notes:
  - "Dual-clock FIFO, separate write/read domains"
  - "Internal submodule, not instantiated directly by soc_top"
```

Toto lepšie vystihuje, čo si do súboru doplnil: nie je to len obyčajný `standalone` blok, ale skôr dependency asset bundle s clock/reset semantikou.

---

# 8. Najdôležitejšie zmeny oproti dnešku

Z tvojich aktuálnych súborov by som vedome zjednotil tieto veci:

### `plugins.ip` vs `paths.ip_plugins`

Dnes máš v rôznych projektoch dva štýly. Vo v2 by som nechal iba `registries.ip`.

### `module:` vs `type:`

Vo v2 len `type:`.

### `port_overrides`

Vo v2 radšej `bind.ports`. Lepšie sa to validuje aj reportuje.

### `onboard.*: true`

Vo v2 by som to posunul na `features.use`, aby bolo jasné, že ide o aktiváciu board resources, nie len boolean prepínače.

### `files:` v IP descriptoroch

Vo v2 rozdeliť na `artifacts.synthesis`, `simulation`, `metadata`. To je obzvlášť dôležité pre vendor-generated IP.

---

# 9. Čo by som ponechal ako kompatibilitnú vrstvu pri migrácii

Počas prechodu by som ešte dočasne podporil:

* načítanie starých `project_config.yaml`,
* mapovanie `onboard.leds: true` → `features.use += board:onboard.leds`,
* mapovanie `port_overrides` → `bind.ports`,
* mapovanie `files:` → `artifacts.synthesis`,
* mapovanie `paths.ip_plugins` a `plugins.ip` → `registries.ip`.

Tak by sa staré projekty dali automaticky migrovať bez ručného prepisovania všetkého naraz.

---

# 10. Môj stručný verdict

Toto by som považoval za dobrý finálny kontrakt pre YAML v2:

* **board YAML** = fyzická doska a jej resources, zdieľané medzi projektmi, čo už dnes tvoj board návrh robí dobre.
* **project YAML** = design intent, moduly, bindings, feature usage, clocks.
* **timing YAML** = generované clocky a constraints pre konkrétny dizajn.
* **IP YAML** = jednotné descriptors pre source aj vendor-generated IP, s explicitným `origin` a `artifacts`.

A najdôležitejšia architektonická zmena je táto:

**Quartus-generated IP už nemá byť modelované ako „ďalší core adresár“, ale ako prvotriedny IP descriptor s asset bundle semantikou.**

Ak chceš, ďalší krok spravím veľmi praktický: pripravím ti **mapovanie starý YAML → nový YAML v2 po jednotlivých poliach**, aby z toho vedel vzniknúť aj automatický migrátor.
