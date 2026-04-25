Áno. Tu je **Commit 31 ako file-by-file scaffold**:

# Commit 31 — real `simple_bus_to_wishbone_bridge` ako first-class bridge artifact

Cieľ:

* prestať patchovať `soc_top.sv` cez `compat_top_patch.py`
* zaviesť bridge ako normálny build/elaboration artifact
* pripraviť základ pre reálny bridge planner
* ponechať ešte dočasný legacy backend, ale bez string-hack insertu

---

# Názov commitu

```text
bridge: add real simple_bus_to_wishbone bridge artifact and stop top patching
```

---

# Súbory pridať

```text
socfw/bridges/simple_bus_to_wishbone_bridge.sv
socfw/elaborate/bridge_plan.py
socfw/elaborate/bridge_planner.py
tests/unit/test_bridge_planner.py
```

---

# Súbory upraviť

```text
socfw/build/vendor_artifacts.py
socfw/build/full_pipeline.py
legacy_build.py
tests/integration/test_build_vendor_sdram_soc.py
```

A odstrániť alebo prestať používať:

```text
socfw/build/compat_top_patch.py
```

---

# 1. `socfw/bridges/simple_bus_to_wishbone_bridge.sv`

```systemverilog
`default_nettype none

module simple_bus_to_wishbone_bridge (
  input  wire        clk,
  input  wire        reset_n,

  input  wire [31:0] sb_addr,
  input  wire [31:0] sb_wdata,
  input  wire [3:0]  sb_be,
  input  wire        sb_we,
  input  wire        sb_valid,
  output wire [31:0] sb_rdata,
  output wire        sb_ready,

  output wire [31:0] wb_adr,
  output wire [31:0] wb_dat_w,
  input  wire [31:0] wb_dat_r,
  output wire [3:0]  wb_sel,
  output wire        wb_we,
  output wire        wb_cyc,
  output wire        wb_stb,
  input  wire        wb_ack
);

  assign wb_adr   = sb_addr;
  assign wb_dat_w = sb_wdata;
  assign wb_sel   = sb_be;
  assign wb_we    = sb_we;
  assign wb_cyc   = sb_valid;
  assign wb_stb   = sb_valid;

  assign sb_rdata = wb_dat_r;
  assign sb_ready = wb_ack;

endmodule

`default_nettype wire
```

---

# 2. `socfw/elaborate/bridge_plan.py`

```python
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PlannedBridge:
    instance: str
    kind: str
    src_protocol: str
    dst_protocol: str
    target_module: str
    fabric: str
    rtl_file: str
```

---

# 3. `socfw/elaborate/bridge_planner.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.elaborate.bridge_registry import BridgeRegistry
from socfw.elaborate.bridge_plan import PlannedBridge


class BridgePlanner:
    def __init__(self, registry: BridgeRegistry | None = None) -> None:
        self.registry = registry or BridgeRegistry()

    def plan(self, system) -> list[PlannedBridge]:
        bridges: list[PlannedBridge] = []

        for mod in system.project.modules:
            if mod.bus is None:
                continue

            fabric = system.project.fabric_by_name(mod.bus.fabric)
            if fabric is None:
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            iface = ip.slave_bus_interface()
            if iface is None:
                continue

            if fabric.protocol == iface.protocol:
                continue

            support = self.registry.find_bridge(
                src_protocol=fabric.protocol,
                dst_protocol=iface.protocol,
            )
            if support is None:
                continue

            rtl_file = Path("socfw/bridges/simple_bus_to_wishbone_bridge.sv").resolve()

            bridges.append(
                PlannedBridge(
                    instance=f"u_bridge_{mod.instance}",
                    kind=support.bridge_kind,
                    src_protocol=fabric.protocol,
                    dst_protocol=iface.protocol,
                    target_module=mod.instance,
                    fabric=fabric.name,
                    rtl_file=str(rtl_file),
                )
            )

        return sorted(bridges, key=lambda b: b.instance)
```

---

# 4. Úprava `socfw/build/full_pipeline.py`

Doplň plánovanie bridgov do provenance a build contextu.

Prakticky zatiaľ stačí:

```python
from socfw.elaborate.bridge_planner import BridgePlanner
```

V `__init__`:

```python
self.bridge_planner = BridgePlanner()
```

V `build()` po `system = loaded.value`:

```python
planned_bridges = self.bridge_planner.plan(system)
```

A do reportu môžeš bridge pairs skladať z plánovaných bridgov:

```python
bridge_pairs=[f"{b.target_module}: {b.src_protocol} -> {b.dst_protocol}" for b in planned_bridges]
```

Zároveň ich potrebuješ dostať do legacy backendu. Najjednoduchšie:

```python
built = self.legacy.build(system=system, request=request, planned_bridges=planned_bridges)
```

---

# 5. Úprava `socfw/build/legacy_backend.py`

Zmeň signatúru:

```python
def build(self, *, system, request, planned_bridges=None) -> BuildResult:
```

a volanie:

```python
generated_files = build_legacy(
    project_file=request.project_file,
    out_dir=str(out_dir),
    system=system,
    planned_bridges=planned_bridges or [],
)
```

---

# 6. Úprava `legacy_build.py`

Zmeň signatúru:

```python
def build_legacy(project_file: str, out_dir: str, system=None, planned_bridges=None) -> list[str]:
```

Pridaj helper:

```python
def _copy_bridge_artifacts(out_dir: str, planned_bridges) -> list[str]:
    if not planned_bridges:
        return []

    rtl_dir = Path(out_dir) / "rtl"
    rtl_dir.mkdir(parents=True, exist_ok=True)

    copied = []
    for bridge in planned_bridges:
        src = Path(bridge.rtl_file)
        dst = rtl_dir / src.name
        dst.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
        copied.append(str(dst))

    return sorted(dict.fromkeys(copied))
```

V `build_legacy()` odstráň:

```python
patch_soc_top_with_bridge_scaffold(...)
```

a namiesto toho:

```python
bridge_files = _copy_bridge_artifacts(out_dir, planned_bridges or [])
```

Do generated files:

```python
for extra in [patched_files_tcl, bridge_summary, *bridge_files]:
    ...
```

---

# 7. Úprava `tests/integration/test_build_vendor_sdram_soc.py`

Zmeň assertion z patchnutého topu na first-class artifact:

```python
bridge_rtl = out_dir / "rtl" / "simple_bus_to_wishbone_bridge.sv"

assert bridge_rtl.exists()
assert "module simple_bus_to_wishbone_bridge" in bridge_rtl.read_text(encoding="utf-8")
```

Zatiaľ už netvrď:

```python
assert "u_bridge_sdram0" in rtl_text
```

To príde až v Commit 32, keď bridge planner začne generovať top-level instance cez IR/native emitter.

---

# 8. `tests/unit/test_bridge_planner.py`

```python
from socfw.elaborate.bridge_planner import BridgePlanner
from socfw.model.board import BoardClock, BoardModel
from socfw.model.bus import BusFabric, IpBusInterface, ModuleBusAttachment
from socfw.model.ip import IpDescriptor
from socfw.model.project import ProjectModel, ProjectModule
from socfw.model.system import SystemModel


def test_bridge_planner_plans_simple_bus_to_wishbone():
    system = SystemModel(
        board=BoardModel(
            board_id="demo",
            system_clock=BoardClock(id="clk", top_name="SYS_CLK", pin="A1", frequency_hz=50_000_000),
        ),
        project=ProjectModel(
            name="demo",
            mode="soc",
            board_ref="demo",
            buses=[BusFabric(name="main", protocol="simple_bus")],
            modules=[
                ProjectModule(
                    instance="sdram0",
                    type_name="sdram_ctrl",
                    bus=ModuleBusAttachment(fabric="main"),
                )
            ],
        ),
        ip_catalog={
            "sdram_ctrl": IpDescriptor(
                name="sdram_ctrl",
                module="sdram_ctrl",
                category="memory",
                bus_interfaces=(
                    IpBusInterface(port_name="wb", protocol="wishbone", role="slave"),
                ),
            )
        },
    )

    bridges = BridgePlanner().plan(system)

    assert len(bridges) == 1
    assert bridges[0].instance == "u_bridge_sdram0"
    assert bridges[0].kind == "simple_bus_to_wishbone"
```

---

# 9. Čo odstrániť / označiť deprecated

Po tomto commite:

```text
socfw/build/compat_top_patch.py
```

buď:

* zmaž,
* alebo nechaj, ale nepoužívať a označiť ako deprecated.

Odporúčam zmazať po tom, čo testy prejdú.

---

# Definition of Done

Commit 31 je hotový, keď:

* bridge RTL existuje ako súbor
* bridge planner ho plánuje
* `vendor_sdram_soc` build skopíruje bridge RTL do outputu
* `compat_top_patch.py` sa už nepoužíva
* testy sú green

Ďalší commit:

```text
elaborate: generate bridge instance in top-level IR instead of compatibility copy
```
