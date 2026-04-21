Super. Ideme na:

**generated regblock integration + peripheral shell pattern + prvý plne generovaný GPIO control plane**

Toto je jeden z najdôležitejších krokov v celom refaktore, lebo práve tu sa oddelí:

* **control plane** → generovaný frameworkom
* **data plane / peripheral behavior** → písané ručne alebo pluginom

To je presne architektúra, ktorú chceš, ak má byť framework dlhodobo rozšíriteľný.

---

# 1. Cieľ

Po tomto kroku už `gpio.sv` nebude obsahovať:

* bus decode
* register read/write mux
* reset hodnôt registrov

To všetko prevezme generovaný `gpio0_regs.sv`.

Ručne písaná periféria bude mať len:

* clock/reset
* registrové vstupy z regblocku
* status/irq výstupy
* fyzické IO

---

# 2. Architektonický pattern

Každá jednoduchá peripheral sa rozdelí na 2 bloky:

## A. generated register block

Napr.

```text
gpio0_regs.sv
```

Zodpovednosť:

* bus slave interface
* register storage
* readback
* write strobes
* reset defaults

## B. peripheral shell / core

Napr.

```text
gpio_core.sv
```

Zodpovednosť:

* robiť niečo s registrami
* produkovať status
* produkovať IRQ
* riadiť externé IO

Tým pádom vieš:

* meniť control plane bez zásahu do core logic
* znovu použiť core pri inom bus protokole
* neskôr generovať aj APB/AXI-lite wrapper bez zmeny periférie

---

# 3. Register block template upgrade

Doteraz regblock generoval len registre. Teraz doplníme:

* write pulse signály
* status inputs pre RO registre

## `socfw/ir/register_block.py`

Rozšír `RegFieldIR`:

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
    hw_source: str | None = None      # status / external signal for RO regs
    write_pulse: bool = False         # emit one-cycle write strobe


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

Rozšír builder:

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
                    hw_source=r.get("hw_source"),
                    write_pulse=bool(r.get("write_pulse", False)),
                )
                for r in regs_meta
            ],
        )
```

---

# 4. Nový regblock template

Tento template už podporí:

* `rw`
* `ro`
* `wo`
* hw-driven RO signal
* write pulse pre command registre

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
{% if r.access == "ro" and r.hw_source %}
  input  wire{% if r.width > 1 %} [{{ r.width - 1 }}:0]{% endif %} hw_{{ r.name.lower() }}
{% else %}
  output logic{% if r.width > 1 %} [{{ r.width - 1 }}:0]{% endif %} reg_{{ r.name.lower() }}
{% endif %}
{% if r.write_pulse %}
,
  output logic reg_{{ r.name.lower() }}_we
{% endif %}
{%- endfor %}
);

{% for r in regblk.regs if not (r.access == "ro" and r.hw_source) -%}
logic{% if r.width > 1 %} [{{ r.width - 1 }}:0]{% endif %} r_{{ r.name.lower() }};
{% endfor %}

{% if regblk.regs | selectattr("write_pulse") | list %}
always_comb begin
{% for r in regblk.regs if r.write_pulse -%}
  reg_{{ r.name.lower() }}_we = 1'b0;
{% endfor %}
  if (valid_i && we_i) begin
    case (addr_i)
{% for r in regblk.regs if r.write_pulse -%}
      {{ regblk.addr_width }}'h{{ "%X"|format(r.word_addr) }}: reg_{{ r.name.lower() }}_we = 1'b1;
{% endfor %}
      default: ;
    endcase
  end
end
{% endif %}

{% set writable = regblk.regs | rejectattr("access", "equalto", "ro") | list %}
{% if writable %}
always_ff @(posedge SYS_CLK or negedge RESET_N) begin
  if (!RESET_N) begin
{% for r in writable -%}
    r_{{ r.name.lower() }} <= {{ r.width }}'h{{ "%X"|format(r.reset) }};
{% endfor %}
  end else if (valid_i && we_i) begin
    case (addr_i)
{% for r in writable if r.access in ["rw", "wo"] -%}
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
{% if r.access == "ro" and r.hw_source -%}
    {{ regblk.addr_width }}'h{{ "%X"|format(r.word_addr) }}: rdata_o = { {{ 32 - r.width }}'b0, hw_{{ r.name.lower() }} };
{% else -%}
    {{ regblk.addr_width }}'h{{ "%X"|format(r.word_addr) }}: rdata_o = { {{ 32 - r.width }}'b0, r_{{ r.name.lower() }} };
{% endif -%}
{% endfor %}
    default: rdata_o = 32'h0;
  endcase
end

always_comb begin
  ready_o = valid_i;
end

{% for r in regblk.regs if not (r.access == "ro" and r.hw_source) -%}
assign reg_{{ r.name.lower() }} = r_{{ r.name.lower() }};
{% endfor %}

endmodule : {{ regblk.module_name }}
`default_nettype wire
```

---

# 5. Peripheral shell pattern

Teraz GPIO rozdelíme na:

* `gpio0_regs.sv` → generované
* `gpio_core.sv` → ručne písané
* `gpio_shell.sv` → tenký wrapper, môže byť ručný alebo neskôr generovaný

Pre prvý krok odporúčam:

* `gpio_core.sv` ručne
* `gpio.sv` ako shell ručne
* neskôr shell generovať

---

# 6. GPIO core

## `tests/golden/fixtures/soc_led_test/rtl/gpio_core.sv`

```systemverilog
`default_nettype none

module gpio_core (
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  input  wire [31:0] reg_value,
  output logic [5:0] gpio_o,
  output logic       irq_changed
);

  logic [31:0] prev_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      prev_value <= 32'h0;
    end else begin
      prev_value <= reg_value;
    end
  end

  assign gpio_o = reg_value[5:0];
  assign irq_changed = (reg_value != prev_value);

endmodule

`default_nettype wire
```

---

# 7. GPIO shell

Tento shell spája generated regblock + core.

## `tests/golden/fixtures/soc_led_test/rtl/gpio.sv`

```systemverilog
`default_nettype none

module gpio (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus,
  output wire [5:0] gpio_o,
  output wire irq_changed
);

  logic [31:0] reg_value;
  logic [31:0] rdata;
  logic        ready;

  gpio0_regs u_regs (
    .SYS_CLK   (SYS_CLK),
    .RESET_N   (RESET_N),
    .addr_i    (bus.addr[11:2]),
    .wdata_i   (bus.wdata),
    .we_i      (bus.we),
    .valid_i   (bus.valid),
    .rdata_o   (rdata),
    .ready_o   (ready),
    .reg_value (reg_value)
  );

  gpio_core u_core (
    .SYS_CLK     (SYS_CLK),
    .RESET_N     (RESET_N),
    .reg_value   (reg_value),
    .gpio_o      (gpio_o),
    .irq_changed (irq_changed)
  );

  assign bus.rdata = rdata;
  assign bus.ready = ready;

endmodule

`default_nettype wire
```

Toto je už veľmi dobrý pattern:

* regblock generated
* core reusable
* shell tenký

---

# 8. IP metadata pre generated regblock

GPIO descriptor ostane skoro rovnaký, ale register metadata sa teraz naozaj použijú.

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
  generate_registers: true
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
    - tests/golden/fixtures/soc_led_test/rtl/gpio_core.sv
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

---

# 9. Build pipeline update pre generated regblocks

## `socfw/build/pipeline.py`

Pridaj import:

```python
from socfw.builders.register_block_ir_builder import RegisterBlockIRBuilder
```

V `__init__`:

```python
        self.regblk_ir_builder = RegisterBlockIRBuilder()
```

Do `BuildResult`:

```python
    register_block_irs: list[object] = field(default_factory=list)
```

A v `run()` po `design = ...`:

```python
        regblk_irs = []
        for p in system.peripheral_blocks:
            ip = system.ip_catalog.get(p.module)
            if ip is None:
                continue
            if not ip.generate_registers:
                continue
            regblk = self.regblk_ir_builder.build_for_peripheral(p, ip.meta)
            if regblk is not None:
                regblk_irs.append(regblk)
```

A do return:

```python
            register_block_irs=regblk_irs,
```

---

# 10. Emit orchestrator update

## `socfw/plugins/bootstrap.py`

Pridaj:

```python
from socfw.emit.register_block_emitter import RegisterBlockEmitter
```

A registráciu:

```python
    reg.register_emitter("rtl_regs", RegisterBlockEmitter(templates_dir))
```

## `socfw/emit/orchestrator.py`

Podpis:

```python
    def emit_all(self, ctx, *, board_ir, timing_ir, rtl_ir, software_ir=None, docs_ir=None, register_block_irs=None) -> BuildManifest:
```

A na koniec:

```python
        if register_block_irs:
            emitter = self.registry.emitters.get("rtl_regs")
            if emitter is not None:
                for art in emitter.emit_many(ctx, register_block_irs):
                    manifest.artifacts.append(art)
```

## `socfw/build/full_pipeline.py`

Doplň do volania:

```python
            register_block_irs=result.register_block_irs,
```

---

# 11. IRQ wiring do periférií

Doteraz sme pridávali IRQ port connect na základe metadata. To necháme, ale teraz to už bude sedieť na shell pattern.

V `RtlIRBuilder` už máš:

```python
for irq in ip.meta.get("irqs", []):
    irq_name = str(irq["name"])
    sig = f"irq_{mod.instance}_{irq_name}"
    conns.append(RtlConn(port=f"irq_{irq_name}", signal=sig))
```

To je správne pre shell `gpio.sv`, ktorý má port `irq_changed`.

---

# 12. `soc_irq.h`

Ak si urobil predošlý krok, teraz to už bude generovať:

```c
#define GPIO0_CHANGED_IRQ 0U
```

A to je prvý praktický “vertical slice” od IP metadata až po SW header.

---

# 13. Čo sa týmto zlepšilo

Po tomto kroku sa periféria rozdelí tak, ako by mala byť v modernom frameworku:

### framework generuje

* regblock
* SW mapy
* IRQ mapy
* adresný model

### používateľ / plugin píše

* core logic
* prípadne thin shell

Toto je kľúčový moment pre rozšíriteľnosť. Odtiaľto už vieš:

* robiť rôzne bus wrappery nad rovnakým core
* robiť AXI-lite alebo Wishbone wrapper bez zmeny core
* generovať register map docs bez ručnej synchronizácie

---

# 14. Čo by som spravil hneď potom

Najlepší ďalší krok teraz je:

**peripheral shell generation**

Teda framework začne generovať aj ten shell, nielen regblock.

To znamená:

* IP descriptor povie:

  * bus port
  * reg outputs
  * hw status inputs
  * irq outputs
  * external ports
* framework vygeneruje:

  * `gpio0_shell.sv`
* ručne písaný zostane už len `gpio_core.sv`

To je podľa mňa ďalší veľký skok.

Ak chceš, ďalšia správa môže byť presne:
**generated peripheral shell layer + IP metadata contract pre core/shell split**.
