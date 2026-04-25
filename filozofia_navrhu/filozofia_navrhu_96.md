Áno. Tu je **Commit 33 ako file-by-file scaffold**:

# Commit 33 — native RTL IR emitter namiesto top-level injection

Cieľ:

* prestať patchovať `soc_top.sv` cez `top_injection.py`
* zaviesť prvý minimálny **RTL IR**
* generovať `soc_top.sv` z dátovej štruktúry, nie string patchom
* bridge instance už bude súčasťou IR

---

# Názov commitu

```text
rtl: replace top-level injection with minimal native RTL IR emitter
```

---

# Súbory pridať

```text
socfw/ir/rtl.py
socfw/builders/rtl_ir_builder.py
socfw/emit/rtl_emitter.py
tests/unit/test_rtl_ir_builder_bridge.py
tests/unit/test_rtl_emitter.py
```

---

# Súbory upraviť

```text
legacy_build.py
socfw/build/full_pipeline.py
tests/integration/test_build_vendor_sdram_soc.py
tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv
```

A prestať používať:

```text
socfw/build/top_injection.py
```

---

# `socfw/ir/rtl.py`

```python
from __future__ import annotations

from dataclasses import dataclass, field


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
    ports: list[str] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)
```

---

# `socfw/builders/rtl_ir_builder.py`

```python
from __future__ import annotations

from socfw.ir.rtl import RtlConnection, RtlInstance, RtlTop


class RtlIrBuilder:
    def build(self, *, system, planned_bridges) -> RtlTop:
        top = RtlTop(module_name="soc_top")

        # Minimal Phase 1 native IR:
        # keep ports light for now, add bridge instances deterministically.
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

        return top
```

---

# `socfw/emit/rtl_emitter.py`

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

# Úprava `socfw/build/full_pipeline.py`

Pridaj:

```python
from socfw.builders.rtl_ir_builder import RtlIrBuilder
from socfw.emit.rtl_emitter import RtlEmitter
```

V `__init__`:

```python
self.rtl_builder = RtlIrBuilder()
self.rtl_emitter = RtlEmitter()
```

V `build()` po `planned_bridges = ...`:

```python
rtl_top = self.rtl_builder.build(system=system, planned_bridges=planned_bridges)
native_top_file = self.rtl_emitter.emit_top(request.out_dir, rtl_top)
```

Po legacy build:

```python
built.generated_files.append(native_top_file)
built.normalize_files()
```

---

# Úprava `legacy_build.py`

Odstráň použitie:

```python
inject_bridge_instances(...)
```

a nechaj len:

* vendor files export
* bridge summary
* copy bridge RTL artifact

Teda žiadne patchovanie topu.

---

# `tests/unit/test_rtl_ir_builder_bridge.py`

```python
from socfw.builders.rtl_ir_builder import RtlIrBuilder
from socfw.elaborate.bridge_plan import PlannedBridge


def test_rtl_ir_builder_adds_planned_bridge_instance():
    bridge = PlannedBridge(
        instance="u_bridge_sdram0",
        kind="simple_bus_to_wishbone",
        src_protocol="simple_bus",
        dst_protocol="wishbone",
        target_module="sdram0",
        fabric="main",
        rtl_file="bridge.sv",
    )

    top = RtlIrBuilder().build(system=None, planned_bridges=[bridge])

    assert len(top.instances) == 1
    assert top.instances[0].module == "simple_bus_to_wishbone_bridge"
    assert top.instances[0].instance == "u_bridge_sdram0"
```

---

# `tests/unit/test_rtl_emitter.py`

```python
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.ir.rtl import RtlConnection, RtlInstance, RtlTop


def test_rtl_emitter_writes_top(tmp_path):
    top = RtlTop(
        module_name="soc_top",
        instances=[
            RtlInstance(
                module="demo_mod",
                instance="u0",
                connections=(RtlConnection("clk", "1'b0"),),
            )
        ],
    )

    out = RtlEmitter().emit_top(str(tmp_path), top)
    text = (tmp_path / "rtl" / "soc_top.sv").read_text(encoding="utf-8")

    assert out.endswith("soc_top.sv")
    assert "module soc_top" in text
    assert "demo_mod u0" in text
```

---

# Úprava `tests/integration/test_build_vendor_sdram_soc.py`

Nech zostane:

```python
assert "simple_bus_to_wishbone_bridge" in rtl_text
assert "u_bridge_sdram0" in rtl_text
```

Teraz to má pochádzať z native RTL emittera, nie injection helpera.

---

# Golden update

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
cp build/vendor_sdram_soc/rtl/soc_top.sv tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv
```

---

# Čo ešte nerobiť

Ešte nerob:

* plné SDRAM zapojenie
* top-level ports
* module port binding
* úplné odstránenie legacy backendu

Tento commit je len prvý native RTL top emitter.

---

# Definition of Done

Commit 33 je hotový, keď:

* `soc_top.sv` vzniká z `RtlTop`
* bridge instance je v IR
* `top_injection.py` sa nepoužíva
* integration + golden testy sú green

Ďalší commit:

```text
rtl: add module instances and board-bound top ports to native RTL IR
```
