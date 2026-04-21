from __future__ import annotations
from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.ir.board import BoardIR


class QuartusBoardEmitter:
    family = "board"

    def emit(self, ctx: BuildContext, ir: BoardIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "hal" / "board.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append(f'set_global_assignment -name FAMILY "{ir.family}"')
        lines.append(f"set_global_assignment -name DEVICE  {ir.device}")
        lines.append("")

        grouped: dict[tuple[str, str | None, bool], list[tuple[int | None, str]]] = {}
        for a in ir.assignments:
            key = (a.top_name, a.io_standard, a.weak_pull_up)
            grouped.setdefault(key, []).append((a.index, a.pin))

        for (top_name, io_standard, weak_pull_up), pins in grouped.items():
            if io_standard:
                wildcard = any(idx is not None for idx, _ in pins)
                suffix = "[*]" if wildcard else ""
                lines.append(
                    f'set_instance_assignment -name IO_STANDARD "{io_standard}" -to {top_name}{suffix}'
                )
            if weak_pull_up:
                wildcard = any(idx is not None for idx, _ in pins)
                suffix = "[*]" if wildcard else ""
                lines.append(
                    f"set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {top_name}{suffix}"
                )
            for idx, pin in sorted(pins, key=lambda x: (-1 if x[0] is None else x[0])):
                if idx is None:
                    lines.append(f"set_location_assignment PIN_{pin} -to {top_name}")
                else:
                    lines.append(f"set_location_assignment PIN_{pin} -to {top_name}[{idx}]")
            lines.append("")

        out.write_text("\n".join(lines), encoding="ascii")
        return [GeneratedArtifact(family=self.family, path=str(out), generator=self.__class__.__name__)]
