Áno. Tu je **Commit 16 ako file-by-file scaffold**:

# Commit 16 — board external SDRAM resource model + `vendor_sdram_soc` fixture scaffold

Cieľ tohto commitu:

* rozšíriť nový board model tak, aby vedel niesť **externé SDRAM resources**
* pripraviť prvý **vendor SDRAM fixture** v novom flow
* dostať do systému:

  * externé piny
  * vector / inout resources
  * board binding na SDRAM vetvu
* ešte stále bez plnej SDRAM funkcionality

Toto je správny krok po vendor PLL, lebo teraz už overuješ druhý reálny vendor use-case:

* nie clocking IP
* ale **memory-oriented external interface IP**

---

# Názov commitu

```text
board: add external SDRAM resource model and converged vendor SDRAM fixture scaffold
```

---

# 1. Čo má byť výsledok po Commite 16

Po tomto commite má platiť:

```bash
socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml
```

A očakávaš:

* board loader vie načítať `external.sdram.*`
* `vendor_sdram_soc` fixture sa načíta
* bind targety typu:

  * `board:external.sdram.addr`
  * `board:external.sdram.dq`
  * `board:external.sdram.clk`
    sa dajú rozlíšiť v modeli

**Build ešte nemusí byť plne green**, ak ešte nemáš bridge-aware/top-level wiring dotiahnuté.
Commit 16 je hlavne o:

* board resource modeli
* fixture scaffolde
* loader/validate pripravenosti

---

# 2. Súbory, ktoré pridať

```text
tests/golden/fixtures/vendor_sdram_soc/project.yaml
tests/golden/fixtures/vendor_sdram_soc/ip/dummy_cpu.cpu.yaml
tests/golden/fixtures/vendor_sdram_soc/rtl/dummy_cpu.sv
tests/integration/test_validate_vendor_sdram_soc.py
```

Voliteľne, ak chceš fixture hneď kompletnejší:

```text
tests/golden/fixtures/vendor_sdram_soc/timing_config.yaml
```

---

# 3. Súbory, ktoré upraviť

```text
socfw/model/board.py
socfw/config/board_loader.py
packs/builtin/boards/qmtech_ep4ce55/board.yaml
```

Voliteľne, ak máš prvé validate pravidlá pre bind targets:

```text
socfw/validate/rules/project_rules.py
```

---

# 4. Kľúčové rozhodnutie pre Commit 16

Správny scope je:

## rozšíriť board model len natoľko, aby vedel uniesť SDRAM resource tree

Nerob ešte:

* plný typed recursive board resource schema
* generický I/O constraint systém
* plný top-level wiring planner

Na tento commit stačí:

* loader nech vie uchovať bohatý `resources` strom
* plus malý helper pre lookup resource targetu

To je úplne správne.

---

# 5. úprava `socfw/model/board.py`

Doterajší `BoardModel.resources` je síce flexibilný, ale teraz sa oplatí doplniť helper na lookup cez cestu.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class BoardPin:
    pin: str


@dataclass(frozen=True)
class BoardPinVector:
    pins: tuple[str, ...]


@dataclass
class BoardClock:
    id: str
    top_name: str
    pin: str
    frequency_hz: int


@dataclass
class BoardReset:
    id: str
    top_name: str
    pin: str
    active_low: bool = True


@dataclass
class BoardResource:
    kind: str                     # scalar / vector / inout
    top_name: str
    width: int = 1
    pin: str | None = None
    pins: tuple[str, ...] = ()


@dataclass
class BoardModel:
    board_id: str
    system_clock: BoardClock
    system_reset: BoardReset | None = None
    fpga_family: str | None = None
    fpga_part: str | None = None
    resources: dict[str, object] = field(default_factory=dict)

    def resolve_resource_path(self, dotted_path: str):
        cur = self.resources
        for part in dotted_path.split("."):
            if not isinstance(cur, dict) or part not in cur:
                return None
            cur = cur[part]
        return cur
```

### prečo

Toto ti už teraz umožní:

* `board:onboard.leds`
* `board:external.sdram.addr`
* `board:external.sdram.dq`

rozlišovať a validovať bez toho, aby si musel hneď zavádzať zložitý typed tree model.

---

# 6. úprava `socfw/config/board_loader.py`

Tu zatiaľ nechaj resources ako raw dict, ale validuj aspoň minimum:

* `kind`
* `top_name`
* `pin` alebo `pins`

Na Commit 16 netreba plnú normalizáciu, ale aspoň základné sanity checky sa oplatia.

## odporúčaná úprava

Doplň helper:

```python
def _validate_resources_shape(resources: dict, *, file: str) -> list[Diagnostic]:
    diags = []

    def walk(node, path: str):
        if not isinstance(node, dict):
            return

        if "kind" in node and "top_name" in node:
            kind = node.get("kind")
            if kind not in {"scalar", "vector", "inout"}:
                diags.append(
                    Diagnostic(
                        code="BRD201",
                        severity=Severity.ERROR,
                        message=f"Invalid board resource kind '{kind}'",
                        subject="board.resources",
                        file=file,
                        path=path,
                    )
                )
                return

            if kind == "scalar" and "pin" not in node:
                diags.append(
                    Diagnostic(
                        code="BRD202",
                        severity=Severity.ERROR,
                        message="Scalar board resource requires 'pin'",
                        subject="board.resources",
                        file=file,
                        path=path,
                    )
                )

            if kind in {"vector", "inout"}:
                if "pins" not in node or not isinstance(node.get("pins"), list):
                    diags.append(
                        Diagnostic(
                            code="BRD203",
                            severity=Severity.ERROR,
                            message=f"{kind} board resource requires 'pins' list",
                            subject="board.resources",
                            file=file,
                            path=path,
                        )
                    )
                if "width" in node and isinstance(node.get("pins"), list):
                    if int(node["width"]) != len(node["pins"]):
                        diags.append(
                            Diagnostic(
                                code="BRD204",
                                severity=Severity.ERROR,
                                message="Board resource width does not match number of pins",
                                subject="board.resources",
                                file=file,
                                path=path,
                            )
                        )
            return

        for k, v in node.items():
            child_path = f"{path}.{k}" if path else k
            walk(v, child_path)

    walk(resources, "resources")
    return diags
```

A v `load()` po parse doplň:

```python
        diags = _validate_resources_shape(dict(doc.resources), file=path)
```

A pri návrate:

```python
        return Result(value=model, diagnostics=diags)
```

### prečo

Týmto už board loader:

* stále ostáva flexibilný
* ale vie chytiť rozbité SDRAM resource definície

---

# 7. úprava `packs/builtin/boards/qmtech_ep4ce55/board.yaml`

Teraz doplň do built-in board packu externú SDRAM vetvu.

## cieľový tvar

Do `resources:` doplň približne toto:

```yaml
resources:
  onboard:
    leds:
      kind: vector
      top_name: ONB_LEDS
      width: 6
      pins: [P1, P2, P3, P4, P5, P6]

  external:
    sdram:
      addr:
        kind: vector
        top_name: ZS_ADDR
        width: 13
        pins: [A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13]

      ba:
        kind: vector
        top_name: ZS_BA
        width: 2
        pins: [B1, B2]

      dq:
        kind: inout
        top_name: ZS_DQ
        width: 16
        pins: [D1, D2, D3, D4, D5, D6, D7, D8, D9, D10, D11, D12, D13, D14, D15, D16]

      dqm:
        kind: vector
        top_name: ZS_DQM
        width: 2
        pins: [E1, E2]

      cs_n:
        kind: scalar
        top_name: ZS_CS_N
        pin: F1

      we_n:
        kind: scalar
        top_name: ZS_WE_N
        pin: F2

      ras_n:
        kind: scalar
        top_name: ZS_RAS_N
        pin: F3

      cas_n:
        kind: scalar
        top_name: ZS_CAS_N
        pin: F4

      cke:
        kind: scalar
        top_name: ZS_CKE
        pin: F5

      clk:
        kind: scalar
        top_name: ZS_CLK
        pin: F6
```

### veľmi dôležitá poznámka

Tieto piny ber ako scaffold placeholder, **ak ešte nemáš presný pinout prenesený**.
Keď máš v pôvodnom board súbore reálne SDRAM signály, skopíruj ich presne.

Na tomto commite je najdôležitejšie:

* shape
* resource names
* width
* `inout` pre `dq`

---

# 8. `tests/golden/fixtures/vendor_sdram_soc/project.yaml`

Toto je prvý vendor SDRAM fixture scaffold.

```yaml
version: 2
kind: project

project:
  name: vendor_sdram_soc
  mode: soc
  board: qmtech_ep4ce55
  output_dir: build/gen
  debug: true

registries:
  packs:
    - packs/builtin
    - packs/vendor-intel
  ip: []
  cpu:
    - tests/golden/fixtures/vendor_sdram_soc/ip

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

cpu:
  instance: cpu0
  type: dummy_cpu
  fabric: main
  reset_vector: 0

modules:
  - instance: sdram0
    type: sdram_ctrl
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

### prečo bez bus sekcie

Na Commite 16 ešte nechceš riešiť plný bus/bridge path.
Toto je scaffold commit:

* loader
* board resource binding
* fixture structure

Bus-aware integrácia príde o commit neskôr.

Ak už chceš byť bližšie cieľu, môžeš doplniť:

```yaml
    bus:
      fabric: main
      base: 0x80000000
      size: 0x01000000
```

ale len ak už to tvoj project schema/compat mapping zvláda.

---

# 9. `tests/golden/fixtures/vendor_sdram_soc/ip/dummy_cpu.cpu.yaml`

Na scaffold fixture stačí veľmi jednoduchý CPU descriptor.

```yaml
version: 2
kind: cpu

cpu:
  name: dummy_cpu
  module: dummy_cpu
  family: test

clock_port: SYS_CLK
reset_port: RESET_N
irq_port: irq

bus_master:
  port_name: bus
  protocol: simple_bus
  addr_width: 32
  data_width: 32

default_params: {}

artifacts:
  - ../rtl/dummy_cpu.sv
```

---

# 10. `tests/golden/fixtures/vendor_sdram_soc/rtl/dummy_cpu.sv`

Na validate-only/scaffold commit stačí placeholder CPU.

```systemverilog
`default_nettype none

module dummy_cpu (
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  input  wire [31:0] irq,
  output wire [31:0] bus_addr,
  output wire [31:0] bus_wdata,
  output wire [3:0]  bus_be,
  output wire        bus_we,
  output wire        bus_valid,
  input  wire [31:0] bus_rdata,
  input  wire        bus_ready
);

  assign bus_addr  = 32'h0;
  assign bus_wdata = 32'h0;
  assign bus_be    = 4'h0;
  assign bus_we    = 1'b0;
  assign bus_valid = 1'b0;

endmodule

`default_nettype wire
```

### poznámka

Toto je len scaffold asset, aby CPU catalog loading bolo green.

---

# 11. `tests/integration/test_validate_vendor_sdram_soc.py`

Toto je hlavný test commitu.

```python
from socfw.build.full_pipeline import FullBuildPipeline


def test_validate_vendor_sdram_soc():
    result = FullBuildPipeline().validate("tests/golden/fixtures/vendor_sdram_soc/project.yaml")

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    assert result.value is not None

    board = result.value.board
    assert board.resolve_resource_path("external.sdram.addr") is not None
    assert board.resolve_resource_path("external.sdram.dq") is not None
    assert board.resolve_resource_path("external.sdram.clk") is not None

    assert result.value.project.cpu is not None
    assert result.value.cpu_desc() is not None
```

### čo tým potvrdzuješ

* board external SDRAM resource vetva existuje
* CPU catalog loading funguje
* fixture sa dá načítať

To je presne správny scaffold-level test.

---

# 12. Voliteľná úprava validation pravidiel

Ak už chceš na tomto commite chytať zlé bind targety, doplň do `socfw/validate/rules/project_rules.py` malé pravidlo.

## nový rule scaffold

```python
class UnknownBoardBindingTargetRule(ValidationRule):
    def validate(self, system) -> list:
        diags = []

        for midx, mod in enumerate(system.project.modules):
            ports = mod.bind.get("ports", {}) if isinstance(mod.bind, dict) else {}
            for port_name, bind_spec in ports.items():
                if not isinstance(bind_spec, dict):
                    continue
                target = bind_spec.get("target")
                if not isinstance(target, str):
                    continue
                if not target.startswith("board:"):
                    continue

                board_path = target[len("board:"):]
                if system.board.resolve_resource_path(board_path) is None:
                    diags.append(
                        Diagnostic(
                            code="PRJ202",
                            severity=Severity.ERROR,
                            message=f"Unknown board binding target '{target}'",
                            subject="project.bind",
                            file=system.sources.project_file,
                            path=f"modules[{midx}].bind.ports.{port_name}",
                            hints=("Check that the board resource path exists in the selected board definition.",),
                        )
                    )

        return diags
```

A pridaj ho do `ValidationRunner`.

### ale

Ak chceš Commit 16 držať veľmi úzky, môžeš to nechať až na Commit 17.

---

# 13. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* `sdram_ctrl` vendor descriptor
* bus interface model
* bridge rules
* `simple_bus -> wishbone` planner
* build test pre `vendor_sdram_soc`
* golden snapshot pre SDRAM fixture

Commit 16 má riešiť len:

* board external SDRAM resource model
* fixture scaffold
* validate-level coverage

To je správny scope.

---

# 14. Čo po Commite 16 overiť

Spusti:

```bash
pip install -e .
socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml
pytest tests/integration/test_validate_vendor_sdram_soc.py
```

### očakávanie

* validate green
* board external resource tree funguje
* fixture scaffold je pripravený na ďalší commit

---

# 15. Definition of Done pre Commit 16

Commit 16 je hotový, keď:

* board pack obsahuje `external.sdram.*`
* board loader to načíta
* `vendor_sdram_soc` fixture existuje
* `socfw validate` na ňom prejde
* resource lookup helper vie nájsť SDRAM targets

To je správny SDRAM scaffold checkpoint.

---

# 16. Čo má byť Commit 17

Po tomto by som išiel priamo na:

## Commit 17

```text
vendor: add sdram_ctrl descriptor + bus-aware fixture fields + first bridge validation
```

Ten prinesie:

* `sdram_ctrl` vendor descriptor do `packs/vendor-intel`
* prvé bus fields vo fixture
* prvé validation pravidlo pre chýbajúci bridge / nekompatibilný protocol

To je ďalší prirodzený krok.

---

# 17. Môj praktický odporúčaný rytmus

Po Commite 16:

1. potvrď, že board resource model je stabilný
2. nechaj validate-level fixture green
3. až potom pridaj `sdram_ctrl`
4. až potom choď do bridge-aware buildu

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 17 ako file-by-file scaffold: `sdram_ctrl` vendor descriptor + bus-aware fixture fields + prvé bridge validation pravidlo**
