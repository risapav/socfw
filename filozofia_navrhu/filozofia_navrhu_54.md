Super. Ideme na:

# vendor stabilization sprint: PLL fixture cleanup, SDRAM fixture integration, vendor pack examples, and golden test coverage

Toto je presne správny krok na uzavretie pôvodného praktického cieľa.
Architektúra už stojí, teraz ju treba potvrdiť na reálnych vendor scenároch:

* **PLL**
* **SDRAM controller**
* **Quartus-generated IP packy**
* **golden coverage**

Cieľ sprintu:

* znormalizovať vendor fixtures,
* dostať ich do pack modelu,
* overiť emitter policy pre `QIP_FILE` / `SDC_FILE`,
* mať regression testy,
* a potvrdiť, že framework zvláda reálne generated IP use-cases.

---

# 1. Sprint cieľ

Na konci sprintu má platiť:

* PLL fixture je pack-aware a stabilný
* SDRAM fixture je pack-aware a buildovateľný
* vendor `.qip` a `.sdc` idú korektne do exportu
* vendor family warning funguje
* golden testy pokrývajú aspoň jeden PLL a jeden vendor-IP scenár
* fixtures už nie sú “ad hoc project-local chaos”, ale referenčné príklady

---

# 2. Rozsah sprintu

Odporúčam rozdeliť sprint na 4 pracovné bloky:

1. **PLL stabilization**
2. **SDRAM stabilization**
3. **vendor pack examples**
4. **golden + validation coverage**

To je rozumný scope.

---

# 3. Výsledná štruktúra po sprinte

Odporúčaný cieľový layout:

```text
packs/
  builtin/
    pack.yaml
    boards/
      qmtech_ep4ce55/
        board.yaml

  vendor-intel/
    pack.yaml
    vendor/
      intel/
        pll/
          sys_pll/
            ip.yaml
            files/
              sys_pll.qip
              sys_pll.v
              sys_pll.sdc
        sdram/
          sdram_ctrl/
            ip.yaml
            files/
              sdram_ctrl.qip
              sdram_ctrl.v
              sdram_ctrl.sdc

tests/
  golden/
    fixtures/
      vendor_pll_soc/
      vendor_sdram_soc/
    expected/
      vendor_pll_soc/
      vendor_sdram_soc/
```

To je veľmi dobrý cieľový stav.

---

# 4. Pracovný blok A — PLL fixture cleanup

## cieľ

Dostať PLL use-case z “projektový workaround” do:

* pack-backed IP
* čistého project YAML
* stabilného timing/files exportu

---

## A1. Vendor PLL pack

Vytvor pack:

```text
packs/vendor-intel/vendor/intel/pll/sys_pll/
```

### súbory

* `ip.yaml`
* `files/sys_pll.qip`
* `files/sys_pll.v`
* `files/sys_pll.sdc`

---

## A2. PLL descriptor

## `packs/vendor-intel/vendor/intel/pll/sys_pll/ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: sys_pll
  module: sys_pll
  category: clocking

origin:
  kind: generated
  packaging: quartus_ip

vendor:
  vendor: intel
  tool: quartus
  generator: ip_catalog
  family: cyclone_iv_e
  qip: files/sys_pll.qip
  sdc:
    - files/sys_pll.sdc
  filesets:
    - quartus_qip
    - timing_sdc
    - generated_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: areset
  active_high: true

clocking:
  primary_input_port: inclk0
  additional_input_ports: []
  outputs:
    - name: c0
      domain_hint: sys_clk
      frequency_hz: 100000000
    - name: locked
      domain_hint: null
      frequency_hz: null

artifacts:
  synthesis:
    - files/sys_pll.qip
    - files/sys_pll.v
  simulation: []
  metadata: []
```

---

## A3. Vendor PLL fixture

## `tests/golden/fixtures/vendor_pll_soc/project.yaml`

```yaml
version: 2
kind: project

project:
  name: vendor_pll_soc
  mode: standalone
  board: qmtech_ep4ce55
  output_dir: build/gen
  debug: true

registries:
  packs:
    - packs/builtin
    - packs/vendor-intel
  ip: []

features:
  use:
    - board:onboard.leds

clocks:
  primary:
    domain: ref_clk
    source: board:sys_clk
  generated: []

modules:
  - instance: pll0
    type: sys_pll
    clocks:
      inclk0: ref_clk

  - instance: blink_test
    type: blink_test
    params:
      CLK_FREQ: 100000000
    clocks:
      SYS_CLK: pll0:c0
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds

artifacts:
  emit: [rtl, timing, board, docs]
```

Kľúčové je:

* board ide z built-in packu
* PLL ide z vendor packu
* projekt už nemusí mať lokálne nakopírované PLL artefakty

---

## A4. Čo musíš overiť

Pri `socfw build ...` očakávaj:

### `files.tcl`

obsahuje:

* `QIP_FILE ...sys_pll.qip`
* prípadne `VERILOG_FILE` len pre non-QIP files

### `soc_top.sdc`

obsahuje:

* generated clock / merged timing
* plus vendor `.sdc` cez files/timing policy

### `soc_top.sv`

obsahuje:

* instanciu `sys_pll`

---

# 5. Pracovný blok B — SDRAM fixture integration

## cieľ

Overiť druhý reálny vendor use-case:

* memory controller
* bus-attached IP
* external pins
* vendor QIP/SDC handling

Tu odporúčam nezačať plne funkčnou SDRAM simuláciou.
Najprv sprav:

* descriptor
* build integration
* files/timing export
* top-level wiring

To je správny scope.

---

## B1. Vendor SDRAM pack

```text
packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/
```

### súbory

* `ip.yaml`
* `files/sdram_ctrl.qip`
* `files/sdram_ctrl.v`
* `files/sdram_ctrl.sdc`

---

## B2. SDRAM descriptor

## `packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: sdram_ctrl
  module: sdram_ctrl
  category: memory

origin:
  kind: generated
  packaging: quartus_ip

vendor:
  vendor: intel
  tool: quartus
  generator: megawizard
  family: cyclone_iv_e
  qip: files/sdram_ctrl.qip
  sdc:
    - files/sdram_ctrl.sdc
  filesets:
    - quartus_qip
    - timing_sdc
    - generated_rtl

integration:
  needs_bus: true
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: reset_n
  active_high: false

clocking:
  primary_input_port: clk
  additional_input_ports: []
  outputs: []

bus_interfaces:
  - port_name: wb
    protocol: wishbone
    role: slave
    addr_width: 32
    data_width: 32

artifacts:
  synthesis:
    - files/sdram_ctrl.qip
    - files/sdram_ctrl.v
  simulation: []
  metadata: []
```

---

## B3. Fixture pre SDRAM integration

## `tests/golden/fixtures/vendor_sdram_soc/project.yaml`

```yaml
version: 2
kind: project

project:
  name: vendor_sdram_soc
  mode: soc
  board: qmtech_ep4ce55
  output_dir: build/gen
  debug: true

registries:
  packs:
    - packs/builtin
    - packs/vendor-intel
  ip: []

features:
  use:
    - board:onboard.leds
    - board:external.sdram

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

cpu:
  instance: cpu0
  type: dummy_cpu
  fabric: main
  reset_vector: 0x00000000
  params: {}

ram:
  module: soc_ram
  base: 0x00000000
  size: 32768
  latency: registered
  init_file: ""
  image_format: hex

boot:
  reset_vector: 0x00000000
  stack_percent: 25

buses:
  - name: main
    protocol: simple_bus
    addr_width: 32
    data_width: 32

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

artifacts:
  emit: [rtl, timing, board, docs]
```

Poznámka:

* toto predpokladá, že board pack už vie opísať SDRAM external resource
* ak ešte nevie, pridaj ho do board.yaml

---

## B4. Čo overuješ

Nemusíš hneď dokazovať plnú funkčnosť SDRAM.
Pre sprint je dôležité overiť:

* bridge insertion (`simple_bus -> wishbone`)
* vendor `.qip` export
* vendor `.sdc` export
* external port bindings
* top-level instantiation

To je správny stabilization scope.

---

# 6. Pracovný blok C — vendor pack examples

## cieľ

Mať jasné referenčné packy, ktoré ukazujú pattern.

Odporúčam aspoň:

* `packs/builtin`
* `packs/vendor-intel`

Každý pack nech má `pack.yaml` a krátky README.

---

## `packs/vendor-intel/pack.yaml`

```yaml
version: 1
kind: pack
name: vendor-intel
title: Intel Quartus generated IP pack
description: Reusable generated IP blocks for Intel/Quartus flows
provides:
  - ip
  - vendor
```

---

## `packs/vendor-intel/README.md`

Obsah:

* čo pack obsahuje
* ako sa používa v `registries.packs`
* aké FPGA family podporuje
* ako sa regenerujú IP artefakty

Toto je veľmi užitočné.

---

## Dôležitá dokumentačná poznámka

Pri generated vendor IP packu by som vždy doplnil:

* či je to ručne committed generated output
* alebo či sa očakáva regenerácia cez tool
* akým Quartus version bol pack generovaný

To pomáha pri reproducibilite.

---

# 7. Pracovný blok D — golden + validation coverage

Toto je rozhodujúce. Bez testov sa vendor vrstva rýchlo rozpadne.

---

## D1. Integration test pre PLL vendor pack

## `tests/integration/test_vendor_pll_pack_build.py`

```python
from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_vendor_pll_pack_build(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/vendor_pll_soc/project.yaml"
    out_dir = tmp_path / "out"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok

    rtl = (out_dir / "rtl" / "soc_top.sv").read_text(encoding="utf-8")
    files_tcl = (out_dir / "hal" / "files.tcl").read_text(encoding="utf-8")

    assert "sys_pll" in rtl
    assert "QIP_FILE" in files_tcl
    assert "sys_pll.qip" in files_tcl
```

---

## D2. Integration test pre SDRAM vendor pack

## `tests/integration/test_vendor_sdram_pack_build.py`

```python
from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_vendor_sdram_pack_build(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/vendor_sdram_soc/project.yaml"
    out_dir = tmp_path / "out"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok

    rtl = (out_dir / "rtl" / "soc_top.sv").read_text(encoding="utf-8")
    files_tcl = (out_dir / "hal" / "files.tcl").read_text(encoding="utf-8")

    assert "sdram_ctrl" in rtl
    assert "simple_bus_to_wishbone_bridge" in rtl
    assert "QIP_FILE" in files_tcl
```

---

## D3. Golden snapshot pre PLL fixture

Na sprint by som spravil exact golden snapshot pre:

* `vendor_pll_soc/rtl/soc_top.sv`
* `vendor_pll_soc/hal/files.tcl`
* `vendor_pll_soc/timing/soc_top.sdc`
* `vendor_pll_soc/reports/build_report.md`

To dá veľmi dobré coverage.

---

## D4. Validator test pre vendor family mismatch

## `tests/unit/test_vendor_family_rule.py`

```python
from socfw.validate.rules.vendor_rules import VendorFamilyMismatchRule


def test_vendor_family_mismatch_warns(system_with_vendor_family_mismatch):
    diags = VendorFamilyMismatchRule().validate(system_with_vendor_family_mismatch)
    assert any(d.code == "VND001" for d in diags)
```

---

# 8. Emitter policy cleanup

Počas sprintu by som veľmi explicitne dotiahol tieto pravidlá:

## `files.tcl`

* vendor IP s `qip` → emit `QIP_FILE`
* non-vendor IP → emit `VERILOG_FILE`
* vendor `.sdc` → emit `SDC_FILE`

## `soc_top.sv`

* framework stále generuje top-level instantiation z descriptoru
* vendor IP nie je “mimo modelu”

## timing

* framework timing + generated clocks + vendor `.sdc`
* merge policy nech je deterministická

To je jadro stabilizácie.

---

# 9. Definition of done pre vendor sprint

Sprint je hotový, keď:

* `vendor_pll_soc` build prejde
* `vendor_sdram_soc` build prejde
* `files.tcl` korektne obsahuje `QIP_FILE`
* vendor `.sdc` sú zahrnuté v exporte
* vendor packy fungujú cez `registries.packs`
* golden snapshot pre PLL fixture je green
* `VND001` validator funguje

To je veľmi dobrý a realistický milestone.

---

# 10. Môj odporúčaný commit plán

Odporúčam 6 commitov.

## Commit 1

`catalog: add vendor-intel pack skeleton and manifests`

## Commit 2

`ip: add vendor metadata model and artifact normalization`

## Commit 3

`emit: add qip/sdc-aware files export policy`

## Commit 4

`test: add vendor_pll_soc fixture and integration coverage`

## Commit 5

`test: add vendor_sdram_soc fixture and bridge-aware integration coverage`

## Commit 6

`golden: lock vendor pll snapshots and add vendor validation coverage`

---

# 11. Môj praktický verdikt

Toto je podľa mňa posledný veľký kus, ktorý uzavrie tvoj pôvodný praktický problém:

* shared board
* shared FPGA kit
* projekty s PLL
* projekty so SDRAM
* generated Quartus IP
* všetko v jednom rozumnom framework modeli

Po tomto bode už bude návrh veľmi presvedčivý aj prakticky, nielen architektonicky.

---

# 12. Čo by som robil potom

Po tomto bode by som už nešiel ďalej do veľkých architektonických vecí. Ďalšie smery by som videl skôr takto:

### A

**workspace model**

* viac projektov v jednom workspace
* shared packs + local overrides

### B

**interactive init v2**

* pack-aware wizard
* board/resource selection
* vendor starter bundles

### C

**implementation convergence**

* zobrať tento návrh a fakticky preklopiť repozitár na nový layout

Môj praktický odporúčaný ďalší krok je:

👉 **C — implementation convergence plan**

Teda už nie ďalšia architektúra, ale:

* čo presne prekopiť,
* čo vyhodiť,
* čo zachovať,
* v akom poradí refaktorovať reálny repo stav.

Ak chceš, ďalšia správa môže byť presne:
**implementation convergence: čo ponechať, čo zahodiť, cieľový layout, a migračný/refaktor plán na reálny repozitár**
