from __future__ import annotations

from pathlib import Path

from socfw.emit.renderer import Renderer
from socfw.ir.rtl import RtlTop

_DEFAULT_TEMPLATES = str(Path(__file__).resolve().parents[1] / "templates")

_SIM_CYCLES_MIN = 10_000
_SIM_CYCLES_MAX = 1_000_000


class SimTbEmitter:
    def __init__(self, templates_dir: str | None = None) -> None:
        self.renderer = Renderer(templates_dir or _DEFAULT_TEMPLATES)

    def emit(self, out_dir: str, top: RtlTop, system) -> str:
        sim_dir = Path(out_dir) / "sim"
        sim_dir.mkdir(parents=True, exist_ok=True)
        out = sim_dir / "tb_soc_top.sv"

        clk_period_ns = 20.0
        clk_port = system.board.sys_clock.top_name if system.board.sys_clock else "SYS_CLK"
        rst_port: str | None = None
        rst_active_low = True

        if system.timing and system.timing.primary_clocks:
            pclk = system.timing.primary_clocks[0]
            clk_period_ns = pclk.period_ns
            if pclk.source_port:
                clk_port = pclk.source_port

        if system.board.sys_reset is not None:
            rst_port = system.board.sys_reset.top_name
            rst_active_low = system.board.sys_reset.active_low

        # 1 ms worth of cycles at the primary clock frequency, clamped to a sane range
        sim_cycles = max(_SIM_CYCLES_MIN, min(_SIM_CYCLES_MAX, int(1_000_000.0 / clk_period_ns)))

        content = self.renderer.render(
            "tb_soc_top.sv.j2",
            module=top,
            clk_period_ns=clk_period_ns,
            clk_port=clk_port,
            rst_port=rst_port,
            rst_active_low=rst_active_low,
            sim_cycles=sim_cycles,
        )

        old = out.read_text(encoding="utf-8") if out.exists() else None
        if old != content:
            self.renderer.write_text(out, content, encoding="utf-8")

        return str(out)
