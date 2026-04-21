from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.timing import TimingIR


class TimingEmitter:
    family = "timing"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx: BuildContext, ir: TimingIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "timing" / "soc_top.sdc"

        content = self.renderer.render(
            "soc_top.sdc.j2",
            timing=ir,
        )
        self.renderer.write_text(out, content, encoding="utf-8")

        return [
            GeneratedArtifact(
                family=self.family,
                path=str(out),
                generator=self.__class__.__name__,
            )
        ]
