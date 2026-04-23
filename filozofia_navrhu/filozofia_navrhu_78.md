Áno. Tu je **Commit 17 ako file-by-file scaffold**:

# Commit 17 — `sdram_ctrl` vendor descriptor + bus-aware fixture fields + prvé bridge validation pravidlo

Cieľ tohto commitu:

* pridať prvý **vendor SDRAM IP descriptor**
* rozšíriť projektový model o minimálne **bus fields**
* dostať `vendor_sdram_soc` z čisto validačného scaffoldu na:

  * bus-aware fixture
  * bridge-aware validate
* zaviesť prvé pravidlo:

  * **chýbajúci bridge medzi fabric protocol a IP protocol**

Toto je správny commit po SDRAM board-resource scaffolde, lebo teraz už nový flow nezačne len “vidieť SDRAM piny”, ale začne rozumieť aj tomu, že:

* CPU/fabric je jeden protokol
* SDRAM controller IP má iný protokol
* medzi nimi musí byť bridge alebo kompatibilita

---

# Názov commitu

```text
vendor: add sdram_ctrl descriptor, bus-aware fixture fields, and first bridge validation rule
```

---

# 1. Čo má byť výsledok po Commite 17

Po tomto commite má platiť:

```bash
socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml
```

A očakávaš:

* `sdram_ctrl` sa načíta z `packs/vendor-intel`
* fixture už obsahuje:

  * `buses`
  * modulový `bus` attachment
* validation pipeline vie povedať:

  * či je IP typ známy
  * či CPU typ je známy
  * či fabric existuje
  * či protokoly sedia alebo chýba bridge

Na tomto commite je úplne v poriadku, ak `vendor_sdram_soc` ešte **nebuildí**.
Cieľ je:

* správny model
* správna validácia
* správne chyby

---

# 2. Súbory, ktoré pridať

```text
packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/ip.yaml
packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/files/sdram_ctrl.qip
packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/files/sdram_ctrl.v
packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/files/sdram_ctrl.sdc

socfw/model/bus.py
socfw/validate/rules/bridge_rules.py

tests/unit/test_bridge_validation_rule.py
tests/integration/test_validate_vendor_sdram_soc_missing_bridge.py
```

---

# 3. Súbory, ktoré upraviť

```text
socfw/model/project.py
socfw/config/project_schema.py
socfw/config/project_loader.py
socfw/model/ip.py
socfw/config/ip_schema.py
socfw/config/ip_loader.py
socfw/model/system.py
socfw/validate/runner.py
tests/golden/fixtures/vendor_sdram_soc/project.yaml
```

Voliteľne:

```text
socfw/config/system_loader.py
```

ale len ak chceš pridať helper mapy pre fabriky.

---

# 4. Kľúčové rozhodnutie pre Commit 17

Správny scope je:

## ešte nerobiť bridge planner ani RTL bridge insertion

Na tomto commite len:

* opíš protokoly
* opíš fabric
* skontroluj kompatibilitu

To znamená:

* ak `CPU/fabric = simple_bus`
* a `sdram_ctrl = wishbone`
* a nič ešte neregistruje bridge

tak validation má dať chybu typu:

* `BRG001 No bridge registered for simple_bus -> wishbone`

To je presne správny ďalší krok.

---

# 5. `socfw/model/bus.py`

Toto je nový malý model pre fabrics a attachments.

```python
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class BusFabric:
    name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


@dataclass
class ModuleBusAttachment:
    fabric: str
    base: int | None = None
    size: int | None = None


@dataclass
class IpBusInterface:
    port_name: str
    protocol: str
    role: str
    addr_width: int = 32
    data_width: int = 32
```

---

# 6. úprava `socfw/model/project.py`

Teraz doplň fabrics a bus attachment na moduloch.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field

from socfw.model.bus import BusFabric, ModuleBusAttachment


@dataclass
class ProjectModule:
    instance: str
    type_name: str
    params: dict = field(default_factory=dict)
    clocks: dict = field(default_factory=dict)
    bind: dict = field(default_factory=dict)
    bus: ModuleBusAttachment | None = None
    raw: dict = field(default_factory=dict)


@dataclass
class ProjectCpu:
    instance: str
    type_name: str
    fabric: str | None = None
    reset_vector: int | None = None
    params: dict = field(default_factory=dict)
    raw: dict = field(default_factory=dict)


@dataclass
class ProjectModel:
    name: str
    mode: str
    board_ref: str
    board_file: str | None = None
    registries_packs: list[str] = field(default_factory=list)
    registries_ip: list[str] = field(default_factory=list)
    registries_cpu: list[str] = field(default_factory=list)
    buses: list[BusFabric] = field(default_factory=list)
    modules: list[ProjectModule] = field(default_factory=list)
    cpu: ProjectCpu | None = None
    raw: dict = field(default_factory=dict)

    def fabric_by_name(self, name: str) -> BusFabric | None:
        for b in self.buses:
            if b.name == name:
                return b
        return None
```

---

# 7. úprava `socfw/config/project_schema.py`

Treba doplniť `buses` a `module.bus`.

## nahradiť týmto

```python
from __future__ import annotations

from pydantic import BaseModel, Field


class ProjectModuleBusSchema(BaseModel):
    fabric: str
    base: int | None = None
    size: int | None = None


class ProjectModuleSchema(BaseModel):
    instance: str
    type: str
    params: dict = Field(default_factory=dict)
    clocks: dict = Field(default_factory=dict)
    bind: dict = Field(default_factory=dict)
    bus: ProjectModuleBusSchema | None = None


class ProjectCpuSchema(BaseModel):
    instance: str
    type: str
    fabric: str | None = None
    reset_vector: int | None = None
    params: dict = Field(default_factory=dict)


class ProjectBusSchema(BaseModel):
    name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


class RegistriesSchema(BaseModel):
    packs: list[str] = Field(default_factory=list)
    ip: list[str] = Field(default_factory=list)
    cpu: list[str] = Field(default_factory=list)


class ProjectMetaSchema(BaseModel):
    name: str
    mode: str
    board: str
    board_file: str | None = None
    output_dir: str | None = None
    debug: bool = False


class ClocksSchema(BaseModel):
    primary: dict | None = None
    generated: list[dict] = Field(default_factory=list)


class ProjectConfigSchema(BaseModel):
    version: int = 2
    kind: str = "project"
    project: ProjectMetaSchema
    registries: RegistriesSchema = Field(default_factory=RegistriesSchema)
    clocks: ClocksSchema = Field(default_factory=ClocksSchema)
    buses: list[ProjectBusSchema] = Field(default_factory=list)
    cpu: ProjectCpuSchema | None = None
    modules: list[ProjectModuleSchema] = Field(default_factory=list)
```

---

# 8. úprava `socfw/config/project_loader.py`

Treba doplniť:

* `buses`
* `module.bus`
* legacy mapping pre `bus`, ak existuje

## uprav importy

pridaj:

```python
from socfw.model.bus import BusFabric, ModuleBusAttachment
```

## v `_legacy_to_project_doc()` doplň

```python
    buses = data.get("buses", [])

    mapped_buses = []
    if isinstance(buses, list):
        for b in buses:
            if not isinstance(b, dict):
                continue
            mapped_buses.append({
                "name": b.get("name", "main"),
                "protocol": b.get("protocol", "simple_bus"),
                "addr_width": b.get("addr_width", 32),
                "data_width": b.get("data_width", 32),
            })
```

A v mapped module loop:

```python
        mapped_modules.append({
            "instance": m.get("name") or m.get("instance") or m.get("type") or "u0",
            "type": m.get("type") or m.get("module") or "unknown",
            "params": m.get("params", {}),
            "clocks": m.get("clocks", {}),
            "bind": m.get("bind", {}),
            "bus": m.get("bus"),
        })
```

A do návratu:

```python
        "buses": mapped_buses,
```

## pri skladaní `ProjectModel(...)` doplň

```python
            buses=[
                BusFabric(
                    name=b.name,
                    protocol=b.protocol,
                    addr_width=b.addr_width,
                    data_width=b.data_width,
                )
                for b in doc.buses
            ],
```

A pri moduloch:

```python
                    bus=(
                        ModuleBusAttachment(
                            fabric=m.bus.fabric,
                            base=m.bus.base,
                            size=m.bus.size,
                        )
                        if m.bus is not None else None
                    ),
```

### výsledný relevantný kus

Nemusíš prepisovať celý súbor, stačí tieto nové polia doplniť.

---

# 9. úprava `socfw/model/ip.py`

Treba doplniť bus interfaces.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field

from socfw.model.bus import IpBusInterface
from socfw.model.vendor import VendorInfo


@dataclass
class IpClockOutput:
    name: str
    frequency_hz: int | None = None
    domain_hint: str | None = None


@dataclass
class IpDescriptor:
    name: str
    module: str
    category: str
    origin_kind: str = "source"
    packaging: str = "plain_rtl"

    needs_bus: bool = False
    generate_registers: bool = False
    instantiate_directly: bool = True
    dependency_only: bool = False

    reset_port: str | None = None
    reset_active_high: bool | None = None

    primary_clock_port: str | None = None
    additional_clock_ports: tuple[str, ...] = ()
    clock_outputs: tuple[IpClockOutput, ...] = ()
    bus_interfaces: tuple[IpBusInterface, ...] = ()

    synthesis_files: tuple[str, ...] = ()
    simulation_files: tuple[str, ...] = ()
    metadata_files: tuple[str, ...] = ()

    vendor_info: VendorInfo | None = None

    raw: dict = field(default_factory=dict)

    def slave_bus_interface(self) -> IpBusInterface | None:
        for iface in self.bus_interfaces:
            if iface.role == "slave":
                return iface
        return None
```

---

# 10. úprava `socfw/config/ip_schema.py`

Treba doplniť `bus_interfaces`.

## nahradiť týmto

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class IpMetaSchema(BaseModel):
    name: str
    module: str
    category: str = "generic"


class IpOriginSchema(BaseModel):
    kind: str = "source"
    packaging: str = "plain_rtl"


class IpVendorSchema(BaseModel):
    vendor: str
    tool: str
    generator: str | None = None
    family: str | None = None
    qip: str | None = None
    sdc: list[str] = Field(default_factory=list)
    filesets: list[str] = Field(default_factory=list)


class IpIntegrationSchema(BaseModel):
    needs_bus: bool = False
    generate_registers: bool = False
    instantiate_directly: bool = True
    dependency_only: bool = False


class IpResetSchema(BaseModel):
    port: str | None = None
    active_high: bool | None = None


class IpClockOutputSchema(BaseModel):
    name: str
    frequency_hz: int | None = None
    domain_hint: str | None = None


class IpClockingSchema(BaseModel):
    primary_input_port: str | None = None
    additional_input_ports: list[str] = Field(default_factory=list)
    outputs: list[IpClockOutputSchema] = Field(default_factory=list)


class IpBusInterfaceSchema(BaseModel):
    port_name: str
    protocol: str
    role: str
    addr_width: int = 32
    data_width: int = 32


class IpArtifactsSchema(BaseModel):
    synthesis: list[str] = Field(default_factory=list)
    simulation: list[str] = Field(default_factory=list)
    metadata: list[str] = Field(default_factory=list)


class IpConfigSchema(BaseModel):
    version: int = 2
    kind: Literal["ip"] = "ip"
    ip: IpMetaSchema
    origin: IpOriginSchema = Field(default_factory=IpOriginSchema)
    vendor: IpVendorSchema | None = None
    integration: IpIntegrationSchema = Field(default_factory=IpIntegrationSchema)
    reset: IpResetSchema = Field(default_factory=IpResetSchema)
    clocking: IpClockingSchema = Field(default_factory=IpClockingSchema)
    bus_interfaces: list[IpBusInterfaceSchema] = Field(default_factory=list)
    artifacts: IpArtifactsSchema = Field(default_factory=IpArtifactsSchema)
```

---

# 11. úprava `socfw/config/ip_loader.py`

Treba naplniť `bus_interfaces`.

## uprav importy

pridaj:

```python
from socfw.model.bus import IpBusInterface
```

## v `_legacy_to_ip_doc()` doplň jednoduchý mapping

```python
    bus_interfaces = []
    if isinstance(interfaces, dict) and isinstance(interfaces.get("bus"), dict):
        bus = interfaces["bus"]
        bus_interfaces.append({
            "port_name": bus.get("port_name", "bus"),
            "protocol": bus.get("protocol", "simple_bus"),
            "role": bus.get("role", "slave"),
            "addr_width": bus.get("addr_width", 32),
            "data_width": bus.get("data_width", 32),
        })
```

A do návratu:

```python
        "bus_interfaces": bus_interfaces,
```

## pri skladaní `IpDescriptor(...)` doplň

```python
            bus_interfaces=tuple(
                IpBusInterface(
                    port_name=bi.port_name,
                    protocol=bi.protocol,
                    role=bi.role,
                    addr_width=bi.addr_width,
                    data_width=bi.data_width,
                )
                for bi in doc.bus_interfaces
            ),
```

---

# 12. `packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/ip.yaml`

Toto je prvý vendor SDRAM descriptor.

```yaml
version: 2
kind: ip

ip:
  name: sdram_ctrl
  module: sdram_ctrl
  category: memory

origin:
  kind: generated
  packaging: quartus_ip

vendor:
  vendor: intel
  tool: quartus
  generator: megawizard
  family: cyclone_iv_e
  qip: files/sdram_ctrl.qip
  sdc:
    - files/sdram_ctrl.sdc
  filesets:
    - quartus_qip
    - timing_sdc
    - generated_rtl

integration:
  needs_bus: true
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: reset_n
  active_high: false

clocking:
  primary_input_port: clk
  additional_input_ports: []
  outputs: []

bus_interfaces:
  - port_name: wb
    protocol: wishbone
    role: slave
    addr_width: 32
    data_width: 32

artifacts:
  synthesis:
    - files/sdram_ctrl.qip
    - files/sdram_ctrl.v
  simulation: []
  metadata: []
```

---

# 13. `packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/files/sdram_ctrl.qip`

```tcl
# Placeholder QIP file for sdram_ctrl vendor pack fixture
set_global_assignment -name VERILOG_FILE sdram_ctrl.v
set_global_assignment -name SDC_FILE sdram_ctrl.sdc
```

---

# 14. `packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/files/sdram_ctrl.v`

Na tento commit stačí placeholder modul s externými portmi.
Nie funkčný controller, len scaffold.

```systemverilog
`default_nettype none

module sdram_ctrl (
  input  wire        clk,
  input  wire        reset_n,

  input  wire [12:0] zs_addr,
  input  wire [1:0]  zs_ba,
  inout  wire [15:0] zs_dq,
  output wire [1:0]  zs_dqm,
  output wire        zs_cs_n,
  output wire        zs_we_n,
  output wire        zs_ras_n,
  output wire        zs_cas_n,
  output wire        zs_cke,
  output wire        zs_clk,

  input  wire [31:0] wb_adr,
  input  wire [31:0] wb_dat_w,
  output wire [31:0] wb_dat_r,
  input  wire [3:0]  wb_sel,
  input  wire        wb_we,
  input  wire        wb_cyc,
  input  wire        wb_stb,
  output wire        wb_ack
);

  assign zs_dqm   = 2'b00;
  assign zs_cs_n  = 1'b1;
  assign zs_we_n  = 1'b1;
  assign zs_ras_n = 1'b1;
  assign zs_cas_n = 1'b1;
  assign zs_cke   = 1'b0;
  assign zs_clk   = clk;

  assign wb_dat_r = 32'h0;
  assign wb_ack   = wb_cyc & wb_stb;

endmodule

`default_nettype wire
```

---

# 15. `packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/files/sdram_ctrl.sdc`

```tcl
# Placeholder SDC for sdram_ctrl vendor pack fixture
create_clock -name sdram_clk -period 20.000 [get_ports SYS_CLK]
```

---

# 16. úprava `tests/golden/fixtures/vendor_sdram_soc/project.yaml`

Teraz z neho sprav bus-aware fixture.

## nahradiť týmto

```yaml
version: 2
kind: project

project:
  name: vendor_sdram_soc
  mode: soc
  board: qmtech_ep4ce55
  output_dir: build/gen
  debug: true

registries:
  packs:
    - packs/builtin
    - packs/vendor-intel
  ip: []
  cpu:
    - tests/golden/fixtures/vendor_sdram_soc/ip

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

buses:
  - name: main
    protocol: simple_bus
    addr_width: 32
    data_width: 32

cpu:
  instance: cpu0
  type: dummy_cpu
  fabric: main
  reset_vector: 0

modules:
  - instance: sdram0
    type: sdram_ctrl
    bus:
      fabric: main
      base: 2147483648   # 0x80000000
      size: 16777216     # 0x01000000
    clocks:
      clk: sys_clk
    bind:
      ports:
        zs_addr:
          target: board:external.sdram.addr
        zs_ba:
          target: board:external.sdram.ba
        zs_dq:
          target: board:external.sdram.dq
        zs_dqm:
          target: board:external.sdram.dqm
        zs_cs_n:
          target: board:external.sdram.cs_n
        zs_we_n:
          target: board:external.sdram.we_n
        zs_ras_n:
          target: board:external.sdram.ras_n
        zs_cas_n:
          target: board:external.sdram.cas_n
        zs_cke:
          target: board:external.sdram.cke
        zs_clk:
          target: board:external.sdram.clk
```

---

# 17. `socfw/validate/rules/bridge_rules.py`

Toto je hlavný nový rule súbor commitu.

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class MissingBridgeRule(ValidationRule):
    """
    Phase-1 bridge validation:
    - if module bus fabric protocol != module slave interface protocol
    - and no bridge registry exists yet
    - emit an error
    """

    def validate(self, system) -> list:
        diags = []

        for idx, mod in enumerate(system.project.modules):
            if mod.bus is None:
                continue

            fabric = system.project.fabric_by_name(mod.bus.fabric)
            if fabric is None:
                diags.append(
                    Diagnostic(
                        code="BUS001",
                        severity=Severity.ERROR,
                        message=f"Unknown fabric '{mod.bus.fabric}' for module '{mod.instance}'",
                        subject="project.modules.bus",
                        file=system.sources.project_file,
                        path=f"modules[{idx}].bus.fabric",
                        hints=("Define the fabric in project.buses.",),
                    )
                )
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            iface = ip.slave_bus_interface()
            if iface is None:
                if ip.needs_bus:
                    diags.append(
                        Diagnostic(
                            code="BUS002",
                            severity=Severity.ERROR,
                            message=f"IP '{ip.name}' requires a bus but declares no slave bus interface",
                            subject="ip.bus_interfaces",
                            file=system.sources.project_file,
                            path=f"modules[{idx}]",
                        )
                    )
                continue

            if iface.protocol != fabric.protocol:
                diags.append(
                    Diagnostic(
                        code="BRG001",
                        severity=Severity.ERROR,
                        message=(
                            f"No bridge registered for fabric protocol '{fabric.protocol}' "
                            f"to peripheral protocol '{iface.protocol}'"
                        ),
                        subject="project.modules.bus",
                        file=system.sources.project_file,
                        path=f"modules[{idx}].bus",
                        hints=(
                            "Add a bridge planner/adapter for this protocol pair.",
                            "Or change the module interface protocol to match the selected fabric.",
                        ),
                    )
                )

        return diags
```

### prečo takto

Toto je jednoduché, ale veľmi praktické:

* zachytí chýbajúci bridge
* zachytí unknown fabric
* zachytí IP, ktoré potrebuje bus, ale nemá interface

Na tento commit ideálne.

---

# 18. úprava `socfw/validate/runner.py`

Pridaj nový rule.

## nahradiť týmto

```python
from __future__ import annotations

from socfw.validate.rules.bridge_rules import MissingBridgeRule
from socfw.validate.rules.cpu_rules import CpuMissingBusMasterWarningRule, UnknownCpuTypeRule
from socfw.validate.rules.ip_rules import UnknownIpTypeRule
from socfw.validate.rules.project_rules import DuplicateModuleInstanceRule, EmptyProjectWarningRule


class ValidationRunner:
    def __init__(self) -> None:
        self.rules = [
            EmptyProjectWarningRule(),
            DuplicateModuleInstanceRule(),
            UnknownCpuTypeRule(),
            CpuMissingBusMasterWarningRule(),
            UnknownIpTypeRule(),
            MissingBridgeRule(),
        ]

    def run(self, system) -> list:
        diags = []
        for rule in self.rules:
            diags.extend(rule.validate(system))
        return diags
```

---

# 19. `tests/unit/test_bridge_validation_rule.py`

Tento test izoluje nový rule.

```python
from socfw.model.board import BoardClock, BoardModel
from socfw.model.bus import BusFabric, IpBusInterface, ModuleBusAttachment
from socfw.model.cpu import CpuBusMasterDesc, CpuDescriptor
from socfw.model.ip import IpDescriptor
from socfw.model.project import ProjectCpu, ProjectModel, ProjectModule
from socfw.model.source_context import SourceContext
from socfw.model.system import SystemModel
from socfw.validate.rules.bridge_rules import MissingBridgeRule


def test_missing_bridge_rule_reports_protocol_mismatch():
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
            cpu=ProjectCpu(instance="cpu0", type_name="dummy_cpu", fabric="main"),
            modules=[
                ProjectModule(
                    instance="sdram0",
                    type_name="sdram_ctrl",
                    bus=ModuleBusAttachment(fabric="main", base=0x80000000, size=0x01000000),
                )
            ],
        ),
        ip_catalog={
            "sdram_ctrl": IpDescriptor(
                name="sdram_ctrl",
                module="sdram_ctrl",
                category="memory",
                needs_bus=True,
                bus_interfaces=(
                    IpBusInterface(
                        port_name="wb",
                        protocol="wishbone",
                        role="slave",
                    ),
                ),
            )
        },
        cpu_catalog={
            "dummy_cpu": CpuDescriptor(
                name="dummy_cpu",
                module="dummy_cpu",
                family="test",
                bus_master=CpuBusMasterDesc(port_name="bus", protocol="simple_bus"),
            )
        },
        sources=SourceContext(project_file="project.yaml"),
    )

    diags = MissingBridgeRule().validate(system)
    assert any(d.code == "BRG001" for d in diags)
```

---

# 20. `tests/integration/test_validate_vendor_sdram_soc_missing_bridge.py`

Toto je hlavný integration test commitu.

```python
from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_vendor_sdram_soc_reports_missing_bridge():
    result = FullBuildPipeline().validate("tests/golden/fixtures/vendor_sdram_soc/project.yaml")

    assert not result.ok
    codes = {d.code for d in result.diagnostics}
    assert "BRG001" in codes
```

### prečo error a nie green

Lebo na tomto commite ešte bridge neexistuje.
A to je v poriadku.
Správne správanie je:

* fixture je modelovo správny
* ale validate ho zastaví na chýbajúcom bridge

To je presne to, čo chceš.

---

# 21. Voliteľná drobná úprava `socfw/model/system.py`

Nemusí byť, ale môže sa hodiť helper:

```python
    def ip_desc(self, type_name: str):
        return self.ip_catalog.get(type_name)
```

Nie je nutný, len komfortný.

---

# 22. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* bridge planner registry
* bridge RTL
* wishbone interface model
* build test pre `vendor_sdram_soc`
* `QIP_FILE` assertion pre SDRAM
* golden snapshoty pre SDRAM fixture

Commit 17 má vyriešiť len:

* vendor SDRAM descriptor
* bus-aware fixture
* správnu bridge validation chybu

To je správny scope.

---

# 23. Čo po Commite 17 overiť

Spusti:

```bash
pip install -e .
socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml
pytest tests/unit/test_bridge_validation_rule.py
pytest tests/integration/test_validate_vendor_sdram_soc_missing_bridge.py
```

### očakávanie

* validate je **red správnym spôsobom**
* chyba je `BRG001`
* vendor SDRAM descriptor sa resolve-ne
* fabric/model je už pripravený na ďalší commit

To je veľmi dobrý checkpoint.

---

# 24. Definition of Done pre Commit 17

Commit 17 je hotový, keď:

* `sdram_ctrl` descriptor existuje vo vendor packu
* fixture obsahuje `buses` a modulový `bus`
* validation správne nahlási `BRG001`
* unit + integration testy na bridge validation sú green

To je správny prechod medzi:

* “SDRAM scaffold exists”
  a
* “SDRAM build path is implementable”

---

# 25. Čo má byť Commit 18

Po tomto by som išiel priamo na:

## Commit 18

```text
bridge: add simple_bus->wishbone bridge planner model and allow vendor_sdram_soc validation to pass
```

Ten prinesie:

* bridge planner registry alebo aspoň minimálny bridge compatibility model
* `simple_bus -> wishbone` support
* `vendor_sdram_soc` validate green

Ešte stále nemusí buildiť, ale validate už prejde.

To je ďalší prirodzený krok.

---

# 26. Môj praktický odporúčaný rytmus

Po Commite 17:

1. potvrď, že `BRG001` je pravdivý a stabilný
2. nechaj tento commit ako “red-but-correct” checkpoint
3. až potom pridaj bridge support
4. až následne rieš RTL/build pre SDRAM

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 18 ako file-by-file scaffold: `simple_bus -> wishbone` bridge compatibility model + validate green pre `vendor_sdram_soc`**
