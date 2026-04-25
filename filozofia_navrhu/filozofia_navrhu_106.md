## Commit 42 — tested `blink` / `pll` / `sdram` init templates

Cieľ:

* rozšíriť `socfw init`
* mať nové projekty pre najdôležitejšie prípady
* každý template musí prejsť minimálne cez `validate`
* `blink` ostáva default

Názov commitu:

```text
scaffold: add tested blink pll and sdram init templates
```

## Pridať

```text
socfw/scaffold/templates/pll/project.yaml.j2
socfw/scaffold/templates/pll/timing_config.yaml.j2
socfw/scaffold/templates/pll/ip/blink_test.ip.yaml.j2
socfw/scaffold/templates/pll/rtl/blink_test.sv.j2

socfw/scaffold/templates/sdram/project.yaml.j2
socfw/scaffold/templates/sdram/timing_config.yaml.j2
socfw/scaffold/templates/sdram/ip/dummy_cpu.cpu.yaml.j2
socfw/scaffold/templates/sdram/rtl/dummy_cpu.sv.j2

tests/integration/test_socfw_init_templates.py
```

## Upraviť

```text
socfw/scaffold/init_project.py
socfw/cli/main.py
docs/user/getting_started.md
```

## `ProjectInitializer`

Pridaj generic dispatch:

```python
def init(self, *, template: str, target_dir: str, name: str, board: str) -> list[str]:
    if template == "blink":
        return self.init_blink(target_dir=target_dir, name=name, board=board)
    if template == "pll":
        return self.init_pll(target_dir=target_dir, name=name, board=board)
    if template == "sdram":
        return self.init_sdram(target_dir=target_dir, name=name, board=board)
    raise ValueError(f"Unknown template: {template}")
```

A helper:

```python
def _render_files(self, *, target_dir: str, files: dict[str, tuple[str, dict]]) -> list[str]:
    target = Path(target_dir)
    target.mkdir(parents=True, exist_ok=True)

    renderer = Renderer(str(self.templates_dir))
    written = []

    for rel, (tpl, ctx) in files.items():
        out = target / rel
        text = renderer.render(tpl, **ctx)
        renderer.write_text(out, text)
        written.append(str(out))

    return written
```

Potom `init_blink()` prepíš cez `_render_files`.

## `init_pll`

```python
def init_pll(self, *, target_dir: str, name: str, board: str) -> list[str]:
    return self._render_files(
        target_dir=target_dir,
        files={
            "project.yaml": ("pll/project.yaml.j2", {"name": name, "board": board}),
            "timing_config.yaml": ("pll/timing_config.yaml.j2", {}),
            "ip/blink_test.ip.yaml": ("pll/ip/blink_test.ip.yaml.j2", {}),
            "rtl/blink_test.sv": ("pll/rtl/blink_test.sv.j2", {}),
        },
    )
```

## `init_sdram`

```python
def init_sdram(self, *, target_dir: str, name: str, board: str) -> list[str]:
    return self._render_files(
        target_dir=target_dir,
        files={
            "project.yaml": ("sdram/project.yaml.j2", {"name": name, "board": board}),
            "timing_config.yaml": ("sdram/timing_config.yaml.j2", {}),
            "ip/dummy_cpu.cpu.yaml": ("sdram/ip/dummy_cpu.cpu.yaml.j2", {}),
            "rtl/dummy_cpu.sv": ("sdram/rtl/dummy_cpu.sv.j2", {}),
        },
    )
```

## CLI zmena

`init` doplň o template:

```python
p_init.add_argument(
    "--template",
    default="blink",
    choices=["blink", "pll", "sdram"],
)
```

Handler:

```python
written = ProjectInitializer().init(
    template=args.template,
    target_dir=args.directory,
    name=args.name,
    board=args.board,
)
```

## `pll/project.yaml.j2`

```yaml
version: 2
kind: project

project:
  name: {{ name }}
  mode: standalone
  board: {{ board }}
  debug: true

timing:
  file: timing_config.yaml

registries:
  packs:
    - packs/builtin
    - packs/vendor-intel
  ip:
    - ip
  cpu: []

clocks:
  primary:
    domain: ref_clk
    source: board:SYS_CLK
    frequency_hz: 50000000
  generated: []

modules:
  - instance: blink_test
    type: blink_test
    params:
      CLK_FREQ: 50000000
    clocks:
      SYS_CLK: ref_clk
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds
```

## `pll/timing_config.yaml.j2`

```yaml
version: 2
kind: timing

timing:
  clocks:
    - name: SYS_CLK
      port: SYS_CLK
      period_ns: 20.0

  generated_clocks: []

  io_delays:
    auto: true
    clock: SYS_CLK
    default_input_max_ns: 3.0
    default_output_max_ns: 3.0

  false_paths: []
```

## `sdram/project.yaml.j2`

```yaml
version: 2
kind: project

project:
  name: {{ name }}
  mode: soc
  board: {{ board }}
  debug: true

timing:
  file: timing_config.yaml

registries:
  packs:
    - packs/builtin
    - packs/vendor-intel
  ip: []
  cpu:
    - ip

clocks:
  primary:
    domain: sys_clk
    source: board:SYS_CLK
    frequency_hz: 50000000
  generated: []

buses:
  - name: main
    protocol: simple_bus
    addr_width: 32
    data_width: 32

cpu:
  instance: cpu0
  type: dummy_cpu
  fabric: main
  reset_vector: 0

modules:
  - instance: sdram0
    type: sdram_ctrl
    bus:
      fabric: main
      base: 2147483648
      size: 16777216
    clocks:
      clk: sys_clk
    bind:
      ports:
        zs_addr:
          target: board:external.sdram.addr
        zs_ba:
          target: board:external.sdram.ba
        zs_dq:
          target: board:external.sdram.dq
        zs_dqm:
          target: board:external.sdram.dqm
        zs_cs_n:
          target: board:external.sdram.cs_n
        zs_we_n:
          target: board:external.sdram.we_n
        zs_ras_n:
          target: board:external.sdram.ras_n
        zs_cas_n:
          target: board:external.sdram.cas_n
        zs_cke:
          target: board:external.sdram.cke
        zs_clk:
          target: board:external.sdram.clk
```

## `sdram/timing_config.yaml.j2`

```yaml
version: 2
kind: timing

timing:
  clocks:
    - name: SYS_CLK
      port: SYS_CLK
      period_ns: 20.0
      reset:
        port: RESET_N
        active_low: true
        sync_stages: 2

  io_delays:
    auto: true
    clock: SYS_CLK
    default_input_max_ns: 3.0
    default_output_max_ns: 3.0

  false_paths:
    - from_port: RESET_N
      comment: Async reset
```

## Test

```python
from socfw.build.full_pipeline import FullBuildPipeline
from socfw.scaffold.init_project import ProjectInitializer


def test_init_all_templates_validate(tmp_path):
    for template in ["blink", "pll", "sdram"]:
        target = tmp_path / template
        ProjectInitializer().init(
            template=template,
            target_dir=str(target),
            name=f"demo_{template}",
            board="qmtech_ep4ce55",
        )

        result = FullBuildPipeline().validate(str(target / "project.yaml"))
        assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
```

## Docs update

````md
## Templates

```bash
socfw init my_blink --template blink
socfw init my_pll --template pll
socfw init my_sdram --template sdram
````

````

## Definition of Done

Commit 42 je hotový, keď:

- `socfw init --template blink` funguje
- `socfw init --template pll` funguje
- `socfw init --template sdram` funguje
- všetky templates validate-nú
- docs uvádzajú template možnosti

Ďalší commit:

```text
build: add native files.tcl emitter and stop patching files export
````
