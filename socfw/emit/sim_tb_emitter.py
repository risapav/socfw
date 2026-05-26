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
        extra_clocks: list[dict] = []

        if system.timing and system.timing.primary_clocks:
            pclk = system.timing.primary_clocks[0]
            clk_period_ns = pclk.period_ns
            if pclk.source_port:
                clk_port = self._resolve_clk_port(pclk.source_port, system)

            # Collect additional clock drivers for remaining primary clocks
            port_names = {p.name for p in top.ports if p.direction == "input"}
            seen_clks = {clk_port}
            for extra in system.timing.primary_clocks[1:]:
                port = self._resolve_clk_port(extra.source_port, system)
                if port in port_names and port not in seen_clks:
                    seen_clks.add(port)
                    extra_clocks.append({"port": port, "half_ns": extra.period_ns / 2.0})

        if system.board.sys_reset is not None:
            rst_port = system.board.sys_reset.top_name
            rst_active_low = system.board.sys_reset.active_low

        # 1 ms worth of cycles at the primary clock frequency, clamped to a sane range
        sim_cycles = max(_SIM_CYCLES_MIN, min(_SIM_CYCLES_MAX, int(1_000_000.0 / clk_period_ns)))

        extra_clk_ports = {c["port"] for c in extra_clocks}

        content = self.renderer.render(
            "tb_soc_top.sv.j2",
            module=top,
            clk_period_ns=clk_period_ns,
            clk_port=clk_port,
            rst_port=rst_port,
            rst_active_low=rst_active_low,
            sim_cycles=sim_cycles,
            extra_clocks=extra_clocks,
            extra_clk_ports=extra_clk_ports,
        )

        old = out.read_text(encoding="utf-8") if out.exists() else None
        if old != content:
            self.renderer.write_text(out, content, encoding="utf-8")

        return str(out)

    def _resolve_clk_port(self, source: str, system) -> str:
        if not source.startswith("board:"):
            return source
        selector = source[len("board:"):]
        if system.board.sys_clock and system.board.sys_clock.id == selector:
            return system.board.sys_clock.top_name
        if system.board.sys_reset and system.board.sys_reset.id == selector:
            return system.board.sys_reset.top_name
        return selector
