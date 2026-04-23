Áno. Tu je **Commit 12 ako file-by-file scaffold**:

# Commit 12 — converged PLL fixture + typed timing coverage + build test

Cieľ tohto commitu:

* pridať druhý **nový-style fixture**
* overiť, že nový flow zvláda:

  * `project.yaml`
  * `timing_config.yaml`
  * generated clocks
  * PLL IP descriptor
* dostať prvý **PLL-oriented regression anchor** ešte pred vendor pack convergenciou

Toto je správny medzikrok medzi:

* `blink_converged`
  a
* `vendor_pll_soc`

Najprv stabilizuješ:

* nový shape projektu
* timing model
* build flow

Až potom prejdeš na:

* `QIP_FILE`
* vendor pack
* Quartus generated IP normalizáciu

---

# Názov commitu

```text
fixture: add converged pll project and typed timing coverage
```

---

# 1. Čo má byť výsledok po Commite 12

Po tomto commite má fungovať:

```bash
socfw validate tests/golden/fixtures/pll_converged/project.yaml
socfw build tests/golden/fixtures/pll_converged/project.yaml --out build/pll_converged
```

A očakávaš:

* projekt sa načíta novým flow
* timing config sa načíta do `TimingModel`
* PLL IP descriptor sa resolve-ne z lokálneho `ip/`
* build prejde cez wrapper
* výstupy vzniknú
* integration testy prejdú

---

# 2. Súbory, ktoré pridať

```text
tests/golden/fixtures/pll_converged/project.yaml
tests/golden/fixtures/pll_converged/timing_config.yaml
tests/golden/fixtures/pll_converged/ip/clkpll.ip.yaml
tests/golden/fixtures/pll_converged/rtl/clkpll.sv
tests/golden/fixtures/pll_converged/ip/blink_test.ip.yaml
tests/golden/fixtures/pll_converged/rtl/blink_test.sv
tests/integration/test_validate_pll_converged.py
tests/integration/test_build_pll_converged.py
```

Voliteľne neskôr:

```text
tests/golden/expected/pll_converged/...
tests/golden/test_pll_converged_golden.py
```

Ale na Commit 12 by som ešte nezačínal golden snapshotom, kým neoveríš stabilitu.

---

# 3. Prečo spraviť aj lokálny `blink_test.ip.yaml`

Lebo chceš, aby fixture bol:

* samostatný
* čitateľný
* nezávislý od iných fixture adresárov

Takže v `pll_converged` drž:

* lokálny `clkpll.ip.yaml`
* lokálny `blink_test.ip.yaml`
* lokálne RTL súbory

To je čistejšie pre regression fixture.

---

# 4. `tests/golden/fixtures/pll_converged/project.yaml`

Toto je nový-style projekt s PLL.

```yaml
version: 2
kind: project

project:
  name: pll_converged
  mode: standalone
  board: qmtech_ep4ce55
  output_dir: build/gen
  debug: true

registries:
  packs:
    - packs/builtin
  ip:
    - tests/golden/fixtures/pll_converged/ip
  cpu: []

clocks:
  primary:
    domain: ref_clk
    source: board:sys_clk
  generated: []

modules:
  - instance: pll0
    type: clkpll
    clocks:
      inclk0: ref_clk

  - instance: blink_test
    type: blink_test
    params:
      CLK_FREQ: 100000000
    clocks:
      SYS_CLK: pll0:c0
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds
```

### čo tým testuješ

* nový project shape
* lokálny IP registry
* viac modulov
* clock chaining
* PLL output referenciu `pll0:c0`

To je presne správny fixture.

---

# 5. `tests/golden/fixtures/pll_converged/timing_config.yaml`

Tu chceš využiť už nový typed timing formát.

```yaml
version: 2
kind: timing

generated_clocks:
  - name: pll0_c0
    source: pll0|inclk0
    target: pll0|c0
    divide_by: 1
    multiply_by: 2
    frequency_hz: 100000000

false_paths:
  - from_path: "*reset*"
    to_path: "*"
```

### prečo takto

Toto je jednoduché, typed a dobre testovateľné.
A zároveň už pokrýva:

* generated clock
* false path

---

# 6. `tests/golden/fixtures/pll_converged/ip/clkpll.ip.yaml`

Na tomto commite ešte nechceš vendor pack model.
Takže sprav čistý typed IP descriptor.

```yaml
version: 2
kind: ip

ip:
  name: clkpll
  module: clkpll
  category: clocking

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: areset
  active_high: true

clocking:
  primary_input_port: inclk0
  additional_input_ports: []
  outputs:
    - name: c0
      domain_hint: sys_clk
      frequency_hz: 100000000
    - name: locked
      domain_hint: null
      frequency_hz: null

artifacts:
  synthesis:
    - ../rtl/clkpll.sv
  simulation: []
  metadata: []
```

### prečo ešte nie vendor model

Lebo Commit 12 má byť o:

* converged fixture
* typed timing coverage

Nie ešte o:

* `qip`
* vendor metadata
* Quartus pack normalization

---

# 7. `tests/golden/fixtures/pll_converged/rtl/clkpll.sv`

Stačí veľmi jednoduchý placeholder PLL model pre build-level coverage.

```systemverilog
`default_nettype none

module clkpll (
  input  wire inclk0,
  input  wire areset,
  output wire c0,
  output wire locked
);

  assign c0 = inclk0;
  assign locked = ~areset;

endmodule

`default_nettype wire
```

### dôležité

Toto nie je fyzikálne presný PLL model.
To je v poriadku.
Na tomto commite ide o:

* top-level integráciu
* loading
* binding
* timing path

Nie o reálnu vendor implementáciu.

---

# 8. `tests/golden/fixtures/pll_converged/ip/blink_test.ip.yaml`

Môže byť rovnaký ako pri `blink_converged`, len lokálne skopírovaný.

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

# 9. `tests/golden/fixtures/pll_converged/rtl/blink_test.sv`

Použi ten istý jednoduchý blink modul ako predtým, alebo jeho lokálnu kópiu.

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

# 10. `tests/integration/test_validate_pll_converged.py`

Tento test je dôležitý, lebo overí typed timing loading cez nový fixture.

```python
from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_pll_converged():
    result = FullBuildPipeline().validate("tests/golden/fixtures/pll_converged/project.yaml")

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    assert result.value is not None
    assert result.value.project.name == "pll_converged"
    assert result.value.board.board_id == "qmtech_ep4ce55"
    assert "clkpll" in result.value.ip_catalog
    assert "blink_test" in result.value.ip_catalog
    assert result.value.timing is not None
    assert len(result.value.timing.generated_clocks) == 1
    assert len(result.value.timing.false_paths) == 1
```

---

# 11. `tests/integration/test_build_pll_converged.py`

Toto je hlavný build test.

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_pll_converged(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/pll_converged/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    rtl = out_dir / "rtl" / "soc_top.sv"
    board_tcl = out_dir / "hal" / "board.tcl"
    timing_sdc = out_dir / "timing" / "soc_top.sdc"

    assert rtl.exists()
    assert board_tcl.exists()
    assert timing_sdc.exists()

    rtl_text = rtl.read_text(encoding="utf-8")
    assert "module soc_top" in rtl_text
    assert "clkpll" in rtl_text
    assert "blink_test" in rtl_text
```

### prečo takto

Toto je už solídny build-level regression test:

* projekt s dvoma IP
* typed timing
* generated clock use-case
* konkrétne výstupy

---

# 12. Čo možno bude treba doplniť v `legacy_build.py`

Ak legacy backend nevie prirodzene spracovať:

* `timing_config.yaml` vedľa projektu
* alebo nový shape clock referencie typu `pll0:c0`

možno budeš musieť doplniť compatibility mapping.

## odporúčaný patch

V `_convert_new_project_to_legacy_shape()` doplň:

* prenesenie clock väzieb do presne toho legacy shape-u, ktorý starý builder čaká

Toto je presne miesto, kde má byť compatibility shim.

Nie v:

* `ProjectLoader`
* `TimingLoader`
* testoch

---

# 13. Čo v tomto commite ešte **nerobiť**

Vedome by som stále nechal bokom:

* vendor PLL pack
* `QIP_FILE`
* `.sdc` z vendor IP
* golden snapshot pre PLL fixture
* nový timing emitter

Commit 12 má riešiť len:

* typed timing coverage
* converged PLL fixture
* build-level regression

To je správny scope.

---

# 14. Čo po Commite 12 overiť

Spusti:

```bash
pip install -e .
socfw validate tests/golden/fixtures/pll_converged/project.yaml
socfw build tests/golden/fixtures/pll_converged/project.yaml --out build/pll_converged
pytest tests/integration/test_validate_pll_converged.py
pytest tests/integration/test_build_pll_converged.py
```

### očakávanie

* validate green
* build green
* typed timing je načítané
* PLL fixture funguje ako nový-style regression slice

To je veľmi dôležitý checkpoint pred vendor PLL packom.

---

# 15. Definition of Done pre Commit 12

Commit 12 je hotový, keď:

* existuje `pll_converged` fixture v novom shape
* `socfw validate` na ňom prejde
* `TimingModel` obsahuje generated clocks
* `socfw build` na ňom prejde
* integration test je green

To je veľmi slušný míľnik.

---

# 16. Čo má byť Commit 13

Po tomto by som išiel priamo na:

## Commit 13

```text
vendor: add first vendor PLL metadata model and pack-based pll fixture
```

Ten prinesie:

* vendor metadata v `IpDescriptor`
* `packs/vendor-intel`
* `vendor_pll_soc` fixture
* prvý `QIP_FILE` export use-case

To je ďalší prirodzený krok.

---

# 17. Môj praktický odporúčaný rytmus

Po Commite 12:

1. potvrď stabilitu `pll_converged`
2. ak build wrapper potrebuje clock-related compatibility shim, oprav len `legacy_build.py`
3. až potom choď na vendor PLL pack
4. golden snapshot pre PLL rob až po vendor/non-vendor rozhodnutí

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 13 ako file-by-file scaffold: vendor metadata model + `packs/vendor-intel` + `vendor_pll_soc` fixture**
