Áno. Tu je **Commit 13 ako file-by-file scaffold**:

# Commit 13 — vendor metadata model + `packs/vendor-intel` + `vendor_pll_soc` fixture

Cieľ tohto commitu:

* zaviesť prvý **vendor-aware IP model**
* dostať prvý **vendor pack**
* pridať prvý fixture, ktorý už nejde cez “plain RTL PLL”, ale cez:

  * vendor metadata
  * `QIP_FILE`
  * vendor `.sdc`
* otestovať build-level integráciu bez toho, aby si ešte musel robiť plný vendor cleanup pre všetko

Toto je prvý krok, kde sa nový flow začne reálne približovať tvojmu pôvodnému Quartus use-case.

---

# Názov commitu

```text
vendor: add first vendor PLL metadata model and pack-based pll fixture
```

---

# 1. Čo má byť výsledok po Commite 13

Po tomto commite má fungovať:

```bash
socfw validate tests/golden/fixtures/vendor_pll_soc/project.yaml
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
```

A očakávaš:

* `vendor_pll_soc` sa načíta novým flow
* `clkpll` už nejde z lokálneho fixture IP adresára, ale z `packs/vendor-intel`
* build prejde
* `files.tcl` obsahuje `QIP_FILE`
* fixture je pripravený na neskoršiu golden stabilizáciu

---

# 2. Súbory, ktoré pridať

```text
socfw/model/vendor.py
packs/vendor-intel/pack.yaml
packs/vendor-intel/README.md
packs/vendor-intel/vendor/intel/pll/clkpll/ip.yaml
packs/vendor-intel/vendor/intel/pll/clkpll/files/clkpll.qip
packs/vendor-intel/vendor/intel/pll/clkpll/files/clkpll.v
packs/vendor-intel/vendor/intel/pll/clkpll/files/clkpll.sdc

tests/golden/fixtures/vendor_pll_soc/project.yaml
tests/golden/fixtures/vendor_pll_soc/timing_config.yaml
tests/golden/fixtures/vendor_pll_soc/ip/blink_test.ip.yaml
tests/golden/fixtures/vendor_pll_soc/rtl/blink_test.sv

tests/unit/test_ip_loader_vendor_metadata.py
tests/integration/test_validate_vendor_pll_soc.py
tests/integration/test_build_vendor_pll_soc.py
```

---

# 3. Súbory, ktoré upraviť

```text
socfw/model/ip.py
socfw/config/ip_schema.py
socfw/config/ip_loader.py
legacy_build.py
tests/integration/test_build_pll_converged.py
```

Voliteľne:

```text
tcl.py
```

ak potrebuješ reálne dostať `QIP_FILE` do legacy files exportu.

---

# 4. Kľúčové rozhodnutie pre Commit 13

Správny scope je:

## zaviesť vendor metadata, ale ešte nepretvárať celý build stack

To znamená:

* nový loader už rozumie vendor IP
* descriptor už vie niesť:

  * `vendor`
  * `tool`
  * `qip`
  * `sdc`
* ale build ešte stále ide cez legacy wrapper

Aby to fungovalo, `legacy_build.py` musí vedieť:

* z nového fixture spraviť legacy-compatible config
* plus zabezpečiť, že `QIP_FILE` a `SDC_FILE` sa dostanú do legacy exportu

To je úplne v poriadku.

---

# 5. `socfw/model/vendor.py`

Toto je malý nový model pre vendor metadata.

```python
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class VendorInfo:
    vendor: str
    tool: str
    generator: str | None = None
    family: str | None = None
    qip: str | None = None
    sdc: tuple[str, ...] = ()
    filesets: tuple[str, ...] = ()
```

---

# 6. úprava `socfw/model/ip.py`

Treba doplniť `vendor_info`.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field

from socfw.model.vendor import VendorInfo


@dataclass
class IpClockOutput:
    name: str
    frequency_hz: int | None = None
    domain_hint: str | None = None


@dataclass
class IpDescriptor:
    name: str
    module: str
    category: str
    origin_kind: str = "source"
    packaging: str = "plain_rtl"

    needs_bus: bool = False
    generate_registers: bool = False
    instantiate_directly: bool = True
    dependency_only: bool = False

    reset_port: str | None = None
    reset_active_high: bool | None = None

    primary_clock_port: str | None = None
    additional_clock_ports: tuple[str, ...] = ()
    clock_outputs: tuple[IpClockOutput, ...] = ()

    synthesis_files: tuple[str, ...] = ()
    simulation_files: tuple[str, ...] = ()
    metadata_files: tuple[str, ...] = ()

    vendor_info: VendorInfo | None = None

    raw: dict = field(default_factory=dict)
```

---

# 7. úprava `socfw/config/ip_schema.py`

Treba doplniť `vendor:` sekciu.

## nahradiť týmto

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class IpMetaSchema(BaseModel):
    name: str
    module: str
    category: str = "generic"


class IpOriginSchema(BaseModel):
    kind: str = "source"
    packaging: str = "plain_rtl"


class IpVendorSchema(BaseModel):
    vendor: str
    tool: str
    generator: str | None = None
    family: str | None = None
    qip: str | None = None
    sdc: list[str] = Field(default_factory=list)
    filesets: list[str] = Field(default_factory=list)


class IpIntegrationSchema(BaseModel):
    needs_bus: bool = False
    generate_registers: bool = False
    instantiate_directly: bool = True
    dependency_only: bool = False


class IpResetSchema(BaseModel):
    port: str | None = None
    active_high: bool | None = None


class IpClockOutputSchema(BaseModel):
    name: str
    frequency_hz: int | None = None
    domain_hint: str | None = None


class IpClockingSchema(BaseModel):
    primary_input_port: str | None = None
    additional_input_ports: list[str] = Field(default_factory=list)
    outputs: list[IpClockOutputSchema] = Field(default_factory=list)


class IpArtifactsSchema(BaseModel):
    synthesis: list[str] = Field(default_factory=list)
    simulation: list[str] = Field(default_factory=list)
    metadata: list[str] = Field(default_factory=list)


class IpConfigSchema(BaseModel):
    version: int = 2
    kind: Literal["ip"] = "ip"
    ip: IpMetaSchema
    origin: IpOriginSchema = Field(default_factory=IpOriginSchema)
    vendor: IpVendorSchema | None = None
    integration: IpIntegrationSchema = Field(default_factory=IpIntegrationSchema)
    reset: IpResetSchema = Field(default_factory=IpResetSchema)
    clocking: IpClockingSchema = Field(default_factory=IpClockingSchema)
    artifacts: IpArtifactsSchema = Field(default_factory=IpArtifactsSchema)
```

---

# 8. úprava `socfw/config/ip_loader.py`

Doplň `vendor_info` a nech sa normalizujú `qip` a `sdc`.

## uprav importy

pridaj:

```python
from socfw.model.vendor import VendorInfo
```

## uprav `IpDescriptor(...)` skladanie na

```python
        ipd = IpDescriptor(
            name=doc.ip.name,
            module=doc.ip.module,
            category=doc.ip.category,
            origin_kind=doc.origin.kind,
            packaging=doc.origin.packaging,
            needs_bus=doc.integration.needs_bus,
            generate_registers=doc.integration.generate_registers,
            instantiate_directly=doc.integration.instantiate_directly,
            dependency_only=doc.integration.dependency_only,
            reset_port=doc.reset.port,
            reset_active_high=doc.reset.active_high,
            primary_clock_port=doc.clocking.primary_input_port,
            additional_clock_ports=tuple(doc.clocking.additional_input_ports),
            clock_outputs=tuple(
                IpClockOutput(
                    name=o.name,
                    frequency_hz=o.frequency_hz,
                    domain_hint=o.domain_hint,
                )
                for o in doc.clocking.outputs
            ),
            synthesis_files=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.synthesis),
            simulation_files=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.simulation),
            metadata_files=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.metadata),
            vendor_info=(
                VendorInfo(
                    vendor=doc.vendor.vendor,
                    tool=doc.vendor.tool,
                    generator=doc.vendor.generator,
                    family=doc.vendor.family,
                    qip=str((base_dir / doc.vendor.qip).resolve()) if doc.vendor.qip else None,
                    sdc=tuple(str((base_dir / p).resolve()) for p in doc.vendor.sdc),
                    filesets=tuple(doc.vendor.filesets),
                )
                if doc.vendor is not None else None
            ),
            raw=doc.model_dump(),
        )
```

### dôležité

Týmto už loader vie normalizovať vendor artifact paths a to je presne základ pre pack-aware vendor flow.

---

# 9. `packs/vendor-intel/pack.yaml`

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

# 10. `packs/vendor-intel/README.md`

````md
# vendor-intel

Reusable Intel Quartus generated IP blocks.

Current contents:
- `vendor/intel/pll/clkpll`

Usage:
```yaml
registries:
  packs:
    - packs/builtin
    - packs/vendor-intel
````

Notes:

* artifacts are committed as generated outputs
* descriptor metadata is the source of truth for integration
* QIP and SDC files are expected to be consumed by the Quartus-oriented files export path

````

---

# 11. `packs/vendor-intel/vendor/intel/pll/clkpll/ip.yaml`

Toto je prvý skutočný vendor descriptor.

```yaml
version: 2
kind: ip

ip:
  name: clkpll
  module: clkpll
  category: clocking

origin:
  kind: generated
  packaging: quartus_ip

vendor:
  vendor: intel
  tool: quartus
  generator: ip_catalog
  family: cyclone_iv_e
  qip: files/clkpll.qip
  sdc:
    - files/clkpll.sdc
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
    - files/clkpll.qip
    - files/clkpll.v
  simulation: []
  metadata: []
````

---

# 12. `packs/vendor-intel/vendor/intel/pll/clkpll/files/clkpll.qip`

Na commit scaffold úplne stačí placeholder.

```tcl
# Placeholder QIP file for clkpll vendor pack fixture
set_global_assignment -name VERILOG_FILE clkpll.v
set_global_assignment -name SDC_FILE clkpll.sdc
```

### poznámka

Keď nasadíš reálny Quartus-generated pack, sem pôjde skutočný `.qip`.

---

# 13. `packs/vendor-intel/vendor/intel/pll/clkpll/files/clkpll.v`

Na prvý build-level fixture stačí placeholder modul kompatibilný s descriptorom.

```systemverilog
`default_nettype none

module clkpll (
  input  wire inclk0,
  input  wire areset,
  output wire c0,
  output wire locked
);

  assign c0 = inclk0;
  assign locked = ~areset;

endmodule

`default_nettype wire
```

---

# 14. `packs/vendor-intel/vendor/intel/pll/clkpll/files/clkpll.sdc`

Opäť stačí placeholder.

```tcl
# Placeholder SDC for clkpll vendor pack fixture
create_generated_clock -name clkpll_c0 -source [get_ports SYS_CLK] [get_ports SYS_CLK]
```

Neskôr to nahradíš reálnym vendor `.sdc`.

---

# 15. `tests/golden/fixtures/vendor_pll_soc/project.yaml`

Toto je nový fixture, ktorý už používa pack vendor PLL.

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
  ip:
    - tests/golden/fixtures/vendor_pll_soc/ip
  cpu: []

clocks:
  primary:
    domain: ref_clk
    source: board:sys_clk
  generated: []

modules:
  - instance: pll0
    type: clkpll
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
```

### dôležité

PLL už tu nie je z lokálneho `ip/`, ale z vendor packu.

---

# 16. `tests/golden/fixtures/vendor_pll_soc/timing_config.yaml`

Môže byť skoro rovnaký ako v `pll_converged`.

```yaml
version: 2
kind: timing

generated_clocks:
  - name: pll0_c0
    source: pll0|inclk0
    target: pll0|c0
    divide_by: 1
    multiply_by: 2
    frequency_hz: 100000000

false_paths:
  - from_path: "*reset*"
    to_path: "*"
```

---

# 17. `tests/golden/fixtures/vendor_pll_soc/ip/blink_test.ip.yaml`

Rovnaký lokálny descriptor ako doteraz.

```yaml
version: 2
kind: ip

ip:
  name: blink_test
  module: blink_test
  category: standalone

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: null
  active_high: null

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

artifacts:
  synthesis:
    - ../rtl/blink_test.sv
  simulation: []
  metadata: []
```

---

# 18. `tests/golden/fixtures/vendor_pll_soc/rtl/blink_test.sv`

Rovnaký jednoduchý blink modul.

```systemverilog
`default_nettype none

module blink_test #(
  parameter integer CLK_FREQ = 50000000
)(
  input  wire       SYS_CLK,
  output reg  [5:0] ONB_LEDS
);

  reg [31:0] counter;

  always @(posedge SYS_CLK) begin
    counter <= counter + 1'b1;
    ONB_LEDS <= counter[25:20];
  end

endmodule

`default_nettype wire
```

---

# 19. `tests/unit/test_ip_loader_vendor_metadata.py`

Tento test overí nový vendor metadata model.

```python
from socfw.config.ip_loader import IpLoader


def test_ip_loader_loads_vendor_metadata():
    res = IpLoader().load_file("packs/vendor-intel/vendor/intel/pll/clkpll/ip.yaml")
    assert res.ok
    assert res.value is not None
    assert res.value.vendor_info is not None
    assert res.value.vendor_info.vendor == "intel"
    assert res.value.vendor_info.tool == "quartus"
    assert res.value.vendor_info.qip is not None
    assert res.value.vendor_info.qip.endswith("clkpll.qip")
    assert len(res.value.vendor_info.sdc) == 1
```

---

# 20. `tests/integration/test_validate_vendor_pll_soc.py`

Toto overí, že nový fixture sa resolve-ne korektne.

```python
from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_vendor_pll_soc():
    result = FullBuildPipeline().validate("tests/golden/fixtures/vendor_pll_soc/project.yaml")

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    assert result.value is not None
    assert "clkpll" in result.value.ip_catalog
    assert result.value.ip_catalog["clkpll"].vendor_info is not None
```

---

# 21. `tests/integration/test_build_vendor_pll_soc.py`

Toto je hlavný build test commitu.

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_vendor_pll_soc(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_pll_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    rtl = out_dir / "rtl" / "soc_top.sv"
    board_tcl = out_dir / "hal" / "board.tcl"
    timing_sdc = out_dir / "timing" / "soc_top.sdc"

    assert rtl.exists()
    assert board_tcl.exists()
    assert timing_sdc.exists()

    rtl_text = rtl.read_text(encoding="utf-8")
    assert "clkpll" in rtl_text
    assert "blink_test" in rtl_text
```

### v tomto commite ešte netlač assertion na `QIP_FILE`, ak legacy export ešte nie je napojený

To bude až ďalší commit.

---

# 22. čo bude pravdepodobne treba doplniť v `legacy_build.py`

Toto je prakticky najdôležitejší compatibility bod.

Ak legacy backend nevie sám:

* preniesť `registries.packs`
* nájsť vendor pack IP
* dostať `qip/sdc` do files exportu

tak v `legacy_build.py` sprav minimálne dve veci:

## A. new-to-legacy project shim

To už zrejme máš z Commitu 10.

## B. vendor IP artifact collection shim

Pri dočasnej compatibility vrstve môžeš:

* po načítaní nového project file zistiť, ktoré IP sú vendor-aware
* a do temporary legacy configu doplniť cesty na ich QIP/SDC artifacts spôsobom, ktorý legacy flow zje

Ak legacy `files.tcl` emitter ešte nevie `QIP_FILE`, ďalší commit to doplní.

---

# 23. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* `QIP_FILE` assertions
* reálnu Quartus files export policy
* vendor family validation
* golden snapshots pre vendor fixture
* vendor PLL ako jediný PLL path

Commit 13 má riešiť len:

* vendor metadata model
* vendor pack resolution
* build-level vendor fixture

To je správny scope.

---

# 24. Čo po Commite 13 overiť

Spusti:

```bash
pip install -e .
socfw validate tests/golden/fixtures/vendor_pll_soc/project.yaml
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
pytest tests/unit/test_ip_loader_vendor_metadata.py
pytest tests/integration/test_validate_vendor_pll_soc.py
pytest tests/integration/test_build_vendor_pll_soc.py
```

### očakávanie

* loader rozumie vendor metadata
* pack vendor PLL sa resolve-ne
* build fixture prejde

To je veľmi dôležitý checkpoint pred reálnym `QIP_FILE` flow.

---

# 25. Definition of Done pre Commit 13

Commit 13 je hotový, keď:

* existuje `VendorInfo` model
* `IpLoader` vie načítať `vendor:` sekciu
* `packs/vendor-intel` existuje
* `vendor_pll_soc` fixture sa validate-ne
* `vendor_pll_soc` fixture sa buildí

To je veľmi silný míľnik.

---

# 26. Čo má byť Commit 14

Po tomto by som išiel priamo na:

## Commit 14

```text
emit: add qip/sdc-aware files export policy and assert QIP_FILE for vendor pll fixture
```

Ten prinesie:

* `QIP_FILE`
* `SDC_FILE`
* prvý reálny Quartus-oriented vendor export contract
* silný praktický dôkaz, že vendor pack model je použiteľný

To je ďalší prirodzený krok.

---

# 27. Môj praktický odporúčaný rytmus

Po Commite 13:

1. potvrď, že vendor fixture vôbec prejde buildom
2. až potom sprav `QIP_FILE` export
3. až potom golden snapshot pre vendor PLL
4. až potom SDRAM vendor fixture

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 14 ako file-by-file scaffold: `QIP_FILE` / `SDC_FILE` export policy + vendor PLL build assertions**
