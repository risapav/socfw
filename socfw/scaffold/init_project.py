from __future__ import annotations

from pathlib import Path

from socfw.emit.renderer import Renderer


class ProjectInitializer:
    def __init__(self) -> None:
        self.templates_dir = Path(__file__).parent / "templates"

    def init_blink(self, *, target_dir: str, name: str, board: str) -> list[str]:
        target = Path(target_dir)
        target.mkdir(parents=True, exist_ok=True)

        renderer = Renderer(str(self.templates_dir))
        written = []

        files = {
            "project.yaml": ("blink/project.yaml.j2", {"name": name, "board": board}),
            "ip/blink_test.ip.yaml": ("blink/ip/blink_test.ip.yaml.j2", {}),
            "rtl/blink_test.sv": ("blink/rtl/blink_test.sv.j2", {}),
        }

        for rel, (tpl, ctx) in files.items():
            out = target / rel
            text = renderer.render(tpl, **ctx)
            renderer.write_text(out, text)
            written.append(str(out))

        return written
