Áno. Tu je **Commit 10 ako file-by-file scaffold**:

# Commit 10 — prvý pack-aware converged blink fixture + build test

Cieľ tohto commitu:

* mať prvý projekt, ktorý už nejde cez starý `project_config.yaml` štýl
* používa:

  * `project.board`
  * `registries.packs`
  * nový `project.yaml` shape
* a nový `socfw build` ho vie:

  * načítať
  * validovať
  * poslať do legacy backend wrappera

Toto je prvý skutočný dôkaz, že convergence už nie je len “nový loader na staré configy”, ale že vieš zakladať a buildiť **nový typ projektu**.

---

# Názov commitu

```text
fixture: add first pack-aware converged blink project and build test
```

---

# 1. Čo má byť výsledok po Commite 10

Po tomto commite má fungovať niečo ako:

```bash
socfw validate tests/golden/fixtures/blink_converged/project.yaml
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
```

A očakávaš:

* nový shape projektu sa načíta bez legacy mappingu
* board sa vyrieši z `packs/builtin`
* IP descriptor sa načíta z lokálneho `ip/`
* build prejde cez nový front-end
* vzniknú prvé reálne artefakty

---

# 2. Súbory, ktoré pridať

```text
tests/golden/fixtures/blink_converged/project.yaml
tests/golden/fixtures/blink_converged/ip/blink_test.ip.yaml
tests/golden/fixtures/blink_converged/rtl/blink_test.sv
tests/integration/test_build_blink_converged.py
```

Voliteľne:

```text
tests/integration/test_validate_blink_converged.py
```

---

# 3. Súbory, ktoré upraviť

Pravdepodobne žiadne povinné.
Maximálne:

```text
legacy_build.py
```

ak starý build wrapper ešte nevie dobre pracovať s novým project shape.

---

# 4. Kľúčové rozhodnutie pre Commit 10

Tu je veľmi dôležité pochopiť jednu vec:

## nový fixture má ísť novým loaderom, ale build ešte môže ísť legacy backendom

To znamená:

* `project.yaml` je nový
* `socfw validate` ide čisto novým flow
* `socfw build` ešte na konci volá legacy build

Aby to fungovalo, máš dve možnosti:

### možnosť A

`legacy_build.py` už vie spracovať aj nový `project.yaml`

### možnosť B

`legacy_build.py` dostane malý adapter, ktorý nový `project.yaml` premapuje do shape-u, ktorý legacy backend očakáva

Pre Commit 10 je úplne v poriadku spraviť **B**.

---

# 5. `tests/golden/fixtures/blink_converged/project.yaml`

Toto je prvý “nový svet” fixture.

```yaml
version: 2
kind: project

project:
  name: blink_converged
  mode: standalone
  board: qmtech_ep4ce55
  output_dir: build/gen
  debug: true

registries:
  packs:
    - packs/builtin
  ip:
    - tests/golden/fixtures/blink_converged/ip
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

### prečo takto

Toto presne testuje:

* `project.board`
* `registries.packs`
* lokálny IP registry path
* modul s parametrami
* bind na board resource

To je perfektný prvý converged fixture.

---

# 6. `tests/golden/fixtures/blink_converged/ip/blink_test.ip.yaml`

Použi nový typed shape, nie legacy.

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

### poznámka

`../rtl/blink_test.sv` je správne, lebo loader normalizuje cesty relatívne k descriptor súboru.

---

# 7. `tests/golden/fixtures/blink_converged/rtl/blink_test.sv`

Na prvý converged fixture stačí veľmi jednoduchý modul.

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

Ak chceš zachovať presnejší starý blink modul, môžeš sem prekopírovať ten overený.
Na Commit 10 ale ide skôr o flow než o presnú funkcionalitu.

---

# 8. `tests/integration/test_validate_blink_converged.py` (voliteľné, ale odporúčané)

Tento test je veľmi užitočný, lebo ti oddeľuje validate od build.

```python
from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_blink_converged():
    result = FullBuildPipeline().validate("tests/golden/fixtures/blink_converged/project.yaml")
    assert result.ok
    assert result.value is not None
    assert result.value.project.name == "blink_converged"
    assert result.value.board.board_id == "qmtech_ep4ce55"
    assert "blink_test" in result.value.ip_catalog
```

---

# 9. `tests/integration/test_build_blink_converged.py`

Toto je hlavný test commitu.

## odporúčaná verzia

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_blink_converged(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/blink_converged/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok
    assert len(result.generated_files) >= 1

    # tighten once legacy backend is fully stable for the converged fixture
    assert (out_dir / "rtl" / "soc_top.sv").exists() or any(
        "LEGACY_BACKEND" in p for p in result.generated_files
    )
```

### keď bude legacy wrapper už stabilný

Sprísni to na:

```python
assert (out_dir / "rtl" / "soc_top.sv").exists()
assert (out_dir / "hal" / "board.tcl").exists()
```

---

# 10. Čo bude pravdepodobne treba doplniť v `legacy_build.py`

Toto je najpraktickejšia časť.

Ak legacy backend vie len starý `project_config.yaml` formát, musíš do `legacy_build.py` doplniť **new-to-legacy shim**.

Odporúčam helper:

```python
def _convert_new_project_to_legacy_shape(project_file: str, temp_out_dir: str) -> str:
    ...
```

Tento helper:

* načíta nový `project.yaml`
* vyrobí dočasný legacy-style config
* legacy generator spustíš nad ním

To je na Commit 10 úplne v poriadku.

---

# 11. Odporúčaný shape new-to-legacy shimu

Ak tvoj legacy build očakáva niečo ako:

* `design`
* `board`
* `plugins.ip`
* `modules`

tak shim spraví temporary YAML:

```yaml
design:
  name: blink_converged
  type: standalone
  output_dir: ...

board:
  type: qmtech_ep4ce55
  file: packs/builtin/boards/qmtech_ep4ce55/board.yaml

plugins:
  ip:
    - tests/golden/fixtures/blink_converged/ip

modules:
  - name: blink_test
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

A uložíš ho napr. do:

```text
<out_dir>/.compat/legacy_project_config.yaml
```

Potom legacy backend zavoláš nad týmto dočasným configom.

---

# 12. Ako vyzerá praktický shim v `legacy_build.py`

Tu je odporúčaný scaffold.

```python
from __future__ import annotations

from pathlib import Path
import yaml


def _collect_generated(out_dir: str) -> list[str]:
    root = Path(out_dir)
    found = []
    for sub in ["rtl", "hal", "timing", "sw", "docs"]:
        sp = root / sub
        if sp.exists():
            for fp in sorted(sp.rglob("*")):
                if fp.is_file():
                    found.append(str(fp))
    return found


def _convert_new_project_to_legacy_shape(project_file: str, out_dir: str) -> str:
    project_path = Path(project_file).resolve()
    data = yaml.safe_load(project_path.read_text(encoding="utf-8")) or {}

    if data.get("kind") != "project" or "project" not in data:
        return str(project_path)

    compat_dir = Path(out_dir) / ".compat"
    compat_dir.mkdir(parents=True, exist_ok=True)

    registries = data.get("registries", {})
    project = data.get("project", {})
    modules = data.get("modules", [])

    legacy = {
        "design": {
            "name": project.get("name", "project"),
            "type": project.get("mode", "standalone"),
            "output_dir": out_dir,
            "debug": bool(project.get("debug", False)),
        },
        "board": {
            "type": project.get("board"),
            "file": project.get("board_file"),
        },
        "plugins": {
            "ip": list(registries.get("ip", [])),
            "cpu": list(registries.get("cpu", [])),
        },
        "modules": [
            {
                "name": m.get("instance"),
                "type": m.get("type"),
                "params": m.get("params", {}),
                "clocks": m.get("clocks", {}),
                "bind": m.get("bind", {}),
            }
            for m in modules
        ],
    }

    # if board_file is absent, point legacy build directly to the builtin board file
    if not legacy["board"]["file"] and project.get("board") == "qmtech_ep4ce55":
        legacy["board"]["file"] = str(Path("packs/builtin/boards/qmtech_ep4ce55/board.yaml").resolve())

    compat_file = compat_dir / "legacy_project_config.yaml"
    compat_file.write_text(yaml.safe_dump(legacy, sort_keys=False), encoding="utf-8")
    return str(compat_file)
```

A potom v `build_legacy()`:

```python
def build_legacy(project_file: str, out_dir: str) -> list[str]:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    effective_project_file = _convert_new_project_to_legacy_shape(project_file, out_dir)

    # TODO: replace this with the actual current build entrypoint.
    # Example:
    # from <legacy module> import build_project
    # build_project(effective_project_file, out_dir)

    marker = out / "LEGACY_BACKEND_NOT_FULLY_WIRED.txt"
    marker.write_text(
        f"project_file={project_file}\neffective_project_file={effective_project_file}\nout_dir={out_dir}\n",
        encoding="utf-8",
    )

    generated = [str(marker)]
    generated.extend(_collect_generated(out_dir))
    return generated
```

### dôležité

Aj keď ešte nemáš plný reálny legacy entrypoint, týmto si pripravíš:

* converged fixture
* compatibility translation
* jeden čistý build bridge

To je správny krok.

---

# 13. Čo v tomto commite ešte **nerobiť**

Vedome by som stále nechal bokom:

* golden snapshots pre converged blink
* nový report
* nový emit stack
* pack-aware vendor PLL
* nové files/timing emitters

Commit 10 má riešiť len:

* prvý nový-style fixture
* prvý nový-style build test

To je správny scope.

---

# 14. Čo po Commite 10 overiť

Spusti:

```bash
pip install -e .
socfw validate tests/golden/fixtures/blink_converged/project.yaml
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
pytest tests/integration/test_build_blink_converged.py
```

### cieľ

* nový fixture sa dá používať
* nový CLI ho vie spracovať
* a build flow ho vie aspoň cez compatibility bridge dostať do legacy backendu

---

# 15. Definition of Done pre Commit 10

Commit 10 je hotový, keď:

* existuje `blink_converged/project.yaml` v novom shape
* `socfw validate` na ňom prejde bez legacy project mappingu
* `socfw build` ho vie poslať do compatibility bridge
* integration test je green

To je veľmi dôležitý moment:
od tohto bodu už máš prvý reálny projekt v novom formáte.

---

# 16. Čo má byť Commit 11

Po tomto by som išiel na:

## Commit 11

```text
fixture: stabilize converged blink outputs and add first golden coverage
```

Ten by priniesol:

* stabilný build assertion
* prvé exact alebo semi-exact golden snapshoty pre `blink_converged`
* prvý nový fixture ako regression anchor

To je ďalší logický krok.

---

# 17. Môj praktický odporúčaný rytmus

Po Commite 10 by som spravil:

1. dostať `blink_converged` na green validate
2. dostať `blink_converged` na green build
3. až potom snapshot/golden
4. až potom ďalšie converged fixtures ako PLL

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 11 ako file-by-file scaffold: stabilizácia `blink_converged` výstupov + prvé golden coverage**
