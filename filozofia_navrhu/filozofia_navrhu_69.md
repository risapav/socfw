Áno. Tu je **Commit 8 ako file-by-file scaffold**:

# Commit 8 — prvé validation rules + čitateľné diagnostics pre board / project / IP / CPU resolution

Cieľ tohto commitu:

* prestať sa spoliehať len na to, že loader “nejako prejde”
* zaviesť prvé **skutočné validačné pravidlá**
* dostať z `socfw validate` zmysluplné chyby typu:

  * neznámy CPU
  * neznámy IP typ
  * chýbajúci board
  * prázdny / podozrivý projekt

Toto je veľmi dôležitý commit, lebo od tohto bodu už nový flow nezačne byť len parser, ale aj **kontrolná vrstva**.

---

# Názov commitu

```text
validate: add first real validation rules for board project cpu and ip resolution
```

---

# 1. Súbory, ktoré pridať

```text
socfw/validate/rules/project_rules.py
socfw/validate/rules/cpu_rules.py
socfw/validate/rules/ip_rules.py
socfw/validate/runner.py
tests/unit/test_validation_rules_basic.py
tests/integration/test_validate_reports_missing_cpu_and_ip.py
```

---

# 2. Súbory, ktoré upraviť

```text
socfw/core/result.py
socfw/build/full_pipeline.py
socfw/cli/main.py
socfw/config/system_loader.py
```

Len malé a kontrolované zmeny.

---

# 3. Dôležitý princíp pre Commit 8

Doteraz:

* `SystemLoader` robil load + resolve
* a chyby boli hlavne parse/load chyby

Teraz zavedieme:

## dvojkrokový model

1. **loader**

   * načíta model
   * vyrieši cesty / katalógy
2. **validator**

   * povie, či model dáva zmysel

To je správny architektonický rez.

---

# 4. `socfw/validate/rules/project_rules.py`

Začni veľmi malým setom.
Nerieš ešte bus overlapy ani clock graf.

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class EmptyProjectWarningRule(ValidationRule):
    def validate(self, system) -> list:
        if system.project.cpu is None and not system.project.modules:
            return [
                Diagnostic(
                    code="PRJ200",
                    severity=Severity.WARNING,
                    message="Project defines neither a CPU nor any modules",
                    subject="project",
                    file=system.sources.project_file,
                    hints=("Add at least one module or define a CPU.",),
                )
            ]
        return []


class DuplicateModuleInstanceRule(ValidationRule):
    def validate(self, system) -> list:
        seen = set()
        diags = []

        for idx, mod in enumerate(system.project.modules):
            if mod.instance in seen:
                diags.append(
                    Diagnostic(
                        code="PRJ201",
                        severity=Severity.ERROR,
                        message=f"Duplicate module instance name '{mod.instance}'",
                        subject="project.modules",
                        file=system.sources.project_file,
                        path=f"modules[{idx}]",
                        hints=("Use unique instance names for all modules.",),
                    )
                )
            seen.add(mod.instance)

        return diags
```

---

# 5. `socfw/validate/rules/cpu_rules.py`

Toto bude prvé veľmi dôležité pravidlo.

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class UnknownCpuTypeRule(ValidationRule):
    def validate(self, system) -> list:
        if system.project.cpu is None:
            return []

        cpu_type = system.project.cpu.type_name
        if cpu_type not in system.cpu_catalog:
            known = ", ".join(sorted(system.cpu_catalog.keys())) or "none"
            return [
                Diagnostic(
                    code="CPU001",
                    severity=Severity.ERROR,
                    message=f"Unknown CPU type '{cpu_type}'",
                    subject="project.cpu",
                    file=system.sources.project_file,
                    path="cpu.type",
                    hints=(
                        "Add a matching *.cpu.yaml descriptor to a registered CPU catalog path.",
                        "Or change project.cpu.type to an existing CPU descriptor.",
                        f"Known CPU descriptors: {known}",
                    ),
                )
            ]
        return []


class CpuMissingBusMasterWarningRule(ValidationRule):
    def validate(self, system) -> list:
        desc = system.cpu_desc()
        if desc is None:
            return []

        if system.project.mode == "soc" and desc.bus_master is None:
            return [
                Diagnostic(
                    code="CPU002",
                    severity=Severity.WARNING,
                    message=f"CPU '{desc.name}' has no bus_master descriptor in a SoC project",
                    subject="cpu.bus_master",
                    file=system.sources.project_file,
                    hints=(
                        "Add a bus_master section to the CPU descriptor if this CPU should drive the SoC fabric.",
                    ),
                )
            ]

        return []
```

---

# 6. `socfw/validate/rules/ip_rules.py`

Toto je druhé kľúčové pravidlo.

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class UnknownIpTypeRule(ValidationRule):
    def validate(self, system) -> list:
        diags = []

        known = ", ".join(sorted(system.ip_catalog.keys())) or "none"

        for idx, mod in enumerate(system.project.modules):
            if mod.type_name not in system.ip_catalog:
                diags.append(
                    Diagnostic(
                        code="IP001",
                        severity=Severity.ERROR,
                        message=f"Unknown IP type '{mod.type_name}' for instance '{mod.instance}'",
                        subject="project.modules",
                        file=system.sources.project_file,
                        path=f"modules[{idx}].type",
                        hints=(
                            "Add a matching *.ip.yaml descriptor to a registered IP catalog path.",
                            "Or change the module type to an existing IP descriptor.",
                            f"Known IP descriptors: {known}",
                        ),
                    )
                )

        return diags


class DuplicateIpDescriptorWarningRule(ValidationRule):
    def validate(self, system) -> list:
        # Placeholder for richer duplicate provenance later.
        return []
```

---

# 7. `socfw/validate/runner.py`

Toto je nový centrálny runner validation pravidiel.

```python
from __future__ import annotations

from socfw.validate.rules.cpu_rules import CpuMissingBusMasterWarningRule, UnknownCpuTypeRule
from socfw.validate.rules.ip_rules import UnknownIpTypeRule
from socfw.validate.rules.project_rules import DuplicateModuleInstanceRule, EmptyProjectWarningRule


class ValidationRunner:
    def __init__(self) -> None:
        self.rules = [
            EmptyProjectWarningRule(),
            DuplicateModuleInstanceRule(),
            UnknownCpuTypeRule(),
            CpuMissingBusMasterWarningRule(),
            UnknownIpTypeRule(),
        ]

    def run(self, system) -> list:
        diags = []
        for rule in self.rules:
            diags.extend(rule.validate(system))
        return diags
```

### prečo bez registry

Na Commit 8 by som to ešte nekomplikoval plugin registry modelom.
Najprv nech validation pipeline žije. Registry príde neskôr.

---

# 8. úprava `socfw/core/result.py`

Teraz je vhodné mať pomocný merge pattern.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Generic, TypeVar

from socfw.core.diagnostics import Severity

T = TypeVar("T")


@dataclass
class Result(Generic[T]):
    value: T | None = None
    diagnostics: list = field(default_factory=list)

    @property
    def ok(self) -> bool:
        for d in self.diagnostics:
            sev = getattr(d, "severity", None)
            if sev == Severity.ERROR or getattr(sev, "value", None) == "error":
                return False
        return True

    def extend(self, diags: list) -> None:
        self.diagnostics.extend(diags)
```

Nie je to nutné, ale praktické.

---

# 9. úprava `socfw/build/full_pipeline.py`

Teraz do pipeline vlož validation runner.

## nahradiť týmto

```python
from __future__ import annotations

from socfw.build.legacy_backend import LegacyBackend
from socfw.build.result import BuildResult
from socfw.config.system_loader import SystemLoader
from socfw.validate.runner import ValidationRunner


class FullBuildPipeline:
    def __init__(self) -> None:
        self.loader = SystemLoader()
        self.validator = ValidationRunner()
        self.legacy = LegacyBackend()

    def validate(self, project_file: str):
        loaded = self.loader.load(project_file)
        if loaded.ok and loaded.value is not None:
            loaded.extend(self.validator.run(loaded.value))
        return loaded

    def build(self, request) -> BuildResult:
        loaded = self.validate(request.project_file)

        diags = list(loaded.diagnostics)
        if not loaded.ok or loaded.value is None:
            return BuildResult(ok=False, diagnostics=diags, generated_files=[])

        built = self.legacy.build(system=loaded.value, request=request)
        built.diagnostics = diags + list(built.diagnostics)
        return built
```

Toto je prvý okamih, keď:

* `build` automaticky používa aj validation
* `validate` je samostatná pipeline entry

To je správne.

---

# 10. úprava `socfw/cli/main.py`

Teraz nech `validate` ide cez `FullBuildPipeline`, nie priamo cez `SystemLoader`.

## uprav importy

nahraď:

```python
from socfw.config.system_loader import SystemLoader
```

za:

```python
from socfw.build.full_pipeline import FullBuildPipeline
```

## uprav `cmd_validate`

```python
def cmd_validate(args) -> int:
    pipeline = FullBuildPipeline()
    loaded = pipeline.validate(args.project)
    _print_diags(loaded.diagnostics)

    if loaded.ok and loaded.value is not None:
        timing_info = "timing=none"
        if loaded.value.timing is not None:
            timing_info = (
                f"timing=generated_clocks:{len(loaded.value.timing.generated_clocks)} "
                f"false_paths:{len(loaded.value.timing.false_paths)}"
            )

        cpu_info = "cpu=none"
        if loaded.value.project.cpu is not None:
            resolved = loaded.value.cpu_desc()
            cpu_info = f"cpu={loaded.value.project.cpu.type_name}"
            if resolved is None:
                cpu_info += "(unresolved)"
            else:
                cpu_info += f"(module={resolved.module})"

        print(
            f"OK: project={loaded.value.project.name} "
            f"board={loaded.value.board.board_id} "
            f"ip_catalog={len(loaded.value.ip_catalog)} "
            f"cpu_catalog={len(loaded.value.cpu_catalog)} "
            f"{cpu_info} "
            f"{timing_info}"
        )
        return 0
    return 1
```

Toto je malá zmena, ale dôležitá:

* CLI už ide cez unified validate path

---

# 11. Voliteľná malá úprava `socfw/config/system_loader.py`

Ak chceš lepšie future diagnostics, môžeš doplniť `ip_files` mapu reálnymi cestami, ale na Commit 8 to nie je nutné.

---

# 12. `tests/unit/test_validation_rules_basic.py`

Tento test je veľmi dôležitý.
Nech je priamo na pravidlá, bez zbytočného loader noise.

```python
from socfw.core.diagnostics import Severity
from socfw.model.board import BoardClock, BoardModel
from socfw.model.cpu import CpuDescriptor
from socfw.model.project import ProjectCpu, ProjectModel, ProjectModule
from socfw.model.source_context import SourceContext
from socfw.model.system import SystemModel
from socfw.validate.runner import ValidationRunner


def test_unknown_cpu_type_rule_triggers():
    system = SystemModel(
        board=BoardModel(
            board_id="demo",
            system_clock=BoardClock(id="clk", top_name="SYS_CLK", pin="A1", frequency_hz=50_000_000),
        ),
        project=ProjectModel(
            name="demo",
            mode="soc",
            board_ref="demo",
            cpu=ProjectCpu(instance="cpu0", type_name="missing_cpu"),
            modules=[],
        ),
        timing=None,
        ip_catalog={},
        cpu_catalog={},
        sources=SourceContext(project_file="project.yaml"),
    )

    diags = ValidationRunner().run(system)
    assert any(d.code == "CPU001" and d.severity == Severity.ERROR for d in diags)


def test_unknown_ip_type_rule_triggers():
    system = SystemModel(
        board=BoardModel(
            board_id="demo",
            system_clock=BoardClock(id="clk", top_name="SYS_CLK", pin="A1", frequency_hz=50_000_000),
        ),
        project=ProjectModel(
            name="demo",
            mode="standalone",
            board_ref="demo",
            modules=[ProjectModule(instance="u0", type_name="missing_ip")],
        ),
        timing=None,
        ip_catalog={},
        cpu_catalog={},
        sources=SourceContext(project_file="project.yaml"),
    )

    diags = ValidationRunner().run(system)
    assert any(d.code == "IP001" and d.severity == Severity.ERROR for d in diags)
```

---

# 13. `tests/integration/test_validate_reports_missing_cpu_and_ip.py`

Toto je prvý praktický validate UX test.

```python
from pathlib import Path

from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_reports_missing_cpu_and_ip(tmp_path):
    packs_builtin = Path("packs/builtin").resolve()

    project_file = tmp_path / "project.yaml"
    project_file.write_text(
        f"""
version: 2
kind: project

project:
  name: bad_soc
  mode: soc
  board: qmtech_ep4ce55

registries:
  packs:
    - {packs_builtin}

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

cpu:
  instance: cpu0
  type: nonexistent_cpu
  fabric: main

modules:
  - instance: periph0
    type: nonexistent_ip
""",
        encoding="utf-8",
    )

    result = FullBuildPipeline().validate(str(project_file))
    assert not result.ok
    codes = {d.code for d in result.diagnostics}
    assert "CPU001" in codes
    assert "IP001" in codes
```

---

# 14. Čo v tomto commite ešte **nerobiť**

Vedome by som stále nechal bokom:

* bus rules
* clock graph validation
* bridge rules
* vendor rules
* RAM rules
* richer diagnostics model v2

Commit 8 má riešiť len:

* prvé základné rozumové validation pravidlá

To je správny scope.

---

# 15. Čo po Commite 8 overiť

Spusti:

```bash
pip install -e .
socfw validate project_config.yaml
pytest tests/unit/test_validation_rules_basic.py
pytest tests/integration/test_validate_reports_missing_cpu_and_ip.py
```

### očakávanie

* validate už nebude len “loader passes”
* ale bude dávať prvé zmysluplné chyby

Toto je veľmi dôležitý milestone.

---

# 16. Pravdepodobné riziko v Commite 8

Najväčšie riziko je, že reálny legacy projekt bude hlásiť veľa chýb naraz, lebo ešte:

* CPU catalog nie je doplnený
* IP descriptor shape nie je plne namapovaný
* project compatibility mapping nie je úplný

To je v poriadku.

### riešenie

Nesnaž sa hneď spraviť validate “clean” pre všetko.
Najprv:

* nech sú chyby pravdivé
* potom po jednej opravuj compatibility mapping

To je správny postup.

---

# 17. Definition of Done pre Commit 8

Commit 8 je hotový, keď:

* `FullBuildPipeline.validate()` existuje a používa validation runner
* `socfw validate` ide cez novú validate pipeline
* neznámy CPU dá `CPU001`
* neznámy IP dá `IP001`
* duplicate module instance vie dať chybu
* empty project vie dať warning

To je veľmi dobrý checkpoint.

---

# 18. Čo má byť Commit 9

Po tomto by som išiel na:

## Commit 9

```text
emit: add first new deterministic report and validation summary output
```

alebo alternatívne, ak chceš skôr buildovať:

## Commit 9

```text
build: wire real legacy entrypoint into LegacyBackend and stabilize first build artifact assertions
```

Môj praktický odporúčaný ďalší krok je skôr:

👉 **najprv stabilizovať reálny build wrapper**

Lebo už:

* loader funguje
* validation funguje
* a teraz chceš, aby `socfw build` naozaj robil použiteľný build, nie len shim.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 9 ako file-by-file scaffold: napojenie reálneho legacy entrypointu do `LegacyBackend` + prvé build assertions**
