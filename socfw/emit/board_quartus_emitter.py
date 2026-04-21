from __future__ import annotations

from collections import defaultdict
from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.ir.board import BoardIR, BoardPinAssignment


class QuartusBoardEmitter:
    family = "board"

    def emit(self, ctx: BuildContext, ir: BoardIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "hal" / "board.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("# AUTO-GENERATED - DO NOT EDIT")
        lines.append(f"# Device family: {ir.family}")
        lines.append(f"# Device part:   {ir.device}")
        lines.append("")
        lines.append(f'set_global_assignment -name FAMILY "{ir.family}"')
        lines.append(f"set_global_assignment -name DEVICE  {ir.device}")
        lines.append("")

        grouped: dict[str, list[BoardPinAssignment]] = defaultdict(list)
        for a in ir.assignments:
            grouped[a.top_name].append(a)

        for top_name in sorted(grouped.keys()):
            pins = sorted(grouped[top_name], key=lambda a: (-1 if a.index is None else a.index))
            sample = pins[0]

            lines.append(f"# {top_name}")

            if sample.io_standard:
                if any(p.index is not None for p in pins):
                    lines.append(
                        f'set_instance_assignment -name IO_STANDARD "{sample.io_standard}" -to {top_name}[*]'
                    )
                else:
                    lines.append(
                        f'set_instance_assignment -name IO_STANDARD "{sample.io_standard}" -to {top_name}'
                    )

            if sample.weak_pull_up:
                if any(p.index is not None for p in pins):
                    lines.append(
                        f"set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {top_name}[*]"
                    )
                else:
                    lines.append(
                        f"set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {top_name}"
                    )

            for pin in pins:
                if pin.index is None:
                    lines.append(f"set_location_assignment PIN_{pin.pin} -to {top_name}")
                else:
                    lines.append(f"set_location_assignment PIN_{pin.pin} -to {top_name}[{pin.index}]")
            lines.append("")

        out.write_text("\n".join(lines), encoding="ascii")

        return [
            GeneratedArtifact(
                family=self.family,
                path=str(out),
                generator=self.__class__.__name__,
            )
        ]
