Super. Toto je správny moment spraviť **bus/interconnect vrstvu**, lebo práve tam sa rozhodne, či nový framework bude naozaj rozšíriteľný, alebo len „uprataný standalone generator“.

Zo súčasného frameworku je vidno dve dôležité veci:

* existuje už zárodok abstrakcie bus rozhraní (`bus_if`, `axi_lite_if`, `axi_stream_if`), takže myšlienka viacerých protocol families tam už je, len ešte nie je premietnutá do planner vrstvy. 
* SoC vetva je ešte stále čiastočne závislá na legacy contexte v `rtl.py`, čo je presne to, čo chceme novým bus plannerom odstrániť. 
* dokumentačný a SW výstup už implicitne počítajú s address mapou, perifériami a IRQ väzbami, takže nový bus/address planner musí vedieť tieto dáta produkovať systematicky.  

Nižšie dávam **kompletný refaktorovaný návrh bus layer**:

* bus modely,
* planner API,
* `simple_bus` plugin,
* address map builder,
* napojenie na RTL IR a `SoftwareIR`.

---

# 1. Cieľ bus vrstvy

Bus vrstva má vyriešiť tieto úlohy:

* reprezentovať **bus protokol** ako explicitný model,
* reprezentovať **master/slave attachment** ako doménové objekty,
* riešiť **address allocation**,
* riešiť **width/protocol compatibility**,
* vedieť vložiť **bridges/adapters**,
* produkovať dáta pre:

  * RTL,
  * software mapy,
  * docs,
  * graph/report.

To je presne ten kus, ktorý dnes v starom frameworku ešte nie je plnohodnotne vytiahnutý, hoci šablóny a generator flow už s ním implicitne počítajú.  

---

# 2. Nové bus modely

## `socfw/model/bus.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class BusRole(str, Enum):
    MASTER = "master"
    SLAVE = "slave"
    BRIDGE = "bridge"


@dataclass(frozen=True)
class AddressRegion:
    base: int
    size: int

    @property
    def end(self) -> int:
        return self.base + self.size - 1


@dataclass(frozen=True)
class BusProtocolDef:
    name: str
    addr_width: int
    data_width: int
    features: tuple[str, ...] = ()


@dataclass(frozen=True)
class BusEndpoint:
    instance: str
    port_name: str
    protocol: str
    role: BusRole
    addr_width: int = 32
    data_width: int = 32
    region: AddressRegion | None = None
    clock_domain: str | None = None
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass
class BusInstance:
    name: str
    protocol: str
    addr_width: int
    data_width: int
    masters: list[str] = field(default_factory=list)
    slaves: list[str] = field(default_factory=list)
    meta: dict[str, Any] = field(default_factory=dict)
```

Toto je základný doménový model. Oproti starému stavu už bus nie je len string typu `simple_bus`, ale objekt, ku ktorému sa dá pripnúť planner a validačné pravidlá.

---

# 3. Rozšírenie IP modelu o bus interfaces

Keď chceš pluginový interconnect, IP descriptor musí vedieť povedať, aký bus endpoint poskytuje.

## `socfw/model/ip.py` – doplnenie

```python
from dataclasses import dataclass, field

# ... pôvodné triedy ostávajú ...

@dataclass(frozen=True)
class IpBusInterface:
    port_name: str
    protocol: str
    role: str               # master / slave
    addr_width: int = 32
    data_width: int = 32


@dataclass(frozen=True)
class IpDescriptor:
    name: str
    module: str
    category: str
    origin: IpOrigin
    needs_bus: bool
    generate_registers: bool
    instantiate_directly: bool
    dependency_only: bool
    reset: IpResetSemantics
    clocking: IpClocking
    artifacts: IpArtifactBundle
    bus_interfaces: tuple[IpBusInterface, ...] = ()
    meta: dict[str, object] = field(default_factory=dict)

    def bus_interface(self, role: str | None = None) -> IpBusInterface | None:
        for b in self.bus_interfaces:
            if role is None or b.role == role:
                return b
        return None
```

Týmto sa vie `uart`, `gpio`, `timer`, CPU alebo bus bridge definovať bez hardcoded if-ov v core.

---

# 4. Project model – bus attachments

Projekt musí explicitne povedať, kto sa pripája na ktorý fabric.

## `socfw/model/project.py` – doplnenie

```python
from dataclasses import dataclass, field

# ... pôvodné triedy ostávajú ...

@dataclass(frozen=True)
class BusAttach:
    fabric: str
    base: int | None = None
    size: int | None = None


@dataclass
class ModuleInstance:
    instance: str
    type_name: str
    params: dict[str, object] = field(default_factory=dict)
    clocks: list[ClockBinding] = field(default_factory=list)
    port_bindings: list[PortBinding] = field(default_factory=list)
    bus: BusAttach | None = None


@dataclass(frozen=True)
class BusFabricRequest:
    name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32
    masters: list[str] = field(default_factory=list)
    slaves: list[str] = field(default_factory=list)


@dataclass
class ProjectModel:
    name: str
    mode: str
    board_ref: str
    board_file: str | None = None
    registries_ip: list[str] = field(default_factory=list)
    feature_refs: list[str] = field(default_factory=list)
    modules: list[ModuleInstance] = field(default_factory=list)
    primary_clock_domain: str = "sys_clk"
    generated_clocks: list[GeneratedClockRequest] = field(default_factory=list)
    timing_file: str | None = None
    debug: bool = False
    bus_fabrics: list[BusFabricRequest] = field(default_factory=list)

    def fabric_by_name(self, name: str) -> BusFabricRequest | None:
        for f in self.bus_fabrics:
            if f.name == name:
                return f
        return None
```

---

# 5. Planner výstupné modely

## `socfw/elaborate/bus_plan.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ResolvedBusEndpoint:
    instance: str
    module_type: str
    fabric: str
    protocol: str
    role: str
    port_name: str
    addr_width: int
    data_width: int
    base: int | None = None
    size: int | None = None
    end: int | None = None


@dataclass(frozen=True)
class PlannedBusBridge:
    instance: str
    module: str
    src_protocol: str
    dst_protocol: str
    src_fabric: str
    dst_fabric: str


@dataclass
class InterconnectPlan:
    fabrics: dict[str, list[ResolvedBusEndpoint]] = field(default_factory=dict)
    bridges: list[PlannedBusBridge] = field(default_factory=list)

    def endpoints_for(self, fabric: str) -> list[ResolvedBusEndpoint]:
        return self.fabrics.get(fabric, [])
```

---

# 6. Planner API

## `socfw/plugins/bus_api.py`

```python
from __future__ import annotations
from abc import ABC, abstractmethod

from socfw.model.system import SystemModel
from socfw.elaborate.bus_plan import InterconnectPlan


class BusPlanner(ABC):
    protocol: str

    @abstractmethod
    def plan(self, system: SystemModel) -> InterconnectPlan:
        raise NotImplementedError
```

Toto je presne miesto, kde sa neskôr pridá `axi_lite`, `wishbone`, bridge planner a pod.

---

# 7. Simple bus planner

## `socfw/plugins/simple_bus/planner.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan, ResolvedBusEndpoint
from socfw.model.system import SystemModel
from socfw.plugins.bus_api import BusPlanner


class SimpleBusPlanner(BusPlanner):
    protocol = "simple_bus"

    def plan(self, system: SystemModel) -> InterconnectPlan:
        plan = InterconnectPlan()

        for fabric in system.project.bus_fabrics:
            if fabric.protocol != self.protocol:
                continue

            endpoints: list[ResolvedBusEndpoint] = []

            for mod in system.project.modules:
                if mod.bus is None or mod.bus.fabric != fabric.name:
                    continue

                ip = system.ip_catalog.get(mod.type_name)
                if ip is None:
                    continue

                iface = ip.bus_interface()
                if iface is None:
                    continue

                base = mod.bus.base
                size = mod.bus.size
                end = None if (base is None or size is None) else (base + size - 1)

                endpoints.append(
                    ResolvedBusEndpoint(
                        instance=mod.instance,
                        module_type=mod.type_name,
                        fabric=fabric.name,
                        protocol=iface.protocol,
                        role=iface.role,
                        port_name=iface.port_name,
                        addr_width=iface.addr_width,
                        data_width=iface.data_width,
                        base=base,
                        size=size,
                        end=end,
                    )
                )

            plan.fabrics[fabric.name] = endpoints

        return plan
```

Toto je minimálny planner pre `simple_bus`. Je jednoduchý, ale dôležitý: presúva fabric plan z „nejakého legacy kontextu“ do explicitného modelu.

---

# 8. Address map builder

Address map nemá byť roztrúsená po SW generátore. Má vzniknúť ako samostatný build krok.

## `socfw/builders/address_map_builder.py`

```python
from __future__ import annotations

from socfw.model.addressing import AddressRegion, IrqDef, PeripheralAddressBlock, RegisterDef
from socfw.model.system import SystemModel
from socfw.elaborate.bus_plan import InterconnectPlan


class AddressMapBuilder:
    def build(self, system: SystemModel, plan: InterconnectPlan) -> list[PeripheralAddressBlock]:
        blocks: list[PeripheralAddressBlock] = []

        for fabric_name, endpoints in plan.fabrics.items():
            for ep in endpoints:
                if ep.role != "slave":
                    continue
                if ep.base is None or ep.size is None:
                    continue

                ip = system.ip_catalog.get(ep.module_type)
                if ip is None:
                    continue

                reg_defs = []
                irq_defs = []

                regs_meta = ip.meta.get("registers", [])
                for r in regs_meta:
                    reg_defs.append(
                        RegisterDef(
                            name=r["name"],
                            offset=int(r["offset"]),
                            width=int(r.get("width", 32)),
                            access=str(r.get("access", "rw")),
                            reset=int(r.get("reset", 0)),
                            desc=str(r.get("desc", "")),
                        )
                    )

                irqs_meta = ip.meta.get("irqs", [])
                for irq in irqs_meta:
                    irq_defs.append(
                        IrqDef(
                            name=str(irq["name"]),
                            irq_id=int(irq["id"]),
                        )
                    )

                blocks.append(
                    PeripheralAddressBlock(
                        instance=ep.instance,
                        module=ep.module_type,
                        region=AddressRegion(base=ep.base, size=ep.size),
                        registers=reg_defs,
                        irqs=irq_defs,
                    )
                )

        return blocks
```

Toto je dôležitý zlom: `SoftwareIR` a docs už nemusia čítať „peripherals“ z legacy modelu, ale berú explicitne vybudovanú address mapu.

---

# 9. Rozšírenie `ElaboratedDesign`

## `socfw/elaborate/design.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from .board_bindings import ResolvedPortBinding
from .clocks import ResolvedClockDomain
from .bus_plan import InterconnectPlan


@dataclass
class ElaboratedDesign:
    system: object
    port_bindings: list[ResolvedPortBinding] = field(default_factory=list)
    clock_domains: list[ResolvedClockDomain] = field(default_factory=list)
    dependency_assets: list[str] = field(default_factory=list)
    interconnect: InterconnectPlan | None = None
```

---

# 10. Rozšírený elaborator

## `socfw/elaborate/planner.py`

```python
from __future__ import annotations

from socfw.builders.address_map_builder import AddressMapBuilder
from socfw.model.system import SystemModel
from socfw.plugins.simple_bus.planner import SimpleBusPlanner
from .board_bindings import BoardBindingResolver
from .clocks import ClockResolver
from .design import ElaboratedDesign


class Elaborator:
    def __init__(self) -> None:
        self.board_bindings = BoardBindingResolver()
        self.clocks = ClockResolver()
        self.simple_bus = SimpleBusPlanner()
        self.addr_builder = AddressMapBuilder()

    def elaborate(self, system: SystemModel) -> ElaboratedDesign:
        design = ElaboratedDesign(system=system)
        design.port_bindings = self.board_bindings.resolve(system)
        design.clock_domains = self.clocks.resolve(system)

        interconnect = self.simple_bus.plan(system)
        design.interconnect = interconnect

        used_types = {m.type_name for m in system.project.modules}
        for t in used_types:
            ip = system.ip_catalog.get(t)
            if ip is None:
                continue
            design.dependency_assets.extend(ip.artifacts.synthesis)

        # Build address map into system for SW/docs layers.
        system.peripheral_blocks = self.addr_builder.build(system, interconnect)

        return design
```

---

# 11. Validation rules pre bus layer

## `socfw/validate/rules/bus_rules.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


class UnknownBusFabricRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        known = {f.name for f in system.project.bus_fabrics}

        for mod in system.project.modules:
            if mod.bus is None:
                continue
            if mod.bus.fabric not in known:
                diags.append(
                    Diagnostic(
                        code="BUS001",
                        severity=Severity.ERROR,
                        message=(
                            f"Instance '{mod.instance}' references unknown bus fabric "
                            f"'{mod.bus.fabric}'"
                        ),
                        subject="project.modules.bus",
                    )
                )
        return diags


class MissingBusInterfaceRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            if mod.bus is None:
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            iface = ip.bus_interface()
            if iface is None:
                diags.append(
                    Diagnostic(
                        code="BUS002",
                        severity=Severity.ERROR,
                        message=(
                            f"Instance '{mod.instance}' is attached to a bus, "
                            f"but IP '{mod.type_name}' declares no bus interface"
                        ),
                        subject="project.modules.bus",
                    )
                )
        return diags


class DuplicateAddressRegionRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        regs = []
        for mod in system.project.modules:
            if mod.bus and mod.bus.base is not None and mod.bus.size is not None:
                regs.append((mod.instance, mod.bus.base, mod.bus.base + mod.bus.size - 1))

        for i, (n1, b1, e1) in enumerate(regs):
            for n2, b2, e2 in regs[i + 1:]:
                if not (e1 < b2 or e2 < b1):
                    diags.append(
                        Diagnostic(
                            code="BUS003",
                            severity=Severity.ERROR,
                            message=(
                                f"Address overlap between '{n1}' "
                                f"(0x{b1:08X}-0x{e1:08X}) and '{n2}' "
                                f"(0x{b2:08X}-0x{e2:08X})"
                            ),
                            subject="project.modules.bus",
                        )
                    )
        return diags


class FabricProtocolMismatchRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        fabrics = {f.name: f for f in system.project.bus_fabrics}

        for mod in system.project.modules:
            if mod.bus is None:
                continue
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue
            iface = ip.bus_interface()
            if iface is None:
                continue

            fabric = fabrics.get(mod.bus.fabric)
            if fabric is None:
                continue

            if iface.protocol != fabric.protocol:
                diags.append(
                    Diagnostic(
                        code="BUS004",
                        severity=Severity.ERROR,
                        message=(
                            f"Instance '{mod.instance}' uses protocol '{iface.protocol}', "
                            f"but fabric '{fabric.name}' uses '{fabric.protocol}'"
                        ),
                        subject="project.modules.bus",
                    )
                )

        return diags
```

---

# 12. Napojenie do pipeline

## `socfw/build/pipeline.py` – doplnenie pravidiel

```python
from socfw.validate.rules.bus_rules import (
    DuplicateAddressRegionRule,
    FabricProtocolMismatchRule,
    MissingBusInterfaceRule,
    UnknownBusFabricRule,
)

# do self.rules pridať:
self.rules = [
    DuplicateModuleInstanceRule(),
    UnknownIpTypeRule(),
    UnknownGeneratedClockSourceRule(),
    UnknownBoardFeatureRule(),
    UnknownBoardBindingTargetRule(),
    VendorIpArtifactExistsRule(),
    BindingWidthCompatibilityRule(),
    UnknownBusFabricRule(),
    MissingBusInterfaceRule(),
    DuplicateAddressRegionRule(),
    FabricProtocolMismatchRule(),
]
```

---

# 13. Napojenie na RTL IR

Teraz musí `RtlIRBuilder` vedieť vytvoriť bus prepojenia.

Najprv zjednodušene: pre `simple_bus` nech je fabric represented ako shared wire bundle menom fabricu.

## `socfw/ir/rtl.py` – doplnenie

```python
@dataclass(frozen=True)
class RtlBusConn:
    port: str
    bus_name: str


@dataclass
class RtlInstance:
    module: str
    name: str
    params: dict[str, object] = field(default_factory=dict)
    conns: list[RtlConn] = field(default_factory=list)
    bus_conns: list[RtlBusConn] = field(default_factory=list)
    comment: str = ""
```

---

## `socfw/builders/rtl_ir_builder.py` – doplnenie

Do buildera doplň:

```python
from socfw.ir.rtl import RtlBusConn
```

A v loop-e nad modulmi, po bežných port binds:

```python
            # Bus attachments
            if design.interconnect is not None:
                for eps in design.interconnect.fabrics.values():
                    for ep in eps:
                        if ep.instance != mod.instance:
                            continue
                        conns_bus_name = f"bus_{ep.fabric}"
                        rtl.add_wire_once(
                            RtlWire(
                                name=conns_bus_name,
                                width=1,
                                comment=f"{ep.protocol} fabric {ep.fabric}",
                            )
                        )
                        if hasattr(ip, "bus_interface") and ip.bus_interface() is not None:
                            conns.append(RtlConn(port=ip.bus_interface().port_name, signal=conns_bus_name))
```

Toto je zatiaľ len placeholder reprezentácia. V ďalšom kroku by sa z toho stali:

* `interface` instancie pre `bus_if`,
* prípadne bus fabric moduly,
* bridge inštancie.

Ale ako prvý slice to stačí, lebo sa vytvorí planner-visible fabric väzba.

A súčasný framework už aj tak pozná `bus_if` a `axi_lite_if` ako explicitné SV interfaces, takže ďalšia evolúcia týmto smerom je prirodzená. 

---

# 14. Napojenie na SoftwareIR a DocsIR

Toto sa už vlastne stalo cez:

* `AddressMapBuilder`
* `system.peripheral_blocks`

Takže tvoje staré SW/docs generovanie už prestáva byť priamo závislé od pôvodného `SoCModel.peripherals`. A to je veľký architektonický posun oproti starému `SWGenerator`, ktorý ešte nad týmto starým modelom priamo stál. 

---

# 15. Čo týmto získavaš

Po tomto kroku už framework vie:

* opísať **fabric** ako prvotriedny objekt,
* validovať bus attachmenty,
* vybudovať address mapu,
* preniesť ju do:

  * `SoftwareIR`,
  * `DocsIR`,
  * čiastočne aj `RtlIR`,
* pripraviť plugin point pre ďalšie protocol families.

To je kľúčové, lebo práve tu sa framework mení z „vylepšeného standalone generatora“ na skutočné rozšíriteľné jadro.

---

# 16. Čo ešte chýba v bus vrstve

Aby to bolo plnohodnotné, ďalší krok by mal doplniť:

### 1. `bus_if` / `axi_lite_if` interface instantiation v RTL IR

Nie len dummy wire name, ale reálne SV interface alebo fabric module IR.

### 2. bridge/adapters

Napríklad:

* `axi_lite` slave na `simple_bus`
* width adapter
* ready/latency adapter

### 3. auto address allocator

Teraz sú `base/size` explicitné. Neskôr môže planner vedieť prideliť rozsahy automaticky.

### 4. graph/report

Interconnect plan je ideálny vstup pre nový graphviz/report layer. Starý `soc_graph.dot.j2` už ukazuje, že to je hodnotný výstup. 

---

# 17. Môj odporúčaný ďalší krok

Najlepšie pokračovanie teraz je:

**spraviť reálny RTL bus layer**

* `RtlInterfaceIR`
* `RtlFabricIR`
* instantiation `bus_if`
* prvý `simple_bus_fabric` emitter/template
* napojenie CPU/master/slave modportov

To je bod, kde sa SoC mode definitívne odpojí od legacy contextu a budeš mať architektúru pripravenú aj na nové bus-y.

V ďalšej správe ti viem pripraviť práve toto:
**kompletný refaktorovaný RTL bus layer pre `simple_bus`**
vrátane:

* IR typov,
* planner napojenia,
* buildera,
* templatu pre fabric/interface instancie.
