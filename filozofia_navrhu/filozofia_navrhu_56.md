Áno. Tu je **konkrétny first real convergence sprint** pre existujúci repozitár — už nie architektúra, ale **čo presne robiť, v akom poradí, po dňoch a po commitoch**.

Cieľ sprintu:

* dostať nový core do reálneho repa,
* preklopiť **shared board + blink + pll** do nového flow,
* zaviesť **pack-aware resolution**,
* mať **green stable testy**,
* bez big-bang rozbitia starého stavu.

---

# Sprint cieľ

Na konci sprintu má platiť:

* nový `socfw` vie buildnúť:

  * `blink_test_01`
  * `blink_test_02`
  * `vendor_pll_soc`
* board ide cez **pack**
* PLL ide cez **vendor pack**
* `files.tcl` obsahuje korektne `QIP_FILE`
* stable integration + golden testy sú green
* starý flow ešte existuje, ale nový je už použiteľný

---

# Scope sprintu

Tento sprint zámerne **neberie**:

* SDRAM
* PicoRV32 firmware
* AXI/Wishbone demo
* full legacy removal

Berie len:

* shared board
* standalone blink
* PLL generated IP
* packs/catalogs
* stabilization

To je správny scope.

---

# Deň 1 — layout + packs + board resolution

## cieľ dňa

* zaviesť pack-aware infra
* dostať shared board do packu
* rozbehať board resolution bez `board_file`

---

## Commit 1

### `converge: add pack catalog infrastructure`

### súbory

* `socfw/catalog/pack_schema.py`
* `socfw/catalog/pack_model.py`
* `socfw/catalog/pack_loader.py`
* `socfw/catalog/index.py`
* `socfw/catalog/indexer.py`
* `socfw/catalog/board_resolver.py`
* `socfw/model/source_context.py`

### úlohy

* pack manifest model
* indexer pre `boards/`, `ip/`, `cpu/`
* board resolver:

  * explicit `board_file` first
  * pack lookup second

### done keď

* unit test na board resolution z packu prejde

---

## Commit 2

### `converge: extend project model with pack registries`

### súbory

* `socfw/config/project_schema.py`
* `socfw/model/project.py`
* `socfw/config/project_loader.py`
* `socfw/config/system_loader.py`

### úlohy

* `registries.packs`
* `registries.cpu`
* pack index do `SystemLoader`
* resolve `project.board` cez packy

### done keď

* projekt bez `board_file`, len s `board: qmtech_ep4ce55`, sa načíta korektne

---

## Commit 3

### `packs: add builtin board pack for qmtech_ep4ce55`

### súbory

* `packs/builtin/pack.yaml`
* `packs/builtin/boards/qmtech_ep4ce55/board.yaml`
* `packs/builtin/README.md`

### úlohy

* preklopiť shared board definíciu do built-in packu
* nič ďalšie, len board

### done keď

* `blink` fixture vie použiť board len cez `registries.packs`

---

## Commit 4

### `test: add pack-aware board resolution integration test`

### súbory

* `tests/integration/test_pack_board_resolution.py`

### done keď

* test prejde green

---

# Deň 2 — blink fixtures converged

## cieľ dňa

* dostať `blink_test_01` a `blink_test_02` na nový pack-aware flow
* zafixovať stable golden outputs

---

## Commit 5

### `converge: migrate blink_test_01 to pack-aware project`

### súbory

* `tests/golden/fixtures/blink_test_01/project.yaml`
* prípadne `tests/golden/fixtures/blink_test_01/ip/...`

### úlohy

* odstrániť explicit `board_file`, ak už netreba
* používať:

  * `registries.packs: [packs/builtin]`
* zachovať rovnaký výsledok buildu

### done keď

* `socfw build blink_test_01` prejde

---

## Commit 6

### `converge: migrate blink_test_02 pll clock flow to new stable fixture`

### súbory

* `tests/golden/fixtures/blink_test_02/project.yaml`
* timing/fixture súbory podľa potreby

### úlohy

* stabilizovať generated clock flow
* blink_test_02 zatiaľ môže ešte používať lokálny PLL asset, ak vendor pack ešte nie je hotový
* cieľom je mať green fixture, nie hneď vendor normalization

### done keď

* `soc_top.sdc` obsahuje generated clock
* build prejde

---

## Commit 7

### `golden: lock stable snapshots for blink fixtures`

### súbory

* `tests/golden/expected/blink_test_01/...`
* `tests/golden/expected/blink_test_02/...`
* `tests/golden/test_golden_outputs.py`

### úlohy

* snapshoty:

  * `rtl/soc_top.sv`
  * `hal/board.tcl`
  * `timing/soc_top.sdc`
  * `reports/build_report.md`

### done keď

* `pytest tests/golden -k blink` green

---

## Commit 8

### `docs: update quickstart to use pack-based board resolution`

### súbory

* `README.md`
* `docs/user/getting_started.md`

### úlohy

* ukázať:

  * `registries.packs`
  * built-in board pack
  * build blink example

---

# Deň 3 — vendor PLL pack

## cieľ dňa

* preklopiť PLL do vendor packu
* QIP-aware export
* vendor PLL fixture green

---

## Commit 9

### `vendor: add vendor metadata model and normalized artifact loading`

### súbory

* `socfw/config/ip_schema.py`
* `socfw/model/ip.py`
* `socfw/config/ip_loader.py`

### úlohy

* `vendor:` sekcia v IP descriptor
* `IpVendorInfo`
* normalizácia:

  * `qip`
  * `sdc`
  * synthesis files

### done keď

* IP loader vie načítať vendor PLL descriptor

---

## Commit 10

### `vendor: add qip/sdc-aware files export policy`

### súbory

* `socfw/model/vendor_artifacts.py`
* `socfw/ir/files.py`
* `socfw/builders/vendor_artifact_collector.py`
* `socfw/builders/files_ir_builder.py`
* `socfw/templates/files.tcl.j2`
* emitter/builder súbory podľa aktuálneho stavu repa

### úlohy

* `QIP_FILE` export
* `SDC_FILE` export
* oddeliť vendor artifacts od plain RTL

### done keď

* `files.tcl` vie emitnúť `QIP_FILE`

---

## Commit 11

### `packs: add vendor-intel pll pack`

### súbory

* `packs/vendor-intel/pack.yaml`
* `packs/vendor-intel/README.md`
* `packs/vendor-intel/vendor/intel/pll/sys_pll/ip.yaml`
* `packs/vendor-intel/vendor/intel/pll/sys_pll/files/...`

### úlohy

* pack s jedným PLL IP
* descriptor + generated files

### done keď

* pack je loadovateľný z `registries.packs`

---

## Commit 12

### `converge: add vendor_pll_soc fixture using vendor pack`

### súbory

* `tests/golden/fixtures/vendor_pll_soc/project.yaml`

### úlohy

* fixture používa:

  * `packs/builtin`
  * `packs/vendor-intel`
* `pll0` je `sys_pll`
* blink beží na `pll0:c0`

### done keď

* build prejde
* `soc_top.sv` obsahuje `sys_pll`
* `files.tcl` obsahuje `sys_pll.qip`

---

## Commit 13

### `test: add vendor pll integration and golden coverage`

### súbory

* `tests/integration/test_vendor_pll_pack_build.py`
* `tests/golden/expected/vendor_pll_soc/...`

### snapshoty

* `rtl/soc_top.sv`
* `hal/files.tcl`
* `timing/soc_top.sdc`
* `reports/build_report.md`

### done keď

* vendor PLL fixture je green v integration aj golden testoch

---

# Deň 4 — cleanup + CI lane

## cieľ dňa

* spraviť z toho review-ready stav
* zapnúť CI lane pre converged stable fixtures

---

## Commit 14

### `ci: include converged blink and vendor pll fixtures in stable lane`

### súbory

* `.github/workflows/ci.yml`

### úlohy

* stable lane spúšťa:

  * unit
  * integration pre blink + vendor_pll
  * golden pre blink + vendor_pll

### done keď

* CI green

---

## Commit 15

### `report: stabilize output ordering for converged fixtures`

### súbory

* report builder/emitter
* relevant IR/builders

### úlohy

* explicit sorting:

  * artifacts
  * modules
  * clocks
  * endpoints
  * report sections

### done keď

* golden snapshoty neflakujú

---

## Commit 16

### `checkpoint: mark old board/pll path as legacy and document new flow`

### súbory

* `docs/architecture/06_packs_and_catalogs.md`
* `docs/dev_notes/checkpoints.md`
* prípadne `legacy/README.md`

### úlohy

* popísať:

  * nový board pack flow
  * vendor PLL pack flow
  * čo je legacy
  * že nové fixtures už majú používať packy

---

# Výstup sprintu

Na konci máš:

## green converged flows

* `blink_test_01`
* `blink_test_02`
* `vendor_pll_soc`

## nové schopnosti v reálnom repe

* board resolution cez pack
* vendor PLL cez pack
* `QIP_FILE` export policy
* stable golden coverage

## nezmenené / odložené

* SDRAM
* firmware-heavy fixtures
* full legacy removal

To je presne správny “first real convergence sprint”.

---

# Čo by som v tomto sprinte vedome nerobil

Nechal by som mimo sprint:

* SDRAM functional bring-up
* PicoRV32 IRQ verification
* AXI/WB ďalšie rozširovanie
* interactive init v2
* workspace model

Dôvod je jednoduchý:
tento sprint má mať **malé riziko a vysokú istotu dokončenia**.

---

# Riziká sprintu

Najväčšie riziká sú tri:

## 1. `files.tcl` policy sa rozbije medzi plain RTL a QIP

riešenie:

* urob explicitné testy na `QIP_FILE` aj `VERILOG_FILE`

## 2. PLL fixture bude stále závislá na starých lokálnych cestách

riešenie:

* všetky artifact paths normalizovať pri load-e

## 3. golden snapshoty budú nestabilné

riešenie:

* sort everywhere
* nemenit naming počas sprintu

---

# Definition of done

Sprint je hotový, keď:

* `socfw build tests/golden/fixtures/blink_test_01/project.yaml` green
* `socfw build tests/golden/fixtures/blink_test_02/project.yaml` green
* `socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml` green
* `pytest tests/golden -k "blink or vendor_pll"` green
* CI lane green
* docs ukazujú pack-aware flow

---

# Čo by som spravil hneď po tomto sprinte

Hneď ďalší sprint by som dal:

👉 **vendor_sdram convergence sprint**

Teda:

* SDRAM pack
* board external SDRAM resource model
* bridge-aware SDRAM fixture
* vendor golden coverage

To je prirodzené pokračovanie.

Ak chceš, ďalšia správa môže byť už presne:
**day-by-day convergence sprint pre vendor SDRAM**
