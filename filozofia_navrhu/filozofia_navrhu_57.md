Áno. Tu je **day-by-day convergence sprint pre vendor SDRAM**.

Cieľ sprintu:

* dostať **SDRAM generated Quartus IP** do pack-aware nového flow,
* overiť **bridge-aware integráciu**,
* stabilizovať **board external SDRAM resource model**,
* a uzavrieť to **integration + golden coverage**.

Tento sprint by som robil po tom, čo už je green:

* shared board pack
* blink fixtures
* vendor PLL pack

---

# Sprint cieľ

Na konci sprintu má platiť:

* existuje `vendor_sdram_soc` fixture
* `sdram_ctrl` ide z `packs/vendor-intel`
* board má popísaný externý SDRAM resource
* `simple_bus -> wishbone` bridge sa vloží automaticky
* `files.tcl` obsahuje `QIP_FILE`
* vendor `.sdc` sa exportuje
* `soc_top.sv` obsahuje:

  * `sdram_ctrl`
  * `simple_bus_to_wishbone_bridge`
  * top-level SDRAM piny
* integration testy sú green
* aspoň základný golden snapshot je green

---

# Scope sprintu

Tento sprint zámerne berie len:

* board resource model pre SDRAM
* vendor SDRAM IP pack
* bridge-aware top-level wiring
* files/timing export
* golden coverage

A zámerne **neberie**:

* plnohodnotnú funkčnú simuláciu SDRAM protokolu
* reálny firmware boot zo SDRAM
* timing signoff Quartus closure
* vendor regeneration automation

To je správny scope.

---

# Deň 1 — board resource model + vendor SDRAM pack

## cieľ dňa

* mať board model pripravený pre externý SDRAM konektor/resource
* mať vendor SDRAM pack načítateľný loaderom

---

## Commit 1

### `board: add external SDRAM resource model to shared board pack`

### súbory

* `packs/builtin/boards/qmtech_ep4ce55/board.yaml`
* prípadne `docs/architecture/board_resources.md`

### úlohy

Doplniť board resource pre SDRAM, napr.:

```yaml
resources:
  external:
    sdram:
      addr:
        kind: vector
        top_name: ZS_ADDR
        width: 13
        pins: [ ... ]
      ba:
        kind: vector
        top_name: ZS_BA
        width: 2
        pins: [ ... ]
      dq:
        kind: inout
        top_name: ZS_DQ
        width: 16
        pins: [ ... ]
      dqm:
        kind: vector
        top_name: ZS_DQM
        width: 2
        pins: [ ... ]
      cs_n:
        kind: scalar
        top_name: ZS_CS_N
        pin: ...
      we_n:
        kind: scalar
        top_name: ZS_WE_N
        pin: ...
      ras_n:
        kind: scalar
        top_name: ZS_RAS_N
        pin: ...
      cas_n:
        kind: scalar
        top_name: ZS_CAS_N
        pin: ...
      cke:
        kind: scalar
        top_name: ZS_CKE
        pin: ...
      clk:
        kind: scalar
        top_name: ZS_CLK
        pin: ...
```

### done keď

* board loader vie resource načítať
* bind model vie tieto resource referencie rozlíšiť

---

## Commit 2

### `vendor: add sdram_ctrl pack skeleton`

### súbory

* `packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/ip.yaml`
* `packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/files/...`
* `packs/vendor-intel/pack.yaml`

### úlohy

Pridať descriptor pre SDRAM IP:

* `origin.kind: generated`
* `vendor.qip`
* `vendor.sdc`
* `bus_interfaces: wishbone slave`

### done keď

* `IpLoader` vie pack načítať bez chyby

---

## Commit 3

### `test: add unit coverage for SDRAM board resource and vendor IP loading`

### súbory

* `tests/unit/test_board_loader.py`
* `tests/unit/test_ip_loader.py`

### úlohy

Pridať testy:

* board obsahuje `external.sdram`
* vendor IP descriptor má `vendor_info.qip`
* vendor artifacts sú normalizované

### done keď

* unit testy green

---

# Deň 2 — fixture + top-level wiring

## cieľ dňa

* mať `vendor_sdram_soc` fixture
* build musí prejsť
* top musí obsahovať bridge aj SDRAM piny

---

## Commit 4

### `fixture: add vendor_sdram_soc project`

### súbory

* `tests/golden/fixtures/vendor_sdram_soc/project.yaml`

### úlohy

Project nech používa:

* `packs/builtin`
* `packs/vendor-intel`

A modul:

```yaml
modules:
  - instance: sdram0
    type: sdram_ctrl
    bus:
      fabric: main
      base: 0x80000000
      size: 0x01000000
    clocks:
      clk: sys_clk
    bind:
      ports:
        zs_addr:
          target: board:external.sdram.addr
        zs_ba:
          target: board:external.sdram.ba
        zs_dq:
          target: board:external.sdram.dq
        zs_dqm:
          target: board:external.sdram.dqm
        zs_cs_n:
          target: board:external.sdram.cs_n
        zs_we_n:
          target: board:external.sdram.we_n
        zs_ras_n:
          target: board:external.sdram.ras_n
        zs_cas_n:
          target: board:external.sdram.cas_n
        zs_cke:
          target: board:external.sdram.cke
        zs_clk:
          target: board:external.sdram.clk
```

### done keď

* loader + validator prejdú

---

## Commit 5

### `emit: stabilize inout/vector external bindings for vendor SDRAM`

### súbory

* `socfw/elaborate/board_bindings.py`
* `socfw/builders/rtl_ir_builder.py`
* `socfw/templates/soc_top.sv.j2`
* prípadne board/tcl emitter

### úlohy

Dotiahnuť:

* `inout` top-level porty
* vektorové external porty
* board binding pre širšie zbernice
* správny top port naming

### done keď

* `soc_top.sv` obsahuje korektné SDRAM porty
* width sedí

---

## Commit 6

### `bridge: confirm wishbone bridge insertion for vendor_sdram_soc`

### súbory

* `tests/integration/test_vendor_sdram_pack_build.py`

### úlohy

Overiť, že build result obsahuje:

* `simple_bus_to_wishbone_bridge`
* `sdram_ctrl`
* `wishbone_if`

### test assertions

```python
assert "simple_bus_to_wishbone_bridge" in rtl
assert "sdram_ctrl" in rtl
assert "wishbone_if" in rtl
```

### done keď

* integration test prejde

---

# Deň 3 — files/timing export + diagnostics

## cieľ dňa

* QIP/SDC export funguje korektne
* vendor warnings fungujú
* report je čitateľný

---

## Commit 7

### `emit: include vendor sdram qip and sdc in files export`

### súbory

* `socfw/builders/vendor_artifact_collector.py`
* `socfw/builders/files_ir_builder.py`
* `socfw/templates/files.tcl.j2`

### úlohy

Overiť:

* `QIP_FILE` pre `sdram_ctrl.qip`
* `SDC_FILE` pre `sdram_ctrl.sdc`

### done keď

* `files.tcl` obsahuje oba

---

## Commit 8

### `validate: add vendor family warning coverage for sdram pack`

### súbory

* `socfw/validate/rules/vendor_rules.py`
* `tests/unit/test_vendor_family_rule.py`

### úlohy

Ak `family` v generated IP nesedí s board FPGA family:

* warning `VND001`

### done keď

* warning sa dá vyvolať test fixtureom

---

## Commit 9

### `report: improve vendor artifact visibility in build report`

### súbory

* `socfw/reports/builder.py`
* `socfw/reports/markdown_emitter.py`

### úlohy

Doplniť do reportu sekciu napr.:

* Vendor artifacts
* QIP files
* SDC files

### done keď

* `build_report.md` ukáže vendor IP dependencies

---

# Deň 4 — golden stabilization

## cieľ dňa

* mať stabilný golden snapshot pre vendor SDRAM fixture
* fixnúť ordering a noise

---

## Commit 10

### `golden: add vendor_sdram_soc expected outputs`

### snapshotovať

* `rtl/soc_top.sv`
* `hal/files.tcl`
* `reports/build_report.md`

### zatiaľ nesnapshotovať natvrdo

* príliš flakey timing file, ak sa ešte mení merge policy

Ak je timing už stabilný, môžeš pridať aj:

* `timing/soc_top.sdc`

### done keď

* `pytest tests/golden -k vendor_sdram_soc` green

---

## Commit 11

### `stabilize: sort vendor artifact ordering and external port ordering`

### súbory

* relevant builders / emitters

### úlohy

Explicitne sortovať:

* vendor qip list
* vendor sdc list
* top-level external ports
* bound module ports

### done keď

* golden snapshot už neflakuje

---

# Deň 5 — docs + checkpoint

## cieľ dňa

* sprint je review-ready
* dokumentované, čo je hotové a čo ešte nie

---

## Commit 12

### `docs: add vendor sdram pack usage and limitations`

### súbory

* `docs/architecture/06_packs_and_catalogs.md`
* `docs/architecture/07_vendor_ip.md`
* `docs/dev_notes/checkpoints.md`

### zdokumentovať

* ako sa používa vendor pack
* ako funguje board external SDRAM resource
* že fixture zatiaľ overuje:

  * top wiring
  * bridge insertion
  * QIP/SDC export
* a že zatiaľ **neoveruje plnú SDRAM funkčnú simuláciu**

To je dôležité povedať nahlas.

---

## Commit 13

### `checkpoint: mark vendor pll + vendor sdram convergence milestone`

Odporúčaný tag/branch:

```text
milestone/m3-vendor-converged
```

alebo

```text
v0.3.0-vendor-converged
```

---

# Výstup sprintu

Na konci sprintu máš:

## green fixtures

* `vendor_pll_soc`
* `vendor_sdram_soc`

## potvrdené schopnosti frameworku

* shared board pack
* vendor generated IP packs
* bridge-aware vendor integration
* board external resource binding
* QIP/SDC-aware export
* vendor validation warnings
* golden coverage

To je veľmi silný praktický míľnik.

---

# Čo tento sprint vedome nerieši

Aby bol scope zdravý, tento sprint **nerieši**:

* boot zo SDRAM
* SDRAM functional simulation model
* memory calibration/training
* Quartus timing closure correctness
* firmware runtime v SDRAM

To by bol ďalší, oveľa väčší sprint.

---

# Hlavné riziká sprintu

## 1. board external resource model nebude dosť bohatý

Riešenie:

* minimal viable model pre scalar/vector/inout
* neabstrahovať viac, než treba

## 2. generated vendor IP bude mať nečisté interné paths

Riešenie:

* všetko normalizovať pri load-e
* preferovať `.qip`

## 3. top-level binding noise rozbije golden snapshoty

Riešenie:

* explicit sort
* nemeniť naming počas sprintu

---

# Definition of done

Sprint je hotový, keď:

* `vendor_sdram_soc` build green
* `files.tcl` obsahuje `QIP_FILE` aj `SDC_FILE`
* `soc_top.sv` obsahuje SDRAM top-level porty a bridge
* integration testy green
* golden snapshot green
* docs vysvetľujú use-case a limity

---

# Čo by som robil potom

Po tomto bode by som už šiel jedným z dvoch smerov:

### A

**workspace model**

* viac projektov
* shared packs
* local overrides
* team setup

### B

**implementation hard cutover**

* nový flow default
* starý flow freeze
* migration checklist pre reálne projekty

Môj praktický odporúčaný ďalší krok je:

👉 **B — hard cutover plan**

Lebo po vendor PLL + SDRAM convergencii už máš dosť dôkazov, že nový framework vie pokryť hlavné reálne use-cases.

Ak chceš, ďalšia správa môže byť presne:
**hard cutover plan: ako prepnúť repozitár na nový flow, zmraziť legacy, a migrovať reálne projekty bez výpadku**
