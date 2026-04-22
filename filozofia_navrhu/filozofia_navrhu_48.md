Super. Ideme na:

# diagnostics v2: source spans, hints, suggested fixes, grouped reporting, explain mode improvements

Toto je veľmi dobrý ďalší krok, pretože framework už vie veľa, ale používateľská kvalita sa teraz najviac zlepší tým, že:

* chyby budú presnejšie,
* reporty budú akčnejšie,
* explain výstupy budú dôveryhodnejšie,
* a validácia prestane pôsobiť ako “string list”.

Toto je presne ten typ vrstvy, ktorý z dobrého interného frameworku robí dobre použiteľný framework.

---

# 1. Cieľ diagnostics v2

Na konci chceš mať chybu napríklad v štýle:

```text
ERROR BRG001 project.modules[1].bus
No bridge registered for fabric protocol 'simple_bus' to peripheral protocol 'wishbone'.

at: tests/golden/fixtures/wishbone_bridge_soc/project.yaml
path: modules[0].bus

hints:
- register a bridge planner for simple_bus -> wishbone
- or change the peripheral bus interface protocol
- or move this IP behind an existing compatible bridge
```

A nie iba:

```text
No bridge registered ...
```

To je veľký rozdiel.

---

# 2. Hlavné problémy dnešného stavu

Dnes už síce máš `Diagnostic`, ale prakticky ešte chýba:

* stabilný **source span/path model**
* **structured hints**
* **suggested fixes**
* **grouped reporting**
* **diagnostic formatting layer**
* lepší `explain` nad validáciou a plánovaním

Teda: model existuje, ale ešte nie je dotiahnutý ako plnohodnotná UX vrstva.

---

# 3. Nový diagnostic model

## update `socfw/core/diagnostics.py`

Odporúčam prejsť na bohatší model:

```python
from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


@dataclass(frozen=True)
class SourceSpan:
    file: str
    path: str | None = None
    line: int | None = None
    column: int | None = None
    end_line: int | None = None
    end_column: int | None = None


@dataclass(frozen=True)
class SuggestedFix:
    message: str
    replacement: str | None = None
    path: str | None = None


@dataclass(frozen=True)
class RelatedDiagnosticRef:
    code: str
    message: str
    subject: str


@dataclass(frozen=True)
class Diagnostic:
    code: str
    severity: Severity
    message: str
    subject: str
    spans: tuple[SourceSpan, ...] = ()
    hints: tuple[str, ...] = ()
    suggested_fixes: tuple[SuggestedFix, ...] = ()
    related: tuple[RelatedDiagnosticRef, ...] = ()
    category: str = "general"
    detail: str | None = None
```

---

# 4. Prečo je toto lepšie

Týmto získaš:

### `spans`

presne ukáže:

* kde je problém,
* v ktorom súbore,
* na akej YAML ceste.

### `hints`

krátke navigačné odporúčania.

### `suggested_fixes`

už skoro actionable návrhy.

### `related`

napríklad pri overlap chybe vieš ukázať obe kolidujúce oblasti.

### `category`

umožní zoskupovanie:

* config
* validation
* bridge
* cpu
* timing
* firmware
* simulation

### `detail`

dlhšie vysvetlenie, keď chceš bohatší explain/report.

---

# 5. Helper factory pre diagnostics

Aby validátory nemuseli stále ručne skladať celý objekt, sprav malý helper.

## nový `socfw/core/diag_builders.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import (
    Diagnostic,
    RelatedDiagnosticRef,
    Severity,
    SourceSpan,
    SuggestedFix,
)


def err(
    code: str,
    message: str,
    subject: str,
    *,
    file: str | None = None,
    path: str | None = None,
    hints: list[str] | None = None,
    fixes: list[SuggestedFix] | None = None,
    related: list[RelatedDiagnosticRef] | None = None,
    category: str = "general",
    detail: str | None = None,
) -> Diagnostic:
    spans = ()
    if file is not None:
        spans = (SourceSpan(file=file, path=path),)

    return Diagnostic(
        code=code,
        severity=Severity.ERROR,
        message=message,
        subject=subject,
        spans=spans,
        hints=tuple(hints or []),
        suggested_fixes=tuple(fixes or []),
        related=tuple(related or []),
        category=category,
        detail=detail,
    )


def warn(
    code: str,
    message: str,
    subject: str,
    *,
    file: str | None = None,
    path: str | None = None,
    hints: list[str] | None = None,
    category: str = "general",
    detail: str | None = None,
) -> Diagnostic:
    spans = ()
    if file is not None:
        spans = (SourceSpan(file=file, path=path),)

    return Diagnostic(
        code=code,
        severity=Severity.WARNING,
        message=message,
        subject=subject,
        spans=spans,
        hints=tuple(hints or []),
        category=category,
        detail=detail,
    )
```

Toto drasticky zlepší čitateľnosť pravidiel.

---

# 6. Source path propagation z loaderov

Aby diagnostiky ukazovali YAML path, potrebuješ prenášať aspoň súbor a logickú cestu.

Najjednoduchší praktický variant:

* loader si uchová `source_file`
* validátory vedia k približnej YAML ceste manuálne doplniť `path`

Napríklad:

* `project.modules[0].bus`
* `project.cpu.type`
* `timing.generated_clocks[0]`

To je dosť dobré aj bez plného YAML AST parsera.

---

# 7. System source context

## nový `socfw/model/source_context.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class SourceContext:
    project_file: str | None = None
    board_file: str | None = None
    timing_file: str | None = None
    ip_files: dict[str, str] = field(default_factory=dict)
    cpu_files: dict[str, str] = field(default_factory=dict)
```

## update `socfw/model/system.py`

Pridaj:

```python
from .source_context import SourceContext
```

a do `SystemModel`:

```python
    sources: SourceContext = field(default_factory=SourceContext)
```

---

## update `socfw/config/system_loader.py`

Pri skladaní `SystemModel(...)` doplň:

```python
from socfw.model.source_context import SourceContext
```

a:

```python
            sources=SourceContext(
                project_file=project_file,
                board_file=project.board_file,
                timing_file=str(timing_path) if project.timing_file else None,
                ip_files={k: "" for k in catalog_res.value.keys()},
                cpu_files={k: "" for k in cpu_catalog_res.value.keys()},
            ),
```

Ešte lepšie je, ak `IpLoader` a `CpuLoader` vrátia aj mapu `name -> source file`. To odporúčam doplniť neskôr, ale aj toto je už užitočné.

---

# 8. Validation rules s hintami a fixami

Tu je najväčšia praktická hodnota. Ukážem 3 najdôležitejšie pravidlá.

---

## `MissingBridgeRule` v2

## update `socfw/validate/rules/bridge_rules.py`

```python
from __future__ import annotations

from socfw.core.diag_builders import err
from socfw.core.diagnostics import SuggestedFix
from socfw.validate.rules.base import ValidationRule


class MissingBridgeRule(ValidationRule):
    def __init__(self, registry) -> None:
        self.registry = registry

    def validate(self, system) -> list:
        diags = []
        project_file = system.sources.project_file

        for idx, mod in enumerate(system.project.modules):
            if mod.bus is None:
                continue

            fabric = system.project.fabric_by_name(mod.bus.fabric)
            if fabric is None:
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            iface = ip.bus_interface(role="slave")
            if iface is None:
                continue

            if iface.protocol == fabric.protocol:
                continue

            bridge = self.registry.find_bridge(
                src_protocol=fabric.protocol,
                dst_protocol=iface.protocol,
            )
            if bridge is None:
                diags.append(
                    err(
                        "BRG001",
                        (
                            f"No bridge registered for fabric protocol '{fabric.protocol}' "
                            f"to peripheral protocol '{iface.protocol}'"
                        ),
                        "project.modules.bus",
                        file=project_file,
                        path=f"modules[{idx}].bus",
                        category="bridge",
                        hints=[
                            "Register a bridge planner plugin for this protocol pair.",
                            "Or change the peripheral bus interface protocol to match the fabric.",
                            "Or place the peripheral behind an already supported adapter.",
                        ],
                        fixes=[
                            SuggestedFix(
                                message=f"Register bridge {fabric.protocol} -> {iface.protocol}"
                            ),
                            SuggestedFix(
                                message=f"Change peripheral '{mod.instance}' interface protocol to '{fabric.protocol}'",
                                path=f"modules[{idx}]",
                            ),
                        ],
                        detail=(
                            f"Instance '{mod.instance}' is attached to fabric '{fabric.name}', "
                            f"but its IP descriptor declares slave protocol '{iface.protocol}'."
                        ),
                    )
                )
        return diags
```

---

## `UnknownCpuTypeRule` v2

## update `socfw/validate/rules/cpu_rules.py`

```python
from __future__ import annotations

from socfw.core.diag_builders import err
from socfw.core.diagnostics import SuggestedFix
from socfw.validate.rules.base import ValidationRule


class UnknownCpuTypeRule(ValidationRule):
    def validate(self, system) -> list:
        if system.cpu is None:
            return []

        if system.cpu.type_name not in system.cpu_catalog:
            known = ", ".join(sorted(system.cpu_catalog.keys())) or "none"
            return [
                err(
                    "CPU001",
                    f"Unknown CPU type '{system.cpu.type_name}'",
                    "project.cpu",
                    file=system.sources.project_file,
                    path="cpu.type",
                    category="cpu",
                    hints=[
                        "Add a matching *.cpu.yaml descriptor to a registered catalog path.",
                        "Or change project.cpu.type to an existing CPU descriptor.",
                    ],
                    fixes=[
                        SuggestedFix(
                            message="Change to an existing CPU descriptor name"
                        )
                    ],
                    detail=f"Known CPU descriptors: {known}",
                )
            ]
        return []
```

---

## `DuplicateAddressRegionRule` v2

## update `socfw/validate/rules/bus_rules.py`

```python
from __future__ import annotations

from socfw.core.diag_builders import err
from socfw.core.diagnostics import RelatedDiagnosticRef, SuggestedFix
from socfw.validate.rules.base import ValidationRule


class DuplicateAddressRegionRule(ValidationRule):
    def validate(self, system) -> list:
        diags = []
        regs = []

        if system.ram is not None:
            regs.append(("ram", system.ram.base, system.ram.base + system.ram.size - 1, "ram"))

        for idx, mod in enumerate(system.project.modules):
            if mod.bus is not None:
                regs.append(
                    (
                        mod.instance,
                        mod.bus.base,
                        mod.bus.base + mod.bus.size - 1,
                        f"modules[{idx}].bus",
                    )
                )

        for i, (n1, b1, e1, p1) in enumerate(regs):
            for n2, b2, e2, p2 in regs[i + 1:]:
                if not (e1 < b2 or e2 < b1):
                    diags.append(
                        err(
                            "BUS003",
                            f"Address overlap between '{n1}' and '{n2}'",
                            "project.modules.bus",
                            file=system.sources.project_file,
                            path=p1,
                            category="bus",
                            hints=[
                                "Ensure each slave region is unique and non-overlapping.",
                                "Check RAM base/size and all peripheral bus regions.",
                            ],
                            fixes=[
                                SuggestedFix(message=f"Move '{n1}' to a non-overlapping base address", path=p1),
                                SuggestedFix(message=f"Move '{n2}' to a non-overlapping base address", path=p2),
                            ],
                            related=[
                                RelatedDiagnosticRef(
                                    code="BUS003",
                                    message=f"{n1}: 0x{b1:08X}-0x{e1:08X}",
                                    subject=p1,
                                ),
                                RelatedDiagnosticRef(
                                    code="BUS003",
                                    message=f"{n2}: 0x{b2:08X}-0x{e2:08X}",
                                    subject=p2,
                                ),
                            ],
                            detail=(
                                f"Computed regions overlap: "
                                f"{n1}=0x{b1:08X}-0x{e1:08X}, "
                                f"{n2}=0x{b2:08X}-0x{e2:08X}"
                            ),
                        )
                    )
        return diags
```

---

# 9. Diagnostic formatter

Toto je kritické. Model nestačí, musíš ho pekne zobraziť.

## nový `socfw/reports/diagnostic_formatter.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic


class DiagnosticFormatter:
    def format_text(self, d: Diagnostic) -> str:
        lines: list[str] = []
        lines.append(f"{d.severity.value.upper()} {d.code} {d.subject}")
        lines.append(d.message)

        for span in d.spans:
            loc = span.file
            if span.path:
                loc += f" :: {span.path}"
            lines.append(f"at: {loc}")

        if d.detail:
            lines.append(f"detail: {d.detail}")

        if d.hints:
            lines.append("hints:")
            for h in d.hints:
                lines.append(f"- {h}")

        if d.suggested_fixes:
            lines.append("suggested fixes:")
            for f in d.suggested_fixes:
                if f.path:
                    lines.append(f"- {f.message} [{f.path}]")
                else:
                    lines.append(f"- {f.message}")

        if d.related:
            lines.append("related:")
            for r in d.related:
                lines.append(f"- {r.code} {r.subject}: {r.message}")

        return "\n".join(lines)
```

---

# 10. CLI má používať formatter

## update `socfw/cli/main.py`

Pridaj import:

```python
from socfw.reports.diagnostic_formatter import DiagnosticFormatter
```

A helper:

```python
def _print_diags(diags) -> None:
    fmt = DiagnosticFormatter()
    for d in diags:
        print(fmt.format_text(d))
        print()
```

A nahraď všetky:

```python
for d in result.diagnostics:
    print(...)
```

za:

```python
_print_diags(result.diagnostics)
```

To je veľmi veľké UX zlepšenie.

---

# 11. Grouped reporting

Keď je chýb viac, chceš ich vedieť zoskupiť podľa kategórie.

## nový `socfw/reports/diagnostic_groups.py`

```python
from __future__ import annotations

from collections import defaultdict


class DiagnosticGrouper:
    def group_by_category(self, diags):
        groups = defaultdict(list)
        for d in diags:
            groups[d.category].append(d)
        return dict(groups)
```

---

## update `socfw/reports/markdown_emitter.py`

Doplň grouped diagnostics:

```python
from socfw.reports.diagnostic_groups import DiagnosticGrouper
```

V `emit()` v diagnostics sekcii môžeš spraviť:

```python
        lines.append("## Diagnostics\n")
        if report.diagnostics:
            groups = DiagnosticGrouper().group_by_category(report.diagnostics)
            for category in sorted(groups.keys()):
                lines.append(f"### {category}\n")
                lines.append("| Severity | Code | Subject | Message |")
                lines.append("|----------|------|---------|---------|")
                for d in groups[category]:
                    lines.append(f"| {d.severity} | {d.code} | {d.subject} | {d.message} |")
                lines.append("")
        else:
            lines.append("No diagnostics.")
```

Na to musí report model niesť `category`.

---

# 12. Report model rozšírenie

## update `socfw/reports/model.py`

Rozšír `ReportDiagnostic`:

```python
@dataclass(frozen=True)
class ReportDiagnostic:
    code: str
    severity: str
    message: str
    subject: str
    category: str = "general"
    detail: str | None = None
    hints: tuple[str, ...] = ()
```

## update `socfw/reports/builder.py`

Pri append:

```python
            report.diagnostics.append(ReportDiagnostic(
                code=d.code,
                severity=d.severity.value if hasattr(d.severity, "value") else str(d.severity),
                message=d.message,
                subject=d.subject,
                category=getattr(d, "category", "general"),
                detail=getattr(d, "detail", None),
                hints=tuple(getattr(d, "hints", ())),
            ))
```

---

# 13. Explain mode improvements

`explain` by nemal byť len pre clocks. Odporúčam pridať:

* `explain cpu-irq`
* `explain bus`
* `explain address-map`
* `explain diagnostics`

---

## update `socfw/reports/explain.py`

Pridaj:

```python
    def explain_bus(self, design) -> str:
        if design.interconnect is None or not design.interconnect.fabrics:
            return "No bus fabrics."

        lines = ["Bus fabrics:"]
        for fabric in sorted(design.interconnect.fabrics.keys()):
            lines.append(f"- {fabric}")
            for ep in sorted(design.interconnect.fabrics[fabric], key=lambda x: (x.role, x.instance)):
                rng = ""
                if ep.base is not None and ep.end is not None:
                    rng = f" @ 0x{ep.base:08X}-0x{ep.end:08X}"
                lines.append(f"  - {ep.role}: {ep.instance} ({ep.protocol}){rng}")
        return "\n".join(lines)

    def explain_address_map(self, system) -> str:
        lines = ["Address map:"]
        if system.ram is not None:
            lines.append(
                f"- RAM: 0x{system.ram.base:08X} .. 0x{system.ram.base + system.ram.size - 1:08X}"
            )
        for p in sorted(system.peripheral_blocks, key=lambda x: x.base):
            lines.append(f"- {p.instance}: 0x{p.base:08X} .. 0x{p.end:08X} ({p.module})")
        return "\n".join(lines)

    def explain_diagnostics(self, diagnostics) -> str:
        if not diagnostics:
            return "No diagnostics."

        lines = ["Diagnostics summary:"]
        for d in diagnostics:
            lines.append(f"- {d.severity.value.upper()} {d.code}: {d.message}")
            for h in d.hints:
                lines.append(f"    hint: {h}")
        return "\n".join(lines)
```

---

## update `socfw/cli/main.py`

Rozšír choices:

```python
    e.add_argument("topic", choices=["clocks", "cpu-irq", "bus", "address-map", "diagnostics"])
```

A handler:

```python
    elif args.topic == "bus":
        print(expl.explain_bus(design))
    elif args.topic == "address-map":
        print(expl.explain_address_map(loaded.value))
    elif args.topic == "diagnostics":
        print(expl.explain_diagnostics(loaded.diagnostics))
```

---

# 14. Structured error JSON export

Toto je veľmi užitočné pre tooling.

## nový `socfw/tools/diagnostic_json_exporter.py`

```python
from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path


class DiagnosticJsonExporter:
    def export(self, diagnostics, out_file: str) -> str:
        fp = Path(out_file)
        fp.parent.mkdir(parents=True, exist_ok=True)
        fp.write_text(
            json.dumps([asdict(d) for d in diagnostics], indent=2),
            encoding="utf-8",
        )
        return str(fp)
```

Neskôr môžeš spraviť:

```bash
socfw validate project.yaml --json-out build/diags.json
```

To je veľmi dobré pre CI/report tooling.

---

# 15. Integration test pre diagnostics UX

## `tests/integration/test_explain_and_diag_format.py`

```python
from socfw.reports.diagnostic_formatter import DiagnosticFormatter
from socfw.core.diag_builders import err


def test_diagnostic_formatter_renders_hints_and_fixes():
    d = err(
        "BRG001",
        "No bridge registered",
        "project.modules.bus",
        file="project.yaml",
        path="modules[0].bus",
        hints=["Register a matching bridge."],
        category="bridge",
    )

    text = DiagnosticFormatter().format_text(d)
    assert "BRG001" in text
    assert "project.yaml" in text
    assert "Register a matching bridge." in text
```

---

# 16. UX benefit, ktorý týmto získaš

Po tomto kroku framework získa veľmi veľa v praxi:

### používateľ uvidí:

* kde je chyba
* prečo je chyba
* čo má spraviť
* ktoré ďalšie objekty s tým súvisia

### reviewer uvidí:

* kategórie problémov
* detailný report
* explain výstupy

### CI/tooling uvidí:

* structured JSON diagnostics

To je veľmi silný kvalitatívny skok.

---

# 17. Čo by som spravil hneď potom

Teraz sú podľa mňa tri veľmi dobré smery:

### A

**incremental build/cache**

* hashovať config + IR
* neemitovať všetko vždy nanovo

### B

**vendor IP import cleanup**

* Quartus/QIP contracts
* artifact normalization

### C

**editor/tooling support**

* VSCode schema mapping
* YAML templates
* example project generator

Môj praktický odporúčaný ďalší krok je:

👉 **A — incremental build/cache**

Lebo architektúra aj UX sú už veľmi slušné. Ďalší veľký praktický boost bude rýchlosť a menší rebuild scope.

Ak chceš, ďalšia správa môže byť presne:
**incremental build/cache design: fingerprints, stage caching, artifact invalidation, and deterministic rebuild policy**
