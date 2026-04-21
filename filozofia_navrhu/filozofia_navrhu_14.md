Super. Poďme uzavrieť ďalší veľký kus: **SW/docs vrstvu**.

Toto je prirodzené pokračovanie, lebo starý framework už mal dobrý základ pre:

* `soc_map.h`,
* linker script,
* markdown memory map/reporting.   

V novom návrhu to spravíme rovnako ako pri RTL/timing:

* **typed IR**
* **builder**
* **emitre**
* **templaty**

A zároveň sa vyhneme dnešnému stavu, kde je SW generovanie ešte naviazané priamo na širší `SoCModel` a nie na vlastný stabilný IR. 

---

# 1. SW + docs IR

## `socfw/ir/software.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class SwRegisterIR:
    peripheral: str
    peripheral_type: str
    name: str
    offset: int
    address: int
    access: str
    width: int
    reset: int = 0
    desc: str = ""


@dataclass(frozen=True)
class SwIrqIR:
    peripheral: str
    name: str
    irq_id: int


@dataclass(frozen=True)
class MemoryRegionIR:
    name: str
    base: int
    size: int
    module: str
    attrs: dict[str, object] = field(default_factory=dict)

    @property
    def end(self) -> int:
        return self.base + self.size - 1


@dataclass
class SoftwareIR:
    board_name: str
    sys_clk_hz: int
    ram_base: int
    ram_size: int
    reset_vector: int
    stack_percent: int
    memory_regions: list[MemoryRegionIR] = field(default_factory=list)
    registers: list[SwRegisterIR] = field(default_factory=list)
    irqs: list[SwIrqIR] = field(default_factory=list)
```

---

## `socfw/ir/docs.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class DocsRegisterIR:
    peripheral: str
    name: str
    offset: int
    access: str
    width: int
    reset: int
    desc: str = ""


@dataclass(frozen=True)
class DocsPeripheralIR:
    instance: str
    module: str
    base: int
    end: int
    size: int
    registers: list[DocsRegisterIR] = field(default_factory=list)
    irq_ids: list[int] = field(default_factory=list)


@dataclass
class DocsIR:
    board_name: str
    clock_hz: int
    ram_base: int
    ram_size: int
    reset_vector: int
    stack_percent: int
    peripherals: list[DocsPeripheralIR] = field(default_factory=list)
```

---

# 2. Adresový priestor a CSR model

Aby bol SW/docs builder použiteľný, potrebujeme explicitný minimálny model pre periférne registre a adresy. Starý framework toto implicitne bral zo `SoCModel.peripherals`, register blocks a mapy adries.  

V novom návrhu to navrhujem takto.

## `socfw/model/addressing.py`

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

    @property
    def address_word_offset(self) -> int:
        return self.offset // 4


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

## `socfw/model/system.py`

Rozšírenie pre SoC-aware build. Toto je update k predošlému `SystemModel`.

```python
from __future__ import annotations
from dataclasses import dataclass, field

from .addressing import PeripheralAddressBlock
from .board import BoardModel
from .project import ProjectModel
from .timing import TimingModel
from .ip import IpDescriptor


@dataclass
class SystemModel:
    board: BoardModel
    project: ProjectModel
    timing: TimingModel | None
    ip_catalog: dict[str, IpDescriptor]

    # SoC/software-facing fields
    ram_base: int = 0x00000000
    ram_size: int = 0
    reset_vector: int = 0x00000000
    stack_percent: int = 25
    cpu_type: str = "none"
    peripheral_blocks: list[PeripheralAddressBlock] = field(default_factory=list)

    def validate(self) -> list[str]:
        errs: list[str] = []
        errs.extend(self.board.validate())
        errs.extend(self.project.validate())
        if self.timing:
            errs.extend(self.timing.validate())
        for ip in self.ip_catalog.values():
            errs.extend(ip.validate())

        seen_regions: list[tuple[str, int, int]] = []
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

# 3. Software IR builder

## `socfw/builders/software_ir_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.software import (
    MemoryRegionIR,
    SoftwareIR,
    SwIrqIR,
    SwRegisterIR,
)


class SoftwareIRBuilder:
    def build(self, design: ElaboratedDesign) -> SoftwareIR | None:
        system = design.system

        if system.ram_size <= 0:
            # Standalone-only designs without SW image can skip software outputs.
            return None

        ir = SoftwareIR(
            board_name=system.board.board_id,
            sys_clk_hz=system.board.sys_clock.frequency_hz,
            ram_base=system.ram_base,
            ram_size=system.ram_size,
            reset_vector=system.reset_vector,
            stack_percent=system.stack_percent,
        )

        ir.memory_regions.append(
            MemoryRegionIR(
                name="RAM",
                base=system.ram_base,
                size=system.ram_size,
                module="soc_ram",
                attrs={},
            )
        )

        for p in system.peripheral_blocks:
            ir.memory_regions.append(
                MemoryRegionIR(
                    name=p.instance,
                    base=p.base,
                    size=p.size,
                    module=p.module,
                    attrs={},
                )
            )

            for r in p.registers:
                ir.registers.append(
                    SwRegisterIR(
                        peripheral=p.instance,
                        peripheral_type=p.module,
                        name=r.name,
                        offset=r.offset,
                        address=p.base + r.offset,
                        access=r.access,
                        width=r.width,
                        reset=r.reset,
                        desc=r.desc,
                    )
                )

            for irq in p.irqs:
                ir.irqs.append(
                    SwIrqIR(
                        peripheral=p.instance,
                        name=irq.name,
                        irq_id=irq.irq_id,
                    )
                )

        return ir
```

Toto je nový typed nástupca logiky, ktorú dnes robí `SWGenerator.generate_soc_map_h()`, `generate_soc_irq_h()` a `generate_soc_map_md()`, ale už bez priamej závislosti na starom širokom modeli. 

---

# 4. Docs IR builder

## `socfw/builders/docs_ir_builder.py`

```python
from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.docs import DocsIR, DocsPeripheralIR, DocsRegisterIR


class DocsIRBuilder:
    def build(self, design: ElaboratedDesign) -> DocsIR | None:
        system = design.system

        if system.ram_size <= 0 and not system.peripheral_blocks:
            return None

        ir = DocsIR(
            board_name=system.board.board_id,
            clock_hz=system.board.sys_clock.frequency_hz,
            ram_base=system.ram_base,
            ram_size=system.ram_size,
            reset_vector=system.reset_vector,
            stack_percent=system.stack_percent,
        )

        for p in system.peripheral_blocks:
            ir.peripherals.append(
                DocsPeripheralIR(
                    instance=p.instance,
                    module=p.module,
                    base=p.base,
                    end=p.end,
                    size=p.size,
                    registers=[
                        DocsRegisterIR(
                            peripheral=p.instance,
                            name=r.name,
                            offset=r.offset,
                            access=r.access,
                            width=r.width,
                            reset=r.reset,
                            desc=r.desc,
                        )
                        for r in p.registers
                    ],
                    irq_ids=[irq.irq_id for irq in p.irqs],
                )
            )

        return ir
```

---

# 5. Register block IR

Keď už máš registre explicitne modelované, register-block generovanie môže mať vlastný malý IR.

## `socfw/ir/register_block.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class RegFieldIR:
    name: str
    offset: int
    width: int
    access: str
    reset: int
    desc: str
    word_addr: int


@dataclass
class RegisterBlockIR:
    module_name: str
    peripheral_instance: str
    base: int
    addr_width: int
    regs: list[RegFieldIR] = field(default_factory=list)
```

---

## `socfw/builders/register_block_ir_builder.py`

```python
from __future__ import annotations

import math

from socfw.ir.register_block import RegFieldIR, RegisterBlockIR
from socfw.model.addressing import PeripheralAddressBlock


class RegisterBlockIRBuilder:
    def build_for_peripheral(self, p: PeripheralAddressBlock) -> RegisterBlockIR | None:
        if not p.registers:
            return None

        word_count = max((r.offset // 4) for r in p.registers) + 1
        addr_width = max(1, math.ceil(math.log2(word_count)))

        return RegisterBlockIR(
            module_name=f"{p.module}_regs",
            peripheral_instance=p.instance,
            base=p.base,
            addr_width=addr_width,
            regs=[
                RegFieldIR(
                    name=r.name,
                    offset=r.offset,
                    width=r.width,
                    access=r.access,
                    reset=r.reset,
                    desc=r.desc,
                    word_addr=r.address_word_offset,
                )
                for r in p.registers
            ],
        )
```

Toto je priamy nástupca starého `periph_regs`/`reg_block` templatingu, ale s explicitným IR pred renderom. Zároveň tým obchádzame dnešný konkrétny bug v `rtl.py`, kde sa volá neexistujúca šablóna `periph_regs.sv.j2` namiesto dostupného `reg_block.sv.j2`.  

---

# 6. SW emitre

## `socfw/emit/software_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.software import SoftwareIR


class SoftwareEmitter:
    family = "software"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx: BuildContext, ir: SoftwareIR) -> list[GeneratedArtifact]:
        out_dir = Path(ctx.out_dir) / "sw"
        out_dir.mkdir(parents=True, exist_ok=True)

        artifacts: list[GeneratedArtifact] = []

        soc_map_h = out_dir / "soc_map.h"
        soc_irq_h = out_dir / "soc_irq.h"
        linker = out_dir / "sections.lds"

        self.renderer.write_text(
            soc_map_h,
            self.renderer.render("soc_map.h.j2", sw=ir),
            encoding="utf-8",
        )
        artifacts.append(
            GeneratedArtifact(family=self.family, path=str(soc_map_h), generator=self.__class__.__name__)
        )

        self.renderer.write_text(
            soc_irq_h,
            self.renderer.render("soc_irq.h.j2", sw=ir),
            encoding="utf-8",
        )
        artifacts.append(
            GeneratedArtifact(family=self.family, path=str(soc_irq_h), generator=self.__class__.__name__)
        )

        self.renderer.write_text(
            linker,
            self.renderer.render("sections.lds.j2", sw=ir),
            encoding="utf-8",
        )
        artifacts.append(
            GeneratedArtifact(family=self.family, path=str(linker), generator=self.__class__.__name__)
        )

        return artifacts
```

---

## `socfw/emit/docs_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.docs import DocsIR


class DocsEmitter:
    family = "docs"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx: BuildContext, ir: DocsIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "docs" / "soc_map.md"
        out.parent.mkdir(parents=True, exist_ok=True)

        content = self.renderer.render("soc_map.md.j2", docs=ir)
        self.renderer.write_text(out, content, encoding="utf-8")

        return [
            GeneratedArtifact(
                family=self.family,
                path=str(out),
                generator=self.__class__.__name__,
            )
        ]
```

---

## `socfw/emit/register_block_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.register_block import RegisterBlockIR


class RegisterBlockEmitter:
    family = "rtl_regs"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit_one(self, ctx: BuildContext, ir: RegisterBlockIR) -> GeneratedArtifact:
        out = Path(ctx.out_dir) / "rtl" / f"{ir.module_name}.sv"
        out.parent.mkdir(parents=True, exist_ok=True)

        content = self.renderer.render("reg_block.sv.j2", regblk=ir)
        self.renderer.write_text(out, content, encoding="utf-8")

        return GeneratedArtifact(
            family=self.family,
            path=str(out),
            generator=self.__class__.__name__,
        )

    def emit_many(self, ctx: BuildContext, irs: list[RegisterBlockIR]) -> list[GeneratedArtifact]:
        return [self.emit_one(ctx, ir) for ir in irs]
```

---

# 7. Templaty pre SW/docs

## `socfw/templates/soc_map.h.j2`

```jinja2
/* AUTO-GENERATED - DO NOT EDIT */

#ifndef SOC_MAP_H
#define SOC_MAP_H

#include <stdint.h>

#define SYS_CLK_HZ       {{ sw.sys_clk_hz }}UL
#define RAM_BASE         0x{{ "%08X"|format(sw.ram_base) }}UL
#define RAM_SIZE_BYTES   {{ sw.ram_size }}U
#define RESET_VECTOR     0x{{ "%08X"|format(sw.reset_vector) }}UL
#define STACK_SIZE_BYTES ({{ sw.ram_size }}U * {{ sw.stack_percent }}U / 100U)

{% for region in sw.memory_regions if region.name != "RAM" %}
/* {{ region.name }} @ 0x{{ "%08X"|format(region.base) }} ({{ region.module }}) */
#define {{ region.name.upper() }}_BASE 0x{{ "%08X"|format(region.base) }}UL

{% set regs = sw.registers | selectattr("peripheral", "equalto", region.name) | list %}
{% for r in regs -%}
#define {{ r.peripheral.upper() }}_{{ r.name.upper() }}_REG (*((volatile uint32_t*)(0x{{ "%08X"|format(r.address) }}UL)))  /* {{ r.access }}  {{ r.desc }} */
{% endfor %}
{% endfor %}

#endif /* SOC_MAP_H */
```

Toto je priamy typed nástupca starého `soc_map.h` templatu/generátora.  

---

## `socfw/templates/soc_irq.h.j2`

```jinja2
/* AUTO-GENERATED - DO NOT EDIT */

#ifndef SOC_IRQ_H
#define SOC_IRQ_H

{% if sw.irqs %}
{% for irq in sw.irqs | sort(attribute="irq_id") -%}
#define {{ irq.peripheral.upper() }}_{{ irq.name.upper() }}_IRQ {{ irq.irq_id }}U
{% endfor %}
{% else %}
 /* No interrupts configured */
{% endif %}

#endif /* SOC_IRQ_H */
```

---

## `socfw/templates/sections.lds.j2`

```jinja2
/* AUTO-GENERATED - DO NOT EDIT */
/* RAM base:      0x{{ "%08X"|format(sw.ram_base) }}  size: {{ sw.ram_size }} B */
/* Reset vector:  0x{{ "%08X"|format(sw.reset_vector) }} */
/* Stack:         {{ sw.stack_percent }}% of RAM = {{ (sw.ram_size * sw.stack_percent // 100) }} B */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  RAM (rwx) : ORIGIN = 0x{{ "%08X"|format(sw.ram_base) }}, LENGTH = {{ sw.ram_size }}
}

SECTIONS {
  .text : {
    KEEP(*(.text.start))
    *(.text*)
    *(.rodata*)
  } > RAM

  .data : {
    *(.data*)
  } > RAM

  .bss : {
    __bss_start = .;
    *(.bss*) *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  _stack_top  = ORIGIN(RAM) + LENGTH(RAM);
  _stack_size = LENGTH(RAM) * {{ sw.stack_percent }} / 100;
  _stack_base = _stack_top - _stack_size;
}
```

Toto zachováva význam starého linker script templatu, len vstupom je už nový `SoftwareIR`. 

---

## `socfw/templates/soc_map.md.j2`

```jinja2
# SoC Memory Map

Board: **{{ docs.board_name }}**  
Clock: **{{ docs.clock_hz // 1000000 }} MHz**  
RAM: **{{ docs.ram_size }} B @ 0x{{ "%08X"|format(docs.ram_base) }}**  
Reset vector: **0x{{ "%08X"|format(docs.reset_vector) }}**  
Stack: **{{ docs.stack_percent }}%**

## Address Space

| Region | Base | End | Size | Module |
|--------|------|-----|------|--------|
| RAM | `0x{{ "%08X"|format(docs.ram_base) }}` | `0x{{ "%08X"|format(docs.ram_base + docs.ram_size - 1) }}` | {{ docs.ram_size }} B | soc_ram |

{% for p in docs.peripherals -%}
| {{ p.instance }} | `0x{{ "%08X"|format(p.base) }}` | `0x{{ "%08X"|format(p.end) }}` | `0x{{ "%X"|format(p.size) }}` | {{ p.module }} |
{% endfor %}

{% if docs.peripherals %}
## Peripherals

{% for p in docs.peripherals %}
### {{ p.instance }}

- Module: `{{ p.module }}`
- Base: `0x{{ "%08X"|format(p.base) }}`
- End: `0x{{ "%08X"|format(p.end) }}`
- Size: `0x{{ "%X"|format(p.size) }}`

{% if p.registers %}
#### Registers

| Offset | Name | Access | Width | Reset | Description |
|--------|------|--------|-------|-------|-------------|
{% for r in p.registers -%}
| `0x{{ "%02X"|format(r.offset) }}` | {{ r.name }} | {{ r.access }} | {{ r.width }} | `0x{{ "%X"|format(r.reset) }}` | {{ r.desc }} |
{% endfor %}
{% endif %}

{% if p.irq_ids %}
#### IRQs

{{ p.irq_ids | join(", ") }}

{% endif %}
{% endfor %}
{% endif %}
```

Toto je typed pokračovanie starého `soc_map.md` generovania. 

---

## `socfw/templates/reg_block.sv.j2`

```jinja2
// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module {{ regblk.module_name }} (
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  input  wire [{{ regblk.addr_width + 1 }}:2] addr_i,
  input  wire [31:0] wdata_i,
  input  wire        we_i,
  output logic [31:0] rdata_o
{% for r in regblk.regs -%}
,
  output logic{% if r.width > 1 %} [{{ r.width - 1 }}:0]{% endif %} reg_{{ r.name.lower() }}
{% endfor %}
);

{% for r in regblk.regs -%}
logic{% if r.width > 1 %} [{{ r.width - 1 }}:0]{% endif %} r_{{ r.name.lower() }}; // 0x{{ "%02X"|format(r.offset) }} {{ r.access }} {{ r.desc }}
{% endfor %}

{% set writable = regblk.regs | selectattr("access", "in", ["rw", "wo"]) | list %}
{% if writable %}
always_ff @(posedge SYS_CLK or negedge RESET_N) begin
  if (!RESET_N) begin
{% for r in writable -%}
    r_{{ r.name.lower() }} <= {{ r.width }}'h{{ "%X"|format(r.reset) }};
{% endfor %}
  end else if (we_i) begin
    case (addr_i)
{% for r in writable -%}
      {{ regblk.addr_width }}'h{{ "%X"|format(r.word_addr) }}: r_{{ r.name.lower() }} <= wdata_i[{{ r.width - 1 }}:0];
{% endfor %}
      default: ;
    endcase
  end
end
{% endif %}

always_comb begin
  rdata_o = 32'h0;
  case (addr_i)
{% for r in regblk.regs if r.access in ["rw", "ro"] -%}
    {{ regblk.addr_width }}'h{{ "%X"|format(r.word_addr) }}: rdata_o = { {{ 32 - r.width }}'b0, r_{{ r.name.lower() }} };
{% endfor %}
    default: rdata_o = 32'h0;
  endcase
end

{% for r in regblk.regs -%}
assign reg_{{ r.name.lower() }} = r_{{ r.name.lower() }};
{% endfor %}

endmodule : {{ regblk.module_name }}
`default_nettype wire
```

Toto je nový stabilný templating target pre register blocky a zároveň elegantne obchádza dnešný naming mismatch bug.  

---

# 8. Rozšírený emitter suite

## `socfw/emit/run_emitters.py`

```python
from __future__ import annotations

from socfw.build.context import BuildContext
from socfw.build.manifest import BuildManifest
from socfw.emit.board_quartus_emitter import QuartusBoardEmitter
from socfw.emit.docs_emitter import DocsEmitter
from socfw.emit.files_tcl_emitter import QuartusFilesEmitter
from socfw.emit.register_block_emitter import RegisterBlockEmitter
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.emit.software_emitter import SoftwareEmitter
from socfw.emit.timing_emitter import TimingEmitter


class EmitterSuite:
    def __init__(self, templates_dir: str) -> None:
        self.rtl = RtlEmitter(templates_dir)
        self.timing = TimingEmitter(templates_dir)
        self.board = QuartusBoardEmitter()
        self.files = QuartusFilesEmitter()
        self.software = SoftwareEmitter(templates_dir)
        self.docs = DocsEmitter(templates_dir)
        self.regblocks = RegisterBlockEmitter(templates_dir)

    def emit_all(
        self,
        ctx: BuildContext,
        *,
        board_ir,
        timing_ir,
        rtl_ir,
        software_ir=None,
        docs_ir=None,
        register_block_irs=None,
    ) -> BuildManifest:
        manifest = BuildManifest()

        for art in self.board.emit(ctx, board_ir):
            manifest.artifacts.append(art)

        for art in self.rtl.emit(ctx, rtl_ir):
            manifest.artifacts.append(art)

        for art in self.timing.emit(ctx, timing_ir):
            manifest.artifacts.append(art)

        for art in self.files.emit(ctx, rtl_ir):
            manifest.artifacts.append(art)

        if software_ir is not None:
            for art in self.software.emit(ctx, software_ir):
                manifest.artifacts.append(art)

        if docs_ir is not None:
            for art in self.docs.emit(ctx, docs_ir):
                manifest.artifacts.append(art)

        if register_block_irs:
            for art in self.regblocks.emit_many(ctx, register_block_irs):
                manifest.artifacts.append(art)

        return manifest
```

---

# 9. Aktualizovaný build pipeline

## `socfw/build/pipeline.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.build.context import BuildContext, BuildRequest
from socfw.build.manifest import BuildManifest
from socfw.elaborate.planner import Elaborator
from socfw.model.system import SystemModel
from socfw.validate.rules.asset_rules import VendorIpArtifactExistsRule
from socfw.validate.rules.binding_rules import BindingWidthCompatibilityRule
from socfw.validate.rules.board_rules import (
    UnknownBoardBindingTargetRule,
    UnknownBoardFeatureRule,
)
from socfw.validate.rules.project_rules import (
    DuplicateModuleInstanceRule,
    UnknownGeneratedClockSourceRule,
    UnknownIpTypeRule,
)
from socfw.builders.board_ir_builder import BoardIRBuilder
from socfw.builders.docs_ir_builder import DocsIRBuilder
from socfw.builders.register_block_ir_builder import RegisterBlockIRBuilder
from socfw.builders.rtl_ir_builder import RtlIRBuilder
from socfw.builders.software_ir_builder import SoftwareIRBuilder
from socfw.builders.timing_ir_builder import TimingIRBuilder


@dataclass
class BuildResult:
    ok: bool
    diagnostics: list[Diagnostic] = field(default_factory=list)
    manifest: BuildManifest = field(default_factory=BuildManifest)
    board_ir: object | None = None
    timing_ir: object | None = None
    rtl_ir: object | None = None
    software_ir: object | None = None
    docs_ir: object | None = None
    register_block_irs: list[object] = field(default_factory=list)


class BuildPipeline:
    def __init__(self) -> None:
        self.rules = [
            DuplicateModuleInstanceRule(),
            UnknownIpTypeRule(),
            UnknownGeneratedClockSourceRule(),
            UnknownBoardFeatureRule(),
            UnknownBoardBindingTargetRule(),
            VendorIpArtifactExistsRule(),
            BindingWidthCompatibilityRule(),
        ]
        self.elaborator = Elaborator()
        self.board_ir_builder = BoardIRBuilder()
        self.timing_ir_builder = TimingIRBuilder()
        self.rtl_ir_builder = RtlIRBuilder()
        self.software_ir_builder = SoftwareIRBuilder()
        self.docs_ir_builder = DocsIRBuilder()
        self.regblk_ir_builder = RegisterBlockIRBuilder()

    def _validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for msg in system.validate():
            diags.append(
                Diagnostic(
                    code="SYS001",
                    severity=Severity.ERROR,
                    message=msg,
                    subject="system",
                )
            )

        for rule in self.rules:
            diags.extend(rule.validate(system))

        return diags

    def run(self, request: BuildRequest, system: SystemModel) -> BuildResult:
        diags = self._validate(system)
        if any(d.severity == Severity.ERROR for d in diags):
            return BuildResult(ok=False, diagnostics=diags)

        design = self.elaborator.elaborate(system)

        board_ir = self.board_ir_builder.build(design)
        timing_ir = self.timing_ir_builder.build(design)
        rtl_ir = self.rtl_ir_builder.build(design)
        software_ir = self.software_ir_builder.build(design)
        docs_ir = self.docs_ir_builder.build(design)

        regblk_irs = []
        for p in system.peripheral_blocks:
            regblk = self.regblk_ir_builder.build_for_peripheral(p)
            if regblk is not None:
                regblk_irs.append(regblk)

        return BuildResult(
            ok=True,
            diagnostics=diags,
            board_ir=board_ir,
            timing_ir=timing_ir,
            rtl_ir=rtl_ir,
            software_ir=software_ir,
            docs_ir=docs_ir,
            register_block_irs=regblk_irs,
        )
```

---

## `socfw/build/full_pipeline.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.pipeline import BuildPipeline, BuildResult
from socfw.config.system_loader import SystemLoader
from socfw.emit.run_emitters import EmitterSuite


class FullBuildPipeline:
    def __init__(self, templates_dir: str) -> None:
        self.loader = SystemLoader()
        self.pipeline = BuildPipeline()
        self.emitters = EmitterSuite(templates_dir)

    def run(self, request: BuildRequest) -> BuildResult:
        loaded = self.loader.load(request.project_file)
        if not loaded.ok or loaded.value is None:
            return BuildResult(ok=False, diagnostics=loaded.diagnostics)

        result = self.pipeline.run(request, loaded.value)
        result.diagnostics = loaded.diagnostics + result.diagnostics

        if not result.ok:
            return result

        ctx = BuildContext(out_dir=Path(request.out_dir))
        manifest = self.emitters.emit_all(
            ctx,
            board_ir=result.board_ir,
            timing_ir=result.timing_ir,
            rtl_ir=result.rtl_ir,
            software_ir=result.software_ir,
            docs_ir=result.docs_ir,
            register_block_irs=result.register_block_irs,
        )
        result.manifest = manifest
        return result
```

---

# 10. Čo je týmto už uzavreté

Týmto máš refaktorovaný a dosť kompletný skeleton pre:

* **board**
* **RTL**
* **timing**
* **software**
* **docs**
* **register blocks**

Starý framework mal tieto oblasti, ale viac naviazané na jeden širší model a generátory. Teraz je to rozdelené na:

* typed model,
* elaboration,
* IR,
* emitter.    

A navyše sa tým rieši aj konkrétny problém starého kódu:

* register block templating už nemá rozpor medzi `periph_regs.sv.j2` a existujúcim `reg_block.sv.j2`.  

---

# 11. Čo ešte chýba do „seriózne použiteľného“ frameworku

Teraz už chýbajú hlavne tieto tri oblasti:

### 1. Bus/interconnect planner

To je najväčší ďalší kus, ak chceš plný SoC mode bez legacy bridge. Starý framework už má náznaky v `bus_if`, `axi_lite_if` a graph template, ale chýba nová planner vrstva.  

### 2. CPU/RAM/boot/image pipeline

Aby bol software build úplne plnohodnotný, treba explicitne modelovať:

* CPU config,
* RAM region,
* init image / mif / hex,
* možno `bin2hex` integráciu ako utility step. 

### 3. Reporting / explain / graph

JSON/MD build report, explain clocks/address map, graphviz output.

---

# 12. Môj odporúčaný ďalší krok

Najrozumnejšie teraz je spraviť práve:

**bus/interconnect planner API + simple_bus plugin + SoC address map builder**

To je moment, kde sa framework definitívne odlepí od starého legacy SoC contextu a získa skutočnú rozšíriteľnosť pre nové bus-y.

V ďalšej správe ti viem pripraviť:
**kompletný refaktorovaný návrh pre bus layer**:

* bus modely,
* planner API,
* `simple_bus` plugin,
* address map builder,
* napojenie na RTL IR a SoftwareIR.
