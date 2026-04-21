Áno. Nižšie je **praktická migračná mapa starý YAML → nový YAML v2**, rozdelená podľa typu súboru. Cieľ je, aby sa z toho dal spraviť aj automatický migrátor.

Najdôležitejšie zistenie je toto: staré súbory už implicitne rozlišujú board fakty, projektový intent, timing a IP metadata, ale hranice medzi nimi sú nejednotné. Napríklad board súbor sám hovorí, že je to read-only hardware definícia dosky a že projekt ho len referuje, zatiaľ čo projektové YAML miešajú design, paths/plugins, board enable flags a timing odkazy.

## 1. Board YAML: mapovanie polí

Tvoj nový `board_qmtech_ep4ce55.yaml` už dnes nesie správne shared informácie: device identitu, system clock/reset a onboard resources s default `soc_top_name`, smerom, šírkou a pinmi. To je presne to, čo má zostať v `*.board.yaml`.

### Mapovanie

| Staré pole                             | Nové pole v2                                                                   | Poznámka                                         |
| -------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------ |
| `device.family`                        | `fpga.family`                                                                  | priama migrácia                                  |
| `device.part`                          | `fpga.part`                                                                    | priama migrácia                                  |
| `device.package`                       | `fpga.package`                                                                 | priama migrácia                                  |
| `device.pins`                          | `fpga.pins`                                                                    | priama migrácia                                  |
| `device.speed`                         | `fpga.speed`                                                                   | priama migrácia                                  |
| `device.hdl`                           | `fpga.hdl_default`                                                             | premenovanie                                     |
| `output_files.*`                       | `toolchains.quartus.output_files.*` alebo odstrániť                            | skôr emitter metadata než board fact             |
| `system.clock.port`                    | `system.clock.top_name`                                                        | `port` je v2 lepšie pomenovať ako top-level name |
| `system.clock.pin`                     | `system.clock.pin`                                                             | priama migrácia                                  |
| `system.clock.standard`                | `system.clock.io_standard`                                                     | premenovanie                                     |
| `system.clock.period_ns`               | `system.clock.period_ns`                                                       | priama migrácia                                  |
| `system.clock.freq_mhz`                | `system.clock.frequency_hz`                                                    | konverzia MHz → Hz                               |
| `system.reset.port`                    | `system.reset.top_name`                                                        | premenovanie                                     |
| `system.reset.standard`                | `system.reset.io_standard`                                                     | premenovanie                                     |
| `onboard.<x>.soc_top_name`             | `resources.onboard.<x>.top_name`                                               | priama migrácia s presunom                       |
| `onboard.<x>.standard`                 | `resources.onboard.<x>.io_standard`                                            | premenovanie                                     |
| `onboard.<x>.width`                    | `resources.onboard.<x>.width`                                                  | priama migrácia                                  |
| `onboard.<x>.dir`                      | `resources.onboard.<x>.direction`                                              | premenovanie                                     |
| `onboard.<x>.pins`                     | `resources.onboard.<x>.pins`                                                   | priama migrácia                                  |
| `onboard.uart.signals.rx.soc_top_name` | `resources.onboard.uart.signals.rx.top_name`                                   | premenovanie                                     |
| `onboard.sdram.signals.*.soc_top_name` | `resources.onboard.sdram.signals.*.top_name`                                   | premenovanie                                     |
| `onboard.sdram.groups.*.soc_top_name`  | `resources.onboard.sdram.groups.*.top_name`                                    | premenovanie                                     |
| `enabled_var`                          | odstrániť z core modelu, voliteľne uložiť do `toolchains.quartus.conditions.*` | je to legacy toolchain väzba, nie hardware fakt  |

### Čo migrovať s transformáciou

`enabled_var` by som **nemigroval ako first-class board semantiku**. Je to väzba na starý generated-config/TCL flow, čo potvrdzuje aj samotný komentár v board YAML a dnešný Quartus generator. Lepšie je buď ho zahodiť, alebo uložiť len ako Quartus-specific metadata.

## 2. Project YAML: top-level mapovanie

Staré projekty používajú nejednotné top-level sekcie:

* `paths.ip_plugins` v blink teste 01,
* `plugins.ip` v blink teste 02 a SDRAM teste,
* `design.name/mode`, `board.type/file`, `onboard.*`, `timing.file`, `modules.*`.

### Mapovanie

| Staré pole              | Nové pole v2                          |
| ----------------------- | ------------------------------------- |
| `version`               | `version`                             |
| `debug`                 | `project.debug`                       |
| `design.name`           | `project.name`                        |
| `design.mode`           | `project.mode`                        |
| `board.type`            | `project.board`                       |
| `board.file`            | `project.board_file`                  |
| `paths.ip_plugins`      | `registries.ip`                       |
| `plugins.ip`            | `registries.ip`                       |
| `timing.file`           | `timing.file`                         |
| `onboard.*: true/false` | `features.use` zoznam board resources |

### Pravidlo pre `onboard.*`

Napríklad:

* `onboard.leds: true` → `features.use += ["board:onboard.leds"]`
* `onboard.buttons: true` → `features.use += ["board:onboard.buttons"]`
* `onboard.sdram: true` → `features.use += ["board:onboard.sdram"]`
* `pmod_j10_led8: true` → `features.use += ["board:connector.pmod.J10.role.led8"]`
* `pmod_j11_led8: true` → `features.use += ["board:connector.pmod.J11.role.led8"]`

To je presne konzistentné s tým, že board facts majú byť v board YAML a projekt len deklaruje, ktoré resources používa.

## 3. Project YAML: moduly a inštancie

Staré projekty majú dva štýly:

* blink_test_01: `modules.blink_test.module: blink_test` + `enabled: true`,
* blink_test_02 a SDRAM: `modules.<inst>.type: ...`, plus `clock_domains`, `params`, `port_overrides`.

### Nový cieľ

Všetko zjednotiť na zoznam:

```yaml
modules:
  - instance: blink_01
    type: blink_test
```

### Mapovanie

| Staré pole                     | Nové pole                                |
| ------------------------------ | ---------------------------------------- |
| `modules.<inst>.module`        | `modules[].type`                         |
| `modules.<inst>.type`          | `modules[].type`                         |
| key mena v `modules` mape      | `modules[].instance`                     |
| `modules.<inst>.enabled: true` | vynechať, implicitne true ak je prítomné |
| `modules.<inst>.params`        | `modules[].params`                       |
| `modules.<inst>.clock_domains` | `modules[].clocks`                       |

### Príklady

`blink_test_01`:

* `modules.blink_test.module: blink_test` → `instance: blink_test`, `type: blink_test`
* `params.CLK_FREQ` ostáva rovnaké.

`clkpll` v blink 02 a SDRAM:

* `modules.clkpll.type: clkpll` → `instance: clkpll`, `type: clkpll`
* `clock_domains.inclk0: sys_clk` → `clocks.inclk0: sys_clk`.

## 4. `port_overrides` → `bind.ports`

Toto je najdôležitejšia migračná transformácia pre standalone projekty.

V blink teste 02 máš dnes:

* priamy alias `ONB_LEDS: ONB_LEDS`,
* alebo objekt s `name`, `width`, `pad`.

Vo v2 by som to mapoval na explicitné bindingy.

### Mapovanie

| Staré pole                      | Nové pole                                   |
| ------------------------------- | ------------------------------------------- |
| `port_overrides.<PORT>: STRING` | `bind.ports.<PORT>.target` alebo `top_name` |
| `port_overrides.<PORT>.name`    | `bind.ports.<PORT>.top_name`                |
| `port_overrides.<PORT>.width`   | `bind.ports.<PORT>.width`                   |
| `port_overrides.<PORT>.pad`     | `bind.ports.<PORT>.adapt`                   |

### Konkrétne pravidlá

* `ONB_LEDS: ONB_LEDS` → `bind.ports.ONB_LEDS.target: board:onboard.leds`
* `ONB_LEDS: {name: PMOD_J10, width: 8, pad: replicate}` →
  `bind.ports.ONB_LEDS.target: board:connector.pmod.J10.role.led8`
  `bind.ports.ONB_LEDS.top_name: PMOD_J10`
  `bind.ports.ONB_LEDS.width: 8`
  `bind.ports.ONB_LEDS.adapt: replicate`
* `pad: zero` ostáva `adapt: zero`

Toto je presne opreté o dnešné width/padding správanie v RTL builderi, kde sú adaptéry a padding explicitná súčasť logiky, nie len dekorácia.

## 5. `soc.clock_freq` a clock config

V blink teste 01 máš `soc.clock_freq: 50000000`, zatiaľ čo novšie projekty už pracujú s `clock_domains` a samostatným timing YAML.

### Migračné pravidlo

* Ak projekt používa iba board primary clock a nepotrebuje override, `soc.clock_freq` sa **nemusí prenášať vôbec**; vezme sa z board descriptoru.
* Ak je parameter použitý v moduloch, migrátor ho má zachovať v `modules[].params.CLK_FREQ`.
* Ak bol `soc.clock_freq` zdrojom pravdy pre global config, môže sa preniesť do:

  * `clocks.primary.frequency_hz`, len ak sa líši od board defaultu.

Prakticky:

* blink_test_01: `soc.clock_freq` netreba ako samostatné pole v projekte; stačí `clocks.primary.source: board:sys_clk` a parameter modulu zostane 50 MHz.

## 6. Timing YAML: mapovanie

Timing configy už dnes majú dobrú štruktúru:

* `clocks`
* `plls`
* `clock_groups`
* `io_delays`
* `false_paths`
* `derive_uncertainty`

### Mapovanie

| Staré pole                   | Nové pole v2                                                             |
| ---------------------------- | ------------------------------------------------------------------------ |
| `derive_uncertainty`         | `timing.derive_uncertainty`                                              |
| `clocks[]`                   | `timing.clocks[]`                                                        |
| `clocks[].port`              | `clocks[].source: board:...` alebo `clocks[].port` ponechať pri migrácii |
| `clocks[].reset.port`        | `clocks[].reset.source: board:...`                                       |
| `plls[]`                     | `generated_clocks` alebo `timing.generated_clocks[]`                     |
| `plls[].inst`                | `generated_clocks[].source.instance`                                     |
| `plls[].outputs[].pin_index` | ponechať ako vendor metadata alebo odvodiť z IP descriptoru              |
| `clock_groups[]`             | `timing.clock_groups[]`                                                  |
| `io_delays.auto`             | `timing.io_delays.auto`                                                  |
| `io_delays.clock`            | `timing.io_delays.default_clock`                                         |
| `io_delays.default_*`        | `timing.io_delays.default_*`                                             |
| `io_delays.overrides[]`      | `timing.io_delays.overrides[]`                                           |
| `false_paths[]`              | `timing.false_paths[]`                                                   |

### Jedna dôležitá zmena

`plls[].outputs[].pin_index` by som v novom kontrakte držal skôr ako **voliteľnú tool-specific metadata**, nie ako povinný dizajnový údaj. Tvoj timing config ho dnes potrebuje kvôli Quartus SDC generácii, ale v dlhodobom návrhu je lepšie, ak sa to odvodí z IP descriptoru alebo pluginu. Samotný `sdc.py` aj komentáre v timing YAML ukazujú, že tu ide o väzbu na konkrétny vendor path.

## 7. IP YAML: source vs vendor-generated

Toto je po tvojom doplnení zásadné. `clkpll.ip.yaml` a `sdram_fifo.ip.yaml` ukazujú, že vendor-generated Quartus IP dnes vyzerá ako:

* `type: standalone`
* `module: ...`
* `needs_bus: false`
* `files: ["...qip"]`
* reset/clock port mapping
* niekedy `interfaces` s clock outputmi.

### Mapovanie

| Staré pole                       | Nové pole v2                                |
| -------------------------------- | ------------------------------------------- |
| `type`                           | `ip.category`                               |
| `module`                         | `ip.module`                                 |
| `bus_type: none`                 | `integration.needs_bus: false`              |
| `needs_bus`                      | `integration.needs_bus`                     |
| `gen_regs`                       | `integration.generate_registers`            |
| `no_hw_warning`                  | `integration.no_hw_warning` alebo odstrániť |
| `files`                          | `artifacts.synthesis`                       |
| `port_map.clk`                   | `clocking.primary_input.port`               |
| `port_map.rst_n`                 | `reset.port`                                |
| `bypass_rst_sync`                | `reset.bypass_sync`                         |
| `active_high_rst`                | `reset.active_high`                         |
| `interfaces` type `clock_output` | `clocking.outputs[]`                        |

### Pre `clkpll`

* `files: ["clkpll.qip"]` → `artifacts.synthesis: ["clkpll.qip"]`
* komentované `.v` a `_bb.v` → `artifacts.simulation`
* `interfaces.clock_output.signals` → `clocking.outputs[]`
* `locked` signal by som označil ako `kind: status`, nie clock.

### Pre `sdram_fifo`

* `files: ["sdram_fifo.qip"]` → `artifacts.synthesis`
* ak existujú `.v`, `_bb.v`, patria do `artifacts.simulation`
* `soc_top ho neinstanciuje priamo` → `integration.instantiate_directly: false` a `integration.dependency_only: true`
* neštandardný reset cez `aclr` a prázdny `rst_n` treba previesť na explicitný `reset.optional: true` / `reset.asynchronous: true`.

## 8. Automatizačné pravidlá migrátora

Keby sa z toho robil migrátor, použil by som tieto jednoduché pravidlá:

### Project

1. `design.*` presuň do `project.*`
2. `board.type/file` presuň do `project.board/board_file`
3. `paths.ip_plugins` aj `plugins.ip` zjednoť do `registries.ip`
4. `onboard.* == true` prelož na `features.use += board resource ref`
5. `modules` dict premeň na zoznam objektov s `instance`
6. `module` alebo `type` zjednoť na `type`
7. `clock_domains` premenuj na `clocks`
8. `port_overrides` premenuj na `bind.ports`

### Timing

1. obal do top-level `kind: timing`, `version: 2`
2. `plls.outputs[]` prelož do `generated_clocks[]`
3. zachovaj `clock_groups`, `io_delays`, `false_paths`
4. `pin_index` ponechaj len ak nie je odvodený z IP metadata

### IP

1. doplň `origin.kind`
2. `files` rozbi na `artifacts.synthesis` a prípadne `simulation`
3. `port_map` rozdeľ na `clocking` a `reset`
4. `interfaces.clock_output` prelož na `clocking.outputs`

## 9. Polia, ktoré by som pri migrácii vedome zlomil

Tieto veci by som už do nového formátu neprenášal 1:1:

* `enabled_var` v board YAML ako core semantiku, lebo je to skôr legacy TCL podmienka než hardware fakt.
* `soc.clock_freq` ako samostatný project blok, lebo clock policy má patriť do `clocks` a board descriptoru.
* `module:` vs `type:` dualitu, lebo to zbytočne rozbíja schému.
* `paths.ip_plugins` vs `plugins.ip`, lebo to je len historická nejednotnosť.
* `files` ako jediný plochý zoznam v IP descriptoroch, lebo vendor-generated IP potrebuje rozlíšiť synthesis/simulation/metadata assety.

## 10. Stručná migračná šablóna

Ako pravidlo by som to zhrnul takto:

```text
board.yaml
  device.*                  -> fpga.*
  system.clock/reset.*      -> system.clock/reset.*
  onboard.*                 -> resources.onboard.*
  enabled_var               -> toolchain metadata / drop

project_config.yaml
  design.*                  -> project.*
  board.*                   -> project.board*
  plugins.ip / paths.*      -> registries.ip
  onboard flags             -> features.use[]
  modules map               -> modules[]
  module/type               -> type
  clock_domains             -> clocks
  port_overrides            -> bind.ports

timing_config.yaml
  clocks                    -> timing.clocks
  plls                      -> timing.generated_clocks
  clock_groups              -> timing.clock_groups
  io_delays                 -> timing.io_delays
  false_paths               -> timing.false_paths

*.ip.yaml
  files                     -> artifacts.*
  port_map.clk              -> clocking.primary_input
  port_map.rst_n            -> reset.port
  bypass_rst_sync           -> reset.bypass_sync
  active_high_rst           -> reset.active_high
  interfaces.clock_output   -> clocking.outputs
```

Ak chceš, ďalší krok viem spraviť úplne praktický: napíšem ti **návrh Python migrátora `v1/vlegacy -> v2`**, aspoň ako skeleton s konkrétnymi transformačnými funkciami pre board, project, timing a IP YAML.
