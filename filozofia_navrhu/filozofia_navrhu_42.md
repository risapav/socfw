Super. Ideme na:

# generic bridge registry + protocol adapter API + Wishbone bridge pattern

Toto je správny architektonický krok, lebo teraz už máme:

* `simple_bus`
* 1 konkrétny bridge `simple_bus -> axi_lite`
* CPU/RAM/peripherals
* planner
* RTL IR
* firmware flow

Chýba posledná veľká vec, aby bol framework naozaj elegantne rozšíriteľný:

* bridge nemá byť hardcoded v `SimpleBusPlanner`
* bridge má byť samostatný plugin
* planner má vedieť vybrať vhodný adaptér podľa:

  * source fabric protocol
  * destination peripheral protocol

To uzavrie bus architektúru veľmi pekne.

---

# 1. Cieľový model

Chceme, aby flow vyzeral takto:

```text
fabric protocol: simple_bus
peripheral protocol: axi_lite
↓
bridge registry finds:
  simple_bus -> axi_lite
↓
planner inserts bridge
↓
RTL builder emits bridge + interfaces
```

Neskôr:

```text
simple_bus -> wishbone
axi_lite -> simple_bus
wishbone -> simple_bus
```

bez zmeny jadra.

---

# 2. Bridge plugin API

## nový `socfw/plugins/bridge_api.py`

```python
from __future__ import annotations
from abc import ABC, abstractmethod


class BridgePlannerPlugin(ABC):
    src_protocol: str
    dst_protocol: str
    bridge_module: str

    @abstractmethod
    def can_bridge(self, *, fabric, ip, iface) -> bool:
        raise NotImplementedError

    @abstractmethod
    def plan_bridge(self, *, fabric, mod, ip, iface):
        raise NotImplementedError
```

---

# 3. Generic bridge registry

## update `socfw/plugins/registry.py`

Pridaj:

```python
from __future__ import annotations
from dataclasses import dataclass, field

from socfw.validate.rules.base import ValidationRule


@dataclass
class PluginRegistry:
    emitters: dict[str, object] = field(default_factory=dict)
    reports: dict[str, object] = field(default_factory=dict)
    validators: list[ValidationRule] = field(default_factory=list)
    bridge_planners: list[object] = field(default_factory=list)

    def register_emitter(self, family: str, plugin: object) -> None:
        self.emitters[family] = plugin

    def register_report(self, name: str, plugin: object) -> None:
        self.reports[name] = plugin

    def register_validator(self, rule: ValidationRule) -> None:
        self.validators.append(rule)

    def register_bridge_planner(self, plugin: object) -> None:
        self.bridge_planners.append(plugin)

    def find_bridge(self, *, src_protocol: str, dst_protocol: str):
        for p in self.bridge_planners:
            if p.src_protocol == src_protocol and p.dst_protocol == dst_protocol:
                return p
        return None
```

---

# 4. Generic bridge planner helper

## nový `socfw/elaborate/bridge_resolver.py`

```python
from __future__ import annotations


class BridgeResolver:
    def __init__(self, registry) -> None:
        self.registry = registry

    def resolve(self, *, fabric, mod, ip, iface):
        plugin = self.registry.find_bridge(
            src_protocol=fabric.protocol,
            dst_protocol=iface.protocol,
        )
        if plugin is None:
            return None

        if not plugin.can_bridge(fabric=fabric, ip=ip, iface=iface):
            return None

        return plugin.plan_bridge(
            fabric=fabric,
            mod=mod,
            ip=ip,
            iface=iface,
        )
```

---

# 5. AXI-lite bridge plugin

## nový `socfw/plugins/bridges/simple_to_axi.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import PlannedBusBridge


class SimpleBusToAxiLiteBridgePlanner:
    src_protocol = "simple_bus"
    dst_protocol = "axi_lite"
    bridge_module = "simple_bus_to_axi_lite_bridge"

    def can_bridge(self, *, fabric, ip, iface) -> bool:
        return fabric.protocol == "simple_bus" and iface.protocol == "axi_lite"

    def plan_bridge(self, *, fabric, mod, ip, iface):
        return PlannedBusBridge(
            instance=f"bridge_{mod.instance}",
            module=self.bridge_module,
            src_protocol=self.src_protocol,
            dst_protocol=self.dst_protocol,
            src_fabric=fabric.name,
            dst_instance=mod.instance,
            dst_port=iface.port_name,
        )
```

---

# 6. Wishbone bridge plugin pattern

Aj keď ešte hneď neurobíš plný RTL, je dobré už mať pattern.

## nový `socfw/plugins/bridges/simple_to_wishbone.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import PlannedBusBridge


class SimpleBusToWishboneBridgePlanner:
    src_protocol = "simple_bus"
    dst_protocol = "wishbone"
    bridge_module = "simple_bus_to_wishbone_bridge"

    def can_bridge(self, *, fabric, ip, iface) -> bool:
        return fabric.protocol == "simple_bus" and iface.protocol == "wishbone"

    def plan_bridge(self, *, fabric, mod, ip, iface):
        return PlannedBusBridge(
            instance=f"bridge_{mod.instance}",
            module=self.bridge_module,
            src_protocol=self.src_protocol,
            dst_protocol=self.dst_protocol,
            src_fabric=fabric.name,
            dst_instance=mod.instance,
            dst_port=iface.port_name,
        )
```

Toto je zatiaľ len planner plugin, ale už ti uzatvára architektúru.

---

# 7. Bootstrap registrácia bridge pluginov

## update `socfw/plugins/bootstrap.py`

Pridaj importy:

```python
from socfw.plugins.bridges.simple_to_axi import SimpleBusToAxiLiteBridgePlanner
from socfw.plugins.bridges.simple_to_wishbone import SimpleBusToWishboneBridgePlanner
```

A registráciu:

```python
    reg.register_bridge_planner(SimpleBusToAxiLiteBridgePlanner())
    reg.register_bridge_planner(SimpleBusToWishboneBridgePlanner())
```

---

# 8. Simple bus planner bez hardcoded bridge logiky

Toto je hlavný cieľ.

## update `socfw/plugins/simple_bus/planner.py`

```python
from __future__ import annotations

from socfw.elaborate.bridge_resolver import BridgeResolver
from socfw.elaborate.bus_plan import InterconnectPlan, ResolvedBusEndpoint


class SimpleBusPlanner:
    protocol = "simple_bus"

    def __init__(self, registry) -> None:
        self.bridge_resolver = BridgeResolver(registry)

    def plan(self, system) -> InterconnectPlan:
        plan = InterconnectPlan()

        for fabric in system.project.bus_fabrics:
            if fabric.protocol != "simple_bus":
                continue

            endpoints: list[ResolvedBusEndpoint] = []

            cpu_desc = system.cpu_desc()
            if system.cpu is not None and cpu_desc is not None and cpu_desc.bus_master is not None:
                if system.cpu.fabric == fabric.name:
                    endpoints.append(
                        ResolvedBusEndpoint(
                            instance=system.cpu.instance,
                            module_type=system.cpu.type_name,
                            fabric=fabric.name,
                            protocol=cpu_desc.bus_master.protocol,
                            role="master",
                            port_name=cpu_desc.bus_master.port_name,
                            addr_width=cpu_desc.bus_master.addr_width,
                            data_width=cpu_desc.bus_master.data_width,
                        )
                    )

            if system.ram is not None:
                endpoints.append(
                    ResolvedBusEndpoint(
                        instance="ram",
                        module_type=system.ram.module,
                        fabric=fabric.name,
                        protocol="simple_bus",
                        role="slave",
                        port_name="bus",
                        addr_width=system.ram.addr_width,
                        data_width=system.ram.data_width,
                        base=system.ram.base,
                        size=system.ram.size,
                        end=system.ram.base + system.ram.size - 1,
                    )
                )

            for mod in system.project.modules:
                if mod.bus is None or mod.bus.fabric != fabric.name:
                    continue

                ip = system.ip_catalog.get(mod.type_name)
                if ip is None:
                    continue

                iface = ip.bus_interface(role="slave")
                if iface is None:
                    continue

                if iface.protocol == "simple_bus":
                    endpoints.append(
                        ResolvedBusEndpoint(
                            instance=mod.instance,
                            module_type=mod.type_name,
                            fabric=fabric.name,
                            protocol="simple_bus",
                            role="slave",
                            port_name=iface.port_name,
                            addr_width=iface.addr_width,
                            data_width=iface.data_width,
                            base=mod.bus.base,
                            size=mod.bus.size,
                            end=mod.bus.base + mod.bus.size - 1,
                        )
                    )
                else:
                    bridge = self.bridge_resolver.resolve(
                        fabric=fabric,
                        mod=mod,
                        ip=ip,
                        iface=iface,
                    )
                    if bridge is not None:
                        plan.bridges.append(bridge)

                        endpoints.append(
                            ResolvedBusEndpoint(
                                instance=bridge.instance,
                                module_type=bridge.module,
                                fabric=fabric.name,
                                protocol="simple_bus",
                                role="slave",
                                port_name="sbus",
                                addr_width=fabric.addr_width,
                                data_width=fabric.data_width,
                                base=mod.bus.base,
                                size=mod.bus.size,
                                end=mod.bus.base + mod.bus.size - 1,
                            )
                        )

            plan.fabrics[fabric.name] = endpoints

        return plan
```

---

# 9. Elaborator musí dostať registry

Keďže planner už používa registry, treba to preniesť do elaborácie.

## update `socfw/elaborate/planner.py`

```python
from __future__ import annotations

from socfw.builders.address_map_builder import AddressMapBuilder
from socfw.builders.irq_plan_builder import IrqPlanBuilder
from socfw.plugins.simple_bus.planner import SimpleBusPlanner
from .board_bindings import BoardBindingResolver
from .clocks import ClockResolver
from .design import ElaboratedDesign


class Elaborator:
    def __init__(self, registry) -> None:
        self.board_bindings = BoardBindingResolver()
        self.clocks = ClockResolver()
        self.simple_bus = SimpleBusPlanner(registry)
        self.addr_builder = AddressMapBuilder()
        self.irq_builder = IrqPlanBuilder()

    def elaborate(self, system) -> ElaboratedDesign:
        design = ElaboratedDesign(system=system)
        design.port_bindings = self.board_bindings.resolve(system)
        design.clock_domains = self.clocks.resolve(system)

        design.interconnect = self.simple_bus.plan(system)
        system.peripheral_blocks = self.addr_builder.build(system, design.interconnect)
        design.irq_plan = self.irq_builder.build(system)

        used_types = {m.type_name for m in system.project.modules}
        for t in used_types:
            ip = system.ip_catalog.get(t)
            if ip is None:
                continue
            design.dependency_assets.extend(ip.artifacts.synthesis)

        return design
```

---

## update `socfw/build/pipeline.py`

V `__init__`:

```python
        self.elaborator = Elaborator(registry)
```

---

# 10. Bridge validation rule

Keď je peripheral na inom protokole a neexistuje bridge plugin, má to byť explicitná chyba.

## nový `socfw/validate/rules/bridge_rules.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class MissingBridgeRule(ValidationRule):
    def __init__(self, registry) -> None:
        self.registry = registry

    def validate(self, system) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            if mod.bus is None:
                continue

            fabric = system.project.fabric_by_name(mod.bus.fabric)
            if fabric is None:
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            iface = ip.bus_interface(role="slave")
            if iface is None:
                continue

            if iface.protocol == fabric.protocol:
                continue

            bridge = self.registry.find_bridge(
                src_protocol=fabric.protocol,
                dst_protocol=iface.protocol,
            )
            if bridge is None:
                diags.append(
                    Diagnostic(
                        code="BRG001",
                        severity=Severity.ERROR,
                        message=(
                            f"No bridge registered for fabric protocol '{fabric.protocol}' "
                            f"to peripheral protocol '{iface.protocol}' "
                            f"for instance '{mod.instance}'"
                        ),
                        subject="project.modules.bus",
                    )
                )

        return diags
```

## `socfw/plugins/bootstrap.py`

Toto je jediný trochu špeciálny bod, lebo validator potrebuje registry. Najčistejšie:

```python
from socfw.validate.rules.bridge_rules import MissingBridgeRule
```

A po vytvorení `reg` a bridge registráciách:

```python
    reg.register_validator(MissingBridgeRule(reg))
```

---

# 11. Wishbone interface pattern

Aj keď ešte nespravíš plný RTL bridge, je dobré mať už interface a periférny descriptor pattern.

## `src/ip/bus/wishbone_if.sv`

```systemverilog
interface wishbone_if;
  logic [31:0] adr;
  logic [31:0] dat_w;
  logic [31:0] dat_r;
  logic [3:0]  sel;
  logic        we;
  logic        cyc;
  logic        stb;
  logic        ack;

  modport master (
    output adr, output dat_w, output sel, output we, output cyc, output stb,
    input  dat_r, input ack
  );

  modport slave (
    input  adr, input dat_w, input sel, input we, input cyc, input stb,
    output dat_r, output ack
  );
endinterface
```

To ti okamžite pripraví pattern pre ďalší bridge.

---

# 12. Example Wishbone descriptor pattern

## `tests/golden/fixtures/wishbone_bridge_soc/ip/wb_gpio.ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: wb_gpio
  module: wb_gpio
  category: peripheral

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: true
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: RESET_N
  active_high: false

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

artifacts:
  synthesis:
    - tests/golden/fixtures/wishbone_bridge_soc/rtl/wb_gpio.sv
  simulation: []
  metadata: []

bus_interfaces:
  - port_name: wb
    protocol: wishbone
    role: slave
    addr_width: 32
    data_width: 32
```

Aj bez plného bridge RTL už tým vieš overiť planner a validation vrstvu.

---

# 13. Čo je týmto architektonicky hotové

Po tomto kroku už máš:

* generic bridge registry
* bridge planner API
* bridge injection bez hardcodingu
* validation pre chýbajúce bridge
* pattern pre ďalšie protocol families
* elegantné oddelenie:

  * core fabric planner
  * bridge selection
  * RTL bridge emission

To je veľmi čistá architektúra.

---

# 14. Čo by som spravil hneď potom

Teraz sú podľa mňa tri najlepšie smery:

### A

**Wishbone bridge RTL**

* druhý reálny adapter
* ešte silnejší dôkaz rozšíriteľnosti

### B

**repo hardening**

* CI
* golden snapshots
* packaging
* docs

### C

**schema/report/doc hardening**

* export schemas
* richer explain/report
* docs generator pre plugin registry

Môj praktický odporúčaný ďalší krok je:

👉 **B — repo hardening + CI + golden tests**

Lebo architektúra je už v zásade veľmi silná. Teraz sa oplatí z toho spraviť stabilný, reviewovateľný framework, na ktorom sa dá normálne pracovať.

Ak chceš, ďalšia správa môže byť presne:
**repo hardening plan + CI layout + golden test matrix + release-ready project skeleton**
