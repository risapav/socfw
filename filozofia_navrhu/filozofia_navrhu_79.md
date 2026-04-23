Áno. Tu je **Commit 18 ako file-by-file scaffold**:

# Commit 18 — `simple_bus -> wishbone` bridge compatibility model + validate green pre `vendor_sdram_soc`

Cieľ tohto commitu:

* prestať hlásiť `BRG001` pre prípad, ktorý už chceme podporiť
* zaviesť prvý **bridge compatibility model**
* dostať `vendor_sdram_soc` z:

  * “red-but-correct”
    na
  * “validate green”
* stále ešte bez plného bridge RTL insertion, ak nechceš scope nafúknuť

Toto je správny commit, lebo po ňom už nový flow nebude len vedieť povedať, že bridge chýba, ale bude vedieť povedať:

> tento protocol pair je podporovaný

---

# Názov commitu

```text
bridge: add simple_bus-to-wishbone compatibility model and make vendor_sdram_soc validation pass
```

---

# 1. Čo má byť výsledok po Commite 18

Po tomto commite má platiť:

```bash
socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml
```

A očakávaš:

* `vendor_sdram_soc` už nehlási `BRG001`
* fixture je validate-green
* systém vie, že:

  * fabric `simple_bus`
  * IP slave interface `wishbone`
  * sú kompatibilné cez registrovaný bridge pair

Na tomto commite ešte **nemusíš** generovať bridge RTL.
Cieľ je:

* kompatibilita v modeli
* správna validácia
* groundwork pre ďalší build/elaboration commit

---

# 2. Súbory, ktoré pridať

```text
socfw/model/bridge.py
socfw/elaborate/bridge_registry.py
tests/unit/test_bridge_registry.py
tests/integration/test_validate_vendor_sdram_soc_with_bridge_support.py
```

---

# 3. Súbory, ktoré upraviť

```text
socfw/validate/rules/bridge_rules.py
socfw/validate/runner.py
```

Voliteľne:

```text
socfw/model/system.py
```

ak chceš helper na registry attach, ale nie je to nutné.

---

# 4. Kľúčové rozhodnutie pre Commit 18

Správny scope je:

## zaviesť len bridge compatibility registry, nie bridge builder

To znamená:

* registry vie povedať:

  * `simple_bus -> wishbone` = supported
* validation rule sa pozrie:

  * ak sa protokoly nerovnajú
  * opýta sa registry
  * ak pair existuje, chyba sa neemitne

To je presne správny ďalší krok.

---

# 5. `socfw/model/bridge.py`

Toto je malý model, nič zbytočne ťažké.

```python
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BridgeSupport:
    src_protocol: str
    dst_protocol: str
    bridge_kind: str
    notes: str | None = None
```

---

# 6. `socfw/elaborate/bridge_registry.py`

Toto je hlavný nový súbor commitu.

```python
from __future__ import annotations

from socfw.model.bridge import BridgeSupport


class BridgeRegistry:
    def __init__(self) -> None:
        self._pairs: dict[tuple[str, str], BridgeSupport] = {}
        self._register_builtin()

    def _register_builtin(self) -> None:
        self.register(
            BridgeSupport(
                src_protocol="simple_bus",
                dst_protocol="wishbone",
                bridge_kind="simple_bus_to_wishbone",
                notes="Phase-1 compatibility registration",
            )
        )

    def register(self, support: BridgeSupport) -> None:
        self._pairs[(support.src_protocol, support.dst_protocol)] = support

    def find_bridge(self, *, src_protocol: str, dst_protocol: str) -> BridgeSupport | None:
        return self._pairs.get((src_protocol, dst_protocol))

    def supports(self, *, src_protocol: str, dst_protocol: str) -> bool:
        return self.find_bridge(src_protocol=src_protocol, dst_protocol=dst_protocol) is not None
```

### prečo takto

Toto je:

* malé
* explicitné
* ľahko rozšíriteľné
* a neskôr doň vieš zavesiť aj planner/builder vrstvy

---

# 7. úprava `socfw/validate/rules/bridge_rules.py`

Teraz rule potrebuje registry.

## nahradiť týmto

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class MissingBridgeRule(ValidationRule):
    """
    Phase-1 bridge validation:
    - if module bus fabric protocol != module slave interface protocol
    - ask bridge registry
    - emit error only if unsupported
    """

    def __init__(self, registry) -> None:
        self.registry = registry

    def validate(self, system) -> list:
        diags = []

        for idx, mod in enumerate(system.project.modules):
            if mod.bus is None:
                continue

            fabric = system.project.fabric_by_name(mod.bus.fabric)
            if fabric is None:
                diags.append(
                    Diagnostic(
                        code="BUS001",
                        severity=Severity.ERROR,
                        message=f"Unknown fabric '{mod.bus.fabric}' for module '{mod.instance}'",
                        subject="project.modules.bus",
                        file=system.sources.project_file,
                        path=f"modules[{idx}].bus.fabric",
                        hints=("Define the fabric in project.buses.",),
                    )
                )
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            iface = ip.slave_bus_interface()
            if iface is None:
                if ip.needs_bus:
                    diags.append(
                        Diagnostic(
                            code="BUS002",
                            severity=Severity.ERROR,
                            message=f"IP '{ip.name}' requires a bus but declares no slave bus interface",
                            subject="ip.bus_interfaces",
                            file=system.sources.project_file,
                            path=f"modules[{idx}]",
                        )
                    )
                continue

            if iface.protocol == fabric.protocol:
                continue

            if self.registry.supports(
                src_protocol=fabric.protocol,
                dst_protocol=iface.protocol,
            ):
                continue

            diags.append(
                Diagnostic(
                    code="BRG001",
                    severity=Severity.ERROR,
                    message=(
                        f"No bridge registered for fabric protocol '{fabric.protocol}' "
                        f"to peripheral protocol '{iface.protocol}'"
                    ),
                    subject="project.modules.bus",
                    file=system.sources.project_file,
                    path=f"modules[{idx}].bus",
                    hints=(
                        "Add a bridge planner/adapter for this protocol pair.",
                        "Or change the module interface protocol to match the selected fabric.",
                    ),
                )
            )

        return diags
```

### čo sa zmenilo

Predtým:

* mismatch = automaticky chyba

Teraz:

* mismatch → opýtať sa registry
* chyba len ak pair nie je podporovaný

To je presne správne.

---

# 8. úprava `socfw/validate/runner.py`

Treba vytvoriť registry a poslať ho do rule.

## nahradiť týmto

```python
from __future__ import annotations

from socfw.elaborate.bridge_registry import BridgeRegistry
from socfw.validate.rules.bridge_rules import MissingBridgeRule
from socfw.validate.rules.cpu_rules import CpuMissingBusMasterWarningRule, UnknownCpuTypeRule
from socfw.validate.rules.ip_rules import UnknownIpTypeRule
from socfw.validate.rules.project_rules import DuplicateModuleInstanceRule, EmptyProjectWarningRule


class ValidationRunner:
    def __init__(self) -> None:
        self.bridge_registry = BridgeRegistry()
        self.rules = [
            EmptyProjectWarningRule(),
            DuplicateModuleInstanceRule(),
            UnknownCpuTypeRule(),
            CpuMissingBusMasterWarningRule(),
            UnknownIpTypeRule(),
            MissingBridgeRule(self.bridge_registry),
        ]

    def run(self, system) -> list:
        diags = []
        for rule in self.rules:
            diags.extend(rule.validate(system))
        return diags
```

---

# 9. `tests/unit/test_bridge_registry.py`

Tento test overí registry samotný.

```python
from socfw.elaborate.bridge_registry import BridgeRegistry


def test_bridge_registry_supports_simple_bus_to_wishbone():
    reg = BridgeRegistry()
    assert reg.supports(src_protocol="simple_bus", dst_protocol="wishbone")
    assert not reg.supports(src_protocol="wishbone", dst_protocol="simple_bus")
```

### prečo aj reverse assertion

Lebo ti hneď ukáže, že registry je:

* smerový
* explicitný
* nie “magicky symmetric”

To je správne.

---

# 10. úprava `tests/unit/test_bridge_validation_rule.py`

Teraz treba doplniť registry do rule.

## nahradiť týmto

```python
from socfw.elaborate.bridge_registry import BridgeRegistry
from socfw.model.board import BoardClock, BoardModel
from socfw.model.bus import BusFabric, IpBusInterface, ModuleBusAttachment
from socfw.model.cpu import CpuBusMasterDesc, CpuDescriptor
from socfw.model.ip import IpDescriptor
from socfw.model.project import ProjectCpu, ProjectModel, ProjectModule
from socfw.model.source_context import SourceContext
from socfw.model.system import SystemModel
from socfw.validate.rules.bridge_rules import MissingBridgeRule


def test_missing_bridge_rule_reports_protocol_mismatch_when_unregistered():
    system = SystemModel(
        board=BoardModel(
            board_id="demo",
            system_clock=BoardClock(id="clk", top_name="SYS_CLK", pin="A1", frequency_hz=50_000_000),
        ),
        project=ProjectModel(
            name="demo",
            mode="soc",
            board_ref="demo",
            buses=[BusFabric(name="main", protocol="axi_lite")],
            cpu=ProjectCpu(instance="cpu0", type_name="dummy_cpu", fabric="main"),
            modules=[
                ProjectModule(
                    instance="sdram0",
                    type_name="sdram_ctrl",
                    bus=ModuleBusAttachment(fabric="main", base=0x80000000, size=0x01000000),
                )
            ],
        ),
        ip_catalog={
            "sdram_ctrl": IpDescriptor(
                name="sdram_ctrl",
                module="sdram_ctrl",
                category="memory",
                needs_bus=True,
                bus_interfaces=(
                    IpBusInterface(
                        port_name="wb",
                        protocol="wishbone",
                        role="slave",
                    ),
                ),
            )
        },
        cpu_catalog={
            "dummy_cpu": CpuDescriptor(
                name="dummy_cpu",
                module="dummy_cpu",
                family="test",
                bus_master=CpuBusMasterDesc(port_name="bus", protocol="simple_bus"),
            )
        },
        sources=SourceContext(project_file="project.yaml"),
    )

    diags = MissingBridgeRule(BridgeRegistry()).validate(system)
    assert any(d.code == "BRG001" for d in diags)


def test_missing_bridge_rule_allows_registered_simple_bus_to_wishbone():
    system = SystemModel(
        board=BoardModel(
            board_id="demo",
            system_clock=BoardClock(id="clk", top_name="SYS_CLK", pin="A1", frequency_hz=50_000_000),
        ),
        project=ProjectModel(
            name="demo",
            mode="soc",
            board_ref="demo",
            buses=[BusFabric(name="main", protocol="simple_bus")],
            cpu=ProjectCpu(instance="cpu0", type_name="dummy_cpu", fabric="main"),
            modules=[
                ProjectModule(
                    instance="sdram0",
                    type_name="sdram_ctrl",
                    bus=ModuleBusAttachment(fabric="main", base=0x80000000, size=0x01000000),
                )
            ],
        ),
        ip_catalog={
            "sdram_ctrl": IpDescriptor(
                name="sdram_ctrl",
                module="sdram_ctrl",
                category="memory",
                needs_bus=True,
                bus_interfaces=(
                    IpBusInterface(
                        port_name="wb",
                        protocol="wishbone",
                        role="slave",
                    ),
                ),
            )
        },
        cpu_catalog={
            "dummy_cpu": CpuDescriptor(
                name="dummy_cpu",
                module="dummy_cpu",
                family="test",
                bus_master=CpuBusMasterDesc(port_name="bus", protocol="simple_bus"),
            )
        },
        sources=SourceContext(project_file="project.yaml"),
    )

    diags = MissingBridgeRule(BridgeRegistry()).validate(system)
    assert not any(d.code == "BRG001" for d in diags)
```

### prečo dva testy

Jeden overí:

* unsupported pair stále padá

Druhý overí:

* nový supported pair už prejde

To je veľmi dobrý regression set.

---

# 11. `tests/integration/test_validate_vendor_sdram_soc_with_bridge_support.py`

Toto je hlavný integration test commitu.

```python
from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_vendor_sdram_soc_passes_with_simple_bus_to_wishbone_support():
    result = FullBuildPipeline().validate("tests/golden/fixtures/vendor_sdram_soc/project.yaml")

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    assert result.value is not None
    assert "sdram_ctrl" in result.value.ip_catalog
```

---

# 12. Čo spraviť s pôvodným testom `test_validate_vendor_sdram_soc_missing_bridge.py`

Ten bol správny pre Commit 17, ale teraz už bude nepravdivý.

## odporúčanie

Buď:

* ho odstráň
* alebo ho premenuj a zmeň fixture na iný nepodporovaný pair, napr. `axi_lite -> wishbone`

### lepšia voľba

Prekonvertovať ho na negative fixture neskôr, napr.:

* `vendor_sdram_soc_unsupported_bus`

Na Commit 18 by som ten starý test radšej nahradil novým green testom.

---

# 13. Voliteľná drobná úprava `socfw/model/system.py`

Ak chceš, môžeš doplniť helper:

```python
    def bridge_supported(self, src_protocol: str, dst_protocol: str, registry) -> bool:
        return registry.supports(src_protocol=src_protocol, dst_protocol=dst_protocol)
```

Ale úprimne: na Commit 18 to netreba.

---

# 14. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* bridge IR
* bridge RTL insertion
* wishbone signal mapping
* build test pre `vendor_sdram_soc`
* `QIP_FILE` assertions pre SDRAM
* golden snapshot pre SDRAM fixture

Commit 18 má riešiť len:

* compatibility model
* validate green

To je správny scope.

---

# 15. Čo po Commite 18 overiť

Spusti:

```bash
pip install -e .
socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml
pytest tests/unit/test_bridge_registry.py
pytest tests/unit/test_bridge_validation_rule.py
pytest tests/integration/test_validate_vendor_sdram_soc_with_bridge_support.py
```

### očakávanie

* registry test green
* bridge rule test green
* vendor SDRAM fixture validate green

To je veľmi dôležitý checkpoint.

---

# 16. Definition of Done pre Commit 18

Commit 18 je hotový, keď:

* `BridgeRegistry` existuje
* `simple_bus -> wishbone` je registrovaný pair
* `MissingBridgeRule` používa registry
* `vendor_sdram_soc` validate prejde

To je správny bridge-compatibility míľnik.

---

# 17. Čo má byť Commit 19

Po tomto by som išiel priamo na:

## Commit 19

```text
build: add first SDRAM bridge-aware compatibility wiring in legacy build path
```

Ten prinesie:

* prvý build attempt pre `vendor_sdram_soc`
* bridge-aware compatibility shim v `legacy_build.py`
* aspoň scaffold-level top generation s bridge path

To je ďalší prirodzený krok.

---

# 18. Môj praktický odporúčaný rytmus

Po Commite 18:

1. potvrď, že validate green je stabilný
2. nesnaž sa ešte hneď snapshotovať SDRAM
3. až potom skús build path
4. build môže byť najprv scaffold-level, nie plne funkčný

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 19 ako file-by-file scaffold: prvý bridge-aware `vendor_sdram_soc` build path cez compatibility shim**
