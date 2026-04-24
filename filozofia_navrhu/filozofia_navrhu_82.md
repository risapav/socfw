Áno. Tu je **Commit 21 ako file-by-file scaffold**:

# Commit 21 — golden snapshot pre `vendor_sdram_soc` + ordering stabilization

Cieľ tohto commitu:

* zafixovať `vendor_sdram_soc` ako druhý veľký **vendor regression anchor**
* odstrániť flaky ordering v:

  * `rtl/soc_top.sv`
  * `hal/files.tcl`
  * `reports/bridge_summary.txt`
  * prípadne `timing/soc_top.sdc`
* dostať SDRAM fixture do golden coverage

Po tomto commite budeš mať dva silné regression body:

* `vendor_pll_soc`
* `vendor_sdram_soc`

A to je už veľmi blízko k reálnemu cutover checkpointu.

---

# Názov commitu

```text
golden: lock vendor_sdram_soc snapshots and stabilize top/files ordering
```

---

# 1. Čo má byť výsledok po Commite 21

Po tomto commite má platiť:

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
pytest tests/integration/test_build_vendor_sdram_soc.py
pytest tests/golden -k vendor_sdram_soc
```

A očakávaš:

* build green
* integration green
* golden green
* opakovaný build dá rovnaký obsah snapshotovaných súborov

---

# 2. Súbory, ktoré pridať

```text
tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv
tests/golden/expected/vendor_sdram_soc/hal/files.tcl
tests/golden/expected/vendor_sdram_soc/reports/bridge_summary.txt
tests/golden/expected/vendor_sdram_soc/timing/soc_top.sdc
tests/golden/test_vendor_sdram_soc_golden.py
```

Voliteľne, ak už máš stabilný aj board export:

```text
tests/golden/expected/vendor_sdram_soc/hal/board.tcl
```

---

# 3. Súbory, ktoré upraviť

```text
legacy_build.py
socfw/build/compat_top_patch.py
tests/integration/test_build_vendor_sdram_soc.py
```

Voliteľne:

```text
sdc.py
```

ak timing ordering ešte flakuje.

---

# 4. Kľúčové rozhodnutie pre Commit 21

Správny prístup je:

## snapshotovať len to, čo je už deterministické

Odporúčam snapshotovať minimálne:

* `rtl/soc_top.sv`
* `hal/files.tcl`
* `reports/bridge_summary.txt`

A `timing/soc_top.sdc` snapshotuj iba vtedy, ak už:

* poradie constraints je stabilné
* build ho generuje konzistentne

Ak nie, nechaj timing ešte na Commit 21b alebo 22.

---

# 5. Ordering stabilizácia v `socfw/build/compat_top_patch.py`

Patch helper musí vkladať bridge block deterministicky.

Ak už máš verziu z Commitu 20, doplň:

* fixný marker
* fixný insert point
* žiadne opakované vkladanie
* stabilný trailing newline

## odporúčaná verzia

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

    patched = text[:idx].rstrip() + insert_block + "\nendmodule\n"
    soc_top.write_text(patched, encoding="utf-8")
    return str(soc_top)
```

### prečo

Týmto dostaneš:

* stabilný koniec súboru
* žiadne dvojité prázdne riadky
* žiadne opakované insertions

---

# 6. Ordering stabilizácia v `legacy_build.py`

Tu sú tri miesta, ktoré musia byť deterministické:

1. `_collect_generated()`
2. `_write_or_patch_files_tcl()`
3. `_write_bridge_summary()`

---

## 6.1 `_collect_generated()` nech ostane zoradený

```python
def _collect_generated(out_dir: str) -> list[str]:
    root = Path(out_dir)
    found = []
    for sub in ["rtl", "hal", "timing", "sw", "docs", "reports"]:
        sp = root / sub
        if sp.exists():
            for fp in sorted(sp.rglob("*")):
                if fp.is_file():
                    found.append(str(fp))
    return found
```

---

## 6.2 `_write_or_patch_files_tcl()` nech má stabilný append block

Použi verziu, kde:

* `qip_files` sú `sorted(...)`
* `sdc_files` sú `sorted(...)`
* starý appended block sa odstráni pred novým appendom

Túto verziu už si dostal v Commite 15. Na Commite 21 ju len nechaj ako source of truth.

---

## 6.3 `_write_bridge_summary()` nech je deterministický

Ak si ho doteraz mal len jednoduchý, uprav ho na:

```python
def _write_bridge_summary(out_dir: str, system) -> str | None:
    if system is None:
        return None

    pairs = _collect_bridge_pairs(system)
    if not pairs:
        return None

    reports_dir = Path(out_dir) / "reports"
    reports_dir.mkdir(parents=True, exist_ok=True)
    fp = reports_dir / "bridge_summary.txt"

    lines = []
    for src, dst, inst in sorted(pairs, key=lambda x: (x[2], x[0], x[1])):
        lines.append(f"{inst}: {src} -> {dst}")

    fp.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return str(fp)
```

### prečo

Ak budeš mať viac bridged modulov neskôr, snapshot ostane stabilný.

---

# 7. Voliteľná stabilizácia `timing/soc_top.sdc`

Ak timing output flakuje, oprav iba ordering, nie architektúru.

Typické minimálne fixes:

* zoradiť generated clocks
* zoradiť false paths
* stabilizovať sekcie

Ak `sdc.py` ešte nechceš chytať, tak:

* do golden testu zatiaľ timing nepridávaj

To je úplne v poriadku.

---

# 8. úprava `tests/integration/test_build_vendor_sdram_soc.py`

Integration test môže zostať skoro rovnaký, ale ak snapshotuješ aj timing, pridaj tvrdší existence check.

## odporúčaná verzia

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

Ak timing zahrnieš do golden, integration testu to netreba sprísňovať.

---

# 9. `tests/golden/test_vendor_sdram_soc_golden.py`

Toto je hlavný golden test commitu.

## odporúčaná verzia

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _assert_same(generated: Path, expected: Path):
    assert generated.exists(), f"Missing generated file: {generated}"
    assert expected.exists(), f"Missing expected file: {expected}"
    assert _read(generated) == _read(expected)


def test_vendor_sdram_soc_golden(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    expected_root = Path("tests/golden/expected/vendor_sdram_soc")

    _assert_same(out_dir / "rtl" / "soc_top.sv", expected_root / "rtl" / "soc_top.sv")
    _assert_same(out_dir / "hal" / "files.tcl", expected_root / "hal" / "files.tcl")
    _assert_same(out_dir / "reports" / "bridge_summary.txt", expected_root / "reports" / "bridge_summary.txt")

    timing_expected = expected_root / "timing" / "soc_top.sdc"
    timing_generated = out_dir / "timing" / "soc_top.sdc"
    if timing_expected.exists():
        _assert_same(timing_generated, timing_expected)
```

### prečo s podmienkou pre timing

Lebo môžeš commitnúť golden coverage hneď pre:

* RTL
* files
* bridge summary

a timing doplniť o pol kroka neskôr.

To je praktické.

---

# 10. Ako vytvoriť expected golden súbory

Po stabilnom builde sprav jednorazovo:

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc

mkdir -p tests/golden/expected/vendor_sdram_soc/rtl
mkdir -p tests/golden/expected/vendor_sdram_soc/hal
mkdir -p tests/golden/expected/vendor_sdram_soc/reports
mkdir -p tests/golden/expected/vendor_sdram_soc/timing

cp build/vendor_sdram_soc/rtl/soc_top.sv tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv
cp build/vendor_sdram_soc/hal/files.tcl tests/golden/expected/vendor_sdram_soc/hal/files.tcl
cp build/vendor_sdram_soc/reports/bridge_summary.txt tests/golden/expected/vendor_sdram_soc/reports/bridge_summary.txt

# iba ak timing už stabilný
cp build/vendor_sdram_soc/timing/soc_top.sdc tests/golden/expected/vendor_sdram_soc/timing/soc_top.sdc
```

---

# 11. Čo ak `soc_top.sv` stále flakuje

Najčastejšie dôvody budú:

* poradie modulov
* poradie portov
* opakované alebo rôzne whitespace pri patchovaní
* koniec súboru

## riešenie

Oprav len:

* `compat_top_patch.py`
* prípadne najnižší deterministic sort v legacy generatori

Nie test.

---

# 12. Čo v tomto commite ešte **nerobiť**

Vedome by som stále nechal bokom:

* plný bridge RTL wiring
* shared bridge IP catalog
* SDRAM functional simulation
* firmware boot test
* full hard cutover switch
* legacy removal

Commit 21 má uzavrieť len:

* SDRAM fixture snapshot stability

To je správny scope.

---

# 13. Čo po Commite 21 overiť

Spusti:

```bash
pip install -e .
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
pytest tests/integration/test_build_vendor_sdram_soc.py
pytest tests/golden/test_vendor_sdram_soc_golden.py
```

### očakávanie

* build green
* integration green
* golden green
* druhý build dá rovnaký výsledok

To je veľmi dôležitý checkpoint.

---

# 14. Definition of Done pre Commit 21

Commit 21 je hotový, keď:

* `vendor_sdram_soc` build je stabilný
* `soc_top.sv` má stabilný bridge scaffold block
* `files.tcl` má stabilné vendor lines
* `bridge_summary.txt` je stabilný
* golden snapshot je green

To je druhý veľký vendor regression anchor.

---

# 15. Čo má byť Commit 22

Po tomto by som išiel na:

## Commit 22

```text
cutover: add migration status board and mark converged fixtures as new-flow anchors
```

alebo, ak chceš ešte technický krok pred cutover governance:

## Commit 22

```text
report: add first deterministic build summary/provenance artifact for new flow
```

Môj praktický odporúčaný ďalší krok je:

👉 **najprv build summary / provenance artifact**

Lebo po dvoch regression anchoroch už má zmysel, aby build vedel sám vysvetliť:

* čo sa stalo
* čo sa vygenerovalo
* aký bridge/vendor flow sa použil

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 22 ako file-by-file scaffold: prvý deterministic build summary / provenance artifact pre nový flow**
