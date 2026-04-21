from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.docs import DocsIR


class DocsEmitter:
    family = "docs"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx: BuildContext, ir: DocsIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "docs" / "soc_map.md"
        out.parent.mkdir(parents=True, exist_ok=True)

        content = self.renderer.render("soc_map.md.j2", docs=ir)
        self.renderer.write_text(out, content, encoding="utf-8")

        return [
            GeneratedArtifact(
                family=self.family,
                path=str(out),
                generator=self.__class__.__name__,
            )
        ]
