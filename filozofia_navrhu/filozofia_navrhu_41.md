Super. Ideme na:

# AXI-lite → `simple_bus` bridge + adapter plugin + example peripheral integration

Toto je veľmi dôležitý krok, lebo je to prvý skutočný dôkaz, že nový framework je:

* **rozšíriteľný**
* **bus-agnostic v jadre**
* a nie len “uprataný generator pre jeden interný bus”

Cieľ:

* periféria môže byť natívne `axi_lite`
* SoC backbone ostane `simple_bus`
* planner vloží bridge/adaptér
* RTL sa vygeneruje korektne
* SW/docs ostanú nezmenené, lebo address map je stále centrálna

To je presne správna architektúra.

---

# 1. Architektonický princíp

Chceme mať:

```text
CPU (simple_bus master)
   ↓
simple_bus fabric
   ↓
axi_lite_bridge
   ↓
AXI-lite peripheral
```

Teda:

* **core fabric protocol** = `simple_bus`
* **peripheral local protocol** = `axi_lite`
* **bridge** = explicitný plánovací a RTL objekt

Tým pádom:

* address map sa nemení
* firmware nič nevie o tom, že pod kapotou je AXI-lite
* bridge je len implementation detail interconnectu

---

# 2. Nový IP bus interface model

Doteraz sme bus pre periférie modelovali zjednodušene. Teraz ho treba formalizovať.

## update `socfw/model/ip.py`

Pridaj:

```python
from dataclasses import dataclass, field

# ... existing types ...

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
    meta: dict[str, Any] = field(default_factory=dict)

    def bus_interface(self, role: str | None = None) -> IpBusInterface | None:
        for b in self.bus_interfaces:
            if role is None or b.role == role:
                return b
        return None
```

---

# 3. IP schema update

## update `socfw/config/ip_schema.py`

Pridaj:

```python
class IpBusInterfaceSchema(BaseModel):
    port_name: str
    protocol: str
    role: Literal["master", "slave"]
    addr_width: int = 32
    data_width: int = 32
```

A do `IpConfigSchema`:

```python
    bus_interfaces: list[IpBusInterfaceSchema] = Field(default_factory=list)
```

---

## update `socfw/config/ip_loader.py`

Import:

```python
from socfw.model.ip import (
    IpArtifactBundle,
    IpBusInterface,
    IpClockOutput,
    IpClocking,
    IpDescriptor,
    IpOrigin,
    IpResetSemantics,
)
```

A do `IpDescriptor(...)`:

```python
            bus_interfaces=tuple(
                IpBusInterface(
                    port_name=b.port_name,
                    protocol=b.protocol,
                    role=b.role,
                    addr_width=b.addr_width,
                    data_width=b.data_width,
                )
                for b in doc.bus_interfaces
            ),
```

---

# 4. Bridge planning model

Most nemá byť “len tak nejaká extra inštancia v builderi”. Má byť súčasť plánu.

## update `socfw/elaborate/bus_plan.py`

Pridaj:

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
    dst_instance: str
    dst_port: str


@dataclass
class InterconnectPlan:
    fabrics: dict[str, list[ResolvedBusEndpoint]] = field(default_factory=dict)
    bridges: list[PlannedBusBridge] = field(default_factory=list)
```

---

# 5. Bridge planner

Teraz spravíme najjednoduchší planner:

* ak je peripheral `axi_lite`
* a fabric je `simple_bus`
* planner vloží `simple_bus_to_axi_lite_bridge`

## nový `socfw/plugins/bridges/simple_to_axi.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import PlannedBusBridge


class SimpleBusToAxiLiteBridgePlanner:
    def maybe_plan_bridge(self, *, fabric, mod, ip) -> PlannedBusBridge | None:
        iface = ip.bus_interface(role="slave")
        if iface is None:
            return None

        if fabric.protocol == "simple_bus" and iface.protocol == "axi_lite":
            return PlannedBusBridge(
                instance=f"bridge_{mod.instance}",
                module="simple_bus_to_axi_lite_bridge",
                src_protocol="simple_bus",
                dst_protocol="axi_lite",
                src_fabric=fabric.name,
                dst_instance=mod.instance,
                dst_port=iface.port_name,
            )

        return None
```

---

# 6. Simple bus planner update

Teraz uprav planner tak, aby:

* `simple_bus` fabric videl slave endpoint buď priamo,
* alebo cez bridge endpoint

## update `socfw/plugins/simple_bus/planner.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan, PlannedBusBridge, ResolvedBusEndpoint
from socfw.plugins.bridges.simple_to_axi import SimpleBusToAxiLiteBridgePlanner


class SimpleBusPlanner:
    protocol = "simple_bus"

    def __init__(self) -> None:
        self.bridge_planner = SimpleBusToAxiLiteBridgePlanner()

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
                    bridge = self.bridge_planner.maybe_plan_bridge(
                        fabric=fabric,
                        mod=mod,
                        ip=ip,
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

Toto je veľmi dôležité:

* fabric stále pozná len `simple_bus`
* bridge sa tvári ako slave endpoint na fabricu
* skutočná periféria za bridge-om môže byť AXI-lite

---

# 7. RTL IR pre AXI-lite interface

Teraz musí RTL IR vedieť reprezentovať aj `axi_lite_if`.

Ak už používaš generické `RtlInterfaceInstance(if_type=...)`, stačí len v builderi generovať `axi_lite_if`.

---

# 8. Bridge RTL builder

## update `socfw/builders/rtl_bus_builder.py`

Pridaj bridge interface generation a bridge instancie.

```python
from __future__ import annotations

from socfw.ir.rtl import (
    RtlBusConn,
    RtlFabricInstance,
    RtlFabricPort,
    RtlInterfaceInstance,
    RtlInstance,
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
            result.append(
                RtlInterfaceInstance(
                    if_type="bus_if",
                    name=f"if_error_{fabric_name}",
                    comment=f"error slave for {fabric_name}",
                )
            )

        for br in plan.bridges:
            result.append(
                RtlInterfaceInstance(
                    if_type="axi_lite_if",
                    name=f"if_{br.dst_instance}_axil",
                    comment=f"AXI-lite side for {br.instance}",
                )
            )

        return result

    def build_fabrics(self, plan) -> list[RtlFabricInstance]:
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
                comment=f"simple_bus fabric '{fabric_name}'",
            )

            for idx, ep in enumerate(masters):
                fabric.ports.append(
                    RtlFabricPort(
                        port_name="m_bus",
                        interface_name=f"if_{ep.instance}_{fabric_name}",
                        modport="slave",
                        index=None if len(masters) == 1 else idx,
                    )
                )

            for idx, ep in enumerate(slaves):
                fabric.ports.append(
                    RtlFabricPort(
                        port_name="s_bus",
                        interface_name=f"if_{ep.instance}_{fabric_name}",
                        modport="master",
                        index=idx,
                    )
                )

            fabric.ports.append(
                RtlFabricPort(
                    port_name="err_bus",
                    interface_name=f"if_error_{fabric_name}",
                    modport="master",
                    index=None,
                )
            )

            fabrics.append(fabric)

        return fabrics

    def build_bridge_instances(self, plan) -> list[RtlInstance]:
        result: list[RtlInstance] = []

        for br in plan.bridges:
            result.append(
                RtlInstance(
                    module=br.module,
                    name=br.instance,
                    conns=[],
                    bus_conns=[
                        RtlBusConn(
                            port="sbus",
                            interface_name=f"if_{br.instance}_{br.src_fabric}",
                            modport="slave",
                        ),
                        RtlBusConn(
                            port="m_axil",
                            interface_name=f"if_{br.dst_instance}_axil",
                            modport="master",
                        ),
                    ],
                    comment=f"{br.src_protocol} -> {br.dst_protocol} bridge",
                )
            )

        return result

    @staticmethod
    def _pack_words(words: list[int]) -> str:
        if not words:
            return "'0"
        chunks = [f"32'h{w:08X}" for w in reversed(words)]
        return "{ " + ", ".join(chunks) + " }"
```

---

# 9. RTL builder update pre bridge instances

## update `socfw/builders/rtl_ir_builder.py`

Po:

```python
            rtl.fabrics.extend(self.bus_builder.build_fabrics(design.interconnect))
```

doplň:

```python
            rtl.instances.extend(self.bus_builder.build_bridge_instances(design.interconnect))
```

A pri inštanciovaní periférií treba rozhodnúť, či sa pripájajú cez `bus_if` alebo `axi_lite_if`.

V module loop nahradiť bus_conns časť:

```python
            bus_conns = []
            iface = ip.bus_interface(role="slave")

            if iface is not None:
                if iface.protocol == "simple_bus" and mod.bus is not None and design.interconnect is not None:
                    for fabric_name, endpoints in design.interconnect.fabrics.items():
                        for ep in endpoints:
                            if ep.instance == mod.instance:
                                bus_conns.append(RtlBusConn(
                                    port=iface.port_name,
                                    interface_name=f"if_{ep.instance}_{fabric_name}",
                                    modport="slave",
                                ))
                elif iface.protocol == "axi_lite" and design.interconnect is not None:
                    for br in design.interconnect.bridges:
                        if br.dst_instance == mod.instance:
                            bus_conns.append(RtlBusConn(
                                port=iface.port_name,
                                interface_name=f"if_{mod.instance}_axil",
                                modport="slave",
                            ))
```

A extra sources:

```python
        if design.interconnect is not None and design.interconnect.bridges:
            if "src/ip/bus/simple_bus_to_axi_lite_bridge.sv" not in rtl.extra_sources:
                rtl.extra_sources.append("src/ip/bus/simple_bus_to_axi_lite_bridge.sv")
            if "src/ip/bus/axi_lite_if.sv" not in rtl.extra_sources:
                rtl.extra_sources.append("src/ip/bus/axi_lite_if.sv")
```

---

# 10. AXI-lite interface

Ak už máš `axi_lite_if.sv` v starom kóde, môžeš ho prebrať. Pre minimálny slice stačí jednoduchý kontrakt.

## `src/ip/bus/axi_lite_if.sv`

```systemverilog
interface axi_lite_if;
  logic [31:0] awaddr;
  logic        awvalid;
  logic        awready;

  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;

  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;

  logic [31:0] araddr;
  logic        arvalid;
  logic        arready;

  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;

  modport master (
    output awaddr, output awvalid, input awready,
    output wdata, output wstrb, output wvalid, input wready,
    input bresp, input bvalid, output bready,
    output araddr, output arvalid, input arready,
    input rdata, input rresp, input rvalid, output rready
  );

  modport slave (
    input awaddr, input awvalid, output awready,
    input wdata, input wstrb, input wvalid, output wready,
    output bresp, output bvalid, input bready,
    input araddr, input arvalid, output arready,
    output rdata, output rresp, output rvalid, input rready
  );
endinterface
```

---

# 11. Most `simple_bus -> axi_lite`

Toto je minimalistický bridge, nie ešte plne optimalizovaný. Ale je dobrý slice.

## `src/ip/bus/simple_bus_to_axi_lite_bridge.sv`

```systemverilog
`default_nettype none

module simple_bus_to_axi_lite_bridge (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave      sbus,
  axi_lite_if.master m_axil
);

  typedef enum logic [1:0] {
    S_IDLE,
    S_WRITE_RESP,
    S_READ_RESP
  } state_t;

  state_t state;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE: begin
          if (sbus.valid && sbus.we && m_axil.awready && m_axil.wready)
            state <= S_WRITE_RESP;
          else if (sbus.valid && !sbus.we && m_axil.arready)
            state <= S_READ_RESP;
        end
        S_WRITE_RESP: begin
          if (m_axil.bvalid)
            state <= S_IDLE;
        end
        S_READ_RESP: begin
          if (m_axil.rvalid)
            state <= S_IDLE;
        end
      endcase
    end
  end

  always_comb begin
    sbus.ready = 1'b0;
    sbus.rdata = 32'h0;

    m_axil.awaddr  = sbus.addr;
    m_axil.awvalid = (state == S_IDLE) && sbus.valid && sbus.we;

    m_axil.wdata   = sbus.wdata;
    m_axil.wstrb   = sbus.be;
    m_axil.wvalid  = (state == S_IDLE) && sbus.valid && sbus.we;

    m_axil.bready  = 1'b1;

    m_axil.araddr  = sbus.addr;
    m_axil.arvalid = (state == S_IDLE) && sbus.valid && !sbus.we;

    m_axil.rready  = 1'b1;

    if (state == S_WRITE_RESP && m_axil.bvalid) begin
      sbus.ready = 1'b1;
      sbus.rdata = 32'h0;
    end

    if (state == S_READ_RESP && m_axil.rvalid) begin
      sbus.ready = 1'b1;
      sbus.rdata = m_axil.rdata;
    end
  end

endmodule

`default_nettype wire
```

---

# 12. Example AXI-lite peripheral

Spravme minimálnu AXI-lite LED perifériu.

## `tests/golden/fixtures/picorv32_soc/ip/axi_gpio.ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: axi_gpio
  module: axi_gpio
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
    - tests/golden/fixtures/picorv32_soc/rtl/axi_gpio.sv
  simulation: []
  metadata: []

bus_interfaces:
  - port_name: axil
    protocol: axi_lite
    role: slave
    addr_width: 32
    data_width: 32
```

## `tests/golden/fixtures/picorv32_soc/rtl/axi_gpio.sv`

```systemverilog
`default_nettype none

module axi_gpio (
  input  wire SYS_CLK,
  input  wire RESET_N,
  axi_lite_if.slave axil,
  output logic [5:0] gpio_o
);

  logic [31:0] reg_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N)
      reg_value <= 32'h0;
    else if (axil.awvalid && axil.wvalid)
      reg_value <= axil.wdata;
  end

  always_comb begin
    axil.awready = 1'b1;
    axil.wready  = 1'b1;
    axil.bresp   = 2'b00;
    axil.bvalid  = axil.awvalid && axil.wvalid;

    axil.arready = 1'b1;
    axil.rdata   = reg_value;
    axil.rresp   = 2'b00;
    axil.rvalid  = axil.arvalid;
  end

  assign gpio_o = reg_value[5:0];

endmodule

`default_nettype wire
```

---

# 13. Example project integration

Do projektu pridaj modul:

## update `tests/golden/fixtures/picorv32_soc/project.yaml`

```yaml
  - instance: axigpio0
    type: axi_gpio
    bus:
      fabric: main
      base: 0x40002000
      size: 0x1000
    clocks:
      SYS_CLK: sys_clk
    bind:
      ports:
        gpio_o:
          target: board:onboard.leds
```

Pozor: ak už LED používa `gpio0`, tak v test fixture si buď:

* použiješ iný connector resource,
* alebo spravíš samostatný AXI fixture

Odporúčam samostatný fixture.

---

# 14. Samostatný AXI bridge fixture

Najčistejšie bude mať nový fixture napr.:

```text
tests/golden/fixtures/axi_bridge_soc/
```

s:

* rovnakou board
* rovnakým CPU/RAM
* jednou `axi_gpio` perifériou
* firmware, ktoré zapisuje na `0x40002000`

To dá veľmi čistý demo slice.

---

# 15. Firmware pre AXI peripheral

## `tests/golden/fixtures/axi_bridge_soc/fw/main.c`

```c
#define AXIGPIO0_VALUE_REG (*(volatile unsigned*)(0x40002000u))

static void delay(volatile unsigned count) {
    while (count--) {
        __asm__ volatile ("nop");
    }
}

int main(void) {
    while (1) {
        AXIGPIO0_VALUE_REG = 0x15;
        delay(200000);
        AXIGPIO0_VALUE_REG = 0x2A;
        delay(200000);
    }
    return 0;
}
```

Toto je veľmi dobrý dôkaz, že:

* CPU beží po `simple_bus`
* periféria je AXI-lite
* framework vložil bridge

---

# 16. Integration test

## `tests/integration/test_build_axi_bridge_soc.py`

```python
import shutil
import pytest

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow


@pytest.mark.skipif(
    shutil.which("riscv32-unknown-elf-gcc") is None,
    reason="RISC-V toolchain not installed",
)
def test_build_axi_bridge_soc(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/axi_bridge_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok

    rtl = (out_dir / "rtl" / "soc_top.sv").read_text(encoding="utf-8")
    assert "simple_bus_to_axi_lite_bridge" in rtl
    assert "axi_lite_if" in rtl
    assert "axi_gpio" in rtl
```

---

# 17. Čo týmto architektonicky dokazuješ

Tento slice je veľmi silný, lebo dokazuje:

* backbone bus môže byť jednoduchý a interný
* periférie môžu byť z iného protocol family
* framework to rieši cez:

  * IP metadata
  * planner
  * bridge injection
  * RTL interface generation

To je presne vlastnosť, ktorú si chcel od začiatku:
**rozšíriteľnosť bez prerábania jadra**

---

# 18. Čo by som spravil hneď potom

Teraz sú tri veľmi dobré smery:

### A

**Wishbone bridge**

* druhý bridge typ
* ešte silnejší dôkaz rozšíriteľnosti

### B

**bridge registry generalization**

* nie hardcoded planner v simple bus plugin
* samostatný registry/plugin model pre bridges

### C

**repo hardening**

* CI
* golden snapshots
* docs
* packaging

Môj praktický odporúčaný ďalší krok je:

👉 **B — bridge registry generalization**

Lebo zatiaľ máme prvý bridge, ale ešte nie úplne elegantný plugin systém pre viac adapterov. To je podľa mňa posledný architektonický kus, ktorý uzavrie “moderný rozšíriteľný framework”.

Ak chceš, ďalšia správa môže byť presne:
**generic bridge registry + protocol adapter API + Wishbone bridge pattern**
