Super. Ideme na ďalší krok:

**register blocks z metadata + IRQ layer**

Toto je veľmi dôležitý bod, lebo práve tu sa framework začne správať ako skutočný generator periférií, nie len orchestrátor ručne písaných RTL blokov.

Cieľ tohto kroku:

* periféria už nemusí mať ručne písaný register file
* IP descriptor vie niesť:

  * registre
  * IRQ metadata
* framework vie vygenerovať:

  * `*_regs.sv`
  * `soc_irq.h`
  * IRQ combiner wiring
* periféria sa zjednoduší na:

  * bus wrapper
  * core logic
  * register outputs / status inputs

Nižšie je ďalší copy-paste ready slice.

---

# 1. Register block IR

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

# 2. Register block builder

## `socfw/builders/register_block_ir_builder.py`

```python
from __future__ import annotations

import math

from socfw.ir.register_block import RegFieldIR, RegisterBlockIR
from socfw.model.addressing import PeripheralAddressBlock


class RegisterBlockIRBuilder:
    def build_for_peripheral(self, p: PeripheralAddressBlock, ip_meta: dict) -> RegisterBlockIR | None:
        regs_meta = ip_meta.get("registers", [])
        if not regs_meta:
            return None

        word_count = max((int(r["offset"]) // 4) for r in regs_meta) + 1
        addr_width = max(1, math.ceil(math.log2(word_count)))

        return RegisterBlockIR(
            module_name=f"{p.instance}_regs",
            peripheral_instance=p.instance,
            base=p.base,
            addr_width=addr_width,
            regs=[
                RegFieldIR(
                    name=str(r["name"]),
                    offset=int(r["offset"]),
                    width=int(r.get("width", 32)),
                    access=str(r.get("access", "rw")),
                    reset=int(r.get("reset", 0)),
                    desc=str(r.get("desc", "")),
                    word_addr=int(r["offset"]) // 4,
                )
                for r in regs_meta
            ],
        )
```

---

# 3. Register block emitter

## `socfw/emit/register_block_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer


class RegisterBlockEmitter:
    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit_many(self, ctx, irs) -> list[GeneratedArtifact]:
        artifacts: list[GeneratedArtifact] = []

        for ir in irs:
            out = Path(ctx.out_dir) / "rtl" / f"{ir.module_name}.sv"
            out.parent.mkdir(parents=True, exist_ok=True)

            self.renderer.write_text(
                out,
                self.renderer.render("reg_block.sv.j2", regblk=ir),
            )
            artifacts.append(
                GeneratedArtifact("rtl_regs", str(out), self.__class__.__name__)
            )

        return artifacts
```

---

# 4. Register block template

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
  input  wire        valid_i,
  output logic [31:0] rdata_o,
  output logic       ready_o
{% for r in regblk.regs -%}
,
  output logic{% if r.width > 1 %} [{{ r.width - 1 }}:0]{% endif %} reg_{{ r.name.lower() }}
{% endfor %}
);

{% for r in regblk.regs -%}
logic{% if r.width > 1 %} [{{ r.width - 1 }}:0]{% endif %} r_{{ r.name.lower() }};
{% endfor %}

{% set writable = regblk.regs | selectattr("access", "in", ["rw", "wo"]) | list %}
{% if writable %}
always_ff @(posedge SYS_CLK or negedge RESET_N) begin
  if (!RESET_N) begin
{% for r in writable -%}
    r_{{ r.name.lower() }} <= {{ r.width }}'h{{ "%X"|format(r.reset) }};
{% endfor %}
  end else if (valid_i && we_i) begin
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

always_comb begin
  ready_o = valid_i;
end

{% for r in regblk.regs -%}
assign reg_{{ r.name.lower() }} = r_{{ r.name.lower() }};
{% endfor %}

endmodule : {{ regblk.module_name }}
`default_nettype wire
```

---

# 5. IRQ model

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
```

---

# 6. IRQ planner

## `socfw/builders/irq_plan_builder.py`

```python
from __future__ import annotations

from socfw.model.irq import IrqPlan, IrqSource


class IrqPlanBuilder:
    def build(self, system) -> IrqPlan | None:
        if system.cpu is None or system.cpu.irq_port is None:
            return None

        sources: list[IrqSource] = []

        for p in system.peripheral_blocks:
            ip = system.ip_catalog.get(p.module)
            if ip is None:
                continue

            for irq in ip.meta.get("irqs", []):
                irq_name = str(irq["name"])
                irq_id = int(irq["id"])
                sources.append(
                    IrqSource(
                        instance=p.instance,
                        signal_name=f"irq_{p.instance}_{irq_name}",
                        irq_id=irq_id,
                    )
                )

        if not sources:
            return IrqPlan(width=0, sources=[])

        width = max(s.irq_id for s in sources) + 1
        return IrqPlan(width=width, sources=sorted(sources, key=lambda s: s.irq_id))
```

---

# 7. Elaborated design update

## `socfw/elaborate/design.py`

Pridaj:

```python
from socfw.model.irq import IrqPlan
```

A do `ElaboratedDesign`:

```python
    irq_plan: IrqPlan | None = None
```

## `socfw/elaborate/planner.py`

Pridaj import:

```python
from socfw.builders.irq_plan_builder import IrqPlanBuilder
```

V `__init__`:

```python
        self.irq_builder = IrqPlanBuilder()
```

V `elaborate()` po address map build:

```python
        design.irq_plan = self.irq_builder.build(system)
```

---

# 8. RTL IRQ IR

## update `socfw/ir/rtl.py`

Pridaj:

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
    cpu_irq_signal: str
    sources: list[RtlIrqSource] = field(default_factory=list)
```

A do `RtlModuleIR`:

```python
    irq_combiner: RtlIrqCombiner | None = None
```

---

# 9. RTL IRQ builder

## `socfw/builders/rtl_irq_builder.py`

```python
from __future__ import annotations

from socfw.ir.rtl import RtlIrqCombiner, RtlIrqSource, RtlWire


class RtlIrqBuilder:
    def build(self, design, rtl) -> None:
        system = design.system
        irq_plan = design.irq_plan

        if system.cpu is None or system.cpu.irq_port is None:
            return
        if irq_plan is None or irq_plan.width <= 0:
            return

        irq_bus_name = "cpu_irq"
        rtl.add_wire_once(RtlWire(name=irq_bus_name, width=irq_plan.width, comment="CPU IRQ bus"))

        for src in irq_plan.sources:
            rtl.add_wire_once(RtlWire(name=src.signal_name, width=1, comment=f"IRQ source {src.instance}"))

        rtl.irq_combiner = RtlIrqCombiner(
            name="u_irq_combiner",
            width=irq_plan.width,
            cpu_irq_signal=irq_bus_name,
            sources=[
                RtlIrqSource(
                    irq_id=s.irq_id,
                    signal=s.signal_name,
                    instance=s.instance,
                )
                for s in irq_plan.sources
            ],
        )
```

---

# 10. IRQ combiner module

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

---

# 11. RTL builder update

## `socfw/builders/rtl_ir_builder.py`

Pridaj import:

```python
from socfw.builders.rtl_irq_builder import RtlIrqBuilder
```

V `__init__`:

```python
        self.irq_builder = RtlIrqBuilder()
```

Po vytvorení CPU instance a modulov zavolaj:

```python
        self.irq_builder.build(design, rtl)
```

A ak je combiner prítomný, pripoj CPU IRQ port:

```python
        if rtl.irq_combiner is not None and system.cpu is not None and system.cpu.irq_port:
            for inst in rtl.instances:
                if inst.name == "cpu":
                    inst.conns.append(
                        RtlConn(
                            port=system.cpu.irq_port,
                            signal=rtl.irq_combiner.cpu_irq_signal,
                        )
                    )
```

A doplň extra source:

```python
        if rtl.irq_combiner is not None and "src/ip/irq/irq_combiner.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/irq/irq_combiner.sv")
```

---

# 12. RTL template update

## `socfw/templates/soc_top.sv.j2`

Pridaj pred module instances:

```jinja2
{% if module.irq_combiner %}
  // IRQ combiner
  irq_combiner #(
    .WIDTH({{ module.irq_combiner.width }})
  ) {{ module.irq_combiner.name }} (
    .irq_i({
{%- for src in module.irq_combiner.sources | sort(attribute="irq_id", reverse=True) %}
      {{ src.signal }}{{ "," if not loop.last else "" }}
{%- endfor %}
    }),
    .irq_o({{ module.irq_combiner.cpu_irq_signal }})
  );

{% endif %}
```

---

# 13. `soc_irq.h`

## update `socfw/ir/software.py`

Pridaj:

```python
@dataclass(frozen=True)
class SwIrqIR:
    peripheral: str
    name: str
    irq_id: int
```

A do `SoftwareIR`:

```python
    irqs: list[SwIrqIR] = field(default_factory=list)
```

## update `socfw/builders/software_ir_builder.py`

Doplň po registroch:

```python
            for irq in ip.meta.get("irqs", []):
                ir.irqs.append(
                    SwIrqIR(
                        peripheral=p.instance,
                        name=str(irq["name"]),
                        irq_id=int(irq["id"]),
                    )
                )
```

A import:

```python
from socfw.ir.software import MemoryRegionIR, SoftwareIR, SwRegisterIR, SwIrqIR
```

## update `socfw/emit/software_emitter.py`

Doplň:

```python
        soc_irq_h = out_dir / "soc_irq.h"
```

a emit:

```python
        self.renderer.write_text(
            soc_irq_h,
            self.renderer.render("soc_irq.h.j2", sw=ir),
        )
        artifacts.append(GeneratedArtifact("software", str(soc_irq_h), self.__class__.__name__))
```

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

#endif
```

---

# 14. GPIO fixture update s IRQ

Ak chceš hneď overiť IRQ path, rozšír GPIO IP.

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

irqs:
  - name: changed
    id: 0
```

## `tests/golden/fixtures/soc_led_test/rtl/gpio.sv`

Pridaj IRQ výstup:

```systemverilog
`default_nettype none

module gpio (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus,
  output logic [5:0] gpio_o,
  output logic irq_changed
);

  logic [31:0] reg_value;
  logic [31:0] prev_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      reg_value <= 32'h0;
      prev_value <= 32'h0;
    end else begin
      prev_value <= reg_value;
      if (bus.valid && bus.we && bus.addr[11:2] == 10'h0) begin
        reg_value <= bus.wdata;
      end
    end
  end

  always_comb begin
    bus.ready = bus.valid;
    bus.rdata = (bus.addr[11:2] == 10'h0) ? reg_value : 32'h0;
  end

  assign gpio_o = reg_value[5:0];
  assign irq_changed = (reg_value != prev_value);

endmodule
`default_nettype wire
```

---

# 15. Napojenie IRQ signálu do periférie

Aby `irq_gpio0_changed` neostal len vo wire zozname, treba ho pripojiť.

Najjednoduchšie je doplniť do `RtlIRBuilder` po bežných conns:

```python
            for irq in ip.meta.get("irqs", []):
                irq_name = str(irq["name"])
                sig = f"irq_{mod.instance}_{irq_name}"
                conns.append(RtlConn(port=f"irq_{irq_name}", signal=sig))
```

To znamená, že periféria má port napr. `irq_changed`.

---

# 16. Ďalšia veľká hodnota po tomto kroku

Po tomto už framework vie:

* perifériu opísať cez IP metadata
* vytvoriť address map
* vytvoriť SW mapy
* vytvoriť IRQ mapu
* poskladať CPU/RAM/peripheral topológiu
* a začína byť možné nahrádzať ručný peripheral boilerplate generovaným register blockom

Toto je podľa mňa hranica, kde sa návrh už naozaj odlepí od pôvodného frameworku a začne mať vlastnú modernú architektúru.

---

# 17. Čo by som spravil hneď potom

Úplne najlepší ďalší krok je:

**peripheral shell + generated regblock integration**

Teda:

* framework vygeneruje `gpio0_regs.sv`
* ručne písaná periféria už bude len:

  * core logic
  * napojenie na `reg_value`
  * napojenie status/irq
* a register access logika sa odstráni z ručne písaného `gpio.sv`

To je presne bod, kde začneš reálne profitovať z generovania.

Ak chceš, ďalšia správa môže byť presne o tom:
**generated regblock integration + peripheral shell pattern + prvý plne generovaný GPIO control plane**.
