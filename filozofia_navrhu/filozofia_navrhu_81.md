Áno. Tu je **Commit 20 ako file-by-file scaffold**:

# Commit 20 — explicitný bridge insertion scaffold + assertion bridge prítomnosti v `vendor_sdram_soc` top outpute

Cieľ tohto commitu:

* posunúť `vendor_sdram_soc` z:

  * “build-level compatibility path”
    na
  * “bridge je už viditeľný v top-level výstupe”
* ešte stále bez plného nového RTL stacku
* ale už s prvým **explicitným bridge artifactom/scaffoldom**

Toto je dôležitý commit, lebo po ňom už nebude bridge len:

* validovaný
* reportovaný

ale aj:

* **prítomný v generovanom top-level flow**

---

# Názov commitu

```text
rtl: add first explicit bridge insertion scaffold and assert bridge presence in vendor_sdram_soc top output
```

---

# 1. Čo má byť výsledok po Commite 20

Po tomto commite má platiť:

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
```

A očakávaš:

* build prejde
* vznikne `rtl/soc_top.sv`
* v top-level výstupe je už viditeľný bridge scaffold, napr. cez:

  * názov modulu `simple_bus_to_wishbone_bridge`
  * alebo inštanciu `u_bridge_sdram0`
* `files.tcl` stále obsahuje:

  * `QIP_FILE`
  * `sdram_ctrl.qip`
  * `SDC_FILE`
  * `sdram_ctrl.sdc`

---

# 2. Súbory, ktoré pridať

```text
tests/golden/fixtures/vendor_sdram_soc/rtl/simple_bus_to_wishbone_bridge.sv
socfw/build/compat_top_patch.py
tests/unit/test_compat_top_patch.py
```

---

# 3. Súbory, ktoré upraviť

```text
legacy_build.py
tests/integration/test_build_vendor_sdram_soc.py
```

Voliteľne:

```text
tests/golden/fixtures/vendor_sdram_soc/project.yaml
```

ale iba ak chceš doplniť explicitné fixture-level metadata pre bridge, čo na tomto commite nie je nutné.

---

# 4. Kľúčové rozhodnutie pre Commit 20

Správny scope je:

## ešte nerobiť plný RTL planner pre bridge insertion

Namiesto toho spravíme:

* build compatibility shim zistí, že treba bridge
* po legacy generovaní **doplní scaffold-level bridge prítomnosť do `soc_top.sv`**
* nie ako finálnu architektúru, ale ako kontrolovaný compatibility patch

To je na tento commit správne, lebo:

* dostaneš bridge do top-level outputu
* bez veľkého zásahu do starého RTL generátora
* a neskôr túto logiku nahradíš čistým IR/elaboration stackom

---

# 5. `tests/golden/fixtures/vendor_sdram_soc/rtl/simple_bus_to_wishbone_bridge.sv`

Toto je scaffold bridge modul.
Nemusí byť plne funkčný, ale musí byť syntakticky rozumný a pomenovaný stabilne.

```systemverilog
`default_nettype none

module simple_bus_to_wishbone_bridge (
  input  wire        clk,
  input  wire        reset_n,

  input  wire [31:0] sb_addr,
  input  wire [31:0] sb_wdata,
  input  wire [3:0]  sb_be,
  input  wire        sb_we,
  input  wire        sb_valid,
  output wire [31:0] sb_rdata,
  output wire        sb_ready,

  output wire [31:0] wb_adr,
  output wire [31:0] wb_dat_w,
  input  wire [31:0] wb_dat_r,
  output wire [3:0]  wb_sel,
  output wire        wb_we,
  output wire        wb_cyc,
  output wire        wb_stb,
  input  wire        wb_ack
);

  assign wb_adr   = sb_addr;
  assign wb_dat_w = sb_wdata;
  assign wb_sel   = sb_be;
  assign wb_we    = sb_we;
  assign wb_cyc   = sb_valid;
  assign wb_stb   = sb_valid;

  assign sb_rdata = wb_dat_r;
  assign sb_ready = wb_ack;

endmodule

`default_nettype wire
```

### prečo lokálne vo fixture

Na tomto commite chceš čo najmenšie riziko.
Nezakladaj ešte shared bridge catalog, kým si nepotvrdíš, že scaffold path funguje.

---

# 6. `socfw/build/compat_top_patch.py`

Toto je hlavný nový helper commitu.

Jeho úloha:

* zistiť, či fixture potrebuje explicitný bridge scaffold
* ak áno, patchnúť `rtl/soc_top.sv` tak, aby sa tam bridge viditeľne objavil

Na tomto commite odporúčam najjednoduchší stabilný model:

* doplniť **komentovaný marker + dummy instantiation block**
* nie ešte plnú wire-level integráciu

To stačí na regression checkpoint.

## obsah

```python
from __future__ import annotations

from pathlib import Path


def needs_bridge_scaffold(system) -> bool:
    for mod in system.project.modules:
        if mod.bus is None:
            continue

        fabric = system.project.fabric_by_name(mod.bus.fabric)
        if fabric is None:
            continue

        ip = system.ip_catalog.get(mod.type_name)
        if ip is None:
            continue

        iface = ip.slave_bus_interface()
        if iface is None:
            continue

        if fabric.protocol == "simple_bus" and iface.protocol == "wishbone":
            return True

    return False


def patch_soc_top_with_bridge_scaffold(out_dir: str, system) -> str | None:
    if system is None or not needs_bridge_scaffold(system):
        return None

    soc_top = Path(out_dir) / "rtl" / "soc_top.sv"
    if not soc_top.exists():
        return None

    text = soc_top.read_text(encoding="utf-8")
    marker = "// socfw compatibility bridge scaffold"

    if marker in text:
        return str(soc_top)

    insert_block = """

  // socfw compatibility bridge scaffold
  // NOTE: temporary Phase-1/Phase-2 insertion until full bridge RTL planning is implemented.
  simple_bus_to_wishbone_bridge u_bridge_sdram0 (
    .clk(1'b0),
    .reset_n(1'b1),
    .sb_addr(32'h0),
    .sb_wdata(32'h0),
    .sb_be(4'h0),
    .sb_we(1'b0),
    .sb_valid(1'b0),
    .sb_rdata(),
    .sb_ready(),
    .wb_adr(),
    .wb_dat_w(),
    .wb_dat_r(32'h0),
    .wb_sel(),
    .wb_we(),
    .wb_cyc(),
    .wb_stb(),
    .wb_ack(1'b0)
  );
"""

    idx = text.rfind("endmodule")
    if idx == -1:
        return None

    patched = text[:idx] + insert_block + "\n" + text[idx:]
    soc_top.write_text(patched, encoding="utf-8")
    return str(soc_top)
```

### prečo takto

Áno, je to scaffold a nie finálny RTL planner.
Ale presne to je účel commitu:

* bridge bude viditeľný v top outpute
* test bude mať čo overiť
* a scope ostáva bezpečný

---

# 7. úprava `legacy_build.py`

Treba tam doplniť dva kroky:

1. zabezpečiť, aby bridge RTL scaffold súbor bol medzi zdrojmi fixture
2. patchnúť `soc_top.sv` po legacy generovaní

---

## 7.1 pridaj import

Na začiatok:

```python
from socfw.build.compat_top_patch import patch_soc_top_with_bridge_scaffold
```

---

## 7.2 doplň helper, ktorý pridá bridge RTL path do compatibility projektu

Ak legacy build číta `plugins.ip` a vie z descriptorov zobrať synthesis files, stačí, že bridge scaffold bude reachable cez fixture IP alebo iný známy path.

Na tomto commite odporúčam jednoduchší variant:

### do `_convert_new_project_to_legacy_shape()` doplň

Ak zistíš, že ide o `vendor_sdram_soc`, doplň `plugins.ip` o fixture `rtl/` alebo explicitný bridge helper path len ak to legacy flow potrebuje.

Lepší a čistejší spôsob je ale:

* bridge scaffold patchovať len do `soc_top.sv`
* bez nutnosti ho tlačiť do legacy IP catalogu

Na Commit 20 by som preto **nekomplikoval legacy config** a išiel patch-pathom.

---

## 7.3 uprav `build_legacy()` takto

Na konci po `_write_bridge_summary(...)` doplň:

```python
    patched_soc_top = patch_soc_top_with_bridge_scaffold(out_dir, system)
```

a do zoznamu generated files:

```python
    for extra in [patched_files_tcl, bridge_summary, patched_soc_top]:
        if extra is not None and extra not in generated:
            generated.append(extra)
```

### výsledný relevantný kus

```python
def build_legacy(project_file: str, out_dir: str, system=None) -> list[str]:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    effective_project_file = _convert_new_project_to_legacy_shape(project_file, out_dir)

    # TODO: Replace this block with the real current repo build entrypoint.
    # from <legacy module> import build_project
    # build_project(effective_project_file, str(out))

    marker = out / "LEGACY_BACKEND_NOT_FULLY_WIRED.txt"
    if not any(out.iterdir()):
        marker.write_text(
            f"project_file={project_file}\n"
            f"effective_project_file={effective_project_file}\n"
            f"out_dir={out_dir}\n",
            encoding="utf-8",
        )

    patched_files_tcl = _write_or_patch_files_tcl(out_dir, system)
    bridge_summary = _write_bridge_summary(out_dir, system)
    patched_soc_top = patch_soc_top_with_bridge_scaffold(out_dir, system)

    generated = _collect_generated(out_dir)
    for extra in [patched_files_tcl, bridge_summary, patched_soc_top]:
        if extra is not None and extra not in generated:
            generated.append(extra)

    generated = sorted(dict.fromkeys(generated))
    return generated
```

---

# 8. `tests/unit/test_compat_top_patch.py`

Tento test izoluje patch helper.

```python
from pathlib import Path

from socfw.build.compat_top_patch import patch_soc_top_with_bridge_scaffold
from socfw.model.board import BoardClock, BoardModel
from socfw.model.bus import BusFabric, IpBusInterface, ModuleBusAttachment
from socfw.model.ip import IpDescriptor
from socfw.model.project import ProjectModel, ProjectModule
from socfw.model.system import SystemModel


def test_patch_soc_top_with_bridge_scaffold(tmp_path):
    rtl_dir = tmp_path / "rtl"
    rtl_dir.mkdir()
    soc_top = rtl_dir / "soc_top.sv"
    soc_top.write_text(
        "module soc_top;\n\nendmodule\n",
        encoding="utf-8",
    )

    system = SystemModel(
        board=BoardModel(
            board_id="demo",
            system_clock=BoardClock(id="clk", top_name="SYS_CLK", pin="A1", frequency_hz=50_000_000),
        ),
        project=ProjectModel(
            name="demo",
            mode="soc",
            board_ref="demo",
            buses=[BusFabric(name="main", protocol="simple_bus")],
            modules=[
                ProjectModule(
                    instance="sdram0",
                    type_name="sdram_ctrl",
                    bus=ModuleBusAttachment(fabric="main"),
                )
            ],
        ),
        ip_catalog={
            "sdram_ctrl": IpDescriptor(
                name="sdram_ctrl",
                module="sdram_ctrl",
                category="memory",
                bus_interfaces=(
                    IpBusInterface(
                        port_name="wb",
                        protocol="wishbone",
                        role="slave",
                    ),
                ),
            )
        },
        cpu_catalog={},
    )

    patched = patch_soc_top_with_bridge_scaffold(str(tmp_path), system)
    assert patched is not None
    text = soc_top.read_text(encoding="utf-8")
    assert "simple_bus_to_wishbone_bridge" in text
    assert "u_bridge_sdram0" in text
```

---

# 9. úprava `tests/integration/test_build_vendor_sdram_soc.py`

Teraz sprísni assertions.

## nahradiť týmto

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_vendor_sdram_soc(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    rtl = out_dir / "rtl" / "soc_top.sv"
    files_tcl = out_dir / "hal" / "files.tcl"
    bridge_summary = out_dir / "reports" / "bridge_summary.txt"

    assert rtl.exists()
    assert files_tcl.exists()
    assert bridge_summary.exists()

    rtl_text = rtl.read_text(encoding="utf-8")
    files_tcl_text = files_tcl.read_text(encoding="utf-8")
    bridge_summary_text = bridge_summary.read_text(encoding="utf-8")

    assert "simple_bus_to_wishbone_bridge" in rtl_text
    assert "u_bridge_sdram0" in rtl_text

    assert "QIP_FILE" in files_tcl_text
    assert "sdram_ctrl.qip" in files_tcl_text
    assert "SDC_FILE" in files_tcl_text
    assert "sdram_ctrl.sdc" in files_tcl_text

    assert "sdram0: simple_bus -> wishbone" in bridge_summary_text
```

### prečo

Toto už potvrdzuje:

* build path
* vendor artifacts
* explicitnú bridge prítomnosť v top outpute

To je presne cieľ commitu.

---

# 10. Čo ak legacy build ešte negeneruje `rtl/soc_top.sv`

Ak tvoj reálny legacy entrypoint ešte neprodukuje `soc_top.sv` pre tento fixture, máš dve možnosti:

## možnosť A

Najprv dotiahni legacy build, aby `soc_top.sv` vznikal

## možnosť B

V `legacy_build.py` pri scaffold režime vytvor minimálny `rtl/soc_top.sv` placeholder, ktorý potom patch helper doplní

### scaffold fallback

```python
def _ensure_soc_top_exists(out_dir: str) -> str:
    rtl_dir = Path(out_dir) / "rtl"
    rtl_dir.mkdir(parents=True, exist_ok=True)
    soc_top = rtl_dir / "soc_top.sv"
    if not soc_top.exists():
        soc_top.write_text("module soc_top;\n\nendmodule\n", encoding="utf-8")
    return str(soc_top)
```

A v `build_legacy()` pred patchom:

```python
    _ensure_soc_top_exists(out_dir)
```

Toto je na scaffold commite úplne akceptovateľné.

---

# 11. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* plné wire-level bridge zapojenie
* bridge ako shared IP/pack artifact
* golden snapshot pre `vendor_sdram_soc`
* real Wishbone interface bundle model
* full SDRAM top correctness
* firmware boot / RAM use

Commit 20 má vyriešiť len:

* bridge scaffold viditeľný v top-level outpute

To je správny scope.

---

# 12. Čo po Commite 20 overiť

Spusti:

```bash
pip install -e .
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
pytest tests/unit/test_compat_top_patch.py
pytest tests/integration/test_build_vendor_sdram_soc.py
```

### očakávanie

* build green
* bridge scaffold v top outpute
* vendor files export stále green

To je veľmi dobrý checkpoint.

---

# 13. Definition of Done pre Commit 20

Commit 20 je hotový, keď:

* `soc_top.sv` vznikne pre `vendor_sdram_soc`
* compatibility patch doň vloží `simple_bus_to_wishbone_bridge`
* integration test to overí
* vendor artifact export ostáva funkčný

To je prvý bridge-visible SDRAM míľnik.

---

# 14. Čo má byť Commit 21

Po tomto by som išiel na:

## Commit 21

```text
golden: lock vendor_sdram_soc snapshots and stabilize top/files ordering
```

Ten prinesie:

* golden coverage pre SDRAM fixture
* ordering stabilization
* druhý veľký vendor regression anchor po PLL

To je ďalší prirodzený krok.

---

# 15. Môj praktický odporúčaný rytmus

Po Commite 20:

1. potvrď build stabilitu pár opakovanými runmi
2. ak ordering flakuje, oprav len compatibility helpery
3. až potom snapshotuj SDRAM fixture
4. potom môžeš ísť na hard cutover readiness

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 21 ako file-by-file scaffold: golden snapshot pre `vendor_sdram_soc` + ordering stabilization**
