from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.register_block import RegisterBlockIR


class RegisterBlockEmitter:
    family = "rtl_regs"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit_one(self, ctx: BuildContext, ir: RegisterBlockIR) -> GeneratedArtifact:
        out = Path(ctx.out_dir) / "rtl" / f"{ir.module_name}.sv"
        out.parent.mkdir(parents=True, exist_ok=True)

        content = self.renderer.render("reg_block.sv.j2", regblk=ir)
        self.renderer.write_text(out, content, encoding="utf-8")

        return GeneratedArtifact(
            family=self.family,
            path=str(out),
            generator=self.__class__.__name__,
        )

    def emit_many(self, ctx: BuildContext, irs: list[RegisterBlockIR]) -> list[GeneratedArtifact]:
        return [self.emit_one(ctx, ir) for ir in irs]
