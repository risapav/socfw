Super. Týmto krokom sa uzavrie prvý **plný SoC datapath**:

* CPU ako master,
* RAM ako slave,
* periférie ako slave,
* IRQ zber do CPU,
* všetko cez planner a IR, nie cez legacy context.

To je presne to, čo v starom frameworku ešte nie je systematicky vyjadrené: CPU, RAM, periférie, IRQ a fabric síce existujú, ale sú rozliate medzi generátormi a legacy SoC kontextom.   

Nižšie dávam **kompletný refaktorovaný IRQ + RAM slave layer**.

---

# 1. RAM ako plnohodnotný slave endpoint

Doteraz bola RAM len systémový región. Teraz ju planner zaradí aj do fabric.

## `socfw/plugins/simple_bus/ram_endpoint.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import ResolvedBusEndpoint
from socfw.model.system import SystemModel


class RamSlaveEndpointBuilder:
    def build(self, system: SystemModel, fabric_name: str) -> ResolvedBusEndpoint | None:
        if system.ram is None:
            return None

        return ResolvedBusEndpoint(
            instance="ram",
            module_type=system.ram.module,
            fabric=fabric_name,
            protocol="simple_bus",
            role="slave",
            port_name="bus",
            addr_width=system.ram.addr_width,
            data_width=system.ram.data_width,
            base=system.ram.base,
            size=system.ram.size,
            end=system.ram.base + system.ram.size - 1,
        )
```

---

## `socfw/plugins/simple_bus/planner.py`

Update planneru o RAM slave:

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan, ResolvedBusEndpoint
from socfw.model.system import SystemModel
from socfw.plugins.bus_api import BusPlanner
from socfw.plugins.simple_bus.cpu_endpoint import CpuMasterEndpointBuilder
from socfw.plugins.simple_bus.ram_endpoint import RamSlaveEndpointBuilder


class SimpleBusPlanner(BusPlanner):
    protocol = "simple_bus"

    def __init__(self) -> None:
        self.cpu_builder = CpuMasterEndpointBuilder()
        self.ram_builder = RamSlaveEndpointBuilder()

    def plan(self, system: SystemModel) -> InterconnectPlan:
        plan = InterconnectPlan()

        for fabric in system.project.bus_fabrics:
            if fabric.protocol != self.protocol:
                continue

            endpoints: list[ResolvedBusEndpoint] = []

            cpu_ep = self.cpu_builder.build(system, fabric.name)
            if cpu_ep is not None:
                endpoints.append(cpu_ep)

            ram_ep = self.ram_builder.build(system, fabric.name)
            if ram_ep is not None:
                endpoints.append(ram_ep)

            for mod in system.project.modules:
                if mod.bus is None or mod.bus.fabric != fabric.name:
                    continue

                ip = system.ip_catalog.get(mod.type_name)
                if ip is None:
                    continue

                iface = ip.bus_interface(role="slave") or ip.bus_interface()
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

Týmto už fabric planner vracia kompletný master/slave obraz pre prvý SoC flow.

---

# 2. IRQ model

IRQ nesmie zostať len ako vedľajšia poznámka v SW mapách. Potrebuje planner a RTL IR.

## `socfw/model/irq.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class IrqSource:
    instance: str
    signal_name: str
    irq_id: int


@dataclass
class IrqPlan:
    width: int
    sources: list[IrqSource] = field(default_factory=list)

    def max_irq_id(self) -> int:
        if not self.sources:
            return -1
        return max(s.irq_id for s in self.sources)
```

---

# 3. IRQ planner

## `socfw/builders/irq_plan_builder.py`

```python
from __future__ import annotations

from socfw.model.irq import IrqPlan, IrqSource
from socfw.model.system import SystemModel


class IrqPlanBuilder:
    def build(self, system: SystemModel) -> IrqPlan | None:
        if system.cpu is None or system.cpu.irq_port is None:
            return None

        sources: list[IrqSource] = []

        for p in system.peripheral_blocks:
            for irq in p.irqs:
                sources.append(
                    IrqSource(
                        instance=p.instance,
                        signal_name=f"irq_{p.instance}_{irq.name}",
                        irq_id=irq.irq_id,
                    )
                )

        if not sources:
            return IrqPlan(width=0, sources=[])

        width = max(s.irq_id for s in sources) + 1
        return IrqPlan(width=width, sources=sorted(sources, key=lambda s: s.irq_id))
```

To je prirodzené pokračovanie starého SW/graph modelu, kde už IRQ existujú ako pomenované entity s ID.  

---

# 4. Rozšírenie elaborated design

## `socfw/elaborate/design.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from socfw.model.irq import IrqPlan

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
    irq_plan: IrqPlan | None = None
```

---

## `socfw/elaborate/planner.py`

```python
from __future__ import annotations

from socfw.builders.address_map_builder import AddressMapBuilder
from socfw.builders.irq_plan_builder import IrqPlanBuilder
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
        self.irq_builder = IrqPlanBuilder()

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

        system.peripheral_blocks = self.addr_builder.build(system, interconnect)
        design.irq_plan = self.irq_builder.build(system)

        return design
```

---

# 5. RTL IR rozšírenie pre IRQ combiner

## `socfw/ir/rtl.py`

Doplnenie:

```python
@dataclass(frozen=True)
class RtlIrqSource:
    irq_id: int
    signal: str
    instance: str


@dataclass
class RtlIrqCombiner:
    name: str
    width: int
    cpu_irq_port: str
    cpu_irq_signal: str
    sources: list[RtlIrqSource] = field(default_factory=list)
```

A do `RtlModuleIR`:

```python
    irq_combiner: RtlIrqCombiner | None = None
```

---

# 6. IRQ builder do RTL

## `socfw/builders/rtl_irq_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.rtl import RtlIrqCombiner, RtlIrqSource, RtlWire


class RtlIrqBuilder:
    def build(self, design: ElaboratedDesign, rtl) -> None:
        system = design.system
        irq_plan = design.irq_plan

        if system.cpu is None or system.cpu.irq_port is None:
            return
        if irq_plan is None:
            return
        if irq_plan.width <= 0:
            return

        irq_bus_name = "cpu_irq"

        rtl.add_wire_once(RtlWire(name=irq_bus_name, width=irq_plan.width, comment="CPU IRQ bus"))

        for src in irq_plan.sources:
            rtl.add_wire_once(RtlWire(name=src.signal_name, width=1, comment=f"IRQ source {src.instance}"))

        rtl.irq_combiner = RtlIrqCombiner(
            name="u_irq_combiner",
            width=irq_plan.width,
            cpu_irq_port=system.cpu.irq_port,
            cpu_irq_signal=irq_bus_name,
            sources=[
                RtlIrqSource(
                    irq_id=src.irq_id,
                    signal=src.signal_name,
                    instance=src.instance,
                )
                for src in irq_plan.sources
            ],
        )
```

---

# 7. Refaktorovaný `RtlIRBuilder` s CPU, RAM a IRQ

## `socfw/builders/rtl_ir_builder.py`

Toto je konsolidovaná verzia s:

* CPU instance,
* RAM slave,
* bus interfaces/fabric,
* IRQ combiner.

```python
from __future__ import annotations

from socfw.builders.rtl_bus_builder import RtlBusBuilder
from socfw.builders.rtl_bus_connections import RtlBusConnectionResolver
from socfw.builders.rtl_irq_builder import RtlIrqBuilder
from socfw.elaborate.design import ElaboratedDesign
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


class RtlIRBuilder:
    def __init__(self) -> None:
        self.bus_builder = RtlBusBuilder()
        self.bus_conns = RtlBusConnectionResolver()
        self.irq_builder = RtlIrqBuilder()

    def build(self, design: ElaboratedDesign) -> RtlModuleIR:
        system = design.system
        rtl = RtlModuleIR(name="soc_top")

        rtl.add_port_once(RtlPort(name=BOARD_CLOCK, direction="input", width=1))
        rtl.add_port_once(RtlPort(name=BOARD_RESET, direction="input", width=1))

        for binding in design.port_bindings:
            for ext in binding.resolved:
                rtl.add_port_once(
                    RtlPort(
                        name=ext.top_name,
                        direction=ext.direction,
                        width=ext.width,
                    )
                )

        for dom in design.clock_domains:
            if dom.reset_policy == "synced" and dom.name != system.project.primary_clock_domain:
                rst_out = f"rst_n_{dom.name}"
                rtl.add_wire_once(RtlWire(name=dom.name, width=1, comment="clock domain"))
                rtl.add_wire_once(RtlWire(name=rst_out, width=1, comment="reset sync output"))
                rtl.reset_syncs.append(
                    RtlResetSync(
                        name=f"u_rst_sync_{dom.name}",
                        stages=dom.sync_stages or 2,
                        clk_signal=dom.name,
                        rst_out=rst_out,
                    )
                )
            elif dom.source_kind == "generated":
                rtl.add_wire_once(RtlWire(name=dom.name, width=1, comment="generated clock"))

        if design.interconnect is not None:
            for iface in self.bus_builder.build_interfaces(design.interconnect):
                rtl.add_interface_once(iface)

            rtl.fabrics.extend(self.bus_builder.build_fabrics(design.interconnect))

        # CPU
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
                            cpu_bus_conns.append(
                                RtlBusConn(
                                    port=system.cpu.bus_master.port_name,
                                    interface_name=f"if_cpu_{fabric_name}",
                                    modport="master",
                                )
                            )

            rtl.instances.append(
                RtlInstance(
                    module=system.cpu.module,
                    name="cpu",
                    params=system.cpu.params,
                    conns=cpu_conns,
                    bus_conns=cpu_bus_conns,
                    comment=system.cpu.cpu_type,
                )
            )

        # RAM
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
                            ram_bus_conns.append(
                                RtlBusConn(
                                    port="bus",
                                    interface_name=f"if_ram_{fabric_name}",
                                    modport="slave",
                                )
                            )

            rtl.instances.append(
                RtlInstance(
                    module=system.ram.module,
                    name="ram",
                    params={
                        "RAM_BYTES": system.ram.size,
                        "INIT_FILE": system.ram.init_file or "",
                    },
                    conns=ram_conns,
                    bus_conns=ram_bus_conns,
                    comment=f"RAM @ 0x{system.ram.base:08X}",
                )
            )

        # Project modules
        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            conns: list[RtlConn] = []
            bus_conns = self.bus_conns.resolve_for_instance(
                mod=mod,
                ip=ip,
                plan=design.interconnect,
            )

            for cb in mod.clocks:
                signal = cb.domain
                if cb.domain == system.project.primary_clock_domain:
                    signal = BOARD_CLOCK
                conns.append(RtlConn(port=cb.port_name, signal=signal))

                if not cb.no_reset and ip.reset.port:
                    if cb.domain == system.project.primary_clock_domain:
                        rst_sig = BOARD_RESET
                    else:
                        rst_sig = f"rst_n_{cb.domain}"

                    if ip.reset.active_high:
                        rst_sig = f"~{rst_sig}"
                    conns.append(RtlConn(port=ip.reset.port, signal=rst_sig))

            for binding in mod.port_bindings:
                resolved = next(
                    (
                        b for b in design.port_bindings
                        if b.instance == mod.instance and b.port_name == binding.port_name
                    ),
                    None,
                )
                if resolved is None:
                    continue

                if len(resolved.resolved) == 1:
                    ext = resolved.resolved[0]
                    needs_adapter = binding.width is not None and binding.width != ext.width

                    if not needs_adapter:
                        conns.append(RtlConn(port=binding.port_name, signal=ext.top_name))
                    else:
                        wire_name = f"w_{mod.instance}_{binding.port_name}"
                        src_w = ext.width
                        dst_w = binding.width

                        rtl.add_wire_once(
                            RtlWire(
                                name=wire_name,
                                width=src_w,
                                comment=(
                                    f"adapter: {binding.port_name} "
                                    f"{src_w}b->{dst_w}b ({binding.adapt or 'zero'})"
                                ),
                            )
                        )
                        conns.append(RtlConn(port=binding.port_name, signal=wire_name))

                        if ext.direction == "input":
                            rhs = f"{ext.top_name}[{min(src_w, dst_w) - 1}:0]"
                            rtl.assigns.append(
                                RtlAssign(
                                    lhs=wire_name,
                                    rhs=rhs,
                                    direction="input",
                                    comment="input truncate",
                                )
                            )
                        else:
                            rtl.assigns.append(
                                RtlAssign(
                                    lhs=ext.top_name,
                                    rhs=self._pad_rhs(
                                        wire=wire_name,
                                        src_w=src_w,
                                        dst_w=dst_w,
                                        pad_mode=binding.adapt or "zero",
                                    ),
                                    direction="output",
                                    comment=f"{binding.adapt or 'zero'} pad",
                                )
                            )
                else:
                    for ext in resolved.resolved:
                        conns.append(RtlConn(port=ext.top_name, signal=ext.top_name))

            rtl.instances.append(
                RtlInstance(
                    module=ip.module,
                    name=mod.instance,
                    params=mod.params,
                    conns=conns,
                    bus_conns=bus_conns,
                )
            )

            for path in ip.artifacts.synthesis:
                if path not in rtl.extra_sources:
                    rtl.extra_sources.append(path)

        self.irq_builder.build(design, rtl)

        if rtl.fabrics and "src/ip/bus/simple_bus_fabric.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/bus/simple_bus_fabric.sv")

        if rtl.irq_combiner is not None and "src/ip/irq/irq_combiner.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/irq/irq_combiner.sv")

        return rtl

    def _pad_rhs(self, *, wire: str, src_w: int, dst_w: int, pad_mode: str) -> str:
        if dst_w > src_w:
            pad = dst_w - src_w
            if pad_mode == "replicate":
                return f"{{ {{{pad}{{ {wire}[{src_w - 1}] }} }}, {wire} }}"
            if pad_mode == "high_z":
                return f"{{ {pad}'bz, {wire} }}"
            return f"{{ {pad}'b0, {wire} }}"
        return f"{wire}[{dst_w - 1}:0]"
```

---

# 8. RTL template doplnenie o IRQ combiner

## `socfw/templates/soc_top.sv.j2`

Doplniť medzi fabric a module instances:

```jinja2
{% if module.irq_combiner %}
  // IRQ combiner
  irq_combiner #(
    .WIDTH({{ module.irq_combiner.width }})
  ) {{ module.irq_combiner.name }} (
    .irq_o({{ module.irq_combiner.cpu_irq_signal }})
{%- for src in module.irq_combiner.sources %}
    ,
    .irq_i[{{ src.irq_id }}]({{ src.signal }})
{%- endfor %}
  );

{% endif %}
```

A v CPU instancii už `irq_port` pripoj cez bežné `RtlConn` alebo zvlášť.

Lepšie je to spraviť priamo v builderi: ak CPU má `irq_port` a `rtl.irq_combiner` existuje, doplniť CPU conn:

V `RtlIRBuilder`, po `self.irq_builder.build(design, rtl)` ešte uprav CPU instance:

```python
        if rtl.irq_combiner is not None:
            for inst in rtl.instances:
                if inst.name == "cpu" and system.cpu is not None and system.cpu.irq_port:
                    inst.conns.append(
                        RtlConn(
                            port=system.cpu.irq_port,
                            signal=rtl.irq_combiner.cpu_irq_signal,
                        )
                    )
```

Tým pádom template netreba špeciálne meniť na CPU strane.

---

# 9. IRQ combiner IP

## `src/ip/irq/irq_combiner.sv`

```systemverilog
`default_nettype none

module irq_combiner #(
  parameter int WIDTH = 1
)(
  input  wire [WIDTH-1:0] irq_i,
  output wire [WIDTH-1:0] irq_o
);

  assign irq_o = irq_i;

endmodule : irq_combiner
`default_nettype wire
```

Toto je jednoduchý prvý krok. Neskôr môžeš doplniť:

* masking,
* priority encoder,
* edge detect,
* pending/status registers.

---

# 10. SoftwareIRBuilder zostáva správny

Tu sa nič zásadné meniť nemusí, lebo IRQ aj RAM sa už prenášajú cez:

* `system.ram`
* `system.peripheral_blocks`

Takže `soc_irq.h` a `soc_map.md` budú prirodzene odrážať nové planner výsledky. To je presne lepší model než starý priamy prístup k `m.peripherals` a RAM poliam v generátore. 

---

# 11. Image flow pipeline

Teraz má zmysel pripojiť boot image do full pipeline.

## `socfw/build/full_pipeline.py`

Doplnenie:

```python
from socfw.builders.boot_image_builder import BootImageBuilder
from socfw.tools.bin2hex_runner import Bin2HexRunner
```

A v `__init__`:

```python
        self.image_builder = BootImageBuilder()
        self.bin2hex = Bin2HexRunner()
```

A v `run()` po úspešnom build výsledku:

```python
        image = self.image_builder.build(loaded.value, request.out_dir)
        if image is not None and image.input_format == "bin" and image.output_format == "hex":
            conv = self.bin2hex.run(image)
            result.diagnostics.extend(conv.diagnostics)
```

Takto sa starý `bin2hex` konečne dostane do architektúry ako build step, nie len bokom stojaci utility skript. 

---

# 12. Čo týmto už vieš

Po tomto kroku máš prvý **skutočne ucelený SoC skeleton**:

* board resources,
* project/modules,
* vendor/source IP,
* clocks/resets,
* bus fabrics,
* CPU master,
* RAM slave,
* peripheral slaves,
* address map,
* IRQ aggregation,
* software/docs outputs,
* boot image conversion.

To je už výrazne ďalej než starý stav, kde sú tieto veci prítomné, ale ešte rozložené medzi:

* `rtl.py` legacy SoC context, 
* `sw.py` RAM/peripheral outputs, 
* `bin2hex.py` utility flow. 

---

# 13. Čo ešte chýba do prvého „production-like“ jadra

Najväčšie zvyšné medzery sú tieto:

### 1. RAM fabric module contract

Momentálne predpokladáme, že RAM modul má port `bus`. To treba formalizovať v IP alebo memory modeli.

### 2. CPU descriptor registry

Dnes je CPU model priamo v project config. Neskôr bude lepšie mať CPU ako descriptor/plugin podobne ako IP.

### 3. ELF toolchain step

`objcopy` / ELF parsing → BIN → HEX.

### 4. bridge/adapters

`axi_lite`, `wishbone`, width bridges, protocol bridges.

### 5. reporting / graph / explain

Teraz už máš dosť modelu na kvalitný JSON/MD report.

---

# 14. Môj odporúčaný ďalší krok

Teraz by som už nešiel hneď do ďalšej HW funkcionality, ale do **developer experience vrstvy**:

* JSON build report,
* Markdown build report,
* graphviz interconnect graph,
* `explain` outputs pre clock tree / address map / IRQ map.

To je presne to, čo si spomínal na začiatku: detailný reporting, validácia a moderná architektúra. Keď už je jadro pripravené, reporting prinesie obrovskú hodnotu.

V ďalšej správe ti viem pripraviť:
**kompletný refaktorovaný reporting layer**
vrátane:

* `BuildReport` modelov,
* JSON/MD emitterov,
* interconnect/IRQ/address map graph buildera.
