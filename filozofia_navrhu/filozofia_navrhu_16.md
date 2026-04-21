Nižšie je ďalší refaktorovaný slice: **reálny RTL bus layer pre `simple_bus`**.

Cieľ je posunúť sa od dnešného „fabric ako string / legacy context / neskorý template hack“ k tomu, aby bus mal vlastné IR, vlastné interface inštancie a vlastné fabric moduly. To presne nadväzuje na to, čo už dnes v starom kóde existuje len ako základ:

* SystemVerilog `bus_if` a `axi_lite_if` už sú definované ako samostatné interface typy. 
* RTL vetva už má IR vrstvy a builder filozofiu, čo je správny základ pre ďalšie rozšírenie.  
* SoC mode je stále dočasne riešený legacy contextom, takže práve tu je najväčší priestor na architektonické zlepšenie. 

Tento návrh je stále „minimum viable interconnect layer“, ale už má správne hranice.

---

# 1. Nové RTL IR typy pre bus layer

## `socfw/ir/rtl.py`

Toto je update k predchádzajúcemu súboru. Pridávam interface a fabric IR.

```python
from __future__ import annotations
from dataclasses import dataclass, field


BOARD_CLOCK = "SYS_CLK"
BOARD_RESET = "RESET_N"


@dataclass(frozen=True)
class RtlPort:
    name: str
    direction: str
    width: int = 1

    @property
    def width_str(self) -> str:
        return f"[{self.width - 1}:0]" if self.width > 1 else ""


@dataclass(frozen=True)
class RtlWire:
    name: str
    width: int = 1
    comment: str = ""

    @property
    def width_str(self) -> str:
        return f"[{self.width - 1}:0]" if self.width > 1 else ""


@dataclass(frozen=True)
class RtlAssign:
    lhs: str
    rhs: str
    direction: str = "comb"
    comment: str = ""


@dataclass(frozen=True)
class RtlConn:
    port: str
    signal: str


@dataclass(frozen=True)
class RtlBusConn:
    port: str
    interface_name: str
    modport: str


@dataclass
class RtlInstance:
    module: str
    name: str
    params: dict[str, object] = field(default_factory=dict)
    conns: list[RtlConn] = field(default_factory=list)
    bus_conns: list[RtlBusConn] = field(default_factory=list)
    comment: str = ""


@dataclass(frozen=True)
class RtlResetSync:
    name: str
    stages: int
    clk_signal: str
    rst_out: str


@dataclass(frozen=True)
class RtlInterfaceInstance:
    if_type: str                  # bus_if, axi_lite_if, ...
    name: str
    params: dict[str, object] = field(default_factory=dict)
    comment: str = ""


@dataclass(frozen=True)
class RtlFabricPort:
    port_name: str
    interface_name: str
    modport: str                  # master/slave
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


@dataclass
class RtlModuleIR:
    name: str
    ports: list[RtlPort] = field(default_factory=list)
    wires: list[RtlWire] = field(default_factory=list)
    assigns: list[RtlAssign] = field(default_factory=list)
    interfaces: list[RtlInterfaceInstance] = field(default_factory=list)
    fabrics: list[RtlFabricInstance] = field(default_factory=list)
    instances: list[RtlInstance] = field(default_factory=list)
    reset_syncs: list[RtlResetSync] = field(default_factory=list)
    extra_sources: list[str] = field(default_factory=list)

    def add_port_once(self, port: RtlPort) -> None:
        if all(p.name != port.name for p in self.ports):
            self.ports.append(port)

    def add_wire_once(self, wire: RtlWire) -> None:
        if all(w.name != wire.name for w in self.wires):
            self.wires.append(wire)

    def add_interface_once(self, iface: RtlInterfaceInstance) -> None:
        if all(i.name != iface.name for i in self.interfaces):
            self.interfaces.append(iface)
```

---

# 2. Bus fabric IR builder

Toto je vrstva medzi interconnect planom a `RtlModuleIR`.

## `socfw/builders/rtl_bus_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan, ResolvedBusEndpoint
from socfw.ir.rtl import (
    BOARD_CLOCK,
    BOARD_RESET,
    RtlFabricInstance,
    RtlFabricPort,
    RtlInterfaceInstance,
)


class RtlBusBuilder:
    """
    Builds RTL bus/interface/fabric IR for currently supported protocols.

    First target:
      - simple_bus
      - bus_if interface instances
      - simple_bus_fabric module instance
    """

    def build_interfaces(self, plan: InterconnectPlan) -> list[RtlInterfaceInstance]:
        result: list[RtlInterfaceInstance] = []

        for fabric_name, endpoints in plan.fabrics.items():
            for ep in endpoints:
                if ep.protocol == "simple_bus":
                    result.append(
                        RtlInterfaceInstance(
                            if_type="bus_if",
                            name=self._if_name(ep.instance, fabric_name),
                            comment=f"{ep.role} endpoint on {fabric_name}",
                        )
                    )
        return result

    def build_fabrics(self, plan: InterconnectPlan) -> list[RtlFabricInstance]:
        fabrics: list[RtlFabricInstance] = []

        for fabric_name, endpoints in plan.fabrics.items():
            if not endpoints:
                continue

            protocol = endpoints[0].protocol
            if protocol != "simple_bus":
                continue

            masters = [ep for ep in endpoints if ep.role == "master"]
            slaves = [ep for ep in endpoints if ep.role == "slave"]

            fabric = RtlFabricInstance(
                module="simple_bus_fabric",
                name=f"u_fabric_{fabric_name}",
                params={
                    "NSLAVES": len(slaves),
                },
                clock_signal=BOARD_CLOCK,
                reset_signal=BOARD_RESET,
                comment=f"simple_bus fabric '{fabric_name}'",
            )

            for idx, ep in enumerate(masters):
                fabric.ports.append(
                    RtlFabricPort(
                        port_name="m_bus",
                        interface_name=self._if_name(ep.instance, fabric_name),
                        modport="master",
                        index=None if len(masters) == 1 else idx,
                    )
                )

            for idx, ep in enumerate(slaves):
                fabric.ports.append(
                    RtlFabricPort(
                        port_name="s_bus",
                        interface_name=self._if_name(ep.instance, fabric_name),
                        modport="slave",
                        index=idx,
                    )
                )

            fabrics.append(fabric)

        return fabrics

    @staticmethod
    def _if_name(instance: str, fabric: str) -> str:
        return f"if_{instance}_{fabric}"
```

---

# 3. Prepojenie endpointov na instance

Toto je helper, ktorý povie, ako má modulová inštancia dostať svoje bus interface pripojenie.

## `socfw/builders/rtl_bus_connections.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan
from socfw.ir.rtl import RtlBusConn
from socfw.model.ip import IpDescriptor
from socfw.model.project import ModuleInstance


class RtlBusConnectionResolver:
    def resolve_for_instance(
        self,
        *,
        mod: ModuleInstance,
        ip: IpDescriptor,
        plan: InterconnectPlan | None,
    ) -> list[RtlBusConn]:
        if plan is None:
            return []

        result: list[RtlBusConn] = []

        for fabric_name, endpoints in plan.fabrics.items():
            for ep in endpoints:
                if ep.instance != mod.instance:
                    continue

                iface = ip.bus_interface()
                if iface is None:
                    continue

                modport = "master" if ep.role == "master" else "slave"
                result.append(
                    RtlBusConn(
                        port=iface.port_name,
                        interface_name=f"if_{ep.instance}_{fabric_name}",
                        modport=modport,
                    )
                )

        return result
```

---

# 4. Refaktorovaný `RtlIRBuilder`

Toto je update k predchádzajúcemu builderu, aby už vedel:

* inštanciovať `bus_if`,
* vytvoriť `simple_bus_fabric`,
* pripájať moduly na interface/modport namiesto fake wire.

## `socfw/builders/rtl_ir_builder.py`

```python
from __future__ import annotations

from socfw.builders.rtl_bus_builder import RtlBusBuilder
from socfw.builders.rtl_bus_connections import RtlBusConnectionResolver
from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.rtl import (
    BOARD_CLOCK,
    BOARD_RESET,
    RtlAssign,
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

    def build(self, design: ElaboratedDesign) -> RtlModuleIR:
        system = design.system
        rtl = RtlModuleIR(name="soc_top")

        # System ports
        rtl.add_port_once(RtlPort(name=BOARD_CLOCK, direction="input", width=1))
        rtl.add_port_once(RtlPort(name=BOARD_RESET, direction="input", width=1))

        # Top-level external ports from board bindings
        for binding in design.port_bindings:
            for ext in binding.resolved:
                rtl.add_port_once(
                    RtlPort(
                        name=ext.top_name,
                        direction=ext.direction,
                        width=ext.width,
                    )
                )

        # Reset syncs and generated clock wires
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

        # Bus interfaces and fabric modules
        if design.interconnect is not None:
            for iface in self.bus_builder.build_interfaces(design.interconnect):
                rtl.add_interface_once(iface)

            rtl.fabrics.extend(self.bus_builder.build_fabrics(design.interconnect))

        # Module instances
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

            # Clock/reset ports
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

            # External board bindings
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
                    # complex bundle, e.g. SDRAM
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

        # Add static bus fabric source when needed
        if rtl.fabrics and "src/ip/bus/simple_bus_fabric.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/bus/simple_bus_fabric.sv")

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

Toto je dôležitý architektonický zlom: modul už nedostáva „fabric string hack“ ani dummy wire, ale `bus_if` interface cez `modport`.

---

# 15. Nový RTL template so supportom pre interfaces a fabric

## `socfw/templates/soc_top.sv.j2`

```jinja2
// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module {{ module.name }} (
{%- for p in module.ports %}
  {{ "input " if p.direction == "input" else "output" if p.direction == "output" else "inout " }} wire{% if p.width > 1 %} [{{ p.width - 1 }}:0]{% endif %} {{ p.name }}{{ "," if not loop.last else "" }}
{%- endfor %}
);

{% if module.wires %}
  // Internal wires
{% for w in module.wires %}
  wire{% if w.width > 1 %} [{{ w.width - 1 }}:0]{% endif %} {{ w.name }};{% if w.comment %} // {{ w.comment }}{% endif %}
{% endfor %}

{% endif %}

{% if module.interfaces %}
  // Interface instances
{% for iface in module.interfaces %}
  {{ iface.if_type }}
  {%- if iface.params %}
  #(
{%- for k, v in iface.params.items() %}
    .{{ k }}({{ v | sv_param }}){{ "," if not loop.last else "" }}
{%- endfor %}
  )
  {%- endif %}
  {{ iface.name }} ();{% if iface.comment %} // {{ iface.comment }}{% endif %}
{% endfor %}

{% endif %}

{% if module.reset_syncs %}
  // Reset synchronizers
{% for rs in module.reset_syncs %}
  rst_sync #(
    .STAGES({{ rs.stages }})
  ) {{ rs.name }} (
    .clk_i   ({{ rs.clk_signal }}),
    .arst_ni (RESET_N),
    .srst_no ({{ rs.rst_out }})
  );
{% endfor %}

{% endif %}

{% if module.assigns %}
  // Top-level / adapter assigns
{% for a in module.assigns %}
  assign {{ a.lhs }} = {{ a.rhs }};{% if a.comment %} // {{ a.comment }}{% endif %}
{% endfor %}

{% endif %}

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

endmodule : {{ module.name }}
`default_nettype wire
```

Toto je už reálne pripravené na interface/modport štýl, ktorý dnes starý framework zatiaľ používa len čiastočne pri SV interfaces, ale nie systematicky pre bus fabrics. 

---

# 16. Jednoduchý fabric template/modul

Aby to bolo konzistentné, treba aj jednoduchý statický `simple_bus_fabric.sv`.

## `src/ip/bus/simple_bus_fabric.sv`

```systemverilog
`default_nettype none

module simple_bus_fabric #(
  parameter int NSLAVES = 1,
  parameter logic [NSLAVES*32-1:0] BASE_ADDR = '0,
  parameter logic [NSLAVES*32-1:0] ADDR_MASK = '0
)(
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave  m_bus,
  bus_if.master s_bus [NSLAVES]
);

  logic [NSLAVES-1:0] sel;

  genvar i;
  generate
    for (i = 0; i < NSLAVES; i++) begin : g_decode
      wire [31:0] base = BASE_ADDR[i*32 +: 32];
      wire [31:0] mask = ADDR_MASK[i*32 +: 32];
      assign sel[i] = ((m_bus.addr & ~mask) == (base & ~mask));
    end
  endgenerate

  always_comb begin
    m_bus.ready = 1'b0;
    m_bus.rdata = 32'h0;

    for (int j = 0; j < NSLAVES; j++) begin
      s_bus[j].addr  = m_bus.addr;
      s_bus[j].wdata = m_bus.wdata;
      s_bus[j].be    = m_bus.be;
      s_bus[j].we    = m_bus.we;
      s_bus[j].valid = m_bus.valid & sel[j];

      if (sel[j]) begin
        m_bus.ready = s_bus[j].ready;
        m_bus.rdata = s_bus[j].rdata;
      end
    end
  end

endmodule : simple_bus_fabric
`default_nettype wire
```

Toto je jednoduchý prvý fabric. Neskôr sa dá rozšíriť o:

* explicit error slave,
* priority/arbiter pri multi-master,
* registered ready/data policy.

---

# 17. Parametrizácia base/mask do fabric

Aby fabric dával zmysel, builder by mal dodať address decode parametre.

## update `socfw/builders/rtl_bus_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan, ResolvedBusEndpoint
from socfw.ir.rtl import (
    BOARD_CLOCK,
    BOARD_RESET,
    RtlFabricInstance,
    RtlFabricPort,
    RtlInterfaceInstance,
)


class RtlBusBuilder:
    def build_interfaces(self, plan: InterconnectPlan) -> list[RtlInterfaceInstance]:
        result: list[RtlInterfaceInstance] = []

        for fabric_name, endpoints in plan.fabrics.items():
            for ep in endpoints:
                if ep.protocol == "simple_bus":
                    result.append(
                        RtlInterfaceInstance(
                            if_type="bus_if",
                            name=self._if_name(ep.instance, fabric_name),
                            comment=f"{ep.role} endpoint on {fabric_name}",
                        )
                    )
        return result

    def build_fabrics(self, plan: InterconnectPlan) -> list[RtlFabricInstance]:
        fabrics: list[RtlFabricInstance] = []

        for fabric_name, endpoints in plan.fabrics.items():
            if not endpoints:
                continue

            protocol = endpoints[0].protocol
            if protocol != "simple_bus":
                continue

            masters = [ep for ep in endpoints if ep.role == "master"]
            slaves = [ep for ep in endpoints if ep.role == "slave"]

            base_words: list[int] = []
            mask_words: list[int] = []
            for s in slaves:
                base_words.append(s.base or 0)
                size = s.size or 0
                mask = (size - 1) if size > 0 and (size & (size - 1)) == 0 else 0
                mask_words.append(mask)

            fabric = RtlFabricInstance(
                module="simple_bus_fabric",
                name=f"u_fabric_{fabric_name}",
                params={
                    "NSLAVES": len(slaves),
                    "BASE_ADDR": self._pack_words(base_words),
                    "ADDR_MASK": self._pack_words(mask_words),
                },
                clock_signal=BOARD_CLOCK,
                reset_signal=BOARD_RESET,
                comment=f"simple_bus fabric '{fabric_name}'",
            )

            for idx, ep in enumerate(masters):
                fabric.ports.append(
                    RtlFabricPort(
                        port_name="m_bus",
                        interface_name=self._if_name(ep.instance, fabric_name),
                        modport="slave",
                        index=None if len(masters) == 1 else idx,
                    )
                )

            for idx, ep in enumerate(slaves):
                fabric.ports.append(
                    RtlFabricPort(
                        port_name="s_bus",
                        interface_name=self._if_name(ep.instance, fabric_name),
                        modport="master",
                        index=idx,
                    )
                )

            fabrics.append(fabric)

        return fabrics

    @staticmethod
    def _if_name(instance: str, fabric: str) -> str:
        return f"if_{instance}_{fabric}"

    @staticmethod
    def _pack_words(words: list[int]) -> str:
        if not words:
            return "'0"
        chunks = [f"32'h{w:08X}" for w in reversed(words)]
        return "{ " + ", ".join(chunks) + " }"
```

Poznámka: pri `bus_if` sú modporty otočené podľa pohľadu fabric modulu:

* fabric číta od mastera → `m_bus` je `bus_if.slave`
* fabric poháňa slave endpointy → `s_bus[]` sú `bus_if.master`

---

# 18. Prečo je toto lepšie než starý stav

Teraz už SoC bus vrstva:

* nie je len `bus_type` string v modele, 
* nie je len render-context hack v RTL generátore, 
* ale má:

  * **project-level fabric request**
  * **IP-level bus interface metadata**
  * **planner**
  * **address map builder**
  * **RTL interface/fabric IR**
  * **SW/docs address-space napojenie**

To je presne tá architektonická zmena, ktorú si chcel kvôli rozšíriteľnosti na nové bus-y.

---

# 19. Čo by som spravil hneď potom

Najbližšie by som spravil jednu z týchto dvoch vecí:

### možnosť A

**formalizovať CPU model a master endpoint**

* CPU descriptor s `simple_bus` master portom
* napojenie CPU do fabric
* reset/progaddr/RAM model

### možnosť B

**bridge plugin API**

* `axi_lite -> simple_bus`
* `simple_bus -> axi_lite`
* protocol mismatch sa zmení z erroru na planner-inserted bridge

Môj praktický odporúčaný ďalší krok je **A** — CPU/RAM master vrstva, lebo bez nej je SoC pipeline stále len polovičná.

V ďalšej správe ti viem pripraviť:
**kompletný refaktorovaný CPU/RAM/boot-image layer**
vrátane:

* CPU modelu,
* RAM modelu,
* master endpointu,
* napojenia na `simple_bus_fabric`,
* SW init/image flow.
