from __future__ import annotations

import re
from pathlib import Path

_SV_LITERAL_RE = re.compile(r"^\d+\'[bBoOdDhH][0-9a-fA-FxXzZ_?]+$")

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.rtl import RtlModuleIR


class RtlEmitter:
    family = "rtl"

    def __init__(self, templates_dir: str | None = None) -> None:
        self.renderer = Renderer(templates_dir) if templates_dir is not None else None

    def emit(self, ctx: BuildContext, ir: RtlModuleIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "rtl" / "soc_top.sv"

        content = self.renderer.render(
            "soc_top.sv.j2",
            module=ir,
        )
        old = out.read_text(encoding="utf-8") if out.exists() else None
        if old != content:
            self.renderer.write_text(out, content, encoding="utf-8")

        return [
            GeneratedArtifact(
                family=self.family,
                path=str(out),
                generator=self.__class__.__name__,
            )
        ]

    def _format_param_value(self, value) -> str:
        if isinstance(value, bool):
            return "1" if value else "0"
        if isinstance(value, int):
            return str(value)
        if isinstance(value, float):
            return str(value)
        if isinstance(value, str):
            if value.startswith(("'", '"')):
                return value
            if _SV_LITERAL_RE.match(value):
                return value
            if value.isidentifier():
                return value
            return f'"{value}"'
        return str(value)

    def emit_top(self, out_dir: str, top) -> str:
        rtl_dir = Path(out_dir) / "rtl"
        rtl_dir.mkdir(parents=True, exist_ok=True)

        out = rtl_dir / f"{top.module_name}.sv"

        lines: list[str] = []
        lines.append("`default_nettype none")
        lines.append("")

        if top.ports:
            lines.append(f"module {top.module_name} (")
            for idx, p in enumerate(top.ports):
                comma = "," if idx < len(top.ports) - 1 else ""
                width = "" if p.width == 1 else f"[{p.width - 1}:0] "
                lines.append(f"  {p.direction} wire {width}{p.name}{comma}")
            lines.append(");")
        else:
            lines.append(f"module {top.module_name};")

        lines.append("")

        signals = getattr(top, "signals", [])
        for sig in sorted(signals, key=lambda s: s.name):
            width = "" if sig.width == 1 else f"[{sig.width - 1}:0] "
            lines.append(f"  {sig.kind} {width}{sig.name};")
        if signals:
            lines.append("")

        adapt_assigns = getattr(top, "adapt_assigns", [])
        for aa in adapt_assigns:
            lines.append(f"  assign {aa.lhs} = {aa.rhs};")
        if adapt_assigns:
            lines.append("")

        for inst in sorted(top.instances, key=lambda i: i.instance):
            if inst.parameters:
                lines.append(f"  {inst.module} #(")
                params = list(inst.parameters)
                for idx, p in enumerate(params):
                    comma = "," if idx < len(params) - 1 else ""
                    lines.append(f"    .{p.name}({self._format_param_value(p.value)}){comma}")
                lines.append(f"  ) {inst.instance} (")
            else:
                lines.append(f"  {inst.module} {inst.instance} (")
            conns = list(inst.connections)
            for idx, c in enumerate(conns):
                comma = "," if idx < len(conns) - 1 else ""
                if c.expr:
                    lines.append(f"    .{c.port}({c.expr}){comma}")
                else:
                    lines.append(f"    .{c.port}(){comma}")
            lines.append("  );")
            lines.append("")

        lines.append("endmodule")
        lines.append("")
        lines.append("`default_nettype wire")
        lines.append("")

        out.write_text("\n".join(lines), encoding="utf-8")
        return str(out)
