from __future__ import annotations

import json
from pathlib import Path


class BoardBindingsReport:
    def write(self, out_dir: str, system) -> tuple[str, str]:
        reports_dir = Path(out_dir) / "reports"
        reports_dir.mkdir(parents=True, exist_ok=True)

        rows = self._collect_rows(system)

        md_path = str(reports_dir / "board_bindings.md")
        Path(md_path).write_text(self._render_md(rows), encoding="utf-8")

        json_path = str(reports_dir / "board_bindings.json")
        Path(json_path).write_text(self._render_json(rows), encoding="utf-8")

        return md_path, json_path

    def _collect_rows(self, system) -> list[dict]:
        rows = []
        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue
            for b in mod.port_bindings:
                if not b.target.startswith("board:"):
                    continue
                ip_port = ip.port_by_name(b.port_name)
                ip_width = ip_port.width if ip_port else None

                board_width = None
                try:
                    from socfw.model.board import BoardResource, BoardVectorSignal
                    ref = system.board.resolve_ref(b.target)
                    if isinstance(ref, dict):
                        board_width = int(ref.get("width", 1))
                    elif isinstance(ref, BoardResource):
                        sig = ref.default_signal()
                        board_width = sig.width if isinstance(sig, BoardVectorSignal) else 1
                    else:
                        board_width = getattr(ref, "width", 1)
                except Exception:
                    pass

                rows.append({
                    "instance": mod.instance,
                    "port": b.port_name,
                    "ip_width": ip_width,
                    "target": b.target,
                    "board_width": b.width if b.width is not None else board_width,
                    "adapt": b.adapt or "none",
                })
        return rows

    def _render_md(self, rows: list[dict]) -> str:
        lines = [
            "# Board Bindings",
            "",
            "| Instance | Port | IP width | Target | Board width | Adapt |",
            "|---|---|---:|---|---:|---|",
        ]
        for r in rows:
            lines.append(
                f"| {r['instance']} | {r['port']} | {r['ip_width']} "
                f"| {r['target']} | {r['board_width']} | {r['adapt']} |"
            )
        lines.append("")
        return "\n".join(lines)

    def _render_json(self, rows: list[dict]) -> str:
        return json.dumps(rows, indent=2) + "\n"
