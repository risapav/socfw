Áno. Tu je **Commit 28 ako file-by-file scaffold**:

# Commit 28 — `socfw init` vytvára new-flow projekty by default

Cieľ commitu:

* nové projekty už nevznikajú kopírovaním legacy skeletonu
* `socfw init` vytvorí moderný `project.yaml`
* default projekt používa:

  * `registries.packs`
  * `project.board`
  * lokálny IP descriptor
  * nový flow cez `socfw validate/build`

---

# Názov commitu

```text
scaffold: make socfw init create new-flow projects by default
```

---

# Súbory, ktoré pridať

```text
socfw/scaffold/__init__.py
socfw/scaffold/init_project.py
socfw/scaffold/templates/blink/project.yaml.j2
socfw/scaffold/templates/blink/ip/blink_test.ip.yaml.j2
socfw/scaffold/templates/blink/rtl/blink_test.sv.j2
tests/integration/test_socfw_init_blink.py
```

---

# Súbory, ktoré upraviť

```text
socfw/cli/main.py
docs/user/getting_started.md
docs/dev_notes/checkpoints.md
```

---

# `socfw/scaffold/init_project.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.emit.renderer import Renderer


class ProjectInitializer:
    def __init__(self) -> None:
        self.templates_dir = Path(__file__).parent / "templates"

    def init_blink(self, *, target_dir: str, name: str, board: str) -> list[str]:
        target = Path(target_dir)
        target.mkdir(parents=True, exist_ok=True)

        renderer = Renderer(str(self.templates_dir))
        written = []

        files = {
            "project.yaml": ("blink/project.yaml.j2", {"name": name, "board": board}),
            "ip/blink_test.ip.yaml": ("blink/ip/blink_test.ip.yaml.j2", {}),
            "rtl/blink_test.sv": ("blink/rtl/blink_test.sv.j2", {}),
        }

        for rel, (tpl, ctx) in files.items():
            out = target / rel
            text = renderer.render(tpl, **ctx)
            renderer.write_text(out, text)
            written.append(str(out))

        return written
```

---

# `socfw/scaffold/templates/blink/project.yaml.j2`

```yaml
version: 2
kind: project

project:
  name: {{ name }}
  mode: standalone
  board: {{ board }}
  output_dir: build/gen
  debug: true

registries:
  packs:
    - packs/builtin
  ip:
    - ip
  cpu: []

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
```

---

# `socfw/scaffold/templates/blink/ip/blink_test.ip.yaml.j2`

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
  active_high: null

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

artifacts:
  synthesis:
    - ../rtl/blink_test.sv
  simulation: []
  metadata: []
```

---

# `socfw/scaffold/templates/blink/rtl/blink_test.sv.j2`

```systemverilog
`default_nettype none

module blink_test #(
  parameter integer CLK_FREQ = 50000000
)(
  input  wire       SYS_CLK,
  output reg  [5:0] ONB_LEDS
);

  reg [31:0] counter;

  always @(posedge SYS_CLK) begin
    counter <= counter + 1'b1;
    ONB_LEDS <= counter[25:20];
  end

endmodule

`default_nettype wire
```

---

# Úprava `socfw/cli/main.py`

Pridaj subcommand `init`.

## import

```python
from socfw.scaffold.init_project import ProjectInitializer
```

## handler

```python
def cmd_init(args) -> int:
    written = ProjectInitializer().init_blink(
        target_dir=args.directory,
        name=args.name,
        board=args.board,
    )

    print(f"OK: initialized project in {args.directory}")
    for fp in written:
        print(fp)

    print("")
    print("Next:")
    print(f"  socfw validate {args.directory}/project.yaml")
    print(f"  socfw build {args.directory}/project.yaml --out {args.directory}/build/gen")
    return 0
```

## parser doplnok

```python
p_init = sub.add_parser("init", help="Create a new new-flow project")
p_init.add_argument("directory")
p_init.add_argument("--name", default="blink_project")
p_init.add_argument("--board", default="qmtech_ep4ce55")
p_init.set_defaults(func=cmd_init)
```

---

# `tests/integration/test_socfw_init_blink.py`

```python
from pathlib import Path

from socfw.build.full_pipeline import FullBuildPipeline
from socfw.scaffold.init_project import ProjectInitializer


def test_socfw_init_creates_valid_blink_project(tmp_path):
    target = tmp_path / "demo"

    written = ProjectInitializer().init_blink(
        target_dir=str(target),
        name="demo",
        board="qmtech_ep4ce55",
    )

    assert (target / "project.yaml").exists()
    assert (target / "ip" / "blink_test.ip.yaml").exists()
    assert (target / "rtl" / "blink_test.sv").exists()
    assert len(written) == 3

    result = FullBuildPipeline().validate(str(target / "project.yaml"))
    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
```

---

# `docs/user/getting_started.md`

Doplň sekciu:

````md
## Create a new project

```bash
socfw init my_blink --name my_blink --board qmtech_ep4ce55
socfw validate my_blink/project.yaml
socfw build my_blink/project.yaml --out my_blink/build/gen
````

The generated project uses the new pack-aware `project.yaml` format.

````

---

# `docs/dev_notes/checkpoints.md`

Doplň:

```md
## m7-new-flow-scaffolding

Status:
- `socfw init` creates pack-aware projects
- generated blink project validates through new flow
- new projects no longer need legacy skeleton copying

Next:
- freeze legacy feature additions
- prepare cutover tag
````

---

# Definition of Done

Commit 28 je hotový, keď:

* `socfw init demo` vytvorí nový projekt
* projekt obsahuje `project.yaml`, `ip/`, `rtl/`
* `socfw validate demo/project.yaml` prejde
* docs ukazujú `socfw init`

Ďalší commit:

```text
cutover: freeze legacy feature path and document v1.0 readiness checklist
```
