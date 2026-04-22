from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact


class SimFilelistEmitter:
    family = "sim"

    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "sim" / "files.f"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("rtl/soc_top.sv")

        for fp in sorted(ir.extra_sources):
            lines.append(fp)

        tb = Path(ctx.out_dir) / "sim" / "tb_soc_top.sv"
        if tb.exists():
            lines.append(str(tb))

        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return [GeneratedArtifact("sim", str(out), self.__class__.__name__)]
