from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.software import SoftwareIR


class SoftwareEmitter:
    family = "software"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx: BuildContext, ir: SoftwareIR) -> list[GeneratedArtifact]:
        out_dir = Path(ctx.out_dir) / "sw"
        out_dir.mkdir(parents=True, exist_ok=True)

        artifacts: list[GeneratedArtifact] = []

        soc_map_h = out_dir / "soc_map.h"
        soc_irq_h = out_dir / "soc_irq.h"
        linker = out_dir / "sections.lds"

        self.renderer.write_text(
            soc_map_h,
            self.renderer.render("soc_map.h.j2", sw=ir),
            encoding="utf-8",
        )
        artifacts.append(
            GeneratedArtifact(family=self.family, path=str(soc_map_h), generator=self.__class__.__name__)
        )

        self.renderer.write_text(
            soc_irq_h,
            self.renderer.render("soc_irq.h.j2", sw=ir),
            encoding="utf-8",
        )
        artifacts.append(
            GeneratedArtifact(family=self.family, path=str(soc_irq_h), generator=self.__class__.__name__)
        )

        self.renderer.write_text(
            linker,
            self.renderer.render("sections.lds.j2", sw=ir),
            encoding="utf-8",
        )
        artifacts.append(
            GeneratedArtifact(family=self.family, path=str(linker), generator=self.__class__.__name__)
        )

        return artifacts
