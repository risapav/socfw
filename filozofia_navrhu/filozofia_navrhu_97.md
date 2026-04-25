Áno. Tu je **Commit 34 ako file-by-file scaffold**:

# Commit 34 — module instances + board-bound top ports v native RTL IR

Cieľ:

* `soc_top.sv` už nebude obsahovať len bridge
* native RTL IR začne generovať:

  * top-level porty z board bindings
  * bežné IP inštancie z `project.modules`
  * základné clock bindings
* tým sa začne reálne nahrádzať legacy top generator

---

# Názov commitu

```text
rtl: add module instances and board-bound top ports to native RTL IR
```

---

# Súbory upraviť

```text
socfw/ir/rtl.py
socfw/builders/rtl_ir_builder.py
socfw/emit/rtl_emitter.py
tests/unit/test_rtl_ir_builder_bridge.py
tests/unit/test_rtl_emitter.py
tests/integration/test_build_blink_converged.py
tests/integration/test_build_vendor_sdram_soc.py
```

---

# `socfw/ir/rtl.py`

Rozšír IR:

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class RtlPort:
    direction: str
    name: str
    width: int = 1
    kind: str = "wire"


@dataclass(frozen=True)
class RtlConnection:
    port: str
    expr: str


@dataclass(frozen=True)
class RtlInstance:
    module: str
    instance: str
    connections: tuple[RtlConnection, ...] = ()


@dataclass
class RtlTop:
    module_name: str = "soc_top"
    ports: list[RtlPort] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)
```

---

# `socfw/builders/rtl_ir_builder.py`

Nahraď minimalistický builder týmto smerom:

```python
from __future__ import annotations

from socfw.ir.rtl import RtlConnection, RtlInstance, RtlPort, RtlTop


class RtlIrBuilder:
    def build(self, *, system, planned_bridges) -> RtlTop:
        top = RtlTop(module_name="soc_top")

        self._add_board_bound_ports(system, top)
        self._add_project_module_instances(system, top)
        self._add_bridge_instances(planned_bridges, top)

        top.ports = sorted(top.ports, key=lambda p: p.name)
        top.instances = sorted(top.instances, key=lambda i: i.instance)
        return top

    def _add_board_bound_ports(self, system, top: RtlTop) -> None:
        seen = set()

        for mod in system.project.modules:
            ports = mod.bind.get("ports", {}) if isinstance(mod.bind, dict) else {}
            for _module_port, bind_spec in ports.items():
                if not isinstance(bind_spec, dict):
                    continue

                target = bind_spec.get("target")
                if not isinstance(target, str) or not target.startswith("board:"):
                    continue

                board_path = target[len("board:"):]
                resource = system.board.resolve_resource_path(board_path)
                if not isinstance(resource, dict):
                    continue

                name = resource.get("top_name")
                kind = resource.get("kind", "scalar")
                width = int(resource.get("width", 1))

                if not name or name in seen:
                    continue

                direction = "inout" if kind == "inout" else "output"
                top.ports.append(
                    RtlPort(
                        direction=direction,
                        name=name,
                        width=width,
                    )
                )
                seen.add(name)

    def _add_project_module_instances(self, system, top: RtlTop) -> None:
        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            conns = []

            for port_name, domain in sorted(mod.clocks.items()):
                if isinstance(domain, str):
                    conns.append(RtlConnection(port_name, self._clock_expr(system, domain)))

            ports = mod.bind.get("ports", {}) if isinstance(mod.bind, dict) else {}
            for port_name, bind_spec in sorted(ports.items()):
                if not isinstance(bind_spec, dict):
                    continue
                target = bind_spec.get("target")
                if not isinstance(target, str):
                    continue
                if target.startswith("board:"):
                    resource = system.board.resolve_resource_path(target[len("board:"):])
                    if isinstance(resource, dict) and resource.get("top_name"):
                        conns.append(RtlConnection(port_name, resource["top_name"]))

            top.instances.append(
                RtlInstance(
                    module=ip.module,
                    instance=mod.instance,
                    connections=tuple(conns),
                )
            )

    def _add_bridge_instances(self, planned_bridges, top: RtlTop) -> None:
        for bridge in sorted(planned_bridges, key=lambda b: b.instance):
            top.instances.append(
                RtlInstance(
                    module=f"{bridge.kind}_bridge",
                    instance=bridge.instance,
                    connections=(
                        RtlConnection("clk", "1'b0"),
                        RtlConnection("reset_n", "1'b1"),
                        RtlConnection("sb_addr", "32'h0"),
                        RtlConnection("sb_wdata", "32'h0"),
                        RtlConnection("sb_be", "4'h0"),
                        RtlConnection("sb_we", "1'b0"),
                        RtlConnection("sb_valid", "1'b0"),
                        RtlConnection("sb_rdata", ""),
                        RtlConnection("sb_ready", ""),
                        RtlConnection("wb_adr", ""),
                        RtlConnection("wb_dat_w", ""),
                        RtlConnection("wb_dat_r", "32'h0"),
                        RtlConnection("wb_sel", ""),
                        RtlConnection("wb_we", ""),
                        RtlConnection("wb_cyc", ""),
                        RtlConnection("wb_stb", ""),
                        RtlConnection("wb_ack", "1'b0"),
                    ),
                )
            )

    def _clock_expr(self, system, domain: str) -> str:
        if domain in {"sys_clk", "ref_clk"}:
            return system.board.system_clock.top_name
        if ":" in domain:
            inst, output = domain.split(":", 1)
            return f"{inst}_{output}"
        return domain
```

---

# `socfw/emit/rtl_emitter.py`

Rozšír emitter o port list:

```python
from __future__ import annotations

from pathlib import Path


class RtlEmitter:
    def emit_top(self, out_dir: str, top) -> str:
        rtl_dir = Path(out_dir) / "rtl"
        rtl_dir.mkdir(parents=True, exist_ok=True)

        out = rtl_dir / f"{top.module_name}.sv"

        lines: list[str] = []
        lines.append("`default_nettype none")
        lines.append("")

        if top.ports:
            lines.append(f"module {top.module_name} (")
            for idx, p in enumerate(top.ports):
                comma = "," if idx < len(top.ports) - 1 else ""
                width = "" if p.width == 1 else f"[{p.width - 1}:0] "
                lines.append(f"  {p.direction} wire {width}{p.name}{comma}")
            lines.append(");")
        else:
            lines.append(f"module {top.module_name};")

        lines.append("")

        for inst in sorted(top.instances, key=lambda i: i.instance):
            lines.append(f"  {inst.module} {inst.instance} (")
            conns = list(inst.connections)
            for idx, c in enumerate(conns):
                comma = "," if idx < len(conns) - 1 else ""
                if c.expr:
                    lines.append(f"    .{c.port}({c.expr}){comma}")
                else:
                    lines.append(f"    .{c.port}(){comma}")
            lines.append("  );")
            lines.append("")

        lines.append("endmodule")
        lines.append("")
        lines.append("`default_nettype wire")
        lines.append("")

        out.write_text("\n".join(lines), encoding="utf-8")
        return str(out)
```

---

# Test úpravy

## `tests/unit/test_rtl_emitter.py`

Doplň port assertion:

```python
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.ir.rtl import RtlConnection, RtlInstance, RtlPort, RtlTop


def test_rtl_emitter_writes_top_with_ports(tmp_path):
    top = RtlTop(
        module_name="soc_top",
        ports=[RtlPort(direction="output", name="ONB_LEDS", width=6)],
        instances=[
            RtlInstance(
                module="demo_mod",
                instance="u0",
                connections=(RtlConnection("clk", "1'b0"),),
            )
        ],
    )

    RtlEmitter().emit_top(str(tmp_path), top)
    text = (tmp_path / "rtl" / "soc_top.sv").read_text(encoding="utf-8")

    assert "module soc_top (" in text
    assert "output wire [5:0] ONB_LEDS" in text
    assert "demo_mod u0" in text
```

---

# Integration očakávania

## `test_build_blink_converged.py`

Pridaj:

```python
assert "ONB_LEDS" in rtl_text
assert "blink_test blink_test" in rtl_text
```

## `test_build_vendor_sdram_soc.py`

Pridaj:

```python
assert "ZS_DQ" in rtl_text
assert "sdram_ctrl sdram0" in rtl_text
assert "simple_bus_to_wishbone_bridge u_bridge_sdram0" in rtl_text
```

---

# Golden update

Po stabilnom builde:

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc

cp build/blink_converged/rtl/soc_top.sv tests/golden/expected/blink_converged/rtl/soc_top.sv
cp build/vendor_sdram_soc/rtl/soc_top.sv tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv
```

---

# Čo ešte nerobiť

Ešte nerob:

* real signal wiring pre bus
* reset synchronizers
* clock net declarations
* address decoder
* native files.tcl emitter

Tento commit len presúva top štruktúru do native IR.

---

# Definition of Done

Commit 34 je hotový, keď:

* `soc_top.sv` má board-bound top ports
* bežné IP moduly sú inštancované z IR
* bridge je inštancovaný z IR
* blink aj SDRAM integration testy sú green
* golden snapshoty sú aktualizované

Ďalší commit:

```text
rtl: add native signal declarations and basic clock/reset nets
```
