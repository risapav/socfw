Super. Ideme na:

# CPU descriptor systém + prvý softcore integration layer

Cieľ tohto kroku je, aby CPU prestal byť špeciálny objekt priamo v `project.yaml` a stal sa z neho **normálny descriptor/plugin**, podobne ako periférie.

To ti dá:

* jednotný model pre CPU aj periférie,
* menej hardcoded vetiev v loaderi a builderoch,
* jednoduchšiu výmenu CPU jadra,
* cestu k PicoRV32, VexRiscv, neskôr aj multi-core variantom.

---

# 1. Cieľový stav

Namiesto tohto:

```yaml
cpu:
  type: dummy_cpu
  module: dummy_cpu
  clock_port: SYS_CLK
  reset_port: RESET_N
  bus_master_port: bus
  bus_protocol: simple_bus
  params: {}
```

chceme toto:

```yaml
cpu:
  instance: cpu0
  type: picorv32_min
  fabric: main
  reset_vector: 0x00000000
  params:
    ENABLE_IRQ: true
```

A descriptor `picorv32_min.cpu.yaml` povie:

* aký HDL modul sa inštanciuje,
* aké porty má clock/reset,
* aký bus master port má,
* aký IRQ port má,
* aké default parametre vie podporiť.

---

# 2. Nový CPU descriptor model

## `socfw/model/cpu_desc.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class CpuBusMasterDesc:
    port_name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


@dataclass(frozen=True)
class CpuDescriptor:
    name: str
    module: str
    family: str                    # riscv32, rv32im, ...
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master: CpuBusMasterDesc | None = None
    default_params: dict[str, Any] = field(default_factory=dict)
    artifacts: tuple[str, ...] = ()
    meta: dict[str, Any] = field(default_factory=dict)
```

---

# 3. Runtime CPU instance model

## `socfw/model/cpu.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass
class CpuInstance:
    instance: str
    type_name: str
    fabric: str
    reset_vector: int
    params: dict[str, Any] = field(default_factory=dict)
```

Týmto rozdelíš:

* **descriptor** = čo CPU je,
* **instance** = ako je použitý v projekte.

---

# 4. Project schema update

## `socfw/config/project_schema.py`

Nahraď starý `CpuSchema` týmto:

```python
class CpuInstanceSchema(BaseModel):
    instance: str = "cpu0"
    type: str
    fabric: str
    reset_vector: int = 0
    params: dict[str, Any] = Field(default_factory=dict)
```

A v `ProjectConfigSchema`:

```python
    cpu: CpuInstanceSchema | None = None
```

---

# 5. CPU descriptor schema

## `socfw/config/cpu_schema.py`

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class CpuBusMasterSchema(BaseModel):
    port_name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32


class CpuDescriptorMetaSchema(BaseModel):
    name: str
    module: str
    family: str


class CpuDescriptorSchema(BaseModel):
    version: Literal[2]
    kind: Literal["cpu"]
    cpu: CpuDescriptorMetaSchema
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master: CpuBusMasterSchema | None = None
    default_params: dict = Field(default_factory=dict)
    artifacts: list[str] = Field(default_factory=list)
    notes: list[str] = Field(default_factory=list)
```

---

# 6. CPU loader

## `socfw/config/cpu_loader.py`

```python
from __future__ import annotations

from pathlib import Path

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.cpu_schema import CpuDescriptorSchema
from socfw.core.diagnostics import Diagnostic, Severity, SourceRef
from socfw.core.result import Result
from socfw.model.cpu_desc import CpuBusMasterDesc, CpuDescriptor


class CpuLoader:
    def load_file(self, path: str) -> Result[CpuDescriptor]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = CpuDescriptorSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="CPU100",
                    severity=Severity.ERROR,
                    message=f"Invalid CPU YAML: {exc}",
                    subject="cpu",
                    refs=(SourceRef(file=path),),
                )
            ])

        desc = CpuDescriptor(
            name=doc.cpu.name,
            module=doc.cpu.module,
            family=doc.cpu.family,
            clock_port=doc.clock_port,
            reset_port=doc.reset_port,
            irq_port=doc.irq_port,
            bus_master=(
                CpuBusMasterDesc(
                    port_name=doc.bus_master.port_name,
                    protocol=doc.bus_master.protocol,
                    addr_width=doc.bus_master.addr_width,
                    data_width=doc.bus_master.data_width,
                )
                if doc.bus_master else None
            ),
            default_params=dict(doc.default_params),
            artifacts=tuple(doc.artifacts),
            meta={"notes": doc.notes},
        )

        return Result(value=desc)

    def load_catalog(self, search_dirs: list[str]) -> Result[dict[str, CpuDescriptor]]:
        catalog: dict[str, CpuDescriptor] = {}
        diags: list[Diagnostic] = []

        for root in search_dirs:
            p = Path(root)
            if not p.exists():
                continue

            for fp in sorted(p.rglob("*.cpu.yaml")):
                res = self.load_file(str(fp))
                diags.extend(res.diagnostics)
                if res.ok and res.value is not None:
                    if res.value.name in catalog:
                        diags.append(Diagnostic(
                            code="CPU101",
                            severity=Severity.ERROR,
                            message=f"Duplicate CPU descriptor '{res.value.name}'",
                            subject="cpu.registry",
                            refs=(SourceRef(file=str(fp)),),
                        ))
                    else:
                        catalog[res.value.name] = res.value

        return Result(value=catalog, diagnostics=diags)
```

---

# 7. System model update

## `socfw/model/system.py`

Rozšír:

```python
from dataclasses import dataclass, field

from .board import BoardModel
from .cpu import CpuInstance
from .cpu_desc import CpuDescriptor
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
    cpu_catalog: dict[str, CpuDescriptor] = field(default_factory=dict)

    cpu: CpuInstance | None = None
    ram: RamModel | None = None
    reset_vector: int = 0
    stack_percent: int = 25
    peripheral_blocks: list[PeripheralAddressBlock] = field(default_factory=list)

    def cpu_desc(self) -> CpuDescriptor | None:
        if self.cpu is None:
            return None
        return self.cpu_catalog.get(self.cpu.type_name)
```

---

# 8. Project loader update

## `socfw/config/project_loader.py`

Namiesto starého `CpuModel` vracaj `CpuInstance`:

```python
from socfw.model.cpu import CpuInstance
```

A v `load()`:

```python
        cpu = None
        if doc.cpu is not None:
            cpu = CpuInstance(
                instance=doc.cpu.instance,
                type_name=doc.cpu.type,
                fabric=doc.cpu.fabric,
                reset_vector=doc.cpu.reset_vector,
                params=doc.cpu.params,
            )
```

---

# 9. System loader update

## `socfw/config/system_loader.py`

Pridaj import:

```python
from socfw.config.cpu_loader import CpuLoader
```

V `__init__`:

```python
        self.cpu_loader = CpuLoader()
```

Pri načítaní registry paths použi rovnaké `registries.ip` aj pre CPU, alebo zaveď `registries.cpu`. Pre prvý krok stačí zdieľať cestu:

```python
        cpu_catalog_res = self.cpu_loader.load_catalog(project.registries_ip)
        diags.extend(cpu_catalog_res.diagnostics)
        if not cpu_catalog_res.ok or cpu_catalog_res.value is None:
            return Result(diagnostics=diags)
```

A do `SystemModel(...)`:

```python
        system = SystemModel(
            board=board_res.value,
            project=project,
            timing=timing,
            ip_catalog=catalog_res.value,
            cpu_catalog=cpu_catalog_res.value,
            cpu=cpu,
            ram=ram,
            reset_vector=reset_vector,
            stack_percent=stack_percent,
        )
```

---

# 10. Validation rules pre CPU

## nový `socfw/validate/rules/cpu_rules.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class UnknownCpuTypeRule(ValidationRule):
    def validate(self, system) -> list[Diagnostic]:
        if system.cpu is None:
            return []

        if system.cpu.type_name not in system.cpu_catalog:
            return [
                Diagnostic(
                    code="CPU001",
                    severity=Severity.ERROR,
                    message=f"Unknown CPU type '{system.cpu.type_name}'",
                    subject="project.cpu",
                )
            ]
        return []


class UnknownCpuFabricRule(ValidationRule):
    def validate(self, system) -> list[Diagnostic]:
        if system.cpu is None:
            return []

        if system.project.fabric_by_name(system.cpu.fabric) is None:
            return [
                Diagnostic(
                    code="CPU002",
                    severity=Severity.ERROR,
                    message=f"CPU references unknown fabric '{system.cpu.fabric}'",
                    subject="project.cpu.fabric",
                )
            ]
        return []


class CpuDescriptorBusMissingRule(ValidationRule):
    def validate(self, system) -> list[Diagnostic]:
        if system.cpu is None:
            return []

        desc = system.cpu_desc()
        if desc is None:
            return []

        if desc.bus_master is None:
            return [
                Diagnostic(
                    code="CPU003",
                    severity=Severity.ERROR,
                    message=f"CPU '{system.cpu.type_name}' has no bus_master descriptor",
                    subject="cpu.descriptor",
                )
            ]
        return []
```

## `socfw/plugins/bootstrap.py`

Doplň:

```python
from socfw.validate.rules.cpu_rules import (
    CpuDescriptorBusMissingRule,
    UnknownCpuFabricRule,
    UnknownCpuTypeRule,
)
```

A registráciu:

```python
    reg.register_validator(UnknownCpuTypeRule())
    reg.register_validator(UnknownCpuFabricRule())
    reg.register_validator(CpuDescriptorBusMissingRule())
```

---

# 11. Simple bus planner update

## `socfw/plugins/simple_bus/planner.py`

Použi descriptor namiesto inline CPU definície:

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

# 12. RTL builder update

## `socfw/builders/rtl_ir_builder.py`

CPU instance časť uprav takto:

```python
        cpu_desc = system.cpu_desc()
        if system.cpu is not None and cpu_desc is not None:
            cpu_params = dict(cpu_desc.default_params)
            cpu_params.update(system.cpu.params)

            cpu_conns = [
                RtlConn(port=cpu_desc.clock_port, signal=BOARD_CLOCK),
                RtlConn(port=cpu_desc.reset_port, signal=BOARD_RESET),
            ]

            cpu_bus_conns = []
            if cpu_desc.bus_master is not None and design.interconnect is not None:
                for fabric_name, endpoints in design.interconnect.fabrics.items():
                    for ep in endpoints:
                        if ep.instance == system.cpu.instance:
                            cpu_bus_conns.append(
                                RtlBusConn(
                                    port=cpu_desc.bus_master.port_name,
                                    interface_name=f"if_{ep.instance}_{fabric_name}",
                                    modport="master",
                                )
                            )

            rtl.instances.append(
                RtlInstance(
                    module=cpu_desc.module,
                    name=system.cpu.instance,
                    params=cpu_params,
                    conns=cpu_conns,
                    bus_conns=cpu_bus_conns,
                    comment=system.cpu.type_name,
                )
            )

            for art in cpu_desc.artifacts:
                if art not in rtl.extra_sources:
                    rtl.extra_sources.append(art)
```

A IRQ port pripájaj cez descriptor:

```python
        if rtl.irq_combiner is not None and system.cpu is not None and cpu_desc is not None and cpu_desc.irq_port:
            for inst in rtl.instances:
                if inst.name == system.cpu.instance:
                    inst.conns.append(
                        RtlConn(
                            port=cpu_desc.irq_port,
                            signal=rtl.irq_combiner.cpu_irq_signal,
                        )
                    )
```

---

# 13. CPU descriptor example: dummy CPU

## `tests/golden/fixtures/soc_led_test/ip/dummy_cpu.cpu.yaml`

```yaml
version: 2
kind: cpu

cpu:
  name: dummy_cpu
  module: dummy_cpu
  family: riscv32

clock_port: SYS_CLK
reset_port: RESET_N
irq_port: irq

bus_master:
  port_name: bus
  protocol: simple_bus
  addr_width: 32
  data_width: 32

default_params: {}

artifacts:
  - tests/golden/fixtures/soc_led_test/rtl/dummy_cpu.sv

notes:
  - Minimal demo CPU descriptor
```

---

# 14. Project fixture update

## `tests/golden/fixtures/soc_led_test/project.yaml`

CPU sekcia sa zmení na:

```yaml
cpu:
  instance: cpu0
  type: dummy_cpu
  fabric: main
  reset_vector: 0x00000000
  params: {}
```

---

# 15. Dôležitý výsledok

Po tomto kroku už CPU:

* nie je hardcoded runtime object s HDL detailmi,
* ale **plnohodnotný descriptor-driven komponent**.

To znamená, že pridať ďalší CPU bude znamenať:

* nový `*.cpu.yaml`
* nový HDL source
* bez zásahu do loadera/plannera/buildera

To je presne architektúra, ktorú chceš.

---

# 16. Prvý “real” CPU descriptor, ktorý dáva zmysel

Hneď po tomto môžeš spraviť:

## PicoRV32 descriptor

```yaml
version: 2
kind: cpu

cpu:
  name: picorv32_min
  module: picorv32
  family: riscv32

clock_port: clk
reset_port: resetn
irq_port: irq

bus_master:
  port_name: bus
  protocol: simple_bus
  addr_width: 32
  data_width: 32

default_params:
  ENABLE_IRQ: true
  ENABLE_COUNTERS: false
  PROGADDR_RESET: 0x00000000

artifacts:
  - rtl/picorv32_wrapper.sv
  - vendor/picorv32.v
```

V praxi by si nad čistým PicoRV32 pravdepodobne urobil wrapper, ktorý ho premapuje na `simple_bus`.

---

# 17. Čo by som spravil hneď potom

Teraz sú dve veľmi dobré možnosti:

### A) PicoRV32 wrapper + real firmware flow

* `picorv32_wrapper.sv`
* ELF/BIN/HEX
* boot into RAM
* reálne rozsvietenie LED

### B) bus adapters

* AXI-lite → simple_bus
* Wishbone → simple_bus

Môj praktický odporúčaný ďalší krok je:

👉 **A — PicoRV32 wrapper + real firmware flow**

Lebo tým dostaneš prvý reálny “živý” SoC, nie len demo CPU. A framework sa tým okamžite stane oveľa presvedčivejší.

Ak chceš, ďalšia správa môže byť presne:
**PicoRV32/simple_bus wrapper + firmware build flow + bin/hex integration**
