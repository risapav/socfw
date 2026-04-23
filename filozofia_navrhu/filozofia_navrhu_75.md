Áno. Tu je **Commit 14 ako file-by-file scaffold**:

# Commit 14 — `QIP_FILE` / `SDC_FILE` export policy + vendor PLL build assertions

Cieľ tohto commitu:

* dostať vendor metadata z modelu až do reálneho exportu
* zaviesť prvý **Quartus-oriented files export contract**
* potvrdiť, že `vendor_pll_soc` už nie je len “vendor-aware load”, ale aj:

  * `QIP_FILE`
  * `SDC_FILE`
  * použiteľný files flow

Toto je jeden z najdôležitejších praktických commitov, lebo tu sa prvýkrát potvrdí, že pack-aware vendor IP nie je len metadata, ale naozaj sa premietne do build artefaktov.

---

# Názov commitu

```text
emit: add qip/sdc-aware files export policy and assert QIP_FILE for vendor pll fixture
```

---

# 1. Čo má byť výsledok po Commite 14

Po tomto commite má platiť:

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
```

a očakávaš:

* build prejde
* vznikne `hal/files.tcl`
* `hal/files.tcl` obsahuje:

  * `QIP_FILE`
  * `clkpll.qip`
  * `SDC_FILE`
  * `clkpll.sdc`

A integračný test to overí natvrdo.

---

# 2. Súbory, ktoré pridať

```text
socfw/build/vendor_artifacts.py
tests/unit/test_vendor_artifact_collection.py
```

---

# 3. Súbory, ktoré upraviť

```text
legacy_build.py
socfw/build/full_pipeline.py
tests/integration/test_build_vendor_pll_soc.py
```

Voliteľne, ak chceš helper oddeliť čistejšie:

```text
socfw/build/legacy_backend.py
```

Ale nie je to nutné.

---

# 4. Kľúčové rozhodnutie pre Commit 14

Správny scope je:

## neprepisovať ešte celý legacy `files.tcl` emitter

Namiesto toho spravíme **compatibility-side augmentation**:

* legacy build nech si vygeneruje svoje bežné výstupy
* potom `legacy_build.py`:

  * zistí vendor artifacts z nového `SystemModel`
  * doplní / prepíše `hal/files.tcl` deterministickým spôsobom

To je na tento commit úplne správne.

Prečo:

* nezasahuješ agresívne do starého `tcl.py`
* centralizuješ converged vendor bridging na jednom mieste
* vieš neskôr túto logiku presunúť do nového emitter stacku

---

# 5. `socfw/build/vendor_artifacts.py`

Toto je malý helper, ktorý z `SystemModel` vytiahne vendor `qip` a `sdc`.

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class VendorArtifactBundle:
    qip_files: list[str] = field(default_factory=list)
    sdc_files: list[str] = field(default_factory=list)


def collect_vendor_artifacts(system) -> VendorArtifactBundle:
    bundle = VendorArtifactBundle()
    seen_qip = set()
    seen_sdc = set()

    used_types = {m.type_name for m in system.project.modules}
    if system.project.cpu is not None:
        used_types.add(system.project.cpu.type_name)

    for type_name in sorted(used_types):
        ip = system.ip_catalog.get(type_name)
        if ip is not None and ip.vendor_info is not None:
            if ip.vendor_info.qip and ip.vendor_info.qip not in seen_qip:
                bundle.qip_files.append(ip.vendor_info.qip)
                seen_qip.add(ip.vendor_info.qip)

            for sdc in ip.vendor_info.sdc:
                if sdc not in seen_sdc:
                    bundle.sdc_files.append(sdc)
                    seen_sdc.add(sdc)

    bundle.qip_files = sorted(bundle.qip_files)
    bundle.sdc_files = sorted(bundle.sdc_files)
    return bundle
```

### prečo samostatný súbor

Lebo:

* testuje sa ľahko
* neskôr ho použije nový files emitter
* `legacy_build.py` nebude mať túto logiku rozliatu v sebe

---

# 6. úprava `legacy_build.py`

Teraz spravíme tri helpery:

1. `_collect_generated(out_dir)`
2. `_write_or_patch_files_tcl(out_dir, system)`
3. `build_legacy(project_file, out_dir, system=None)`

Kľúčové je, že `build_legacy()` musí dostať aj `system`, nie len `project_file`.

---

## 6.1 uprav signatúru

Z:

```python
def build_legacy(project_file: str, out_dir: str) -> list[str]:
```

Na:

```python
def build_legacy(project_file: str, out_dir: str, system=None) -> list[str]:
```

---

## 6.2 pridaj helper na deterministický `files.tcl`

```python
from pathlib import Path
import yaml

from socfw.build.vendor_artifacts import collect_vendor_artifacts


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


def _write_or_patch_files_tcl(out_dir: str, system) -> str | None:
    if system is None:
        return None

    bundle = collect_vendor_artifacts(system)
    if not bundle.qip_files and not bundle.sdc_files:
        return None

    hal_dir = Path(out_dir) / "hal"
    hal_dir.mkdir(parents=True, exist_ok=True)
    files_tcl = hal_dir / "files.tcl"

    existing = ""
    if files_tcl.exists():
        existing = files_tcl.read_text(encoding="utf-8")

    lines = []
    if existing.strip():
        lines.append(existing.rstrip())
        lines.append("")

    lines.append("# Added by socfw compatibility vendor export")
    for qip in bundle.qip_files:
        lines.append(f"set_global_assignment -name QIP_FILE {qip}")
    for sdc in bundle.sdc_files:
        lines.append(f"set_global_assignment -name SDC_FILE {sdc}")

    content = "\n".join(lines).rstrip() + "\n"
    files_tcl.write_text(content, encoding="utf-8")
    return str(files_tcl)
```

### dôležité

Toto je compatibility policy:

* nič ešte neprepisuješ hlboko v legacy emitri
* len doplníš vendor lines deterministicky na konci

To je na Commit 14 správne.

---

## 6.3 uprav `build_legacy()`

Tu je odporúčaný scaffold výslednej verzie:

```python
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
    cpu = data.get("cpu")

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

    if cpu:
        legacy["cpu"] = {
            "instance": cpu.get("instance"),
            "type": cpu.get("type"),
            "fabric": cpu.get("fabric"),
            "reset_vector": cpu.get("reset_vector"),
            "params": cpu.get("params", {}),
        }

    if not legacy["board"]["file"] and project.get("board") == "qmtech_ep4ce55":
        legacy["board"]["file"] = str(Path("packs/builtin/boards/qmtech_ep4ce55/board.yaml").resolve())

    compat_file = compat_dir / "legacy_project_config.yaml"
    compat_file.write_text(yaml.safe_dump(legacy, sort_keys=False), encoding="utf-8")
    return str(compat_file)


def build_legacy(project_file: str, out_dir: str, system=None) -> list[str]:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    effective_project_file = _convert_new_project_to_legacy_shape(project_file, out_dir)

    # TODO: Replace this block with the real current repo build entrypoint.
    # Example:
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

    generated = _collect_generated(out_dir)
    if patched_files_tcl is not None and patched_files_tcl not in generated:
        generated.append(patched_files_tcl)

    generated = sorted(dict.fromkeys(generated))
    return generated
```

### dôležitá poznámka

Keď už máš reálny legacy entrypoint napojený, marker vetvu môžeš odstrániť.
Na scaffolde ju môžeš nechať len dočasne.

---

# 7. úprava `socfw/build/legacy_backend.py` alebo `socfw/build/full_pipeline.py`

Keďže `build_legacy()` teraz potrebuje `system`, musíš ho poslať ďalej.

Ak to chceš mať čisto, uprav `socfw/build/legacy_backend.py`.

## nahradiť týmto

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.result import BuildResult
from socfw.core.diagnostics import Diagnostic, Severity


class LegacyBackend:
    """
    Thin adapter around the current legacy generation flow.
    """

    def build(self, *, system, request) -> BuildResult:
        out_dir = Path(request.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)

        try:
            from legacy_build import build_legacy

            generated_files = build_legacy(
                project_file=request.project_file,
                out_dir=str(out_dir),
                system=system,
            )

            return BuildResult(
                ok=True,
                diagnostics=[],
                generated_files=generated_files,
            )
        except Exception as exc:
            return BuildResult(
                ok=False,
                diagnostics=[
                    Diagnostic(
                        code="BLD100",
                        severity=Severity.ERROR,
                        message=f"Legacy backend build failed: {exc}",
                        subject="build",
                        file=request.project_file,
                    )
                ],
                generated_files=[],
            )
```

Ak si `LegacyBackend` nemenil od Commitu 9, toto je presne miesto, kde to treba dotiahnuť.

---

# 8. `tests/unit/test_vendor_artifact_collection.py`

Tento test je dobrý, lebo izoluje vendor artifact logiku.

```python
from socfw.build.vendor_artifacts import collect_vendor_artifacts
from socfw.model.board import BoardClock, BoardModel
from socfw.model.ip import IpDescriptor
from socfw.model.project import ProjectModel, ProjectModule
from socfw.model.system import SystemModel
from socfw.model.vendor import VendorInfo


def test_collect_vendor_artifacts_from_used_modules():
    ip = IpDescriptor(
        name="clkpll",
        module="clkpll",
        category="clocking",
        vendor_info=VendorInfo(
            vendor="intel",
            tool="quartus",
            qip="/tmp/clkpll.qip",
            sdc=("/tmp/clkpll.sdc",),
        ),
    )

    system = SystemModel(
        board=BoardModel(
            board_id="demo",
            system_clock=BoardClock(id="clk", top_name="SYS_CLK", pin="A1", frequency_hz=50_000_000),
        ),
        project=ProjectModel(
            name="demo",
            mode="standalone",
            board_ref="demo",
            modules=[ProjectModule(instance="pll0", type_name="clkpll")],
        ),
        ip_catalog={"clkpll": ip},
        cpu_catalog={},
    )

    bundle = collect_vendor_artifacts(system)
    assert bundle.qip_files == ["/tmp/clkpll.qip"]
    assert bundle.sdc_files == ["/tmp/clkpll.sdc"]
```

---

# 9. úprava `tests/integration/test_build_vendor_pll_soc.py`

Teraz už môžeš sprísniť assertions.

## nahradiť týmto

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_vendor_pll_soc(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_pll_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    rtl = out_dir / "rtl" / "soc_top.sv"
    board_tcl = out_dir / "hal" / "board.tcl"
    timing_sdc = out_dir / "timing" / "soc_top.sdc"
    files_tcl = out_dir / "hal" / "files.tcl"

    assert rtl.exists()
    assert board_tcl.exists()
    assert timing_sdc.exists()
    assert files_tcl.exists()

    rtl_text = rtl.read_text(encoding="utf-8")
    files_tcl_text = files_tcl.read_text(encoding="utf-8")

    assert "clkpll" in rtl_text
    assert "blink_test" in rtl_text

    assert "QIP_FILE" in files_tcl_text
    assert "clkpll.qip" in files_tcl_text
    assert "SDC_FILE" in files_tcl_text
    assert "clkpll.sdc" in files_tcl_text
```

Toto je prvý silný praktický test vendor export policy.

---

# 10. Voliteľná úprava `tests/integration/test_build_pll_converged.py`

Keď už bude vendor cesta silnejšia, môžeš nechať `pll_converged` ako plain-RTL fixture a `vendor_pll_soc` ako vendor fixture.
Na tomto commite ho ale nemusíš meniť.

---

# 11. Čo ak legacy build už generuje vlastné `files.tcl`

To je normálne.

### správna politika v Commite 14

* legacy build nech si vygeneruje svoje default lines
* `legacy_build.py` ich len **doplní** o vendor lines

Teda:

* nič ešte nesnaž sa “synchronizovať ideálne”
* len garantuj, že vendor `QIP_FILE` a `SDC_FILE` v súbore budú

To je na tento commit úplne postačujúce.

---

# 12. Čo ak legacy build ešte `hal/files.tcl` negeneruje

Aj to je v poriadku.

`_write_or_patch_files_tcl()` ho vytvorí od nuly.

Teda Commit 14 funguje v oboch prípadoch:

* `files.tcl` existuje → doplniť
* neexistuje → vytvoriť

To je veľmi praktické.

---

# 13. Čo v tomto commite ešte **nerobiť**

Vedome by som stále nechal bokom:

* vendor family validation
* golden snapshot pre `vendor_pll_soc`
* nový files IR / nový files emitter
* vendor SDRAM
* pack-level docs export
* merge policy pre viac vendor IP naraz beyond sort/order

Commit 14 má vyriešiť len:

* `QIP_FILE`
* `SDC_FILE`
* vendor PLL praktický export contract

To je správny scope.

---

# 14. Čo po Commite 14 overiť

Spusti:

```bash
pip install -e .
socfw validate tests/golden/fixtures/vendor_pll_soc/project.yaml
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
pytest tests/unit/test_vendor_artifact_collection.py
pytest tests/integration/test_build_vendor_pll_soc.py
```

### očakávanie

* validate green
* build green
* `files.tcl` obsahuje `QIP_FILE` aj `SDC_FILE`

To je veľmi veľký praktický míľnik.

---

# 15. Definition of Done pre Commit 14

Commit 14 je hotový, keď:

* vendor artifact collector existuje
* `legacy_build.py` dopĺňa `hal/files.tcl`
* `vendor_pll_soc` build vytvorí `files.tcl`
* test natvrdo overí `QIP_FILE` a `SDC_FILE`

To je prvý skutočný Quartus-oriented convergence milestone.

---

# 16. Čo má byť Commit 15

Po tomto by som išiel na:

## Commit 15

```text
golden: lock vendor_pll_soc snapshots and stabilize files/timing ordering
```

Ten prinesie:

* golden coverage pre vendor PLL fixture
* explicitné zoradenie vendor lines
* prvý stabilný vendor regression anchor

To je ďalší prirodzený krok.

---

# 17. Môj praktický odporúčaný rytmus

Po Commite 14:

1. potvrď stabilitu `vendor_pll_soc`
2. ak `files.tcl` ordering flakuje, oprav len helper v `legacy_build.py`
3. až potom sprav golden snapshot
4. až potom choď na vendor SDRAM fixture

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 15 ako file-by-file scaffold: golden snapshot pre `vendor_pll_soc` + ordering stabilization**
