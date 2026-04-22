Super. Ideme na:

# developer tooling v1: `socfw init`, project scaffolds, board/example selection, and starter template generation

Toto je správny ďalší krok, lebo framework už má silné jadro. Teraz treba spraviť to, aby sa **nový projekt dal založiť za minútu**, nie za pol dňa kopírovania fixture súborov.

Cieľ:

* `socfw init` založí nový projekt
* vieš zvoliť:

  * typ projektu
  * board
  * CPU
  * bus/fabric
  * príklad/template
* vygeneruje sa:

  * `project.yaml`
  * `board.yaml` alebo referencia na board catalog
  * adresáre `ip/`, `fw/`, `rtl/`, `tb/`
  * základné starter súbory

Toto dramaticky zlepší použiteľnosť frameworku.

---

# 1. Cieľový UX

Chceš vedieť spraviť napríklad:

```bash
socfw init my_blink --template blink
socfw init my_soc --template picorv32-soc --board qmtech_ep4ce55
socfw init my_axi_demo --template axi-bridge --board qmtech_ep4ce55
```

alebo interaktívne:

```bash
socfw init
```

a dostať otázky:

* názov projektu?
* board?
* standalone alebo soc?
* CPU?
* simple_bus?
* firmware enabled?
* starter example?

---

# 2. Rozumný scope v1

Na prvú verziu by som nerobil plne interaktívny wizard s desiatkami vetiev.
Odporúčam **dve vrstvy**:

## A. non-interactive

rýchly a skriptovateľný:

```bash
socfw init <name> --template <template> --board <board>
```

## B. simple interactive fallback

keď chýbajú argumenty, dopýta sa.

To je najpraktickejšie.

---

# 3. Template registry

Najprv potrebuješ vedieť, aké scaffoldy framework pozná.

## nový `socfw/scaffold/templates.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ScaffoldTemplate:
    key: str
    title: str
    mode: str                  # standalone / soc
    description: str
    files: tuple[str, ...] = ()
    defaults: dict[str, object] = field(default_factory=dict)
```

---

## nový `socfw/scaffold/template_registry.py`

```python
from __future__ import annotations

from socfw.scaffold.templates import ScaffoldTemplate


class TemplateRegistry:
    def all(self) -> list[ScaffoldTemplate]:
        return [
            ScaffoldTemplate(
                key="blink",
                title="Standalone blink",
                mode="standalone",
                description="Minimal standalone blink project.",
                defaults={
                    "cpu": None,
                    "firmware": False,
                },
            ),
            ScaffoldTemplate(
                key="soc-led",
                title="Simple SoC LED demo",
                mode="soc",
                description="simple_bus SoC with RAM and GPIO.",
                defaults={
                    "cpu": "dummy_cpu",
                    "firmware": False,
                },
            ),
            ScaffoldTemplate(
                key="picorv32-soc",
                title="PicoRV32 SoC",
                mode="soc",
                description="PicoRV32 + RAM + GPIO + firmware flow.",
                defaults={
                    "cpu": "picorv32_min",
                    "firmware": True,
                },
            ),
            ScaffoldTemplate(
                key="axi-bridge",
                title="AXI-lite bridge demo",
                mode="soc",
                description="simple_bus SoC with AXI-lite bridged peripheral.",
                defaults={
                    "cpu": "picorv32_min",
                    "firmware": True,
                },
            ),
            ScaffoldTemplate(
                key="wishbone-bridge",
                title="Wishbone bridge demo",
                mode="soc",
                description="simple_bus SoC with Wishbone bridged peripheral.",
                defaults={
                    "cpu": "dummy_cpu",
                    "firmware": False,
                },
            ),
        ]

    def get(self, key: str) -> ScaffoldTemplate | None:
        for t in self.all():
            if t.key == key:
                return t
        return None
```

---

# 4. Board catalog

Pre `init` nechceš vždy kopírovať celý board YAML. Lepší model je mať malý board catalog.

## nový `socfw/scaffold/board_catalog.py`

```python
from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class BoardCatalogEntry:
    key: str
    title: str
    board_file: str
    family: str
    note: str = ""


class BoardCatalog:
    def all(self) -> list[BoardCatalogEntry]:
        return [
            BoardCatalogEntry(
                key="qmtech_ep4ce55",
                title="QMTech EP4CE55F23C8",
                board_file="boards/qmtech_ep4ce55/board.yaml",
                family="cyclone_iv_e",
            ),
        ]

    def get(self, key: str) -> BoardCatalogEntry | None:
        for b in self.all():
            if b.key == key:
                return b
        return None
```

Poznámka:
Toto predpokladá, že časom budeš mať `boards/` ako štandardný adresár alebo catalog package.

---

# 5. Init request model

## nový `socfw/scaffold/model.py`

```python
from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class InitRequest:
    name: str
    out_dir: str
    template: str
    board: str | None = None
    cpu: str | None = None
    force: bool = False
```

---

# 6. Scaffold renderer

Tu spravíš reálny generator súborov.

## nový `socfw/scaffold/generator.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.emit.renderer import Renderer
from socfw.scaffold.board_catalog import BoardCatalog
from socfw.scaffold.model import InitRequest
from socfw.scaffold.template_registry import TemplateRegistry


class ScaffoldGenerator:
    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)
        self.templates = TemplateRegistry()
        self.boards = BoardCatalog()

    def generate(self, req: InitRequest) -> list[str]:
        tmpl = self.templates.get(req.template)
        if tmpl is None:
            raise ValueError(f"Unknown scaffold template '{req.template}'")

        out = Path(req.out_dir) / req.name
        if out.exists() and any(out.iterdir()) and not req.force:
            raise ValueError(f"Target directory '{out}' is not empty; use --force")

        out.mkdir(parents=True, exist_ok=True)

        created: list[str] = []
        created.extend(self._write_common(out, req, tmpl))

        if tmpl.key == "blink":
            created.extend(self._write_blink(out, req))
        elif tmpl.key == "soc-led":
            created.extend(self._write_soc_led(out, req))
        elif tmpl.key == "picorv32-soc":
            created.extend(self._write_picorv32_soc(out, req))
        elif tmpl.key == "axi-bridge":
            created.extend(self._write_axi_bridge(out, req))
        elif tmpl.key == "wishbone-bridge":
            created.extend(self._write_wishbone_bridge(out, req))
        else:
            raise ValueError(f"Unhandled scaffold template '{tmpl.key}'")

        return created

    def _write(self, out_file: Path, content: str) -> str:
        out_file.parent.mkdir(parents=True, exist_ok=True)
        out_file.write_text(content, encoding="utf-8")
        return str(out_file)

    def _write_common(self, out: Path, req: InitRequest, tmpl) -> list[str]:
        created = []

        created.append(self._write(
            out / "README.md",
            self.renderer.render(
                "scaffold/README.md.j2",
                project_name=req.name,
                template=tmpl,
                board=req.board,
            ),
        ))

        created.append(self._write(
            out / ".gitignore",
            self.renderer.render("scaffold/gitignore.j2"),
        ))

        return created

    def _write_blink(self, out: Path, req: InitRequest) -> list[str]:
        return [
            self._write(
                out / "project.yaml",
                self.renderer.render(
                    "scaffold/project_blink.yaml.j2",
                    project_name=req.name,
                    board=req.board or "qmtech_ep4ce55",
                ),
            ),
            self._write(
                out / "ip" / "blink_test.ip.yaml",
                self.renderer.render("scaffold/ip_blink_test.ip.yaml.j2"),
            ),
        ]

    def _write_soc_led(self, out: Path, req: InitRequest) -> list[str]:
        return [
            self._write(
                out / "project.yaml",
                self.renderer.render(
                    "scaffold/project_soc_led.yaml.j2",
                    project_name=req.name,
                    board=req.board or "qmtech_ep4ce55",
                ),
            ),
            self._write(
                out / "ip" / "gpio.ip.yaml",
                self.renderer.render("scaffold/ip_gpio.ip.yaml.j2"),
            ),
            self._write(
                out / "rtl" / "gpio_core.sv",
                self.renderer.render("scaffold/gpio_core.sv.j2"),
            ),
        ]

    def _write_picorv32_soc(self, out: Path, req: InitRequest) -> list[str]:
        return [
            self._write(
                out / "project.yaml",
                self.renderer.render(
                    "scaffold/project_picorv32_soc.yaml.j2",
                    project_name=req.name,
                    board=req.board or "qmtech_ep4ce55",
                    cpu=req.cpu or "picorv32_min",
                ),
            ),
            self._write(
                out / "fw" / "main.c",
                self.renderer.render("scaffold/fw_main_picorv32.c.j2"),
            ),
            self._write(
                out / "fw" / "start.S",
                self.renderer.render("scaffold/fw_start.S.j2"),
            ),
            self._write(
                out / "fw" / "cpu_irq.h",
                self.renderer.render("scaffold/fw_cpu_irq.h.j2"),
            ),
        ]

    def _write_axi_bridge(self, out: Path, req: InitRequest) -> list[str]:
        return [
            self._write(
                out / "project.yaml",
                self.renderer.render(
                    "scaffold/project_axi_bridge.yaml.j2",
                    project_name=req.name,
                    board=req.board or "qmtech_ep4ce55",
                    cpu=req.cpu or "picorv32_min",
                ),
            ),
            self._write(
                out / "ip" / "axi_gpio.ip.yaml",
                self.renderer.render("scaffold/ip_axi_gpio.ip.yaml.j2"),
            ),
            self._write(
                out / "rtl" / "axi_gpio.sv",
                self.renderer.render("scaffold/axi_gpio.sv.j2"),
            ),
            self._write(
                out / "fw" / "main.c",
                self.renderer.render("scaffold/fw_main_axi_bridge.c.j2"),
            ),
            self._write(
                out / "fw" / "start.S",
                self.renderer.render("scaffold/fw_start.S.j2"),
            ),
        ]

    def _write_wishbone_bridge(self, out: Path, req: InitRequest) -> list[str]:
        return [
            self._write(
                out / "project.yaml",
                self.renderer.render(
                    "scaffold/project_wishbone_bridge.yaml.j2",
                    project_name=req.name,
                    board=req.board or "qmtech_ep4ce55",
                ),
            ),
            self._write(
                out / "ip" / "wb_gpio.ip.yaml",
                self.renderer.render("scaffold/ip_wb_gpio.ip.yaml.j2"),
            ),
            self._write(
                out / "rtl" / "wb_gpio.sv",
                self.renderer.render("scaffold/wb_gpio.sv.j2"),
            ),
        ]
```

---

# 7. CLI `init`

## update `socfw/cli/main.py`

Pridaj import:

```python
from socfw.scaffold.generator import ScaffoldGenerator
from socfw.scaffold.model import InitRequest
from socfw.scaffold.template_registry import TemplateRegistry
from socfw.scaffold.board_catalog import BoardCatalog
```

Pridaj handler:

```python
def cmd_init(args) -> int:
    gen = ScaffoldGenerator(templates_dir=args.templates)

    req = InitRequest(
        name=args.name,
        out_dir=args.out,
        template=args.template,
        board=args.board,
        cpu=args.cpu,
        force=args.force,
    )

    try:
        created = gen.generate(req)
    except Exception as exc:
        print(f"ERROR INIT001: {exc}")
        return 1

    for p in created:
        print(p)
    return 0
```

Do parsera pridaj:

```python
    i = sub.add_parser("init")
    i.add_argument("name")
    i.add_argument("--template", required=True, choices=[t.key for t in TemplateRegistry().all()])
    i.add_argument("--board", default=None)
    i.add_argument("--cpu", default=None)
    i.add_argument("--out", default=".")
    i.add_argument("--force", action="store_true")
    i.add_argument("--templates", default=_default_templates_dir())
    i.set_defaults(func=cmd_init)
```

---

# 8. CLI listing commands

Veľmi užitočné budú aj:

```bash
socfw list-templates
socfw list-boards
```

## `socfw/cli/main.py`

Pridaj:

```python
def cmd_list_templates(args) -> int:
    for t in TemplateRegistry().all():
        print(f"{t.key}: {t.title} [{t.mode}] - {t.description}")
    return 0


def cmd_list_boards(args) -> int:
    for b in BoardCatalog().all():
        print(f"{b.key}: {b.title} ({b.family})")
    return 0
```

A parser:

```python
    lt = sub.add_parser("list-templates")
    lt.set_defaults(func=cmd_list_templates)

    lb = sub.add_parser("list-boards")
    lb.set_defaults(func=cmd_list_boards)
```

---

# 9. Scaffold templates

Tu je minimálny set. Nejde o úplne všetky, len základ.

## `socfw/templates/scaffold/gitignore.j2`

```gitignore
build/
dist/
*.egg-info/
.pytest_cache/
__pycache__/
*.pyc
```

---

## `socfw/templates/scaffold/README.md.j2`

````md
# {{ project_name }}

Generated by `socfw init`.

Template: `{{ template.key }}`
Board: `{{ board or "default" }}`

## Commands

```bash
socfw validate project.yaml
socfw build project.yaml --out build/gen
````

````

---

## `socfw/templates/scaffold/project_blink.yaml.j2`

```yaml
version: 2
kind: project

project:
  name: {{ project_name }}
  mode: standalone
  board: {{ board }}
  board_file: boards/{{ board }}/board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - ip

features:
  use:
    - board:onboard.leds

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

modules:
  - instance: blink_test
    type: blink_test
    params:
      CLK_FREQ: 50000000
    clocks:
      SYS_CLK: sys_clk
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds

artifacts:
  emit: [rtl, timing, board, docs]
````

---

## `socfw/templates/scaffold/ip_blink_test.ip.yaml.j2`

```yaml
version: 2
kind: ip

ip:
  name: blink_test
  module: blink_test
  category: standalone

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: null

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

artifacts:
  synthesis:
    - rtl/blink_test.sv
  simulation: []
  metadata: []
```

---

## `socfw/templates/scaffold/project_picorv32_soc.yaml.j2`

```yaml
version: 2
kind: project

project:
  name: {{ project_name }}
  mode: soc
  board: {{ board }}
  board_file: boards/{{ board }}/board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - ip

features:
  use:
    - board:onboard.leds

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

cpu:
  instance: cpu0
  type: {{ cpu }}
  fabric: main
  reset_vector: 0x00000000
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

firmware:
  enabled: true
  src_dir: fw
  out_dir: build/fw
  linker_script: build/gen/sw/sections.lds
  elf_file: firmware.elf
  bin_file: firmware.bin
  hex_file: firmware.hex
  tool_prefix: riscv32-unknown-elf-
  cflags:
    - -Ibuild/gen/sw

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

---

## `socfw/templates/scaffold/fw_main_picorv32.c.j2`

```c
#include "soc_map.h"

static void delay(volatile unsigned count) {
    while (count--) {
        __asm__ volatile ("nop");
    }
}

int main(void) {
    while (1) {
        GPIO0_VALUE_REG = 0x15;
        delay(200000);
        GPIO0_VALUE_REG = 0x2A;
        delay(200000);
    }
    return 0;
}
```

---

## `socfw/templates/scaffold/fw_start.S.j2`

```asm
.section .text.start
.global _start
_start:
  la sp, _stack_top
  call main
1:
  j 1b
```

---

## `socfw/templates/scaffold/fw_cpu_irq.h.j2`

```c
#ifndef CPU_IRQ_H
#define CPU_IRQ_H

static inline void cpu_enable_irqs(void) {
    __asm__ volatile ("" ::: "memory");
}

#endif
```

---

# 10. Example catalog integration

Keď už máš `init`, oplatí sa mať aj príklady.

Odporúčam mať:

```text
examples/
  blink/
  soc-led/
  picorv32-soc/
  axi-bridge/
  wishbone-bridge/
```

a generovať ich buď:

* ručne z fixtures,
* alebo rovno cez `socfw init` do `examples/`.

To je veľmi praktické pre onboarding.

---

# 11. Integration tests pre init

## `tests/integration/test_init_scaffolds.py`

```python
from pathlib import Path

from socfw.scaffold.generator import ScaffoldGenerator
from socfw.scaffold.model import InitRequest


def test_init_blink_scaffold(tmp_path):
    gen = ScaffoldGenerator(templates_dir="socfw/templates")
    created = gen.generate(
        InitRequest(
            name="demo_blink",
            out_dir=str(tmp_path),
            template="blink",
            board="qmtech_ep4ce55",
        )
    )

    root = tmp_path / "demo_blink"
    assert root.exists()
    assert (root / "project.yaml").exists()
    assert (root / "ip" / "blink_test.ip.yaml").exists()


def test_init_picorv32_scaffold(tmp_path):
    gen = ScaffoldGenerator(templates_dir="socfw/templates")
    gen.generate(
        InitRequest(
            name="demo_soc",
            out_dir=str(tmp_path),
            template="picorv32-soc",
            board="qmtech_ep4ce55",
            cpu="picorv32_min",
        )
    )

    root = tmp_path / "demo_soc"
    assert (root / "project.yaml").exists()
    assert (root / "fw" / "main.c").exists()
    assert (root / "fw" / "start.S").exists()
```

---

# 12. README doplnenie

Do `README.md` doplň:

````md
## Project scaffolding

List templates:
```bash
socfw list-templates
````

List boards:

```bash
socfw list-boards
```

Initialize a new project:

```bash
socfw init my_soc --template picorv32-soc --board qmtech_ep4ce55
```

```

---

# 13. Čo týmto získaš

Po tomto kroku framework bude oveľa použiteľnejší:

- nový projekt sa zakladá rýchlo
- onboarding je jednoduchší
- menšie riziko, že ľudia budú kopírovať staré fixture chaoticky
- znižuje sa počet chýb v počiatočnom nastavení

To je veľká praktická hodnota.

---

# 14. Čo by som spravil hneď potom

Po tomto bode sú podľa mňa najlepšie tri smery:

### A
**vendor IP import cleanup**
- qip/qsys/IP catalog normalization

### B
**board/package catalogs**
- shared board packs
- reusable cpu/ip packs
- external package search paths

### C
**project generation v2**
- richer interactive wizard
- optional board copy vs reference
- optional testbench and CI scaffolding

Môj praktický odporúčaný ďalší krok je:

👉 **B — board/package catalogs + reusable external packs**

Lebo to prirodzene nadväzuje na `init` a posunie framework smerom k reálnemu zdieľaniu medzi projektami.

Ak chceš, ďalšia správa môže byť presne:
**board/package catalogs: reusable board packs, IP/CPU packs, external search paths, and dependency resolution policy**
```
