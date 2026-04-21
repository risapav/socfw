Super. Toto je ďalší logický krok: **CPU/RAM/boot-image layer**.

Práve týmto sa nový framework zmení z „config-driven top generatora“ na skutočný SoC build systém. Doteraz sme pripravili:

* board/project/timing/IP model,
* validation,
* elaboration,
* bus layer,
* RTL/timing/board/software/docs emitre.

Teraz doplníme:

* **CPU model**
* **RAM model**
* **master endpoint pre fabric**
* **boot/init image flow**
* **napojenie na `simple_bus_fabric`**
* **software image artifacts**

To zároveň nahradí staré implicitné väzby v `rtl.py`, `sw.py` a `bin2hex.py` čistejším vrstvením. Starý framework už má dobré stavebné kamene: SW generátor pracuje s RAM base/size/reset vector a linker scriptom, a `bin2hex.py` rieši image → hex pre `$readmemh`.   

Nižšie je refaktorovaný návrh.

---

# 1. CPU a RAM modely

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
    bus_master: CpuBusMaster | None = None
    irq_port: str | None = None
```

---

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

---

# 2. System model update

## `socfw/model/system.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field

from .addressing import PeripheralAddressBlock
from .board import BoardModel
from .cpu import CpuModel
from .memory import RamModel
from .project import ProjectModel
from .timing import TimingModel
from .ip import IpDescriptor


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None
    ip_catalog: dict[str, IpDescriptor]

    cpu: CpuModel | None = None
    ram: RamModel | None = None

    reset_vector: int = 0x00000000
    stack_percent: int = 25
    peripheral_blocks: list[PeripheralAddressBlock] = field(default_factory=list)

    @property
    def ram_base(self) -> int:
        return 0 if self.ram is None else self.ram.base

    @property
    def ram_size(self) -> int:
        return 0 if self.ram is None else self.ram.size

    @property
    def cpu_type(self) -> str:
        return "none" if self.cpu is None else self.cpu.cpu_type

    def validate(self) -> list[str]:
        errs: list[str] = []
        errs.extend(self.board.validate())
        errs.extend(self.project.validate())
        if self.timing:
            errs.extend(self.timing.validate())
        for ip in self.ip_catalog.values():
            errs.extend(ip.validate())

        if self.ram is not None and self.reset_vector < self.ram.base:
            errs.append(
                f"reset_vector 0x{self.reset_vector:08X} is below RAM base 0x{self.ram.base:08X}"
            )

        if self.ram is not None and self.reset_vector > self.ram.base + self.ram.size - 1:
            errs.append(
                f"reset_vector 0x{self.reset_vector:08X} is outside RAM range"
            )

        seen_regions: list[tuple[str, int, int]] = []
        if self.ram is not None:
            seen_regions.append(("RAM", self.ram.base, self.ram.base + self.ram.size - 1))

        for p in self.peripheral_blocks:
            for other_name, other_base, other_end in seen_regions:
                if not (p.end < other_base or other_end < p.base):
                    errs.append(
                        f"Address overlap between '{p.instance}' "
                        f"(0x{p.base:08X}-0x{p.end:08X}) and '{other_name}' "
                        f"(0x{other_base:08X}-0x{other_end:08X})"
                    )
            seen_regions.append((p.instance, p.base, p.end))

        return errs
```

---

# 3. Project schema doplnenie o CPU/RAM

## `socfw/config/project_schema.py`

Doplnenie:

```python
class CpuSchema(BaseModel):
    type: str
    module: str
    params: dict[str, Any] = Field(default_factory=dict)
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master_port: str | None = None
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
    modules: list[ModuleSchema] = Field(default_factory=list)
    timing: TimingRefSchema | None = None
    artifacts: ArtifactsSchema = Field(default_factory=ArtifactsSchema)
```

---

## `socfw/config/project_loader.py`

Doplnenie:

```python
from socfw.model.cpu import CpuBusMaster, CpuModel
from socfw.model.memory import RamModel
```

A pri vytvorení modelu:

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
                bus_master=(
                    CpuBusMaster(
                        port_name=doc.cpu.bus_master_port,
                        protocol=doc.cpu.bus_protocol,
                        addr_width=doc.cpu.addr_width,
                        data_width=doc.cpu.data_width,
                    )
                    if doc.cpu.bus_master_port
                    else None
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

        # return value no longer ProjectModel only
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
            bus_fabrics=[],
        )

        return Result(
            value={
                "project": model,
                "cpu": cpu,
                "ram": ram,
                "reset_vector": doc.boot.reset_vector,
                "stack_percent": doc.boot.stack_percent,
            }
        )
```

Keďže sa tým mení návratový typ, upraví sa aj `SystemLoader`.

---

## `socfw/config/system_loader.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.config.board_loader import BoardLoader
from socfw.config.ip_loader import IpLoader
from socfw.config.project_loader import ProjectLoader
from socfw.config.timing_loader import TimingLoader
from socfw.core.diagnostics import Diagnostic, Severity, SourceRef
from socfw.core.result import Result
from socfw.model.system import SystemModel


class SystemLoader:
    def __init__(self) -> None:
        self.board_loader = BoardLoader()
        self.project_loader = ProjectLoader()
        self.timing_loader = TimingLoader()
        self.ip_loader = IpLoader()

    def load(self, project_file: str) -> Result[SystemModel]:
        diags: list[Diagnostic] = []

        prj_res = self.project_loader.load(project_file)
        diags.extend(prj_res.diagnostics)
        if not prj_res.ok or prj_res.value is None:
            return Result(diagnostics=diags)

        prj_bundle = prj_res.value
        project = prj_bundle["project"]
        cpu = prj_bundle["cpu"]
        ram = prj_bundle["ram"]
        reset_vector = prj_bundle["reset_vector"]
        stack_percent = prj_bundle["stack_percent"]

        if not project.board_file:
            return Result(
                diagnostics=diags + [
                    Diagnostic(
                        code="SYS100",
                        severity=Severity.ERROR,
                        message="project.board_file is required in this minimal loader",
                        subject="project.board_file",
                        refs=(SourceRef(file=project_file),),
                    )
                ]
            )

        board_res = self.board_loader.load(project.board_file)
        diags.extend(board_res.diagnostics)
        if not board_res.ok or board_res.value is None:
            return Result(diagnostics=diags)

        catalog_res = self.ip_loader.load_catalog(project.registries_ip)
        diags.extend(catalog_res.diagnostics)
        if not catalog_res.ok or catalog_res.value is None:
            return Result(diagnostics=diags)

        timing = None
        if project.timing_file:
            timing_path = Path(project_file).parent / project.timing_file
            tim_res = self.timing_loader.load(str(timing_path))
            diags.extend(tim_res.diagnostics)
            if not tim_res.ok:
                return Result(diagnostics=diags)
            timing = tim_res.value

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

        return Result(value=system, diagnostics=diags)
```

---

# 4. CPU master endpoint planner

CPU musí byť prvotriedny master endpoint, nie „extra context pre template“.

## `socfw/plugins/simple_bus/cpu_endpoint.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import ResolvedBusEndpoint
from socfw.model.system import SystemModel


class CpuMasterEndpointBuilder:
    def build(self, system: SystemModel, fabric_name: str) -> ResolvedBusEndpoint | None:
        if system.cpu is None or system.cpu.bus_master is None:
            return None

        return ResolvedBusEndpoint(
            instance="cpu",
            module_type=system.cpu.cpu_type,
            fabric=fabric_name,
            protocol=system.cpu.bus_master.protocol,
            role="master",
            port_name=system.cpu.bus_master.port_name,
            addr_width=system.cpu.bus_master.addr_width,
            data_width=system.cpu.bus_master.data_width,
            base=None,
            size=None,
            end=None,
        )
```

---

## `socfw/plugins/simple_bus/planner.py`

Update planneru, aby pridal CPU master:

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan, ResolvedBusEndpoint
from socfw.model.system import SystemModel
from socfw.plugins.bus_api import BusPlanner
from socfw.plugins.simple_bus.cpu_endpoint import CpuMasterEndpointBuilder


class SimpleBusPlanner(BusPlanner):
    protocol = "simple_bus"

    def __init__(self) -> None:
        self.cpu_builder = CpuMasterEndpointBuilder()

    def plan(self, system: SystemModel) -> InterconnectPlan:
        plan = InterconnectPlan()

        for fabric in system.project.bus_fabrics:
            if fabric.protocol != self.protocol:
                continue

            endpoints: list[ResolvedBusEndpoint] = []

            cpu_ep = self.cpu_builder.build(system, fabric.name)
            if cpu_ep is not None:
                endpoints.append(cpu_ep)

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

---

# 5. RAM ako address-space región

RAM nemusí byť nutne bus slave IP descriptor; pre prvý slice je úplne v poriadku modelovať ju ako natívny system memory region.

## `socfw/builders/address_map_builder.py`

Update:

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

RAM sa do SW/docs dostáva cez `SystemModel.ram`, takže netreba ju siliť do `peripheral_blocks`.

---

# 6. Boot image model

## `socfw/model/image.py`

```python
from __future__ import annotations
from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True)
class BootImage:
    input_file: str
    output_file: str
    input_format: Literal["bin", "elf", "hex"] = "bin"
    output_format: Literal["hex", "mif"] = "hex"
    size_bytes: int = 0
    endian: Literal["little", "big"] = "little"
```

---

## `socfw/builders/boot_image_builder.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.model.image import BootImage
from socfw.model.system import SystemModel


class BootImageBuilder:
    def build(self, system: SystemModel, out_dir: str) -> BootImage | None:
        if system.ram is None:
            return None
        if not system.ram.init_file:
            return None

        input_file = system.ram.init_file
        output_file = str(Path(out_dir) / "sw" / "software.hex")

        return BootImage(
            input_file=input_file,
            output_file=output_file,
            input_format="bin" if input_file.endswith(".bin") else "hex",
            output_format=system.ram.image_format,
            size_bytes=system.ram.size,
            endian="little",
        )
```

---

# 7. Image conversion tool wrapper

Starý `bin2hex.py` je funkčne v poriadku ako utilita; čo mu chýba je zapojenie do nového pipeline kontraktu. 

## `socfw/tools/bin2hex_runner.py`

```python
from __future__ import annotations

import subprocess
import sys

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.image import BootImage


class Bin2HexRunner:
    def __init__(self, tool_path: str = "bin2hex.py") -> None:
        self.tool_path = tool_path

    def run(self, image: BootImage) -> Result[str]:
        if image.input_format != "bin" or image.output_format != "hex":
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="IMG001",
                        severity=Severity.ERROR,
                        message=(
                            f"Unsupported image conversion: {image.input_format} -> {image.output_format}"
                        ),
                        subject="boot_image",
                    )
                ]
            )

        cmd = [
            sys.executable,
            self.tool_path,
            image.input_file,
            image.output_file,
            hex(image.size_bytes),
        ]
        if image.endian == "big":
            cmd.append("--big")

        try:
            subprocess.run(cmd, check=True)
        except subprocess.CalledProcessError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="IMG002",
                        severity=Severity.ERROR,
                        message=f"bin2hex failed: {exc}",
                        subject="boot_image",
                    )
                ]
            )

        return Result(value=image.output_file)
```

---

# 8. Napojenie RAM init file na RTL

RAM init súbor musí skončiť v RTL.

Najčistejšie je spraviť špeciálnu RAM inštanciu v `RtlIRBuilder`.

## update `socfw/builders/rtl_ir_builder.py`

Do `build()` doplniť pred loop cez moduly:

```python
        # Optional RAM instance
        if system.ram is not None:
            ram_conns = [
                RtlConn(port="SYS_CLK", signal=BOARD_CLOCK),
                RtlConn(port="RESET_N", signal=BOARD_RESET),
            ]

            # CPU/fabric hookup will be refined later; for now RAM is emitted as a
            # standalone memory primitive in SoC mode only when a corresponding module exists.
            rtl.instances.append(
                RtlInstance(
                    module=system.ram.module,
                    name="ram",
                    params={
                        "RAM_BYTES": system.ram.size,
                        "INIT_FILE": system.ram.init_file or "",
                    },
                    conns=ram_conns,
                    comment=f"RAM @ 0x{system.ram.base:08X}",
                )
            )
```

To je zatiaľ jednoduché; ďalší krok je plnohodnotné RAM slave napojenie na fabric.

---

# 9. CPU instance v RTL

Rovnako CPU musí byť explicitná instance, nie legacy template doplnok.

## update `socfw/builders/rtl_ir_builder.py`

Pred loop cez project modules doplniť:

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
```

Teraz už CPU nie je hidden context, ale normálna IR instance.

---

# 10. CPU endpoint interface creation

`RtlBusBuilder` už generuje interface per endpoint, takže `cpu` sa vytvorí automaticky, keď planner vráti `instance="cpu"`.

---

# 11. SoftwareIR už vie počítať RAM z `SystemModel.ram`

V `SoftwareIRBuilder` je to už hotové, lebo číta `system.ram`. Tým sa prirodzene nahrádza stará väzba na `m.ram_base`, `m.ram_size`, `m.reset_vector`, `m.stack_percent` v `SWGenerator`. 

---

# 12. Example CPU/RAM config v projekte

Aby bolo jasné, ako to sedí na YAML:

```yaml
cpu:
  type: picorv32
  module: picorv32
  bus_master_port: bus
  bus_protocol: simple_bus
  clock_port: clk
  reset_port: resetn
  irq_port: irq
  params:
    ENABLE_IRQ: true
    PROGADDR_RESET: 0x00000000

ram:
  module: soc_ram
  base: 0x00000000
  size: 65536
  latency: registered
  init_file: build/sw/firmware.bin
  image_format: hex

boot:
  reset_vector: 0x00000000
  stack_percent: 25
```

A `project.bus_fabrics` by obsahoval napríklad:

```yaml
buses:
  - name: main
    protocol: simple_bus
```

Na to by ešte bolo treba doplniť schema + loader pre `buses`, ale to je už malý dodatok oproti tomu, čo sme spravili.

---

# 13. Prečo je toto architektonicky dôležité

Týmto sa odstráni ďalší starý problém:

* CPU už nie je „legacy SoC context payload“ v `rtl.py`, ale normálny typed model a IR instance. 
* RAM parametre už nie sú roztrúsené po SW a RTL generátoroch, ale sú v `RamModel` a idú cez build pipeline.  
* image conversion už nie je bokom, ale má miesto v pipeline cez `BootImageBuilder` + runner. 

Toto je presne typ zmeny, ktorý robí framework moderný: z implicitných hodnôt v generátoroch sa stávajú explicitné build artefakty.

---

# 14. Čo ešte chýba, aby CPU/RAM vrstva bola plná

Po tomto kroku ešte chýbajú najmä tri veci:

### 1. skutočné RAM slave napojenie na bus fabric

Zatiaľ je RAM emitovaná ako samostatná instance. Ďalší krok je modelovať RAM ako fabric slave endpoint.

### 2. IRQ aggregation

CPU má `irq_port`, ale ešte nemáme planner/IR pre zber IRQ liniek z periférií.

### 3. ELF → BIN/HEX flow

Zatiaľ riešime len bin → hex wrapper. Neskôr treba aj ELF extraction step.

---

# 15. Môj odporúčaný ďalší krok

Teraz by som išiel týmto smerom:

**IRQ + RAM-as-slave + SoC completion layer**

Konkrétne:

* IRQ planner
* IRQ combiner IR
* RAM ako plnohodnotný `simple_bus` slave
* CPU + RAM + peripherals na jednom fabric
* tým sa uzavrie prvý plný SoC datapath

To je podľa mňa najlepší ďalší krok, lebo bez IRQ a RAM slave ešte SoC vrstva nie je úplná.

V ďalšej správe ti viem pripraviť:
**kompletný refaktorovaný IRQ + RAM slave layer**
vrátane:

* modelov,
* plannerov,
* RTL IR,
* builderov,
* templating doplnkov.
