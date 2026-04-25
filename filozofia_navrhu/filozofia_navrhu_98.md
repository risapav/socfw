Áno. Tu je **Commit 35 ako file-by-file scaffold**:

# Commit 35 — native signal declarations + basic clock/reset nets

Cieľ:

* `soc_top.sv` prestane pripájať všetko priamo na konštanty
* native RTL IR dostane:

  * interné signály
  * clock/reset nety
  * základ pre neskoršie bus wiring
* bridge aj moduly budú mať stabilnejšie pripojenia

---

# Názov commitu

```text
rtl: add native signal declarations and basic clock/reset nets
```

---

# Súbory upraviť

```text
socfw/ir/rtl.py
socfw/builders/rtl_ir_builder.py
socfw/emit/rtl_emitter.py
tests/unit/test_rtl_emitter.py
tests/integration/test_build_vendor_sdram_soc.py
```

---

# `socfw/ir/rtl.py`

Doplň signály:

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class RtlSignal:
    name: str
    width: int = 1
    kind: str = "wire"


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
    signals: list[RtlSignal] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)
```

---

# `socfw/builders/rtl_ir_builder.py`

Pridaj basic nets:

```python
from __future__ import annotations

from socfw.ir.rtl import RtlConnection, RtlInstance, RtlPort, RtlSignal, RtlTop


class RtlIrBuilder:
    def build(self, *, system, planned_bridges) -> RtlTop:
        top = RtlTop(module_name="soc_top")

        self._add_basic_clock_reset_nets(system, top)
        self._add_board_bound_ports(system, top)
        self._add_project_module_instances(system, top)
        self._add_bridge_instances(planned_bridges, top)

        top.ports = sorted(top.ports, key=lambda p: p.name)
        top.signals = sorted(self._dedup_signals(top.signals), key=lambda s: s.name)
        top.instances = sorted(top.instances, key=lambda i: i.instance)
        return top

    def _dedup_signals(self, signals):
        by_name = {}
        for s in signals:
            by_name[s.name] = s
        return list(by_name.values())

    def _add_basic_clock_reset_nets(self, system, top: RtlTop) -> None:
        clk_name = system.board.system_clock.top_name
        top.ports.append(RtlPort(direction="input", name=clk_name, width=1))

        if system.board.system_reset is not None:
            rst_name = system.board.system_reset.top_name
            top.ports.append(RtlPort(direction="input", name=rst_name, width=1))
            top.signals.append(RtlSignal(name="reset_n", width=1))
            if system.board.system_reset.active_low:
                top.signals.append(RtlSignal(name="reset_active", width=1))
        else:
            top.signals.append(RtlSignal(name="reset_n", width=1))

    # keep _add_board_bound_ports from Commit 34

    def _add_project_module_instances(self, system, top: RtlTop) -> None:
        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            conns = []

            for port_name, domain in sorted(mod.clocks.items()):
                if isinstance(domain, str):
                    conns.append(RtlConnection(port_name, self._clock_expr(system, domain)))

            if ip.reset_port:
                conns.append(RtlConnection(ip.reset_port, "reset_n"))

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
                        RtlConnection("clk", self._bridge_clk_expr()),
                        RtlConnection("reset_n", "reset_n"),
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

    def _bridge_clk_expr(self) -> str:
        return "SYS_CLK"

    def _clock_expr(self, system, domain: str) -> str:
        if domain in {"sys_clk", "ref_clk"}:
            return system.board.system_clock.top_name
        if ":" in domain:
            inst, output = domain.split(":", 1)
            return f"{inst}_{output}"
        return domain
```

Poznámka: `_bridge_clk_expr()` je zatiaľ jednoduchý. V ďalšom commite ho zlepšíme na fabric clock/domain.

---

# `socfw/emit/rtl_emitter.py`

Doplň signal declarations po module headere:

```python
        lines.append("")

        for sig in sorted(top.signals, key=lambda s: s.name):
            width = "" if sig.width == 1 else f"[{sig.width - 1}:0] "
            lines.append(f"  {sig.kind} {width}{sig.name};")

        if top.signals:
            lines.append("")
```

Celý relevantný emitter flow:

```python
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

        for sig in sorted(top.signals, key=lambda s: s.name):
            width = "" if sig.width == 1 else f"[{sig.width - 1}:0] "
            lines.append(f"  {sig.kind} {width}{sig.name};")

        if top.signals:
            lines.append("")
```

---

# Test update

## `tests/unit/test_rtl_emitter.py`

Doplň signal assertion:

```python
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.ir.rtl import RtlConnection, RtlInstance, RtlPort, RtlSignal, RtlTop


def test_rtl_emitter_writes_top_with_ports_and_signals(tmp_path):
    top = RtlTop(
        module_name="soc_top",
        ports=[RtlPort(direction="output", name="ONB_LEDS", width=6)],
        signals=[RtlSignal(name="reset_n")],
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
    assert "wire reset_n;" in text
    assert "demo_mod u0" in text
```

---

# Integration očakávania

## `test_build_vendor_sdram_soc.py`

Pridaj:

```python
assert "input wire SYS_CLK" in rtl_text
assert "wire reset_n;" in rtl_text
assert ".reset_n(reset_n)" in rtl_text
```

Ak board reset top port má iný názov, assertion uprav podľa reálneho boardu.

---

# Golden update

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
cp build/vendor_sdram_soc/rtl/soc_top.sv tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv
```

Ak sa mení aj blink top:

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
cp build/blink_converged/rtl/soc_top.sv tests/golden/expected/blink_converged/rtl/soc_top.sv
```

---

# Čo ešte nerobiť

Ešte nerob:

* reset synchronizer
* real PLL output nets
* bus wires
* Wishbone wiring
* address decoder

Tento commit je len stabilný základ pre clock/reset/signals.

---

# Definition of Done

Commit 35 je hotový, keď:

* `RtlTop` má `signals`
* `soc_top.sv` obsahuje interné signály
* bridge a vendor IP používajú `reset_n`
* integration + golden sú green

Ďalší commit:

```text
rtl: add native bus signal declarations and bridge-to-sdram wishbone wiring
```
