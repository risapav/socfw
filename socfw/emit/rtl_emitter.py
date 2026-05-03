from __future__ import annotations

from pathlib import Path

from socfw.emit.renderer import Renderer
from socfw.ir.rtl import RtlTop

_DEFAULT_TEMPLATES = str(Path(__file__).resolve().parents[1] / "templates")


class RtlEmitter:
    family = "rtl"

    def __init__(self, templates_dir: str | None = None) -> None:
        self.renderer = Renderer(templates_dir or _DEFAULT_TEMPLATES)

    def emit(self, out_dir: str, top: RtlTop) -> str:
        rtl_dir = Path(out_dir) / "rtl"
        rtl_dir.mkdir(parents=True, exist_ok=True)
        out = rtl_dir / f"{top.module_name}.sv"

        content = self.renderer.render("soc_top.sv.j2", module=top)
        old = out.read_text(encoding="utf-8") if out.exists() else None
        if old != content:
            self.renderer.write_text(out, content, encoding="utf-8")

        return str(out)
