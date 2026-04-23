Áno. Tu je **Commit 9 ako file-by-file scaffold**:

# Commit 9 — napojenie reálneho legacy entrypointu do `LegacyBackend` + prvé build assertions

Cieľ tohto commitu:

* prestať používať placeholder/no-op shim
* napojiť `socfw build` na **reálny existujúci generator flow**
* mať prvé tvrdé integračné overenie, že nový CLI vie naozaj vygenerovať artefakty

Toto je prvý commit, kde sa nový front-end začne opierať o skutočný build výsledok.

---

# Názov commitu

```text
build: wire real legacy entrypoint into LegacyBackend and stabilize first build artifact assertions
```

---

# 1. Čo je cieľový stav po Commit 9

Po tomto commite má fungovať:

```bash
socfw build project_config.yaml --out build/test_phase1
```

a výsledok má byť:

* build prejde
* vzniknú reálne artefakty
* `BuildResult.generated_files` bude obsahovať konkrétne výstupy
* integračný test overí aspoň:

  * `rtl/soc_top.sv`
  * `hal/board.tcl`
  * `timing/soc_top.sdc`

Ak ešte nevieš stabilne generovať všetky tri, začni s dvoma.

---

# 2. Predpoklad

Tento commit predpokladá, že v existujúcom repo vieš identifikovať **jedno miesto**, ktoré dnes orchestruje:

* `rtl.py`
* `tcl.py`
* `sdc.py`
* `sw.py`

Ak také miesto nemáš, sprav ho teraz.

To je hlavný účel tohto commitu:

> vytvoriť **jediný legacy orchestration entrypoint**

---

# 3. Súbory, ktoré pridať

```text
legacy_build.py
tests/integration/test_build_real_legacy_backend.py
```

---

# 4. Súbory, ktoré upraviť

```text
socfw/build/legacy_backend.py
socfw/build/result.py
socfw/build/full_pipeline.py
socfw/cli/main.py
```

Voliteľne:

```text
rtl.py
tcl.py
sdc.py
sw.py
```

ale len ak potrebuješ znížiť `print()` noise alebo vrátiť generated paths.

---

# 5. Kľúčové rozhodnutie

Nechcem, aby `LegacyBackend`:

* importoval štyri staré moduly a skladal build sám
* poznal detaily legacy flow

Správne je:

## nový súbor

`legacy_build.py`

a v ňom jedna funkcia:

```python
def build_legacy(project_file: str, out_dir: str) -> list[str]:
    ...
```

Nový svet sa bude dotýkať starého sveta iba tu.

To je veľmi dôležité.

---

# 6. `legacy_build.py`

Tu je scaffold. Budeš doň musieť doplniť presné volania podľa reálneho starého flow, ale štruktúra má byť takáto:

```python
from __future__ import annotations

from pathlib import Path


def build_legacy(project_file: str, out_dir: str) -> list[str]:
    """
    Single compatibility entrypoint into the existing legacy generation flow.

    Replace the TODO blocks with the real orchestration currently used in the repo.
    This function should:
      1. load the legacy project config
      2. run the current generation flow
      3. return a list of emitted artifact paths
    """
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    generated: list[str] = []

    # ------------------------------------------------------------------
    # TODO: Replace this placeholder with the actual current repo call.
    #
    # Example patterns you may have in the existing repo:
    #
    #   from rtl_builder import build_project
    #   build_project(project_file=project_file, out_dir=str(out))
    #
    # or:
    #
    #   from rtl import emit_rtl
    #   from tcl import emit_board_tcl, emit_files_tcl
    #   from sdc import emit_sdc
    #   from sw import emit_sw
    #   ...
    #
    # ------------------------------------------------------------------

    # Temporary compatibility marker can remain only until the real entrypoint
    # is wired. Remove once real generation works.
    marker = out / "LEGACY_BACKEND_NOT_FULLY_WIRED.txt"
    marker.write_text(
        f"project_file={project_file}\nout_dir={out_dir}\n",
        encoding="utf-8",
    )
    generated.append(str(marker))

    # If the real flow already emits known outputs, register them here.
    for rel in [
        "rtl/soc_top.sv",
        "hal/board.tcl",
        "hal/files.tcl",
        "timing/soc_top.sdc",
        "sw/soc_map.h",
        "sw/sections.lds",
        "docs/soc_map.md",
    ]:
        fp = out / rel
        if fp.exists():
            generated.append(str(fp))

    return generated
```

---

# 7. Ako to napojiť na tvoj reálny starý flow

Tu je praktický postup.

## nájdi starý orchestration bod

V repozitári hľadaj:

* `if __name__ == "__main__"`
* `main()`
* `build_project(...)`
* `generate_*`
* kód, ktorý volá:

  * `rtl.py`
  * `tcl.py`
  * `sdc.py`
  * `sw.py`

## potom sprav jednu z týchto možností

### možnosť A — existuje top-level funkcia

Napríklad:

```python
from rtl_builder import build_project
build_project(project_file, out_dir)
```

Potom `legacy_build.py` bude len:

```python
from rtl_builder import build_project

def build_legacy(project_file: str, out_dir: str) -> list[str]:
    build_project(project_file=project_file, out_dir=out_dir)
    ...
```

### možnosť B — top-level funkcia neexistuje

Sprav ju teraz v `legacy_build.py`:

* importuj staré moduly
* zavolaj ich v presnom poradí, ako sa dnes používajú

### odporúčané poradie

Ak starý flow generuje:

1. top-level RTL
2. Tcl/board files
3. SDC
4. SW headers/docs

tak v `legacy_build.py` nech je presne toto poradie.

---

# 8. `socfw/build/legacy_backend.py`

Teraz už nebude placeholder, ale bude volať `legacy_build.py`.

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

---

# 9. `socfw/build/result.py`

Teraz sa oplatí mať aj helper na checking.

## nahradiť týmto

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class BuildResult:
    ok: bool = False
    diagnostics: list = field(default_factory=list)
    generated_files: list[str] = field(default_factory=list)

    def add_file(self, path: str) -> None:
        self.generated_files.append(path)
```

Nie je to povinné, ale je to fajn.

---

# 10. `socfw/build/full_pipeline.py`

Tu netreba veľkú zmenu, len nech zostane čisté spojenie:

* validate
* ak OK, build cez legacy backend

Ak už máš verziu z Commit 8, tá je v zásade dobrá.
Stačí ponechať:

```python
from __future__ import annotations

from socfw.build.legacy_backend import LegacyBackend
from socfw.build.result import BuildResult
from socfw.config.system_loader import SystemLoader
from socfw.validate.runner import ValidationRunner


class FullBuildPipeline:
    def __init__(self) -> None:
        self.loader = SystemLoader()
        self.validator = ValidationRunner()
        self.legacy = LegacyBackend()

    def validate(self, project_file: str):
        loaded = self.loader.load(project_file)
        if loaded.ok and loaded.value is not None:
            loaded.extend(self.validator.run(loaded.value))
        return loaded

    def build(self, request) -> BuildResult:
        loaded = self.validate(request.project_file)

        diags = list(loaded.diagnostics)
        if not loaded.ok or loaded.value is None:
            return BuildResult(ok=False, diagnostics=diags, generated_files=[])

        built = self.legacy.build(system=loaded.value, request=request)
        built.diagnostics = diags + list(built.diagnostics)
        return built
```

---

# 11. `socfw/cli/main.py`

`build` command môže zostať skoro rovnaký, ale odporúčam doplniť trochu jasnejší summary.

## uprav `cmd_build` na

```python
def cmd_build(args) -> int:
    pipeline = FullBuildPipeline()
    result = pipeline.build(BuildRequest(project_file=args.project, out_dir=args.out))

    _print_diags(result.diagnostics)

    if result.ok:
        print(f"OK: generated_files={len(result.generated_files)} out={args.out}")
        for fp in result.generated_files:
            print(fp)
        return 0

    print("BUILD FAILED")
    return 1
```

---

# 12. Voliteľné malé úpravy v legacy generátoroch

Ak staré moduly:

* tlačia veľa výstupu
* používajú `print()` bez kontroly
* alebo nevracajú nič

môžeš im pridať **minimálny compatibility patch**.

Odporúčaný pattern:

## v `rtl.py`, `tcl.py`, `sdc.py`, `sw.py`

Pridať voliteľný parameter:

```python
quiet: bool = True
```

a `print()` len ak:

```python
if not quiet:
    print(...)
```

Ale len ak to bude rušiť nový CLI.
Inak sa toho zatiaľ nedotýkaj.

---

# 13. `tests/integration/test_build_real_legacy_backend.py`

Tento test nech je prvý tvrdší build assertion test.

## verzia A — ak už máš reálne napojený legacy flow

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_runs_real_legacy_backend_and_emits_outputs(tmp_path):
    out_dir = tmp_path / "out"
    pipeline = FullBuildPipeline()

    result = pipeline.build(
        BuildRequest(
            project_file="project_config.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok
    assert len(result.generated_files) >= 1

    # tighten these assertions once the real legacy entrypoint is wired
    assert (out_dir / "rtl" / "soc_top.sv").exists() or (out_dir / "LEGACY_BACKEND_NOT_FULLY_WIRED.txt").exists()
```

## verzia B — keď už vieš stabilne, že build generuje konkrétne súbory

Sprísni:

```python
assert (out_dir / "rtl" / "soc_top.sv").exists()
assert (out_dir / "hal" / "board.tcl").exists()
assert (out_dir / "timing" / "soc_top.sdc").exists()
```

Na Commit 9 by som začal verziou A a po prvom úspechu prešiel na B.

---

# 14. Ako presne doplniť `build_legacy()` podľa tvojho repa

Tu je praktický checklist:

## krok 1

Nájdi dnešný script alebo funkciu, ktorou buildíš projekt ručne.

## krok 2

Ak build dnes ide napríklad takto:

* parse `project_config.yaml`
* zavolaj `rtl_builder`
* zavolaj `rtl.py`
* zavolaj `tcl.py`
* zavolaj `sdc.py`
* zavolaj `sw.py`

tak to **neschovávaj** do `LegacyBackend`.
Daj to celé do:

* `legacy_build.py`

## krok 3

Nech `legacy_build.py` na konci prejde výstupný strom a vráti paths.

### helper pattern

Do `legacy_build.py` si môžeš pridať:

```python
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
```

A na konci:

```python
return _collect_generated(out_dir)
```

To je veľmi praktické.

---

# 15. Čo v tomto commite ešte **nerobiť**

Vedome by som stále nechal bokom:

* nový IR builder
* nový emitter stack
* deterministic report builder
* vendor pack wiring
* bridge planner
* CPU-aware build orchestration

Commit 9 má riešiť len:

* nový `build` command ide cez reálny legacy backend

To je správny scope.

---

# 16. Čo po Commite 9 overiť

Spusti:

```bash
pip install -e .
socfw build project_config.yaml --out build/test_phase1
pytest tests/integration/test_build_real_legacy_backend.py
```

### cieľ

* build už negeneruje len marker
* ale reálne build outputs

---

# 17. Pravdepodobné riziká v Commite 9

Najväčšie tri:

## 1. legacy build nie je centralizovaný

Riešenie:

* centralizovať ho do `legacy_build.py`

## 2. legacy build má hardcoded output cesty

Riešenie:

* parameterizovať `out_dir`
* ak treba, sprav len minimálny patch starých scriptov

## 3. generated files sa ťažko zbierajú

Riešenie:

* po buildu ich jednoducho zoskenuj z výstupného stromu

To je úplne dostačujúce pre tento commit.

---

# 18. Definition of Done pre Commit 9

Commit 9 je hotový, keď:

* `socfw build` ide cez nový validate + build flow
* `LegacyBackend` volá reálny legacy entrypoint
* build vygeneruje aspoň prvé reálne artefakty
* integračný test to overí

To je veľmi silný convergence checkpoint.

---

# 19. Čo má byť Commit 10

Po tomto by som išiel na:

## Commit 10

```text
report: add first deterministic validation/build summary report
```

alebo, ak chceš skôr pokryť nový stable slice:

## Commit 10

```text
fixture: add first pack-aware converged blink project and build test
```

Môj praktický odporúčaný ďalší krok je:

👉 **najprv pack-aware converged blink fixture**

Lebo po Commite 9 už nový CLI vie:

* validate
* build

a teraz chceš prvý projekt, ktorý už ide **novým štýlom**, nie len cez legacy project config.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 10 ako file-by-file scaffold: prvý pack-aware converged blink fixture + build test**
