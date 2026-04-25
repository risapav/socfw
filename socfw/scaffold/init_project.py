from __future__ import annotations

from pathlib import Path

from socfw.emit.renderer import Renderer


class ProjectInitializer:
    def __init__(self) -> None:
        self.templates_dir = Path(__file__).parent / "templates"

    def init(self, *, template: str, target_dir: str, name: str, board: str) -> list[str]:
        if template == "blink":
            return self.init_blink(target_dir=target_dir, name=name, board=board)
        if template == "pll":
            return self.init_pll(target_dir=target_dir, name=name, board=board)
        if template == "sdram":
            return self.init_sdram(target_dir=target_dir, name=name, board=board)
        raise ValueError(f"Unknown template: {template}")

    def _render_files(self, *, target_dir: str, files: dict[str, tuple[str, dict]]) -> list[str]:
        target = Path(target_dir)
        target.mkdir(parents=True, exist_ok=True)

        renderer = Renderer(str(self.templates_dir))
        written = []

        for rel, (tpl, ctx) in files.items():
            out = target / rel
            text = renderer.render(tpl, **ctx)
            renderer.write_text(out, text)
            written.append(str(out))

        return written

    def init_blink(self, *, target_dir: str, name: str, board: str) -> list[str]:
        return self._render_files(
            target_dir=target_dir,
            files={
                "project.yaml": ("blink/project.yaml.j2", {"name": name, "board": board}),
                "ip/blink_test.ip.yaml": ("blink/ip/blink_test.ip.yaml.j2", {}),
                "rtl/blink_test.sv": ("blink/rtl/blink_test.sv.j2", {}),
            },
        )

    def init_pll(self, *, target_dir: str, name: str, board: str) -> list[str]:
        return self._render_files(
            target_dir=target_dir,
            files={
                "project.yaml": ("pll/project.yaml.j2", {"name": name, "board": board}),
                "timing_config.yaml": ("pll/timing_config.yaml.j2", {}),
                "ip/blink_test.ip.yaml": ("pll/ip/blink_test.ip.yaml.j2", {}),
                "rtl/blink_test.sv": ("pll/rtl/blink_test.sv.j2", {}),
            },
        )

    def init_sdram(self, *, target_dir: str, name: str, board: str) -> list[str]:
        return self._render_files(
            target_dir=target_dir,
            files={
                "project.yaml": ("sdram/project.yaml.j2", {"name": name, "board": board}),
                "timing_config.yaml": ("sdram/timing_config.yaml.j2", {}),
                "ip/dummy_cpu.cpu.yaml": ("sdram/ip/dummy_cpu.cpu.yaml.j2", {}),
                "ip/sdram_ctrl.ip.yaml": ("sdram/ip/sdram_ctrl.ip.yaml.j2", {}),
                "rtl/dummy_cpu.sv": ("sdram/rtl/dummy_cpu.sv.j2", {}),
            },
        )
