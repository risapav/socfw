Super. Ideme na:

# vendor IP cleanup: Quartus/QIP pack model, generated IP descriptors, artifact normalization, and integration policy

Toto je veľmi dôležitý krok pre tvoj pôvodný use-case, lebo práve tu sa láme rozdiel medzi:

* pekným frameworkom na papieri
* a frameworkom, ktorý vie rozumne absorbovať reálne Quartus-generated IP

Najmä:

* PLL
* SDRAM controller
* ALTPLL / altera_mf závislosti
* `.qip`
* `.sdc`
* generated `.v/.sv`
* niekedy aj helper `.tcl`

Cieľ je spraviť to tak, aby generated vendor IP:

* bolo **čisté a opakovateľné**
* malo **descriptor contract**
* dalo sa **zdieľať v packoch**
* a zároveň neznečisťovalo jadro frameworku vendor-špecifickou logikou

---

# 1. Architektonický princíp

Odporúčam veľmi jasne oddeliť dve veci:

## A. framework-level IP model

Framework má vedieť:

* že IP existuje,
* aké má porty,
* aké má artefakty,
* aké clock outputs generuje,
* aké timing dependency prináša,
* či je direct-instantiated alebo dependency-only.

## B. vendor packaging model

Vendor špecifické veci nech sú len:

* artefakty
* pack layout
* metadata o integrácii

Teda nie:

* hardcoded Quartus vetvy rozliate po builderoch

ale:

* descriptor + artifact normalization + emitter policy

To je správny smer.

---

# 2. Čo je problém Quartus IP dnes

Quartus-generated IP často príde ako mix:

* `.qip`
* `.sip`
* `.tcl`
* `.sdc`
* generated `.v`
* generated `.sv`
* helper subdirs
* niekedy memory init files

A bežné chyby bývajú:

* relatívne cesty v `.qip`
* project-specific vygenerované cesty
* rovnaké IP nakopírované do viacerých projektov
* nejasné, čo je “zdroj pravdy”
* ručné dopĺňanie do `files.tcl`

Tvoj nový framework by to mal vyriešiť tak, že:

* IP descriptor je zdroj pravdy
* artifact paths sa normalizujú
* emitter vie, čo je synthesis dependency a čo timing dependency

---

# 3. Odporúčaný pack layout pre vendor IP

Toto by som považoval za referenčný model.

```text
packs/
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
              sys_pll.ppf
              sys_pll.spd
              sys_pll.sdc
        sdram/
          sdram_ctrl/
            ip.yaml
            files/
              sdram_ctrl.qip
              sdram_ctrl.v
              sdram_ctrl.sdc
              ...
```

Kľúčové:

* každý generated IP block má vlastný adresár
* descriptor `ip.yaml` sedí vedľa artifactov
* všetky artifact paths sú relatívne k descriptoru
* framework ich normalizuje pri load-e

To je čisté a veľmi dobre prenositeľné.

---

# 4. Nový vendor-aware IP metadata contract

Doteraz máš `origin.kind`, `packaging`, `artifacts`. Pre vendor IP treba ešte trochu bohatší contract.

## update `socfw/config/ip_schema.py`

Pridaj:

```python
class IpVendorSchema(BaseModel):
    vendor: str
    tool: str
    generator: str | None = None
    family: str | None = None
    qip: str | None = None
    sdc: list[str] = Field(default_factory=list)
    filesets: list[str] = Field(default_factory=list)
```

A do `IpConfigSchema`:

```python
    vendor: IpVendorSchema | None = None
```

---

## update `socfw/model/ip.py`

Pridaj:

```python
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class IpVendorInfo:
    vendor: str
    tool: str
    generator: str | None = None
    family: str | None = None
    qip: str | None = None
    sdc: tuple[str, ...] = ()
    filesets: tuple[str, ...] = ()
```

A do `IpDescriptor`:

```python
    vendor_info: IpVendorInfo | None = None
```

---

## update `socfw/config/ip_loader.py`

Pri skladaní `IpDescriptor(...)`:

```python
            vendor_info=(
                IpVendorInfo(
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
```

Tým pádom je vendor info explicitne modelované a nie schované v adhoc meta dict.

---

# 5. Generated vendor IP descriptor pattern

Tu je odporúčaný descriptor pre Quartus PLL.

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

Toto je presne to, čo chceš:

* descriptor je framework-native
* vendor info je explicitná
* artifacts sú stále relatívne a normalizované
* clock outputs sú modelované rovnako ako pri custom IP

---

# 6. Generated SDRAM IP descriptor pattern

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

Týmto vieš dať generated vendor IP priamo za bridge alebo priamo na kompatibilný fabric.

---

# 7. Artifact normalization policy

Toto musí byť úplne jasné.

## odporúčaná politika

Pri load-e:

* všetky artifact cesty normalizovať na absolútne
* `qip`, `sdc`, `synthesis`, `simulation`, `metadata` všetko rovnako

To zabezpečí:

* pack môže byť premiestnený
* project môže byť spustený odkiaľkoľvek
* emitter nerieši relatívne cesty

Toto je veľmi dôležité a podľa mňa správne.

---

# 8. Fileset klasifikácia

Generated vendor IP má často zmiešané artefakty. Pomôže mať jemnú klasifikáciu.

Odporúčam zaviesť fileset tags, ale najprv len logicky, nie úplne veľký model.

Napríklad:

* `quartus_qip`
* `timing_sdc`
* `generated_rtl`
* `memory_init`
* `vendor_support`

Toto môže byť najprv len metadata v `vendor.filesets`.

Neskôr sa to dá použiť pre:

* emit policy
* lint
* synth export
* simulation export

---

# 9. QIP-aware board/files emitter policy

Toto je kľúčové:
Quartus nechce vždy len plain list Verilog súborov. Niekedy je správnejšie zaradiť `.qip`.

Odporúčam policy:

## pre Quartus `files.tcl`

* ak IP má `vendor_info.qip`, preferuj:

  * `set_global_assignment -name QIP_FILE <...>`
* plain RTL súbory pridávaj len pre non-QIP alebo doplnkové sources
* `.sdc` daj ako timing dependency

To je oveľa čistejšie než rozbalovať vendor IP na všetky interné generated súbory.

---

## update `socfw/emit/files_emitter.py` alebo príslušný TCL emitter

Potrebný model:

* artifacts z `ip.artifacts.synthesis`
* plus vendor `qip`

Pseudo-policy:

```python
if ip.vendor_info and ip.vendor_info.qip:
    emit_qip_assignment(ip.vendor_info.qip)
else:
    emit_verilog_files(ip.artifacts.synthesis)
```

A timing:

```python
for sdc in ip.vendor_info.sdc:
    emit_sdc_reference(sdc)
```

---

# 10. Nový TCL helper model

## nový `socfw/model/vendor_artifacts.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class VendorArtifactBundle:
    qip_files: list[str] = field(default_factory=list)
    sdc_files: list[str] = field(default_factory=list)
    rtl_files: list[str] = field(default_factory=list)
```

Toto vieš použiť v board/files emitri.

---

# 11. Vendor artifact collector

## nový `socfw/builders/vendor_artifact_collector.py`

```python
from __future__ import annotations

from socfw.model.vendor_artifacts import VendorArtifactBundle


class VendorArtifactCollector:
    def collect(self, design) -> VendorArtifactBundle:
        bundle = VendorArtifactBundle()
        seen = set()

        used_types = {m.type_name for m in design.system.project.modules}
        if design.system.cpu is not None:
            used_types.add(design.system.cpu.type_name)

        for t in sorted(used_types):
            ip = design.system.ip_catalog.get(t)
            if ip is not None and ip.vendor_info is not None:
                if ip.vendor_info.qip and ip.vendor_info.qip not in seen:
                    bundle.qip_files.append(ip.vendor_info.qip)
                    seen.add(ip.vendor_info.qip)
                for sdc in ip.vendor_info.sdc:
                    if sdc not in seen:
                        bundle.sdc_files.append(sdc)
                        seen.add(sdc)

            cpu = design.system.cpu_desc()
            if cpu is not None:
                # CPU vendor handling can come later if needed
                pass

        return bundle
```

---

# 12. Files/TCL emitter update

Toto je veľmi dôležité, ale ideálne spraviť ho jemne.

Ak máš `files.tcl.j2`, rozšír IR alebo context o:

* `qip_files`
* `extra_sdc_files`

Napríklad v `RtlModuleIR` alebo samostatnom files IR.

Najčistejšie je pridať nový IR.

## nový `socfw/ir/files.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class FilesIR:
    rtl_files: list[str] = field(default_factory=list)
    qip_files: list[str] = field(default_factory=list)
    sdc_files: list[str] = field(default_factory=list)
```

---

## nový `socfw/builders/files_ir_builder.py`

```python
from __future__ import annotations

from socfw.ir.files import FilesIR
from socfw.builders.vendor_artifact_collector import VendorArtifactCollector


class FilesIRBuilder:
    def __init__(self) -> None:
        self.vendor = VendorArtifactCollector()

    def build(self, design, rtl_ir) -> FilesIR:
        v = self.vendor.collect(design)
        ir = FilesIR(
            rtl_files=list(rtl_ir.extra_sources),
            qip_files=sorted(v.qip_files),
            sdc_files=sorted(v.sdc_files),
        )
        return ir
```

---

## template `files.tcl.j2`

Doplň:

```jinja2
# AUTO-GENERATED - DO NOT EDIT

{% for q in files.qip_files -%}
set_global_assignment -name QIP_FILE {{ q }}
{% endfor %}

{% for f in files.rtl_files -%}
set_global_assignment -name VERILOG_FILE {{ f }}
{% endfor %}

{% for s in files.sdc_files -%}
set_global_assignment -name SDC_FILE {{ s }}
{% endfor %}
```

To je podľa mňa správny model pre Quartus.

---

# 13. Vendor pack resolution policy

Toto treba explicitne popísať.

## odporúčaná politika

Vendor IP sa načítava rovnako ako normálne packy, ale:

* artifacts sú vždy normalizované
* `.qip` sa preferuje pred rozpisom interných vendor generated sources
* `.sdc` ide do timing/files exportu
* IP descriptor stále nesie framework-level informácie:

  * porty
  * bus interface
  * clocks
  * reset
  * integration behavior

To je kľúčové:
vendor IP sa nesmie stať “special snowflake” mimo frameworkového modelu.

---

# 14. Integration policy pre PLL

PLL je výborný príklad.

Odporúčam:

* `ip.category = clocking`
* `clocking.outputs` definujú generated clocks
* timing emitter vytvorí alebo zlúči:

  * board timing
  * generated clock constraints
  * vendor `.sdc`

To znamená:

* framework stále chápe semantiku PLL
* vendor `.sdc` je len doplnkový artifact
* nie jediný zdroj pravdy

To je veľmi dôležité.

---

# 15. Integration policy pre SDRAM controller

Pre SDRAM controller odporúčam:

* IP descriptor nech jasne povie:

  * bus protocol
  * reset polarity
  * clock input
  * top-level external pins cez bind model alebo shell
* vendor `.qip` a `.sdc` nech idú cez files/timing export
* board-specific pinout nech ostane v board/project vrstve, nie v IP packu

Tým pádom:

* ten istý SDRAM controller pack vieš použiť na viacerých projektoch
* board-specific wiring zostane mimo generated IP packu

To je správne.

---

# 16. Duplicate and compatibility policy

Keďže packy budú zdieľané, treba policy na konflikt.

## odporúčam:

* rovnaký `ip.name` v dvoch packoch → warning, prvý vyhráva
* rovnaký `board id` v dvoch packoch → warning, prvý vyhráva
* vendor `family` mismatch oproti board FPGA family → warning alebo error podľa prísnosti

Toto posledné je veľmi praktické.

---

## nový validator: vendor family compatibility

### `socfw/validate/rules/vendor_rules.py`

```python
from __future__ import annotations

from socfw.core.diag_builders import warn
from socfw.validate.rules.base import ValidationRule


class VendorFamilyMismatchRule(ValidationRule):
    def validate(self, system) -> list:
        diags = []
        board_family = getattr(system.board.fpga, "family", None)

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None or ip.vendor_info is None:
                continue

            fam = ip.vendor_info.family
            if fam and board_family and fam != board_family:
                diags.append(
                    warn(
                        "VND001",
                        f"Vendor IP '{ip.name}' targets family '{fam}', board uses '{board_family}'",
                        "vendor.family",
                        file=system.sources.project_file,
                        category="vendor",
                        hints=[
                            "Check whether the generated Quartus IP was created for the target FPGA family.",
                            "Regenerate the vendor IP for the board family if necessary.",
                        ],
                    )
                )

        return diags
```

To je veľmi užitočné v praxi.

---

# 17. `socfw init` a vendor packs

Keď už máš packy, `init` môže neskôr ponúkať:

* board výber z catalogu
* CPU výber z packov
* vendor IP starter inclusion

Ale to by som nechal až na `init v2`.

V tejto fáze stačí, že:

* packy fungujú
* vendor IP je prvotriedne modelované
* emitteri s tým vedia pracovať

---

# 18. Integration tests

## `tests/integration/test_vendor_qip_collection.py`

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_vendor_qip_is_emitted_to_files_tcl(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/blink_test_02/project.yaml"
    out_dir = tmp_path / "out"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok

    files_tcl = (out_dir / "hal" / "files.tcl").read_text(encoding="utf-8")
    assert "QIP_FILE" in files_tcl or "VERILOG_FILE" in files_tcl
```

A neskôr sprav špecifický fixture s vendor packom.

---

## `tests/integration/test_vendor_family_warning.py`

* board family = `cyclone_iv_e`
* vendor IP family = `stratix`
* očakávaj `VND001`

To bude praktický validator test.

---

# 19. Čo týmto získaš

Po tomto kroku bude framework vedieť veľmi dôležitú vec:

* absorbovať reálne Quartus-generated IP civilizovaným spôsobom
* zdieľať vendor IP cez packy
* normalizovať ich artefakty
* exportovať ich správne do Quartus files/timing flow
* a pritom stále držať jednotný framework-level model

To je presne veľká časť tvojho pôvodného use-case.

---

# 20. Môj odporúčaný ďalší krok

Po tomto bode sú podľa mňa najlepšie tri smery:

### A

**workspace model**

* viac projektov v jednom workspace
* shared packs + local overrides
* team-level config

### B

**interactive init v2**

* wizard
* pack-aware selection
* template bundles

### C

**full vendor fixture stabilization**

* PLL fixture
* SDRAM fixture
* vendor golden tests

Môj praktický odporúčaný ďalší krok je:

👉 **C — full vendor fixture stabilization (PLL + SDRAM + vendor golden tests)**

Lebo to najlepšie uzavrie tvoj pôvodný praktický cieľ a potvrdí, že návrh naozaj funguje aj na reálnych generated IP use-cases.

Ak chceš, ďalšia správa môže byť presne:
**vendor stabilization sprint: PLL fixture cleanup, SDRAM fixture integration, vendor pack examples, and golden test coverage**
