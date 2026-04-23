from __future__ import annotations

from pathlib import Path

from socfw.emit.renderer import Renderer
from socfw.scaffold.board_catalog import BoardCatalog
from socfw.scaffold.model import InitRequest
from socfw.scaffold.template_registry import TemplateRegistry


class ScaffoldGenerator:
    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)
        self.templates = TemplateRegistry()
        self.boards = BoardCatalog()

    def generate(self, req: InitRequest) -> list[str]:
        tmpl = self.templates.get(req.template)
        if tmpl is None:
            raise ValueError(f"Unknown scaffold template '{req.template}'")

        out = Path(req.out_dir) / req.name
        if out.exists() and any(out.iterdir()) and not req.force:
            raise ValueError(f"Target directory '{out}' is not empty; use --force")

        out.mkdir(parents=True, exist_ok=True)

        created: list[str] = []
        created.extend(self._write_common(out, req, tmpl))

        if tmpl.key == "blink":
            created.extend(self._write_blink(out, req))
        elif tmpl.key == "soc-led":
            created.extend(self._write_soc_led(out, req))
        elif tmpl.key == "picorv32-soc":
            created.extend(self._write_picorv32_soc(out, req))
        elif tmpl.key == "axi-bridge":
            created.extend(self._write_axi_bridge(out, req))
        elif tmpl.key == "wishbone-bridge":
            created.extend(self._write_wishbone_bridge(out, req))
        else:
            raise ValueError(f"Unhandled scaffold template '{tmpl.key}'")

        return created

    def _write(self, out_file: Path, content: str) -> str:
        out_file.parent.mkdir(parents=True, exist_ok=True)
        out_file.write_text(content, encoding="utf-8")
        return str(out_file)

    def _write_common(self, out: Path, req: InitRequest, tmpl) -> list[str]:
        created = []
        created.append(self._write(
            out / "README.md",
            self.renderer.render("scaffold/README.md.j2", project_name=req.name, template=tmpl, board=req.board),
        ))
        created.append(self._write(
            out / ".gitignore",
            self.renderer.render("scaffold/gitignore.j2"),
        ))
        return created

    def _write_blink(self, out: Path, req: InitRequest) -> list[str]:
        board = req.board or "qmtech_ep4ce55"
        return [
            self._write(out / "project.yaml",
                        self.renderer.render("scaffold/project_blink.yaml.j2", project_name=req.name, board=board)),
            self._write(out / "ip" / "blink_test.ip.yaml",
                        self.renderer.render("scaffold/ip_blink_test.ip.yaml.j2")),
        ]

    def _write_soc_led(self, out: Path, req: InitRequest) -> list[str]:
        board = req.board or "qmtech_ep4ce55"
        return [
            self._write(out / "project.yaml",
                        self.renderer.render("scaffold/project_soc_led.yaml.j2", project_name=req.name, board=board)),
            self._write(out / "ip" / "gpio.ip.yaml",
                        self.renderer.render("scaffold/ip_gpio.ip.yaml.j2")),
            self._write(out / "rtl" / "gpio_core.sv",
                        self.renderer.render("scaffold/gpio_core.sv.j2")),
        ]

    def _write_picorv32_soc(self, out: Path, req: InitRequest) -> list[str]:
        board = req.board or "qmtech_ep4ce55"
        cpu = req.cpu or "picorv32_min"
        return [
            self._write(out / "project.yaml",
                        self.renderer.render("scaffold/project_picorv32_soc.yaml.j2",
                                            project_name=req.name, board=board, cpu=cpu)),
            self._write(out / "fw" / "main.c",
                        self.renderer.render("scaffold/fw_main_picorv32.c.j2")),
            self._write(out / "fw" / "start.S",
                        self.renderer.render("scaffold/fw_start.S.j2")),
            self._write(out / "fw" / "cpu_irq.h",
                        self.renderer.render("scaffold/fw_cpu_irq.h.j2")),
        ]

    def _write_axi_bridge(self, out: Path, req: InitRequest) -> list[str]:
        board = req.board or "qmtech_ep4ce55"
        cpu = req.cpu or "picorv32_min"
        return [
            self._write(out / "project.yaml",
                        self.renderer.render("scaffold/project_axi_bridge.yaml.j2",
                                            project_name=req.name, board=board, cpu=cpu)),
            self._write(out / "ip" / "axi_gpio.ip.yaml",
                        self.renderer.render("scaffold/ip_axi_gpio.ip.yaml.j2")),
            self._write(out / "rtl" / "axi_gpio.sv",
                        self.renderer.render("scaffold/axi_gpio.sv.j2")),
            self._write(out / "fw" / "main.c",
                        self.renderer.render("scaffold/fw_main_axi_bridge.c.j2")),
            self._write(out / "fw" / "start.S",
                        self.renderer.render("scaffold/fw_start.S.j2")),
        ]

    def _write_wishbone_bridge(self, out: Path, req: InitRequest) -> list[str]:
        board = req.board or "qmtech_ep4ce55"
        return [
            self._write(out / "project.yaml",
                        self.renderer.render("scaffold/project_wishbone_bridge.yaml.j2",
                                            project_name=req.name, board=board)),
            self._write(out / "ip" / "wb_gpio.ip.yaml",
                        self.renderer.render("scaffold/ip_wb_gpio.ip.yaml.j2")),
            self._write(out / "rtl" / "wb_gpio.sv",
                        self.renderer.render("scaffold/wb_gpio.sv.j2")),
        ]
