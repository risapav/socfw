Super. Ideme na:

**generated peripheral shell layer + IP metadata contract pre core/shell split**

Toto je ďalší veľký krok, lebo po ňom už framework nebude generovať len:

* register block,
* SW/docs mapy,

ale aj samotný **bus-facing wrapper** periférie.

Tým pádom sa ručne písaný RTL zúži na čistý:

* `*_core.sv`

a framework vygeneruje:

* `*_regs.sv`
* `*_shell.sv`

To je presne moderný pattern, ktorý chceš pre dlhodobú rozšíriteľnosť.

---

# 1. Cieľ

Po tomto kroku bude IP descriptor vedieť opísať:

* aký je názov core modulu,
* aké registre sa majú exportovať do core,
* aké status signály idú z core do shellu,
* aké IRQ signály idú z core do topu,
* aké externé porty má shell prepustiť.

A framework z toho vygeneruje:

```text
gpio0_regs.sv
gpio0_shell.sv
```

Ručne ostane iba napr.:

```text
gpio_core.sv
```

---

# 2. Nový metadata kontrakt v IP YAML

Rozšírime IP YAML o sekciu `shell`.

## update `socfw/config/ip_schema.py`

Pridaj:

```python
class IpShellPortSchema(BaseModel):
    name: str
    direction: Literal["input", "output", "inout"]
    width: int = 1


class IpShellCorePortSchema(BaseModel):
    kind: Literal["reg", "status", "irq", "external"]
    reg_name: str | None = None
    signal_name: str | None = None
    port_name: str


class IpShellSchema(BaseModel):
    module: str
    external_ports: list[IpShellPortSchema] = Field(default_factory=list)
    core_ports: list[IpShellCorePortSchema] = Field(default_factory=list)
```

A do `IpConfigSchema`:

```python
    shell: IpShellSchema | None = None
```

---

## update `socfw/config/ip_loader.py`

Doplň do `meta`:

```python
                "shell": (
                    {
                        "module": doc.shell.module,
                        "external_ports": [
                            {
                                "name": p.name,
                                "direction": p.direction,
                                "width": p.width,
                            }
                            for p in doc.shell.external_ports
                        ],
                        "core_ports": [
                            {
                                "kind": cp.kind,
                                "reg_name": cp.reg_name,
                                "signal_name": cp.signal_name,
                                "port_name": cp.port_name,
                            }
                            for cp in doc.shell.core_ports
                        ],
                    }
                    if doc.shell is not None else None
                ),
```

---

# 3. Shell IR

## nový `socfw/ir/peripheral_shell.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ShellExternalPortIR:
    name: str
    direction: str
    width: int = 1


@dataclass(frozen=True)
class ShellCoreConnIR:
    kind: str                 # reg / status / irq / external
    port_name: str
    signal_name: str


@dataclass
class PeripheralShellIR:
    module_name: str
    core_module: str
    regblock_module: str
    instance_name: str
    external_ports: list[ShellExternalPortIR] = field(default_factory=list)
    core_conns: list[ShellCoreConnIR] = field(default_factory=list)
```

---

# 4. Shell builder

## nový `socfw/builders/peripheral_shell_ir_builder.py`

```python
from __future__ import annotations

from socfw.ir.peripheral_shell import (
    PeripheralShellIR,
    ShellCoreConnIR,
    ShellExternalPortIR,
)


class PeripheralShellIRBuilder:
    def build_for_peripheral(self, p, ip_meta: dict) -> PeripheralShellIR | None:
        shell = ip_meta.get("shell")
        if not shell:
            return None

        regblock_module = f"{p.instance}_regs"
        shell_module = f"{p.instance}_shell"

        external_ports = [
            ShellExternalPortIR(
                name=ep["name"],
                direction=ep["direction"],
                width=int(ep.get("width", 1)),
            )
            for ep in shell.get("external_ports", [])
        ]

        core_conns: list[ShellCoreConnIR] = []
        for cp in shell.get("core_ports", []):
            kind = cp["kind"]
            port_name = cp["port_name"]

            if kind == "reg":
                signal_name = f"reg_{cp['reg_name']}"
            elif kind == "status":
                signal_name = f"hw_{cp['signal_name']}"
            elif kind == "irq":
                signal_name = cp["signal_name"]
            elif kind == "external":
                signal_name = cp["signal_name"]
            else:
                raise ValueError(f"Unsupported shell core port kind: {kind}")

            core_conns.append(
                ShellCoreConnIR(
                    kind=kind,
                    port_name=port_name,
                    signal_name=signal_name,
                )
            )

        return PeripheralShellIR(
            module_name=shell_module,
            core_module=shell["module"],
            regblock_module=regblock_module,
            instance_name=p.instance,
            external_ports=external_ports,
            core_conns=core_conns,
        )
```

---

# 5. Shell emitter

## nový `socfw/emit/peripheral_shell_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer


class PeripheralShellEmitter:
    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit_many(self, ctx, irs) -> list[GeneratedArtifact]:
        artifacts: list[GeneratedArtifact] = []

        for ir in irs:
            out = Path(ctx.out_dir) / "rtl" / f"{ir.module_name}.sv"
            out.parent.mkdir(parents=True, exist_ok=True)

            self.renderer.write_text(
                out,
                self.renderer.render("peripheral_shell.sv.j2", shell=ir),
            )
            artifacts.append(
                GeneratedArtifact("rtl_shells", str(out), self.__class__.__name__)
            )

        return artifacts
```

---

# 6. Shell template

## nový `socfw/templates/peripheral_shell.sv.j2`

```jinja2
// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module {{ shell.module_name }} (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus
{% for p in shell.external_ports -%}
,
  {{ "input" if p.direction == "input" else "output" if p.direction == "output" else "inout" }} wire{% if p.width > 1 %} [{{ p.width - 1 }}:0]{% endif %} {{ p.name }}
{%- endfor %}
{% for c in shell.core_conns if c.kind == "irq" -%}
,
  output wire {{ c.signal_name }}
{%- endfor %}
);

{% for c in shell.core_conns if c.kind == "reg" -%}
logic [31:0] {{ c.signal_name }};
{% endfor %}
logic [31:0] rdata;
logic        ready;
{% for c in shell.core_conns if c.kind == "status" -%}
logic [31:0] {{ c.signal_name }};
{% endfor %}

{{ shell.regblock_module }} u_regs (
  .SYS_CLK (SYS_CLK),
  .RESET_N (RESET_N),
  .addr_i  (bus.addr[11:2]),
  .wdata_i (bus.wdata),
  .we_i    (bus.we),
  .valid_i (bus.valid),
  .rdata_o (rdata),
  .ready_o (ready)
{% for c in shell.core_conns if c.kind == "reg" -%}
,
  .{{ c.signal_name }} ({{ c.signal_name }})
{% endfor %}
{% for c in shell.core_conns if c.kind == "status" -%}
,
  .{{ c.signal_name }} ({{ c.signal_name }})
{% endfor %}
);

{{ shell.core_module }} u_core (
  .SYS_CLK (SYS_CLK),
  .RESET_N (RESET_N)
{% for c in shell.core_conns -%}
,
  .{{ c.port_name }} ({{ c.signal_name }})
{% endfor %}
{% for p in shell.external_ports -%}
,
  .{{ p.name }} ({{ p.name }})
{% endfor %}
);

assign bus.rdata = rdata;
assign bus.ready = ready;

endmodule : {{ shell.module_name }}
`default_nettype wire
```

---

# 7. Build pipeline update

## `socfw/build/pipeline.py`

Pridaj import:

```python
from socfw.builders.peripheral_shell_ir_builder import PeripheralShellIRBuilder
```

Do `BuildResult` pridaj:

```python
    peripheral_shell_irs: list[object] = field(default_factory=list)
```

V `__init__`:

```python
        self.shell_ir_builder = PeripheralShellIRBuilder()
```

V `run()` po `regblk_irs`:

```python
        shell_irs = []
        for p in system.peripheral_blocks:
            ip = system.ip_catalog.get(p.module)
            if ip is None:
                continue
            shell_ir = self.shell_ir_builder.build_for_peripheral(p, ip.meta)
            if shell_ir is not None:
                shell_irs.append(shell_ir)
```

A do return:

```python
            peripheral_shell_irs=shell_irs,
```

---

# 8. Emit orchestrator update

## `socfw/plugins/bootstrap.py`

Pridaj:

```python
from socfw.emit.peripheral_shell_emitter import PeripheralShellEmitter
```

A registráciu:

```python
    reg.register_emitter("rtl_shells", PeripheralShellEmitter(templates_dir))
```

## `socfw/emit/orchestrator.py`

Podpis:

```python
    def emit_all(
        self,
        ctx,
        *,
        board_ir,
        timing_ir,
        rtl_ir,
        software_ir=None,
        docs_ir=None,
        register_block_irs=None,
        peripheral_shell_irs=None,
    ) -> BuildManifest:
```

A na koniec:

```python
        if peripheral_shell_irs:
            emitter = self.registry.emitters.get("rtl_shells")
            if emitter is not None:
                for art in emitter.emit_many(ctx, peripheral_shell_irs):
                    manifest.artifacts.append(art)
```

## `socfw/build/full_pipeline.py`

Doplň do volania:

```python
            peripheral_shell_irs=result.peripheral_shell_irs,
```

---

# 9. GPIO IP descriptor pre shell generation

Teraz shell nebude ručný. Descriptor povie, ako ho vygenerovať.

## `tests/golden/fixtures/soc_led_test/ip/gpio.ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: gpio
  module: gpio0_shell
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

shell:
  module: gpio_core
  external_ports:
    - name: gpio_o
      direction: output
      width: 6
  core_ports:
    - kind: reg
      reg_name: value
      port_name: reg_value
    - kind: irq
      signal_name: irq_changed
      port_name: irq_changed
    - kind: external
      signal_name: gpio_o
      port_name: gpio_o
```

Dôležité:

* `ip.module` je teraz `gpio0_shell`
* ručne písaný ostáva len `gpio_core.sv`

---

# 10. GPIO core ostáva čistý

## `tests/golden/fixtures/soc_led_test/rtl/gpio_core.sv`

```systemverilog
`default_nettype none

module gpio_core (
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  input  wire [31:0] reg_value,
  output wire [5:0]  gpio_o,
  output wire        irq_changed
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

A ručný `gpio.sv` môžeš úplne zmazať.

---

# 11. RTL builder update pre generated shell module name

Tu netreba veľa meniť, lebo `RtlIRBuilder` už berie `ip.module`. Tým pádom sa bude inštanciovať `gpio0_shell`.

Jediné, čo treba doplniť, je pridať generated shell a regblock súbory do `rtl.extra_sources`.

V `socfw/build/full_pipeline.py` alebo priamo v emitri to už pôjde cez manifest, ale ak chceš, aby ich `files.tcl` tiež obsahoval, doplň po emit-all:

Najčistejšie je pri skladaní `rtl_ir.extra_sources` v pipeline pridať ich explicitne.

Jednoduchý variant v `BuildPipeline.run()`:

```python
        for s in shell_irs:
            generated_path = f"rtl/{s.module_name}.sv"
            if generated_path not in rtl_ir.extra_sources:
                rtl_ir.extra_sources.append(generated_path)

        for r in regblk_irs:
            generated_path = f"rtl/{r.module_name}.sv"
            if generated_path not in rtl_ir.extra_sources:
                rtl_ir.extra_sources.append(generated_path)
```

---

# 12. Status-driven RO registre

Teraz už vieme generovať shell, takže môžeme podporiť aj RO status register z core.

Príklad do budúcna:

```yaml
registers:
  - name: value
    offset: 0
    width: 32
    access: rw
    reset: 0
  - name: status
    offset: 4
    width: 32
    access: ro
    hw_source: status
```

A do `shell.core_ports`:

```yaml
  core_ports:
    - kind: status
      signal_name: status
      port_name: status
```

Tým pádom:

* core produkuje `status`
* shell ho privedie ako `hw_status`
* regblock ho spraví čitateľný cez bus

To je veľmi silný pattern.

---

# 13. Čo týmto získavaš

Po tomto kroku framework vie:

* generovať register block
* generovať peripheral shell
* udržiavať SW/docs mapy z jedného zdroja pravdy
* oddeliť core logic od control plane
* robiť IP reusable naprieč bus wrappermi

Toto je presne architektúra, ktorá sa neskôr veľmi dobre rozšíri na:

* AXI-lite shell
* Wishbone shell
* APB shell

pričom `gpio_core.sv` ostane nezmenený.

---

# 14. Čo by som spravil hneď potom

Najlepší ďalší krok teraz je jeden z týchto dvoch:

### možnosť A

**status/command register contract**

* `write_pulse`
* `clear_on_write`
* `set_by_hw`
* `sticky irq pending`

### možnosť B

**CPU descriptor registry + real softcore integration**

* CPU už nebude inline v project YAML
* bude mať descriptor rovnako ako periféria

Môj praktický odporúčaný ďalší krok je:

👉 **A – status/command register contract**

Lebo tým veľmi posilníš generatívnosť periférií a získaš základ pre serióznejšie IP bez ručného boilerplate.
