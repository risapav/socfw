from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.rtl import RtlModuleIR


class RtlEmitter:
    family = "rtl"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

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
