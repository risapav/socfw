Super. Ideme na:

# schema export + auto-generated config reference docs + example catalog layout

Toto je veľmi dobrý ďalší krok, lebo architektúra už stojí. Teraz treba spraviť framework:

* zrozumiteľný,
* samodokumentačný,
* onboarding-friendly,
* menej závislý od “tribal knowledge”.

Cieľ:

* exportovať schémy configov,
* generovať referenčné docs,
* mať katalóg príkladov,
* a spraviť z YAML kontraktov prvotriednu časť frameworku.

---

# 1. Čo chceme dosiahnuť

Na konci tohto kroku chceš vedieť spraviť:

```bash
socfw schema export --out build/schema
socfw docs export --out build/docs
```

A dostať napríklad:

```text
build/schema/
  board.schema.json
  project.schema.json
  ip.schema.json
  cpu.schema.json
  timing.schema.json

build/docs/
  config_board.md
  config_project.md
  config_ip.md
  config_cpu.md
  config_timing.md
  examples_catalog.md
```

To je obrovská pomoc pre:

* seba o mesiac,
* ďalšieho človeka v tíme,
* review configov,
* IDE tooling.

---

# 2. Najprv si zafixuj princíp

Odporúčam rozdeliť to na 2 vrstvy:

## A. Schema export

Strojovo použiteľné:

* JSON Schema
* validácia
* IDE autocomplete / YAML tooling

## B. Human docs export

Človekom čitateľné:

* markdown
* vysvetlenia sekcií
* pole / typ / required / default
* mini príklady

Toto je správny model.
Schema sama o sebe nestačí.
Ručne písaná dokumentácia sa zase rýchlo rozíde.

---

# 3. Schema exporter

Pydantic už vie generovať JSON schema. To je najjednoduchší pevný základ.

## nový `socfw/tools/schema_exporter.py`

```python
from __future__ import annotations

import json
from pathlib import Path

from socfw.config.board_schema import BoardConfigSchema
from socfw.config.project_schema import ProjectConfigSchema
from socfw.config.ip_schema import IpConfigSchema
from socfw.config.cpu_schema import CpuDescriptorSchema
from socfw.config.timing_schema import TimingDocumentSchema


class SchemaExporter:
    def export_all(self, out_dir: str) -> list[str]:
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)

        schemas = {
            "board.schema.json": BoardConfigSchema.model_json_schema(),
            "project.schema.json": ProjectConfigSchema.model_json_schema(),
            "ip.schema.json": IpConfigSchema.model_json_schema(),
            "cpu.schema.json": CpuDescriptorSchema.model_json_schema(),
            "timing.schema.json": TimingDocumentSchema.model_json_schema(),
        }

        paths: list[str] = []
        for name, schema in schemas.items():
            fp = out / name
            fp.write_text(json.dumps(schema, indent=2), encoding="utf-8")
            paths.append(str(fp))

        return paths
```

---

# 4. Markdown docs generator z Pydantic schém

Schema export je fajn, ale na človeka je to príliš surové.
Spravíme jednoduchý renderer, ktorý z JSON schema vygeneruje referenčný markdown.

## nový `socfw/tools/schema_docgen.py`

```python
from __future__ import annotations

from pathlib import Path


class SchemaDocGenerator:
    def generate_markdown(self, *, title: str, schema: dict, out_file: str) -> str:
        lines: list[str] = []
        lines.append(f"# {title}\n")

        desc = schema.get("description")
        if desc:
            lines.append(desc)
            lines.append("")

        lines.append("## Top-level fields\n")

        props = schema.get("properties", {})
        required = set(schema.get("required", []))

        if props:
            lines.append("| Field | Type | Required | Default |")
            lines.append("|------|------|----------|---------|")
            for name in sorted(props.keys()):
                p = props[name]
                ptype = self._type_str(p)
                req = "yes" if name in required else "no"
                default = p.get("default", "")
                lines.append(f"| `{name}` | `{ptype}` | {req} | `{default}` |")
        else:
            lines.append("No top-level fields.")
        lines.append("")

        defs = schema.get("$defs", {})
        if defs:
            lines.append("## Nested objects\n")
            for def_name in sorted(defs.keys()):
                d = defs[def_name]
                lines.append(f"### {def_name}\n")
                dprops = d.get("properties", {})
                dreq = set(d.get("required", []))

                if dprops:
                    lines.append("| Field | Type | Required | Default |")
                    lines.append("|------|------|----------|---------|")
                    for name in sorted(dprops.keys()):
                        p = dprops[name]
                        ptype = self._type_str(p)
                        req = "yes" if name in dreq else "no"
                        default = p.get("default", "")
                        lines.append(f"| `{name}` | `{ptype}` | {req} | `{default}` |")
                else:
                    lines.append("No fields.")
                lines.append("")

        fp = Path(out_file)
        fp.parent.mkdir(parents=True, exist_ok=True)
        fp.write_text("\n".join(lines), encoding="utf-8")
        return str(fp)

    def _type_str(self, p: dict) -> str:
        if "$ref" in p:
            return p["$ref"].split("/")[-1]
        if "enum" in p:
            return "enum(" + ", ".join(map(str, p["enum"])) + ")"
        if "type" in p:
            return str(p["type"])
        if "anyOf" in p:
            return " | ".join(self._type_str(x) for x in p["anyOf"])
        if "items" in p:
            return f"list[{self._type_str(p['items'])}]"
        return "object"
```

---

# 5. Docs exporter orchestration

## nový `socfw/tools/config_docs_exporter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.config.board_schema import BoardConfigSchema
from socfw.config.project_schema import ProjectConfigSchema
from socfw.config.ip_schema import IpConfigSchema
from socfw.config.cpu_schema import CpuDescriptorSchema
from socfw.config.timing_schema import TimingDocumentSchema
from socfw.tools.schema_docgen import SchemaDocGenerator


class ConfigDocsExporter:
    def __init__(self) -> None:
        self.docgen = SchemaDocGenerator()

    def export_all(self, out_dir: str) -> list[str]:
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)

        targets = [
            ("Board config reference", BoardConfigSchema.model_json_schema(), out / "config_board.md"),
            ("Project config reference", ProjectConfigSchema.model_json_schema(), out / "config_project.md"),
            ("IP descriptor reference", IpConfigSchema.model_json_schema(), out / "config_ip.md"),
            ("CPU descriptor reference", CpuDescriptorSchema.model_json_schema(), out / "config_cpu.md"),
            ("Timing config reference", TimingDocumentSchema.model_json_schema(), out / "config_timing.md"),
        ]

        paths: list[str] = []
        for title, schema, fp in targets:
            paths.append(
                self.docgen.generate_markdown(
                    title=title,
                    schema=schema,
                    out_file=str(fp),
                )
            )

        return paths
```

---

# 6. CLI príkazy

Teraz ich treba sprístupniť používateľovi.

## update `socfw/cli/main.py`

Pridaj importy:

```python
from socfw.tools.schema_exporter import SchemaExporter
from socfw.tools.config_docs_exporter import ConfigDocsExporter
```

Pridaj handlery:

```python
def cmd_schema_export(args) -> int:
    paths = SchemaExporter().export_all(args.out)
    for p in paths:
        print(p)
    return 0


def cmd_docs_export(args) -> int:
    paths = ConfigDocsExporter().export_all(args.out)
    for p in paths:
        print(p)
    return 0
```

A do parsera:

```python
    schema = sub.add_parser("schema")
    schema_sub = schema.add_subparsers(dest="schema_cmd", required=True)

    schema_export = schema_sub.add_parser("export")
    schema_export.add_argument("--out", default="build/schema")
    schema_export.set_defaults(func=cmd_schema_export)

    docs = sub.add_parser("docs")
    docs_sub = docs.add_subparsers(dest="docs_cmd", required=True)

    docs_export = docs_sub.add_parser("export")
    docs_export.add_argument("--out", default="build/docs")
    docs_export.set_defaults(func=cmd_docs_export)
```

---

# 7. Example catalog generator

Ďalšia veľmi praktická vec: mať index príkladov/fixtures.

## nový `socfw/tools/example_catalog.py`

```python
from __future__ import annotations

from pathlib import Path
import yaml


class ExampleCatalogGenerator:
    def generate(self, fixtures_root: str, out_file: str) -> str:
        root = Path(fixtures_root)
        lines: list[str] = []
        lines.append("# Example Catalog\n")

        for proj in sorted(root.glob("*/project.yaml")):
            fixture_dir = proj.parent
            name = fixture_dir.name

            try:
                data = yaml.safe_load(proj.read_text(encoding="utf-8")) or {}
            except Exception:
                data = {}

            project = data.get("project", {})
            title = project.get("name", name)
            mode = project.get("mode", "unknown")

            lines.append(f"## {title}\n")
            lines.append(f"- Directory: `{fixture_dir}`")
            lines.append(f"- Mode: `{mode}`")
            lines.append("")

            clocks = data.get("clocks", {})
            if clocks:
                primary = clocks.get("primary", {})
                lines.append(f"- Primary clock domain: `{primary.get('domain', 'n/a')}`")

            modules = data.get("modules", [])
            lines.append(f"- Modules: `{len(modules)}`")
            lines.append("")

        out = Path(out_file)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("\n".join(lines), encoding="utf-8")
        return str(out)
```

---

# 8. Docs export môže rovno generovať aj examples catalog

## update `socfw/tools/config_docs_exporter.py`

Na konci `export_all()`:

```python
from socfw.tools.example_catalog import ExampleCatalogGenerator
```

V `__init__`:

```python
        self.examples = ExampleCatalogGenerator()
```

A na koniec:

```python
        fixtures_root = "tests/golden/fixtures"
        if Path(fixtures_root).exists():
            paths.append(
                self.examples.generate(
                    fixtures_root=fixtures_root,
                    out_file=str(out / "examples_catalog.md"),
                )
            )
```

A pridaj import:

```python
from pathlib import Path
```

---

# 9. User docs layout

Odporúčam mať auto-generated veci oddelené od ručne písaných docs:

```text
docs/
  user/
    getting_started.md
    cli.md
  architecture/
    00_overview.md
    03_bus_and_bridges.md
    04_firmware_flow.md
  generated/
    config_board.md
    config_project.md
    config_ip.md
    config_cpu.md
    config_timing.md
    examples_catalog.md
```

Teda `docs export` smerovať napr. do:

```bash
socfw docs export --out docs/generated
```

---

# 10. Integration test pre schema/docs export

## `tests/integration/test_schema_and_docs_export.py`

```python
from socfw.tools.schema_exporter import SchemaExporter
from socfw.tools.config_docs_exporter import ConfigDocsExporter


def test_schema_export(tmp_path):
    out = tmp_path / "schema"
    paths = SchemaExporter().export_all(str(out))

    assert len(paths) >= 5
    assert (out / "board.schema.json").exists()
    assert (out / "project.schema.json").exists()


def test_docs_export(tmp_path):
    out = tmp_path / "docs"
    paths = ConfigDocsExporter().export_all(str(out))

    assert len(paths) >= 5
    assert (out / "config_board.md").exists()
    assert (out / "config_project.md").exists()
```

---

# 11. README doplnenie

Do `README.md` pridaj commands:

```md
## Schema and docs

socfw schema export --out build/schema
socfw docs export --out build/docs
```

A stručné vysvetlenie:

* schema export = JSON schema for tooling
* docs export = human-readable references

---

# 12. VS Code / YAML tooling bonus

Keď budeš mať JSON schema, vieš neskôr pridať napr. odporúčaný mapping:

## `.vscode/settings.json` príklad

```json
{
  "yaml.schemas": {
    "build/schema/project.schema.json": "tests/golden/fixtures/*/project.yaml",
    "build/schema/board.schema.json": "tests/golden/fixtures/*/board.yaml",
    "build/schema/ip.schema.json": "tests/golden/fixtures/*/ip/*.ip.yaml",
    "build/schema/cpu.schema.json": "tests/golden/fixtures/*/ip/*.cpu.yaml",
    "build/schema/timing.schema.json": "tests/golden/fixtures/*/timing.yaml"
  }
}
```

To je veľká produktivitná výhoda.

---

# 13. Čo týmto získavaš

Po tomto kroku už máš:

* machine-readable config contracts
* human-readable config reference
* examples catalog
* lepší onboarding
* pripravený základ pre IDE support

To je veľmi veľká hodnota pre reálne používanie frameworku.

---

# 14. Čo by som spravil hneď potom

Po tomto bode by som architektúru už veľmi nehýbal. Išiel by som jedným z týchto smerov:

### A

**vendor IP import cleanup**

* Quartus/QIP contract
* shared core packaging
* import rules

### B

**incremental build/cache**

* neprepočítavať všetko
* hash-based artifact invalidation

### C

**richer diagnostics**

* suggestions
* source refs
* explainable validation failures

Môj praktický odporúčaný ďalší krok je:

👉 **C — richer diagnostics + explainable validation/reporting**

Lebo framework už vie veľa, ale ďalší veľký boost používateľskej kvality je, keď chyby a reporty budú ešte lepšie čitateľné a akčné.

Ak chceš, ďalšia správa môže byť presne:
**diagnostics v2: source spans, hints, suggested fixes, grouped reporting, and explain mode improvements**
