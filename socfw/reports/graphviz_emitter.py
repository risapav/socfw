from __future__ import annotations

from pathlib import Path

from socfw.reports.graph_model import SystemGraph


class GraphvizEmitter:
    name = "graphviz"

    def emit(self, graph: SystemGraph, out_dir: str) -> str:
        out = Path(out_dir) / "reports" / "soc_graph.dot"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("digraph soc {")
        lines.append('  graph [rankdir=LR, fontname="Helvetica", bgcolor="#fafafa"];')
        lines.append('  node  [fontname="Helvetica"];')
        lines.append('  edge  [fontname="Helvetica"];')

        for n in graph.nodes:
            shape = {
                "cpu": "box3d",
                "memory": "cylinder",
                "peripheral": "box",
                "fabric": "ellipse",
            }.get(n.kind, "box")
            lines.append(f'  {n.id} [label="{n.label}", shape={shape}];')

        for e in graph.edges:
            extra = f', style={e.style}' if e.style != "solid" else ""
            if e.label:
                lines.append(f'  {e.src} -> {e.dst} [label="{e.label}"{extra}];')
            else:
                lines.append(f'  {e.src} -> {e.dst} [{extra.lstrip(", ")}];')

        lines.append("}")
        out.write_text("\n".join(lines), encoding="utf-8")
        return str(out)
