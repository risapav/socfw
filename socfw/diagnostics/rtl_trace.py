from __future__ import annotations

from socfw.ir.rtl import RtlTop


def format_rtl_top(top: RtlTop) -> str:
    W = 56
    lines: list[str] = []

    def section(title: str, count: int) -> None:
        label = f"─── {title} ({count}) "
        lines.append(label + "─" * max(0, W - len(label)))

    lines.append(f"[trace] RtlTop: {top.module_name}")

    section("ports", len(top.ports))
    for p in top.ports:
        w = f"[{p.width-1}:0] " if p.width > 1 else ""
        lines.append(f"  {p.direction:<6} {w}{p.name}")

    section("signals", len(top.signals))
    for s in top.signals:
        w = f"[{s.width-1}:0] " if s.width > 1 else ""
        lines.append(f"  {s.kind} {w}{s.name}")

    section("adapt_assigns", len(top.adapt_assigns))
    for a in top.adapt_assigns:
        lines.append(f"  {a.lhs} = {a.rhs}")

    section("instances", len(top.instances))
    for inst in top.instances:
        if inst.parameters:
            params = ", ".join(f"{p.name}={p.value}" for p in inst.parameters)
            lines.append(f"  {inst.module} #({params}) {inst.instance}")
        else:
            lines.append(f"  {inst.module} {inst.instance}")
        for c in inst.connections:
            if c.expr:
                lines.append(f"    .{c.port}({c.expr})")
            else:
                lines.append(f"    .{c.port}()")

    return "\n".join(lines)
