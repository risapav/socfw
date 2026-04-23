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
