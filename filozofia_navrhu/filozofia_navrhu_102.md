## Commit 38 — `socfw doctor` pre resolved config inspection

Cieľ:

* rýchlo zistiť, čo `socfw` reálne načítal
* ukázať resolved cesty
* ukázať board, timing, IP, CPU
* pomôcť debugovať problémy ešte pred buildom

Názov commitu:

```text
cli: add socfw doctor for resolved config inspection
```

## Pridať

```text
socfw/diagnostics/doctor.py
tests/integration/test_socfw_doctor.py
```

## Upraviť

```text
socfw/cli/main.py
socfw/config/system_loader.py
socfw/model/source_context.py
```

---

## `socfw/model/source_context.py`

Rozšír, aby niesol viac resolved informácií:

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
    pack_roots: list[str] = field(default_factory=list)
    ip_search_dirs: list[str] = field(default_factory=list)
    cpu_search_dirs: list[str] = field(default_factory=list)
```

---

## `SystemLoader` doplnky

V `system_loader.py` pri skladaní `SourceContext` doplň:

```python
sources=SourceContext(
    project_file=str(project_path),
    board_file=resolved_board_file,
    timing_file=str(timing_path) if timing_path.exists() else None,
    ip_files={name: getattr(desc, "source_file", "") for name, desc in ip_catalog_res.value.items()},
    cpu_files={name: getattr(desc, "source_file", "") for name, desc in cpu_catalog_res.value.items()},
    pack_roots=pack_roots,
    ip_search_dirs=ip_search_dirs,
    cpu_search_dirs=cpu_search_dirs,
)
```

Ak `IpDescriptor` a `CpuDescriptor` ešte nemajú `source_file`, pridaj to v ďalšom malom patchi alebo zatiaľ nechaj prázdne stringy.

---

## Odporúčané doplnenie do `IpDescriptor` a `CpuDescriptor`

### `socfw/model/ip.py`

```python
source_file: str | None = None
```

### v `ip_loader.py`

```python
source_file=str(Path(path).resolve()),
```

### `socfw/model/cpu.py`

```python
source_file: str | None = None
```

### v `cpu_loader.py`

```python
source_file=str(Path(path).resolve()),
```

Toto je extrémne užitočné pre doctor.

---

## `socfw/diagnostics/doctor.py`

```python
from __future__ import annotations


class DoctorReport:
    def build(self, system) -> str:
        lines: list[str] = []

        lines.append("# socfw doctor")
        lines.append("")

        lines.append("## Project")
        lines.append(f"- name: {system.project.name}")
        lines.append(f"- mode: {system.project.mode}")
        lines.append(f"- file: {system.sources.project_file}")
        lines.append("")

        lines.append("## Board")
        lines.append(f"- id: {system.board.board_id}")
        lines.append(f"- file: {system.sources.board_file}")
        lines.append(f"- clock: {system.board.system_clock.top_name} ({system.board.system_clock.frequency_hz} Hz)")
        if system.board.system_reset is not None:
            lines.append(f"- reset: {system.board.system_reset.top_name}")
        else:
            lines.append("- reset: none")
        lines.append("")

        lines.append("## Timing")
        if system.sources.timing_file:
            lines.append(f"- file: {system.sources.timing_file}")
        else:
            lines.append("- file: none")
        if system.timing is not None:
            lines.append(f"- clocks: {len(getattr(system.timing, 'clocks', []))}")
            lines.append(f"- generated clocks: {len(system.timing.generated_clocks)}")
            lines.append(f"- false paths: {len(system.timing.false_paths)}")
        lines.append("")

        lines.append("## Registries")
        lines.append("- packs:")
        for p in system.sources.pack_roots:
            lines.append(f"  - {p}")
        lines.append("- ip search dirs:")
        for p in system.sources.ip_search_dirs:
            lines.append(f"  - {p}")
        lines.append("- cpu search dirs:")
        for p in system.sources.cpu_search_dirs:
            lines.append(f"  - {p}")
        lines.append("")

        lines.append("## IP catalog")
        if system.ip_catalog:
            for name in sorted(system.ip_catalog):
                desc = system.ip_catalog[name]
                src = getattr(desc, "source_file", None) or system.sources.ip_files.get(name, "")
                vendor = ""
                if getattr(desc, "vendor_info", None) is not None:
                    vendor = f" vendor={desc.vendor_info.vendor}/{desc.vendor_info.tool}"
                lines.append(f"- {name}: module={desc.module} category={desc.category}{vendor} file={src}")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## CPU catalog")
        if system.cpu_catalog:
            for name in sorted(system.cpu_catalog):
                desc = system.cpu_catalog[name]
                src = getattr(desc, "source_file", None) or system.sources.cpu_files.get(name, "")
                lines.append(f"- {name}: module={desc.module} family={desc.family} file={src}")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## Project modules")
        if system.project.modules:
            for mod in system.project.modules:
                lines.append(f"- {mod.instance}: type={mod.type_name}")
        else:
            lines.append("- none")
        lines.append("")

        return "\n".join(lines).rstrip() + "\n"
```

---

## `socfw/cli/main.py`

Pridaj command.

Import:

```python
from socfw.diagnostics.doctor import DoctorReport
from socfw.build.full_pipeline import FullBuildPipeline
```

Handler:

```python
def cmd_doctor(args) -> int:
    pipeline = FullBuildPipeline()
    loaded = pipeline.validate(args.project)
    _print_diags(loaded.diagnostics)

    if loaded.value is None:
        return 1

    print(DoctorReport().build(loaded.value))
    return 0 if loaded.ok else 1
```

Parser:

```python
p_doc = sub.add_parser("doctor", help="Inspect resolved project configuration")
p_doc.add_argument("project")
p_doc.set_defaults(func=cmd_doctor)
```

---

## `tests/integration/test_socfw_doctor.py`

```python
from socfw.build.full_pipeline import FullBuildPipeline
from socfw.diagnostics.doctor import DoctorReport


def test_doctor_report_contains_resolved_project_info():
    loaded = FullBuildPipeline().validate("tests/golden/fixtures/blink_converged/project.yaml")
    assert loaded.value is not None

    text = DoctorReport().build(loaded.value)

    assert "# socfw doctor" in text
    assert "blink_converged" in text
    assert "qmtech_ep4ce55" in text
    assert "IP catalog" in text
    assert "blink_test" in text
```

---

## Očakávané použitie

```bash
socfw doctor project.yaml
```

Výstup napr.:

```text
# socfw doctor

## Project
- name: blink_test_01
- mode: standalone
- file: /.../project.yaml

## Board
- id: qmtech_ep4ce55
- file: /.../board_qmtech_ep4ce55.yaml
- clock: SYS_CLK (50000000 Hz)
- reset: RESET_N

## Timing
- file: /.../timing_config.yaml
- clocks: 1
- generated clocks: 0
- false paths: 1

## IP catalog
- blink_test: module=blink_test category=standalone file=/.../blink_test.ip.yaml
```

---

## Definition of Done

Commit 38 je hotový, keď:

* `socfw doctor project.yaml` funguje
* ukazuje resolved board/timing/IP/CPU
* test overuje základný výstup
* výstup je deterministický a čitateľný

Ďalší commit:

```text
cli: add socfw explain-schema command
```
