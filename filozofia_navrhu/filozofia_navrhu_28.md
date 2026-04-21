Super. Ideme na ďalší praktický krok:

**SoC fixture + `dummy_cpu` + `gpio` + `soc_ram` + address decode + software/docs napojenie**

Toto je prvý moment, kde nový framework začne robiť niečo skutočne SoC-ové, nie len “top generator”. Cieľ tohto kroku je:

* mať **jeden kompletný minimálny SoC fixture**
* mať **CPU master**
* mať **RAM slave**
* mať **GPIO peripheral slave**
* mať **address decode vo fabric**
* mať **`soc_map.h` + `sections.lds` + `soc_map.md`**
* mať **report a graph**, kde už bude vidno CPU/RAM/peripheral väzby

Nižšie to dávam ako ďalší copy-paste ready slice.

---

# 1. Adresné dekódovanie vo fabric

Doteraz bol `simple_bus_fabric` decode-less. Teraz ho spravíme použiteľný.

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

Toto už vie routovať podľa `BASE_ADDR` a `ADDR_MASK`.

---

# 2. Builder fabric parametrov

Treba doplniť parametre do fabric buildera.

## `socfw/builders/rtl_bus_builder.py`

Vymeň za túto verziu:

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

            fabrics.append(fabric)

        return fabrics

    @staticmethod
    def _pack_words(words: list[int]) -> str:
        if not words:
            return "'0"
        chunks = [f"32'h{w:08X}" for w in reversed(words)]
        return "{ " + ", ".join(chunks) + " }"
```

---

# 3. Register metadata v IP descriptoroch

Aby vzniklo `soc_map.h` a docs, IP descriptor musí niesť metadata o registroch.

## update `socfw/config/ip_schema.py`

Pridaj:

```python
class IpRegisterSchema(BaseModel):
    name: str
    offset: int
    width: int = 32
    access: str = "rw"
    reset: int = 0
    desc: str = ""


class IpIrqSchema(BaseModel):
    name: str
    id: int


class IpConfigSchema(BaseModel):
    version: Literal[2]
    kind: Literal["ip"]
    ip: IpMetaSchema
    origin: IpOriginSchema
    integration: IpIntegrationSchema = Field(default_factory=IpIntegrationSchema)
    reset: IpResetSchema = Field(default_factory=IpResetSchema)
    clocking: IpClockingSchema = Field(default_factory=IpClockingSchema)
    artifacts: IpArtifactsSchema = Field(default_factory=IpArtifactsSchema)
    notes: list[str] = Field(default_factory=list)
    registers: list[IpRegisterSchema] = Field(default_factory=list)
    irqs: list[IpIrqSchema] = Field(default_factory=list)
```

## update `socfw/config/ip_loader.py`

Pri skladaní `IpDescriptor(...)` zmeň `meta` na:

```python
            meta={
                "notes": doc.notes,
                "registers": [
                    {
                        "name": r.name,
                        "offset": r.offset,
                        "width": r.width,
                        "access": r.access,
                        "reset": r.reset,
                        "desc": r.desc,
                    }
                    for r in doc.registers
                ],
                "irqs": [
                    {
                        "name": irq.name,
                        "id": irq.id,
                    }
                    for irq in doc.irqs
                ],
            },
```

---

# 4. Software IR a docs IR

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
class MemoryRegionIR:
    name: str
    base: int
    size: int
    module: str

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
```

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

# 5. Software/docs buildre

## `socfw/builders/software_ir_builder.py`

```python
from __future__ import annotations

from socfw.ir.software import MemoryRegionIR, SoftwareIR, SwRegisterIR


class SoftwareIRBuilder:
    def build(self, design) -> SoftwareIR | None:
        system = design.system

        if system.ram is None:
            return None

        ir = SoftwareIR(
            board_name=system.board.board_id,
            sys_clk_hz=system.board.sys_clock.frequency_hz,
            ram_base=system.ram.base,
            ram_size=system.ram.size,
            reset_vector=system.reset_vector,
            stack_percent=system.stack_percent,
        )

        ir.memory_regions.append(
            MemoryRegionIR(
                name="RAM",
                base=system.ram.base,
                size=system.ram.size,
                module=system.ram.module,
            )
        )

        for p in system.peripheral_blocks:
            ir.memory_regions.append(
                MemoryRegionIR(
                    name=p.instance,
                    base=p.base,
                    size=p.size,
                    module=p.module,
                )
            )

            ip = system.ip_catalog.get(p.module)
            regs_meta = [] if ip is None else ip.meta.get("registers", [])
            for r in regs_meta:
                ir.registers.append(
                    SwRegisterIR(
                        peripheral=p.instance,
                        peripheral_type=p.module,
                        name=r["name"],
                        offset=int(r["offset"]),
                        address=p.base + int(r["offset"]),
                        access=str(r.get("access", "rw")),
                        width=int(r.get("width", 32)),
                        reset=int(r.get("reset", 0)),
                        desc=str(r.get("desc", "")),
                    )
                )

        return ir
```

## `socfw/builders/docs_ir_builder.py`

```python
from __future__ import annotations

from socfw.ir.docs import DocsIR, DocsPeripheralIR, DocsRegisterIR


class DocsIRBuilder:
    def build(self, design) -> DocsIR | None:
        system = design.system

        if system.ram is None and not system.peripheral_blocks:
            return None

        ir = DocsIR(
            board_name=system.board.board_id,
            clock_hz=system.board.sys_clock.frequency_hz,
            ram_base=0 if system.ram is None else system.ram.base,
            ram_size=0 if system.ram is None else system.ram.size,
            reset_vector=system.reset_vector,
            stack_percent=system.stack_percent,
        )

        for p in system.peripheral_blocks:
            ip = system.ip_catalog.get(p.module)
            regs_meta = [] if ip is None else ip.meta.get("registers", [])
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
                            name=r["name"],
                            offset=int(r["offset"]),
                            access=str(r.get("access", "rw")),
                            width=int(r.get("width", 32)),
                            reset=int(r.get("reset", 0)),
                            desc=str(r.get("desc", "")),
                        )
                        for r in regs_meta
                    ],
                )
            )

        return ir
```

---

# 6. Software/docs emitre

## `socfw/emit/software_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer


class SoftwareEmitter:
    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        out_dir = Path(ctx.out_dir) / "sw"
        out_dir.mkdir(parents=True, exist_ok=True)

        artifacts: list[GeneratedArtifact] = []

        soc_map_h = out_dir / "soc_map.h"
        sections = out_dir / "sections.lds"

        self.renderer.write_text(
            soc_map_h,
            self.renderer.render("soc_map.h.j2", sw=ir),
        )
        artifacts.append(GeneratedArtifact("software", str(soc_map_h), self.__class__.__name__))

        self.renderer.write_text(
            sections,
            self.renderer.render("sections.lds.j2", sw=ir),
        )
        artifacts.append(GeneratedArtifact("software", str(sections), self.__class__.__name__))

        return artifacts
```

## `socfw/emit/docs_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer


class DocsEmitter:
    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        if ir is None:
            return []

        out = Path(ctx.out_dir) / "docs" / "soc_map.md"
        out.parent.mkdir(parents=True, exist_ok=True)

        self.renderer.write_text(out, self.renderer.render("soc_map.md.j2", docs=ir))
        return [GeneratedArtifact("docs", str(out), self.__class__.__name__)]
```

---

# 7. Templates

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
#define {{ r.peripheral.upper() }}_{{ r.name.upper() }}_REG (*((volatile uint32_t*)(0x{{ "%08X"|format(r.address) }}UL)))
{% endfor %}

{% endfor %}
#endif
```

## `socfw/templates/sections.lds.j2`

```jinja2
/* AUTO-GENERATED - DO NOT EDIT */
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

## `socfw/templates/soc_map.md.j2`

```jinja2
# SoC Memory Map

Board: **{{ docs.board_name }}**  
Clock: **{{ docs.clock_hz }} Hz**  
RAM: **{{ docs.ram_size }} B @ 0x{{ "%08X"|format(docs.ram_base) }}**  
Reset vector: **0x{{ "%08X"|format(docs.reset_vector) }}**

## Peripherals

{% for p in docs.peripherals %}
### {{ p.instance }}

- Module: `{{ p.module }}`
- Base: `0x{{ "%08X"|format(p.base) }}`
- End: `0x{{ "%08X"|format(p.end) }}`

{% if p.registers %}
| Offset | Name | Access | Width | Reset | Description |
|--------|------|--------|-------|-------|-------------|
{% for r in p.registers -%}
| `0x{{ "%02X"|format(r.offset) }}` | {{ r.name }} | {{ r.access }} | {{ r.width }} | `0x{{ "%X"|format(r.reset) }}` | {{ r.desc }} |
{% endfor %}
{% endif %}

{% endfor %}
```

---

# 8. Pipeline updates

## `socfw/plugins/bootstrap.py`

Doplň:

```python
from socfw.emit.software_emitter import SoftwareEmitter
```

A registráciu:

```python
    reg.register_emitter("software", SoftwareEmitter(templates_dir))
```

## `socfw/build/pipeline.py`

Doplň imports:

```python
from socfw.builders.docs_ir_builder import DocsIRBuilder
from socfw.builders.software_ir_builder import SoftwareIRBuilder
```

V `__init__`:

```python
        self.software_ir_builder = SoftwareIRBuilder()
        self.docs_ir_builder = DocsIRBuilder()
```

V return:

```python
        return BuildResult(
            ok=True,
            diagnostics=diags,
            board_ir=self.board_ir_builder.build(design),
            timing_ir=self.timing_ir_builder.build(design),
            rtl_ir=self.rtl_ir_builder.build(design),
            docs_ir=self.docs_ir_builder.build(design),
            design=design,
            software_ir=self.software_ir_builder.build(design),
        )
```

A do `BuildResult` pridaj:

```python
    software_ir: object | None = None
```

## `socfw/emit/orchestrator.py`

Zmeň ordered na:

```python
        ordered = [
            ("board", board_ir),
            ("rtl", rtl_ir),
            ("timing", timing_ir),
            ("files", rtl_ir),
            ("software", software_ir),
            ("docs", docs_ir),
        ]
```

A podpis metódy:

```python
    def emit_all(self, ctx, *, board_ir, timing_ir, rtl_ir, software_ir=None, docs_ir=None) -> BuildManifest:
```

## `socfw/build/full_pipeline.py`

Pri volaní:

```python
        result.manifest = self.emitters.emit_all(
            ctx,
            board_ir=result.board_ir,
            timing_ir=result.timing_ir,
            rtl_ir=result.rtl_ir,
            software_ir=result.software_ir,
            docs_ir=result.docs_ir,
        )
```

---

# 9. Dummy SoC IP

## `tests/golden/fixtures/soc_led_test/ip/gpio.ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: gpio
  module: gpio
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
    - tests/golden/fixtures/soc_led_test/rtl/gpio.sv
  simulation: []
  metadata: []

registers:
  - name: value
    offset: 0
    width: 32
    access: rw
    reset: 0
    desc: GPIO output value
```

## `tests/golden/fixtures/soc_led_test/rtl/gpio.sv`

```systemverilog
`default_nettype none

module gpio (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus,
  output logic [5:0] gpio_o
);

  logic [31:0] reg_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      reg_value <= 32'h0;
    end else if (bus.valid && bus.we && bus.addr[11:2] == 10'h0) begin
      reg_value <= bus.wdata;
    end
  end

  always_comb begin
    bus.ready = bus.valid;
    bus.rdata = (bus.addr[11:2] == 10'h0) ? reg_value : 32'h0;
  end

  assign gpio_o = reg_value[5:0];

endmodule
`default_nettype wire
```

## `tests/golden/fixtures/soc_led_test/rtl/soc_ram.sv`

```systemverilog
`default_nettype none

module soc_ram #(
  parameter int RAM_BYTES = 65536,
  parameter string INIT_FILE = ""
)(
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus
);

  localparam int WORDS = RAM_BYTES / 4;
  logic [31:0] mem [0:WORDS-1];
  wire [31:2] word_addr = bus.addr[31:2];

  initial begin
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
    end
  end

  always_ff @(posedge SYS_CLK) begin
    if (bus.valid && bus.we) begin
      mem[word_addr] <= bus.wdata;
    end
  end

  always_comb begin
    bus.ready = bus.valid;
    bus.rdata = mem[word_addr];
  end

endmodule
`default_nettype wire
```

## `tests/golden/fixtures/soc_led_test/rtl/dummy_cpu.sv`

```systemverilog
`default_nettype none

module dummy_cpu (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.master bus
);

  typedef enum logic [1:0] {
    S_IDLE,
    S_WRITE_GPIO,
    S_DONE
  } state_t;

  state_t state;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE:
          state <= S_WRITE_GPIO;
        S_WRITE_GPIO:
          if (bus.ready)
            state <= S_DONE;
        default:
          state <= S_DONE;
      endcase
    end
  end

  always_comb begin
    bus.addr  = 32'h4000_0000;
    bus.wdata = 32'h0000_0015;
    bus.be    = 4'hF;
    bus.we    = 1'b0;
    bus.valid = 1'b0;

    if (state == S_WRITE_GPIO) begin
      bus.we    = 1'b1;
      bus.valid = 1'b1;
    end
  end

endmodule
`default_nettype wire
```

---

# 10. SoC fixture YAML

## `tests/golden/fixtures/soc_led_test/project.yaml`

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

## `tests/golden/fixtures/soc_led_test/board.yaml`

Použi rovnaký board ako v blink fixtures s LED resource.

---

# 11. Čo teraz vieš otestovať

Po tomto kroku by si mal vedieť spustiť:

```bash
socfw build tests/golden/fixtures/soc_led_test/project.yaml --out build/soc_led_test
```

A očakávať artefakty:

* `rtl/soc_top.sv`
* `hal/board.tcl`
* `files.tcl`
* `sw/soc_map.h`
* `sw/sections.lds`
* `docs/soc_map.md`
* `reports/build_report.json`
* `reports/build_report.md`
* `reports/soc_graph.dot`

---

# 12. Čo by som spravil hneď potom

Tento slice už je dosť silný. Najbližší ďalší krok by som spravil:

* **IRQ planner + `soc_irq.h`**
* **register block emitter**, aby sa periférie dali generovať z metadata
* **CPU descriptor registry**, aby CPU nebolo len inline v project YAML
* **ELF/BIN/HEX flow**

Najpraktickejší ďalší krok je podľa mňa:
**register blocks z metadata + IRQ layer**

Lebo tým odstrániš potrebu ručne písať `gpio.sv` ako perifériu a framework začne byť naozaj generatívny.
