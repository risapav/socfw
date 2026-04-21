Super — ideme teda na **A: minimalistický bus**. To je podľa mňa správne rozhodnutie.

Týmto spravíme prvý reálny `soc/simple-bus-core` tak, aby bol:

* malý,
* implementovateľný,
* dobre testovateľný,
* a neskôr rozšíriteľný na AXI-lite/Wishbone bez rozbitia jadra.

---

# 1. Bus kontrakt

Najprv si zafixujme úplne jednoduchý protokol:

## `simple_bus`

Master → Slave:

* `addr[31:0]`
* `wdata[31:0]`
* `be[3:0]`
* `we`
* `valid`

Slave → Master:

* `rdata[31:0]`
* `ready`

To presne stačí na:

* RAM,
* register block periférie,
* jednoduchý CPU master.

Je to aj veľmi blízko tomu, čo už starý framework implicitne očakáva v jednoduchých periférnych prístupoch, len to nebolo explicitne oddelené ako planner-visible kontrakt.

---

# 2. Čo spravíme v tomto kroku

Tento branch by som rozdelil na tieto bloky:

### 1. YAML rozšírenie

* `buses:`
* `cpu:`
* `ram:`
* `modules[].bus`

### 2. modely

* `BusFabricRequest`
* `BusAttach`
* `CpuModel`
* `RamModel`
* `PeripheralAddressBlock`

### 3. planner

* fabric plan
* address map plan
* overlap detection

### 4. RTL

* `bus_if`
* `simple_bus_fabric`
* CPU master attach
* RAM slave attach
* peripheral slave attach

### 5. SW/docs

* `soc_map.h`
* `sections.lds`
* `soc_map.md`

### 6. fixture

* prvý SoC:

  * dummy CPU
  * RAM
  * gpio/led peripheral

---

# 3. YAML v2 rozšírenie

Tu je odporúčaný minimálny project YAML pre SoC:

```yaml
version: 2
kind: project

project:
  name: soc_led_test
  mode: soc
  board: qmtech_ep4ce55
  board_file: tests/golden/fixtures/soc_led_test/board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - tests/golden/fixtures/soc_led_test/ip

features:
  use:
    - board:onboard.leds

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

cpu:
  type: dummy_cpu
  module: dummy_cpu
  clock_port: SYS_CLK
  reset_port: RESET_N
  bus_master_port: bus
  bus_protocol: simple_bus
  params: {}

ram:
  module: soc_ram
  base: 0x00000000
  size: 65536
  latency: registered
  init_file: ""
  image_format: hex

boot:
  reset_vector: 0x00000000
  stack_percent: 25

buses:
  - name: main
    protocol: simple_bus
    addr_width: 32
    data_width: 32

modules:
  - instance: gpio0
    type: gpio
    bus:
      fabric: main
      base: 0x40000000
      size: 0x1000
    clocks:
      SYS_CLK: sys_clk
    bind:
      ports:
        gpio_o:
          target: board:onboard.leds

artifacts:
  emit: [rtl, timing, board, software, docs]
```

Toto je zámerne malé, ale už pokrýva celý SoC flow.

---

# 4. Project schema doplnenie

## `socfw/config/project_schema.py`

Pridaj:

```python
class CpuSchema(BaseModel):
    type: str
    module: str
    params: dict[str, Any] = Field(default_factory=dict)
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master_port: str
    bus_protocol: str = "simple_bus"
    addr_width: int = 32
    data_width: int = 32


class RamSchema(BaseModel):
    module: str = "soc_ram"
    base: int
    size: int
    data_width: int = 32
    addr_width: int = 32
    latency: Literal["combinational", "registered"] = "registered"
    init_file: str | None = None
    image_format: Literal["hex", "mif", "bin"] = "hex"


class BootSchema(BaseModel):
    reset_vector: int = 0
    stack_percent: int = 25


class BusAttachSchema(BaseModel):
    fabric: str
    base: int
    size: int


class BusFabricSchema(BaseModel):
    name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


class ModuleSchema(BaseModel):
    instance: str
    type: str
    params: dict[str, Any] = Field(default_factory=dict)
    clocks: dict[str, str | ModuleClockPortSchema] = Field(default_factory=dict)
    bind: ModuleBindSchema = Field(default_factory=ModuleBindSchema)
    bus: BusAttachSchema | None = None
```

A do root:

```python
class ProjectConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["project"]
    project: ProjectMetaSchema
    registries: RegistriesSchema = Field(default_factory=RegistriesSchema)
    features: FeaturesSchema = Field(default_factory=FeaturesSchema)
    clocks: ClocksSchema
    cpu: CpuSchema | None = None
    ram: RamSchema | None = None
    boot: BootSchema = Field(default_factory=BootSchema)
    buses: list[BusFabricSchema] = Field(default_factory=list)
    modules: list[ModuleSchema] = Field(default_factory=list)
    timing: TimingRefSchema | None = None
    artifacts: ArtifactsSchema = Field(default_factory=ArtifactsSchema)
```

---

# 5. Modely

## `socfw/model/cpu.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class CpuBusMaster:
    port_name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


@dataclass
class CpuModel:
    cpu_type: str
    module: str
    params: dict[str, Any] = field(default_factory=dict)
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master: CpuBusMaster | None = None
```

## `socfw/model/memory.py`

```python
from __future__ import annotations
from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True)
class RamModel:
    module: str
    base: int
    size: int
    data_width: int = 32
    addr_width: int = 32
    latency: Literal["combinational", "registered"] = "registered"
    init_file: str | None = None
    image_format: Literal["hex", "mif", "bin"] = "hex"
```

## update `socfw/model/project.py`

Pridaj:

```python
@dataclass(frozen=True)
class BusAttach:
    fabric: str
    base: int
    size: int


@dataclass(frozen=True)
class BusFabricRequest:
    name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32
```

A do `ModuleInstance`:

```python
    bus: BusAttach | None = None
```

A do `ProjectModel`:

```python
    bus_fabrics: list[BusFabricRequest] = field(default_factory=list)

    def fabric_by_name(self, name: str) -> BusFabricRequest | None:
        for f in self.bus_fabrics:
            if f.name == name:
                return f
        return None
```

## update `socfw/model/system.py`

```python
from dataclasses import dataclass, field

from .board import BoardModel
from .cpu import CpuModel
from .ip import IpDescriptor
from .memory import RamModel
from .project import ProjectModel
from .timing import TimingModel
from .addressing import PeripheralAddressBlock


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None
    ip_catalog: dict[str, IpDescriptor]
    cpu: CpuModel | None = None
    ram: RamModel | None = None
    reset_vector: int = 0
    stack_percent: int = 25
    peripheral_blocks: list[PeripheralAddressBlock] = field(default_factory=list)
```

## nový `socfw/model/addressing.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class AddressRegion:
    base: int
    size: int

    @property
    def end(self) -> int:
        return self.base + self.size - 1


@dataclass(frozen=True)
class RegisterDef:
    name: str
    offset: int
    width: int
    access: str
    reset: int = 0
    desc: str = ""


@dataclass(frozen=True)
class IrqDef:
    name: str
    irq_id: int


@dataclass
class PeripheralAddressBlock:
    instance: str
    module: str
    region: AddressRegion
    registers: list[RegisterDef] = field(default_factory=list)
    irqs: list[IrqDef] = field(default_factory=list)

    @property
    def base(self) -> int:
        return self.region.base

    @property
    def end(self) -> int:
        return self.region.end

    @property
    def size(self) -> int:
        return self.region.size
```

---

# 6. Loader update

## `socfw/config/project_loader.py`

Rozšír o CPU/RAM/buses:

```python
from socfw.model.cpu import CpuBusMaster, CpuModel
from socfw.model.memory import RamModel
from socfw.model.project import (
    BusAttach,
    BusFabricRequest,
    ClockBinding,
    GeneratedClockRequest,
    ModuleInstance,
    PortBinding,
    ProjectModel,
)
```

A v `load()`:

```python
        cpu = None
        if doc.cpu is not None:
            cpu = CpuModel(
                cpu_type=doc.cpu.type,
                module=doc.cpu.module,
                params=doc.cpu.params,
                clock_port=doc.cpu.clock_port,
                reset_port=doc.cpu.reset_port,
                irq_port=doc.cpu.irq_port,
                bus_master=CpuBusMaster(
                    port_name=doc.cpu.bus_master_port,
                    protocol=doc.cpu.bus_protocol,
                    addr_width=doc.cpu.addr_width,
                    data_width=doc.cpu.data_width,
                ),
            )

        ram = None
        if doc.ram is not None:
            ram = RamModel(
                module=doc.ram.module,
                base=doc.ram.base,
                size=doc.ram.size,
                data_width=doc.ram.data_width,
                addr_width=doc.ram.addr_width,
                latency=doc.ram.latency,
                init_file=doc.ram.init_file,
                image_format=doc.ram.image_format,
            )
```

Pri skladaní `modules`:

```python
            modules.append(ModuleInstance(
                instance=m.instance,
                type_name=m.type,
                params=m.params,
                clocks=clocks,
                port_bindings=port_bindings,
                bus=(
                    BusAttach(
                        fabric=m.bus.fabric,
                        base=m.bus.base,
                        size=m.bus.size,
                    ) if m.bus else None
                ),
            ))
```

Pri `ProjectModel`:

```python
        model = ProjectModel(
            name=doc.project.name,
            mode=doc.project.mode,
            board_ref=doc.project.board,
            board_file=doc.project.board_file,
            registries_ip=doc.registries.ip,
            feature_refs=doc.features.use,
            modules=modules,
            primary_clock_domain=doc.clocks.primary.domain,
            generated_clocks=gen_clocks,
            timing_file=(doc.timing.file if doc.timing else None),
            debug=doc.project.debug,
            bus_fabrics=[
                BusFabricRequest(
                    name=b.name,
                    protocol=b.protocol,
                    addr_width=b.addr_width,
                    data_width=b.data_width,
                )
                for b in doc.buses
            ],
        )
```

A return z loadera zmeň na bundle:

```python
        return Result(value={
            "project": model,
            "cpu": cpu,
            "ram": ram,
            "reset_vector": doc.boot.reset_vector,
            "stack_percent": doc.boot.stack_percent,
        })
```

## `socfw/config/system_loader.py`

Prispôsob:

```python
        prj_bundle = prj_res.value
        project = prj_bundle["project"]
        cpu = prj_bundle["cpu"]
        ram = prj_bundle["ram"]
        reset_vector = prj_bundle["reset_vector"]
        stack_percent = prj_bundle["stack_percent"]
```

A pri `SystemModel(...)`:

```python
        system = SystemModel(
            board=board_res.value,
            project=project,
            timing=timing,
            ip_catalog=catalog_res.value,
            cpu=cpu,
            ram=ram,
            reset_vector=reset_vector,
            stack_percent=stack_percent,
        )
```

---

# 7. Bus plan

## nový `socfw/elaborate/bus_plan.py`

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


@dataclass
class InterconnectPlan:
    fabrics: dict[str, list[ResolvedBusEndpoint]] = field(default_factory=dict)
```

## nový `socfw/plugins/simple_bus/planner.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan, ResolvedBusEndpoint


class SimpleBusPlanner:
    protocol = "simple_bus"

    def plan(self, system) -> InterconnectPlan:
        plan = InterconnectPlan()

        for fabric in system.project.bus_fabrics:
            if fabric.protocol != "simple_bus":
                continue

            endpoints: list[ResolvedBusEndpoint] = []

            if system.cpu is not None and system.cpu.bus_master is not None:
                endpoints.append(
                    ResolvedBusEndpoint(
                        instance="cpu",
                        module_type=system.cpu.cpu_type,
                        fabric=fabric.name,
                        protocol=system.cpu.bus_master.protocol,
                        role="master",
                        port_name=system.cpu.bus_master.port_name,
                        addr_width=system.cpu.bus_master.addr_width,
                        data_width=system.cpu.bus_master.data_width,
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

                endpoints.append(
                    ResolvedBusEndpoint(
                        instance=mod.instance,
                        module_type=mod.type_name,
                        fabric=fabric.name,
                        protocol="simple_bus",
                        role="slave",
                        port_name="bus",
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

# 8. Address map builder

## nový `socfw/builders/address_map_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan
from socfw.model.addressing import AddressRegion, PeripheralAddressBlock


class AddressMapBuilder:
    def build(self, system, plan: InterconnectPlan) -> list[PeripheralAddressBlock]:
        blocks: list[PeripheralAddressBlock] = []

        for endpoints in plan.fabrics.values():
            for ep in endpoints:
                if ep.role != "slave":
                    continue
                if ep.instance == "ram":
                    continue
                if ep.base is None or ep.size is None:
                    continue

                blocks.append(
                    PeripheralAddressBlock(
                        instance=ep.instance,
                        module=ep.module_type,
                        region=AddressRegion(base=ep.base, size=ep.size),
                    )
                )

        return blocks
```

---

# 9. Elaborator update

## `socfw/elaborate/design.py`

Pridaj:

```python
from .bus_plan import InterconnectPlan

@dataclass
class ElaboratedDesign:
    system: object
    port_bindings: list[ResolvedPortBinding] = field(default_factory=list)
    clock_domains: list[ResolvedClockDomain] = field(default_factory=list)
    dependency_assets: list[str] = field(default_factory=list)
    interconnect: InterconnectPlan | None = None
```

## `socfw/elaborate/planner.py`

```python
from socfw.builders.address_map_builder import AddressMapBuilder
from socfw.plugins.simple_bus.planner import SimpleBusPlanner
```

V `__init__`:

```python
        self.simple_bus = SimpleBusPlanner()
        self.addr_builder = AddressMapBuilder()
```

V `elaborate()`:

```python
        design.interconnect = self.simple_bus.plan(system)
        system.peripheral_blocks = self.addr_builder.build(system, design.interconnect)
```

---

# 10. Bus RTL IR

## update `socfw/ir/rtl.py`

Pridaj:

```python
@dataclass(frozen=True)
class RtlBusConn:
    port: str
    interface_name: str
    modport: str


@dataclass(frozen=True)
class RtlInterfaceInstance:
    if_type: str
    name: str
    params: dict[str, object] = field(default_factory=dict)
    comment: str = ""


@dataclass(frozen=True)
class RtlFabricPort:
    port_name: str
    interface_name: str
    modport: str
    index: int | None = None


@dataclass
class RtlFabricInstance:
    module: str
    name: str
    params: dict[str, object] = field(default_factory=dict)
    clock_signal: str = BOARD_CLOCK
    reset_signal: str = BOARD_RESET
    ports: list[RtlFabricPort] = field(default_factory=list)
    comment: str = ""
```

Do `RtlInstance` pridaj:

```python
    bus_conns: list[RtlBusConn] = field(default_factory=list)
```

Do `RtlModuleIR` pridaj:

```python
    interfaces: list[RtlInterfaceInstance] = field(default_factory=list)
    fabrics: list[RtlFabricInstance] = field(default_factory=list)

    def add_interface_once(self, iface: RtlInterfaceInstance) -> None:
        if all(i.name != iface.name for i in self.interfaces):
            self.interfaces.append(iface)
```

---

# 11. RTL bus builder

## nový `socfw/builders/rtl_bus_builder.py`

```python
from __future__ import annotations

from socfw.ir.rtl import (
    RtlFabricInstance,
    RtlFabricPort,
    RtlInterfaceInstance,
)


class RtlBusBuilder:
    def build_interfaces(self, plan) -> list[RtlInterfaceInstance]:
        result: list[RtlInterfaceInstance] = []

        for fabric_name, endpoints in plan.fabrics.items():
            for ep in endpoints:
                if ep.protocol == "simple_bus":
                    result.append(
                        RtlInterfaceInstance(
                            if_type="bus_if",
                            name=f"if_{ep.instance}_{fabric_name}",
                            comment=f"{ep.role} endpoint on {fabric_name}",
                        )
                    )
        return result

    def build_fabrics(self, plan) -> list[RtlFabricInstance]:
        fabrics: list[RtlFabricInstance] = []

        for fabric_name, endpoints in plan.fabrics.items():
            if not endpoints:
                continue

            masters = [ep for ep in endpoints if ep.role == "master"]
            slaves = [ep for ep in endpoints if ep.role == "slave"]

            fabric = RtlFabricInstance(
                module="simple_bus_fabric",
                name=f"u_fabric_{fabric_name}",
                params={"NSLAVES": len(slaves)},
                comment=f"simple_bus fabric '{fabric_name}'",
            )

            for idx, ep in enumerate(masters):
                fabric.ports.append(RtlFabricPort(
                    port_name="m_bus",
                    interface_name=f"if_{ep.instance}_{fabric_name}",
                    modport="slave",
                    index=None if len(masters) == 1 else idx,
                ))

            for idx, ep in enumerate(slaves):
                fabric.ports.append(RtlFabricPort(
                    port_name="s_bus",
                    interface_name=f"if_{ep.instance}_{fabric_name}",
                    modport="master",
                    index=idx,
                ))

            fabrics.append(fabric)

        return fabrics
```

---

# 12. RTL builder update

## `socfw/builders/rtl_ir_builder.py`

Doplň imports:

```python
from socfw.builders.rtl_bus_builder import RtlBusBuilder
from socfw.ir.rtl import (
    BOARD_CLOCK,
    BOARD_RESET,
    RtlAssign,
    RtlBusConn,
    RtlConn,
    RtlInstance,
    RtlModuleIR,
    RtlPort,
    RtlResetSync,
    RtlWire,
)
```

V `__init__`:

```python
    def __init__(self) -> None:
        self.bus_builder = RtlBusBuilder()
```

V `build()` po clock/reset časti:

```python
        if design.interconnect is not None:
            for iface in self.bus_builder.build_interfaces(design.interconnect):
                rtl.add_interface_once(iface)
            rtl.fabrics.extend(self.bus_builder.build_fabrics(design.interconnect))
```

Pred loop cez `project.modules` pridaj CPU a RAM:

```python
        if system.cpu is not None:
            cpu_conns = [
                RtlConn(port=system.cpu.clock_port, signal=BOARD_CLOCK),
                RtlConn(port=system.cpu.reset_port, signal=BOARD_RESET),
            ]
            cpu_bus_conns = []
            if system.cpu.bus_master is not None and design.interconnect is not None:
                for fabric_name, endpoints in design.interconnect.fabrics.items():
                    for ep in endpoints:
                        if ep.instance == "cpu":
                            cpu_bus_conns.append(RtlBusConn(
                                port=system.cpu.bus_master.port_name,
                                interface_name=f"if_cpu_{fabric_name}",
                                modport="master",
                            ))
            rtl.instances.append(RtlInstance(
                module=system.cpu.module,
                name="cpu",
                params=system.cpu.params,
                conns=cpu_conns,
                bus_conns=cpu_bus_conns,
                comment=system.cpu.cpu_type,
            ))

        if system.ram is not None:
            ram_conns = [
                RtlConn(port="SYS_CLK", signal=BOARD_CLOCK),
                RtlConn(port="RESET_N", signal=BOARD_RESET),
            ]
            ram_bus_conns = []
            if design.interconnect is not None:
                for fabric_name, endpoints in design.interconnect.fabrics.items():
                    for ep in endpoints:
                        if ep.instance == "ram":
                            ram_bus_conns.append(RtlBusConn(
                                port="bus",
                                interface_name=f"if_ram_{fabric_name}",
                                modport="slave",
                            ))
            rtl.instances.append(RtlInstance(
                module=system.ram.module,
                name="ram",
                params={
                    "RAM_BYTES": system.ram.size,
                    "INIT_FILE": system.ram.init_file or "",
                },
                conns=ram_conns,
                bus_conns=ram_bus_conns,
                comment=f"RAM @ 0x{system.ram.base:08X}",
            ))
```

A pri `rtl.instances.append(...)` pre bežné moduly pridaj bus_conns:

```python
            bus_conns = []
            if mod.bus is not None and design.interconnect is not None:
                for fabric_name, endpoints in design.interconnect.fabrics.items():
                    for ep in endpoints:
                        if ep.instance == mod.instance:
                            bus_conns.append(RtlBusConn(
                                port="bus",
                                interface_name=f"if_{ep.instance}_{fabric_name}",
                                modport="slave",
                            ))
```

A potom:

```python
            rtl.instances.append(RtlInstance(
                module=ip.module,
                name=mod.instance,
                params=mod.params,
                conns=conns,
                bus_conns=bus_conns,
            ))
```

Na konci:

```python
        if rtl.fabrics and "src/ip/bus/simple_bus_fabric.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/bus/simple_bus_fabric.sv")
        if rtl.fabrics and "src/ip/bus/bus_if.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/bus/bus_if.sv")
```

---

# 13. RTL template update

## `socfw/templates/soc_top.sv.j2`

Pridaj interfaces:

```jinja2
{% if module.interfaces %}
  // Interface instances
{% for iface in module.interfaces %}
  {{ iface.if_type }} {{ iface.name }} ();{% if iface.comment %} // {{ iface.comment }}{% endif %}
{% endfor %}

{% endif %}
```

Pridaj fabrics:

```jinja2
{% if module.fabrics %}
  // Bus fabrics
{% for fab in module.fabrics %}
  {{ fab.module }}
  {%- if fab.params %}
  #(
{%- for k, v in fab.params.items() %}
    .{{ k }}({{ v | sv_param }}){{ "," if not loop.last else "" }}
{%- endfor %}
  )
  {%- endif %}
  {{ fab.name }} (
    .SYS_CLK({{ fab.clock_signal }}),
    .RESET_N({{ fab.reset_signal }})
{%- for p in fab.ports %}
    ,
    .{{ p.port_name }}{% if p.index is not none %}[{{ p.index }}]{% endif %}({{ p.interface_name }}.{{ p.modport }})
{%- endfor %}
  );{% if fab.comment %} // {{ fab.comment }}{% endif %}

{% endfor %}
{% endif %}
```

A zmeň instantiation loop:

```jinja2
{% if module.instances %}
  // Module instances
{% for inst in module.instances %}
  {{ inst.module }}
  {%- if inst.params %}
  #(
{%- for k, v in inst.params.items() %}
    .{{ k }}({{ v | sv_param }}){{ "," if not loop.last else "" }}
{%- endfor %}
  )
  {%- endif %}
  u_{{ inst.name }} (
{%- set ns = namespace(first=true) %}
{%- for c in inst.conns %}
{%- if not ns.first %},{% endif %}
    .{{ c.port }}({{ c.signal }})
{%- set ns.first = false %}
{%- endfor %}
{%- for bc in inst.bus_conns %}
{%- if not ns.first %},{% endif %}
    .{{ bc.port }}({{ bc.interface_name }}.{{ bc.modport }})
{%- set ns.first = false %}
{%- endfor %}
  );{% if inst.comment %} // {{ inst.comment }}{% endif %}

{% endfor %}
{% endif %}
```

---

# 14. Potrebné RTL IP

## `src/ip/bus/bus_if.sv`

```systemverilog
interface bus_if;
  logic [31:0] addr;
  logic [31:0] wdata;
  logic [31:0] rdata;
  logic [3:0]  be;
  logic        we;
  logic        valid;
  logic        ready;

  modport master (
    output addr, output wdata, output be, output we, output valid,
    input  rdata, input ready
  );

  modport slave (
    input  addr, input wdata, input be, input we, input valid,
    output rdata, output ready
  );
endinterface
```

## `src/ip/bus/simple_bus_fabric.sv`

```systemverilog
`default_nettype none

module simple_bus_fabric #(
  parameter int NSLAVES = 1
)(
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave  m_bus,
  bus_if.master s_bus [NSLAVES]
);

  always_comb begin
    m_bus.ready = 1'b0;
    m_bus.rdata = 32'h0;

    for (int j = 0; j < NSLAVES; j++) begin
      s_bus[j].addr  = m_bus.addr;
      s_bus[j].wdata = m_bus.wdata;
      s_bus[j].be    = m_bus.be;
      s_bus[j].we    = m_bus.we;
      s_bus[j].valid = m_bus.valid;

      if (s_bus[j].ready) begin
        m_bus.ready = s_bus[j].ready;
        m_bus.rdata = s_bus[j].rdata;
      end
    end
  end

endmodule : simple_bus_fabric
`default_nettype wire
```

Toto je zatiaľ primitívne decode-less, len na prvý bring-up. Hneď ďalší krok bude address decode.

---

# 15. Prvý SoC fixture

Ak chceš, hneď po tomto by ďalší krok mal byť fixture:

* `dummy_cpu.ip.yaml`
* `gpio.ip.yaml`
* `soc_ram.sv`
* `dummy_cpu.sv`
* `gpio.sv`
* `soc_led_test/project.yaml`

A na tom overiť:

* `cpu -> fabric -> ram/gpio`
* `soc_map.h`
* `soc_graph.dot`

---

# 16. Čo by som spravil hneď potom

Nasledujúci malý krok po tomto minimalistickom `simple_bus-core` je:

1. **address decode vo fabric**
2. **register metadata v IP descriptoroch**
3. **software/docs IR**
4. **golden SoC fixture**

To je podľa mňa najlepší bod, kde to celé začne byť naozaj použiteľné.

Ak chceš, v ďalšej správe ti dám presne tento ďalší krok:
**SoC fixture + dummy_cpu/gpio/soc_ram + address decode + software/docs napojenie**.
