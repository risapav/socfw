Super. Nižšie dávam ďalší ucelený slice: **kompletné refaktorované emitre + Jinja2 templaty** pre:

* `soc_top.sv`
* `soc_top.sdc`
* `board.tcl`

Tento návrh už uzatvára prvý praktický end-to-end tok:

**YAML → typed model → validation → elaboration → IR → emit**

Pri návrhu sa opieram o to, čo je na súčasnom frameworku dobré:

* RTL má mať IR medzi modelom a templatom, nie logiku priamo v šablóne.  
* timing sa má skladať v builderi/context vrstve a šablóna má byť hlavne formátovanie. 
* Quartus board file má byť deterministický, plochý a čitateľný.  

Nižšie sú súbory.

---

# 1. Emittery

## `socfw/emit/rtl_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.rtl import RtlModuleIR


class RtlEmitter:
    family = "rtl"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx: BuildContext, ir: RtlModuleIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "rtl" / "soc_top.sv"

        content = self.renderer.render(
            "soc_top.sv.j2",
            module=ir,
        )
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

## `socfw/emit/timing_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer
from socfw.ir.timing import TimingIR


class TimingEmitter:
    family = "timing"

    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx: BuildContext, ir: TimingIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "timing" / "soc_top.sdc"

        content = self.renderer.render(
            "soc_top.sdc.j2",
            timing=ir,
        )
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

## `socfw/emit/board_quartus_emitter.py`

Toto je mierne vylepšená verzia z predchádzajúceho slice, aby bol výstup čitateľnejší a viac zoskupený.

```python
from __future__ import annotations

from collections import defaultdict
from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.ir.board import BoardIR, BoardPinAssignment


class QuartusBoardEmitter:
    family = "board"

    def emit(self, ctx: BuildContext, ir: BoardIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "hal" / "board.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("# AUTO-GENERATED - DO NOT EDIT")
        lines.append(f'# Device family: {ir.family}')
        lines.append(f"# Device part:   {ir.device}")
        lines.append("")
        lines.append(f'set_global_assignment -name FAMILY "{ir.family}"')
        lines.append(f"set_global_assignment -name DEVICE  {ir.device}")
        lines.append("")

        grouped: dict[str, list[BoardPinAssignment]] = defaultdict(list)
        for a in ir.assignments:
            grouped[a.top_name].append(a)

        for top_name in sorted(grouped.keys()):
            pins = sorted(grouped[top_name], key=lambda a: (-1 if a.index is None else a.index))
            sample = pins[0]

            lines.append(f"# {top_name}")

            if sample.io_standard:
                if any(p.index is not None for p in pins):
                    lines.append(
                        f'set_instance_assignment -name IO_STANDARD "{sample.io_standard}" -to {top_name}[*]'
                    )
                else:
                    lines.append(
                        f'set_instance_assignment -name IO_STANDARD "{sample.io_standard}" -to {top_name}'
                    )

            if sample.weak_pull_up:
                if any(p.index is not None for p in pins):
                    lines.append(
                        f"set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {top_name}[*]"
                    )
                else:
                    lines.append(
                        f"set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {top_name}"
                    )

            for pin in pins:
                if pin.index is None:
                    lines.append(f"set_location_assignment PIN_{pin.pin} -to {top_name}")
                else:
                    lines.append(f"set_location_assignment PIN_{pin.pin} -to {top_name}[{pin.index}]")
            lines.append("")

        out.write_text("\n".join(lines), encoding="ascii")

        return [
            GeneratedArtifact(
                family=self.family,
                path=str(out),
                generator=self.__class__.__name__,
            )
        ]
```

Toto priamo nahrádza starý model, kde Quartus board HAL vznikal z generátora s internou BSP databázou. Po novom emitter dostáva už čisté pin assignments z `BoardIR`.  

---

## `socfw/emit/files_tcl_emitter.py`

Nechávam aj tento, aby bol build kompletnejší.

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.ir.rtl import RtlModuleIR


class QuartusFilesEmitter:
    family = "files"

    def emit(self, ctx: BuildContext, ir: RtlModuleIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "files.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("# AUTO-GENERATED - DO NOT EDIT")
        lines.append("set_global_assignment -name SYSTEMVERILOG_FILE rtl/soc_top.sv")

        for fp in sorted(ir.extra_sources):
            if fp.endswith(".qip"):
                lines.append(f"set_global_assignment -name QIP_FILE {fp}")
            elif fp.endswith(".sdc"):
                lines.append(f"set_global_assignment -name SDC_FILE {fp}")
            elif fp.endswith(".v"):
                lines.append(f"set_global_assignment -name VERILOG_FILE {fp}")
            elif fp.endswith(".sv"):
                lines.append(f"set_global_assignment -name SYSTEMVERILOG_FILE {fp}")
            elif fp.endswith(".vhd") or fp.endswith(".vhdl"):
                lines.append(f"set_global_assignment -name VHDL_FILE {fp}")
            else:
                lines.append(f"set_global_assignment -name SYSTEMVERILOG_FILE {fp}")

        out.write_text("\n".join(lines) + "\n", encoding="ascii")

        return [
            GeneratedArtifact(
                family=self.family,
                path=str(out),
                generator=self.__class__.__name__,
            )
        ]
```

Toto nadväzuje na starý `files.tcl.j2`, ale zdroj súborov už nie je legacy flattening, ale `rtl_ir.extra_sources`. 

---

# 2. Templaty

## `socfw/templates/soc_top.sv.j2`

```jinja2
// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module {{ module.name }} (
{%- for p in module.ports %}
  {{ "input " if p.direction == "input" else "output" if p.direction == "output" else "inout " }} wire{% if p.width > 1 %} [{{ p.width - 1 }}:0]{% endif %} {{ p.name }}{{ "," if not loop.last else "" }}
{%- endfor %}
);

{# --------------------------------------------------------------------- #}
{# Wires #}
{# --------------------------------------------------------------------- #}
{% if module.wires %}
  // Internal wires
{% for w in module.wires %}
  wire{% if w.width > 1 %} [{{ w.width - 1 }}:0]{% endif %} {{ w.name }};{% if w.comment %} // {{ w.comment }}{% endif %}
{% endfor %}

{% endif %}

{# --------------------------------------------------------------------- #}
{# Reset synchronizers #}
{# --------------------------------------------------------------------- #}
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

{# --------------------------------------------------------------------- #}
{# Assigns #}
{# --------------------------------------------------------------------- #}
{% if module.assigns %}
  // Top-level / adapter assigns
{% for a in module.assigns %}
  assign {{ a.lhs }} = {{ a.rhs }};{% if a.comment %} // {{ a.comment }}{% endif %}
{% endfor %}

{% endif %}

{# --------------------------------------------------------------------- #}
{# Instances #}
{# --------------------------------------------------------------------- #}
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
{%- for c in inst.conns %}
    .{{ c.port }}({{ c.signal }}){{ "," if not loop.last else "" }}
{%- endfor %}
  );{% if inst.comment %} // {{ inst.comment }}{% endif %}

{% endfor %}
{% endif %}

endmodule : {{ module.name }}
`default_nettype wire
```

Táto šablóna je úmyselne „hlúpa“. Všetka podstatná logika má byť v builderi, rovnako ako pri dobrom smere starého `RtlBuilder -> RtlContext -> Jinja2`.  

---

## `socfw/templates/soc_top.sdc.j2`

```jinja2
# AUTO-GENERATED - DO NOT EDIT

# -------------------------------------------------------------------------
# Primary clocks
# -------------------------------------------------------------------------
{% for c in timing.clocks -%}
create_clock -name {{ c.name }} -period {{ "%.3f"|format(c.period_ns) }} [get_ports { {{ c.source_port }} }]
{% if c.uncertainty_ns is not none -%}
set_clock_uncertainty {{ "%.3f"|format(c.uncertainty_ns) }} [get_clocks { {{ c.name }} }]
{% endif -%}
{% endfor %}

{% if timing.generated_clocks %}
# -------------------------------------------------------------------------
# Generated clocks
# -------------------------------------------------------------------------
{% for g in timing.generated_clocks -%}
create_generated_clock \
  -name {{ g.name }} \
  -source [get_pins { u_{{ g.source_instance }}|{{ g.source_output }} }] \
  -multiply_by {{ g.multiply_by }} \
  -divide_by {{ g.divide_by }} \
  [get_pins { u_{{ g.source_instance }}|{{ g.source_output }} }]
{% if g.phase_shift_ps is not none -%}
# phase_shift_ps={{ g.phase_shift_ps }}
{% endif -%}
{% endfor %}

{% endif %}

{% if timing.clock_groups %}
# -------------------------------------------------------------------------
# Clock groups
# -------------------------------------------------------------------------
{% for grp in timing.clock_groups -%}
set_clock_groups -{{ grp.type }}
{%- for group in grp.groups %}
  -group { {% for clk in group %}{{ clk }}{% if not loop.last %} {% endif %}{% endfor %} }
{%- endfor %}
{% endfor %}

{% endif %}

{% if timing.derive_uncertainty %}
# -------------------------------------------------------------------------
# Derived uncertainty
# -------------------------------------------------------------------------
derive_clock_uncertainty

{% endif %}

{% if timing.false_paths %}
# -------------------------------------------------------------------------
# False paths
# -------------------------------------------------------------------------
{% for fp in timing.false_paths -%}
{% if fp.from_port %}
set_false_path -from [get_ports { {{ fp.from_port }} }]{% if fp.comment %} ; # {{ fp.comment }}{% endif %}
{% elif fp.from_clock and fp.to_clock %}
set_false_path -from [get_clocks { {{ fp.from_clock }} }] -to [get_clocks { {{ fp.to_clock }} }]{% if fp.comment %} ; # {{ fp.comment }}{% endif %}
{% elif fp.from_cell or fp.to_cell %}
set_false_path{% if fp.from_cell %} -from [get_cells { {{ fp.from_cell }} }]{% endif %}{% if fp.to_cell %} -to [get_cells { {{ fp.to_cell }} }]{% endif %}{% if fp.comment %} ; # {{ fp.comment }}{% endif %}
{% endif -%}
{% endfor %}

{% endif %}

{% if timing.io_delays %}
# -------------------------------------------------------------------------
# IO delays
# -------------------------------------------------------------------------
{% for d in timing.io_delays -%}
{% if d.direction == "input" -%}
set_input_delay -clock [get_clocks { {{ d.clock }} }] -max {{ "%.3f"|format(d.max_ns) }} [get_ports { {{ d.port }} }]
{% if d.min_ns is not none -%}
set_input_delay -clock [get_clocks { {{ d.clock }} }] -min {{ "%.3f"|format(d.min_ns) }} [get_ports { {{ d.port }} }]
{% endif -%}
{% else -%}
set_output_delay -clock [get_clocks { {{ d.clock }} }] -max {{ "%.3f"|format(d.max_ns) }} [get_ports { {{ d.port }} }]
{% if d.min_ns is not none -%}
set_output_delay -clock [get_clocks { {{ d.clock }} }] -min {{ "%.3f"|format(d.min_ns) }} [get_ports { {{ d.port }} }]
{% endif -%}
{% endif -%}
{% if d.comment %}# {{ d.comment }}{% endif %}
{% endfor %}
{% endif %}
```

Toto je opäť v rovnakom duchu ako starý `sdc.py`: builder má pripraviť zoznamy a template ich len vypíše. 

---

## `socfw/templates/board.tcl.j2`

Ak chceš držať board emitter čisto templated, tu je aj alternatíva k ručne skladanému emitteru.

```jinja2
# AUTO-GENERATED - DO NOT EDIT
# Device family: {{ ir.family }}
# Device part:   {{ ir.device }}

set_global_assignment -name FAMILY "{{ ir.family }}"
set_global_assignment -name DEVICE  {{ ir.device }}

{% for a in ir.assignments %}
{% if a.index is none %}
{% if a.io_standard %}set_instance_assignment -name IO_STANDARD "{{ a.io_standard }}" -to {{ a.top_name }}
{% endif %}
{% if a.weak_pull_up %}set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to {{ a.top_name }}
{% endif %}
set_location_assignment PIN_{{ a.pin }} -to {{ a.top_name }}

{% else %}
set_location_assignment PIN_{{ a.pin }} -to {{ a.top_name }}[{{ a.index }}]
{% endif %}
{% endfor %}
```

Ja by som ale pre `board.tcl` nechal skôr Python emitter bez šablóny, lebo tam je užitočné zoskupovanie podľa `top_name`.

---

# 3. Jednoduchý orchestration layer pre emitre

## `socfw/emit/run_emitters.py`

```python
from __future__ import annotations

from socfw.build.context import BuildContext
from socfw.build.manifest import BuildManifest
from socfw.emit.board_quartus_emitter import QuartusBoardEmitter
from socfw.emit.files_tcl_emitter import QuartusFilesEmitter
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.emit.timing_emitter import TimingEmitter


class EmitterSuite:
    def __init__(self, templates_dir: str) -> None:
        self.rtl = RtlEmitter(templates_dir)
        self.timing = TimingEmitter(templates_dir)
        self.board = QuartusBoardEmitter()
        self.files = QuartusFilesEmitter()

    def emit_all(self, ctx: BuildContext, *, board_ir, timing_ir, rtl_ir) -> BuildManifest:
        manifest = BuildManifest()

        for art in self.board.emit(ctx, board_ir):
            manifest.artifacts.append(art)

        for art in self.rtl.emit(ctx, rtl_ir):
            manifest.artifacts.append(art)

        for art in self.timing.emit(ctx, timing_ir):
            manifest.artifacts.append(art)

        for art in self.files.emit(ctx, rtl_ir):
            manifest.artifacts.append(art)

        return manifest
```

---

# 4. Aktualizovaný full pipeline

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
        )
        result.manifest = manifest
        return result
```

---

# 5. Voliteľný jednoduchý CLI entrypoint

## `socfw/cli/main.py`

```python
from __future__ import annotations

import argparse
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("project", help="Path to project YAML")
    ap.add_argument("--out", default="build/gen")
    ap.add_argument("--templates", default=str(Path(__file__).resolve().parents[1] / "templates"))
    args = ap.parse_args()

    pipeline = FullBuildPipeline(templates_dir=args.templates)
    result = pipeline.run(BuildRequest(project_file=args.project, out_dir=args.out))

    for d in result.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if result.ok:
        for art in result.manifest.artifacts:
            print(f"[{art.family}] {art.path}")

    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
```

---

# 6. Čo týmto už vieš robiť

Týmto máš už prvý reálne použiteľný refaktorovaný skeleton:

* načítať board/project/timing/IP YAML,
* postaviť typed model,
* validovať ho,
* rozpracovať na elaborated design,
* postaviť IR,
* emitnúť:

  * `rtl/soc_top.sv`
  * `timing/soc_top.sdc`
  * `hal/board.tcl`
  * `files.tcl`

To je už výrazne čistejšie než dnešný stav, kde:

* Quartus pin facts sú natvrdo v `tcl.py`, 
* RTL ešte stále potrebuje legacy SoC context bridge, 
* a generátory ešte pracujú nad širším, menej explicitným modelom. 

---

# 7. Čo by som spravil ako ďalší krok

Teraz už má zmysel spraviť jednu z dvoch vecí:

### možnosť A

doplniť **presné Jinja templaty pre register blocky, SW mapy a docs**, aby sa začal nahrádzať aj dnešný `SWGenerator`. To je prirodzený ďalší krok, lebo starý framework už má dobrý základ v `soc_map.h`, linker scripte a docs.   

### možnosť B

doplniť **bus/interconnect planner API** a prvý plugin pre `simple_bus`, čím sa otvorí cesta k SoC mode bez legacy bridge.

Najpraktickejšie by som išiel teraz cez **A**: SW/docs vrstvu, lebo je jednoduchšia a uzatvorí ďalší veľký kus frameworku.

V ďalšej správe ti viem dať **kompletné refaktorované SW/docs IR + builder + emitre + templaty**.
