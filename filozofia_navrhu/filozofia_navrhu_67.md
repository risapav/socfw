Áno. Tu je **Commit 6 ako file-by-file scaffold**:

# Commit 6 — `BuildRequest` + `BuildResult` + prvý `socfw build` nad legacy backend wrapperom

Cieľ tohto commitu:

* zaviesť prvý **build orchestration layer**
* mať nový príkaz:

```bash
socfw build <project> --out build/gen
```

* použiť už nový:

  * `SystemLoader`
  * `ProjectModel`
  * `BoardModel`
  * `TimingModel`
  * `ip_catalog`
* ale samotné generovanie ešte môže ísť cez **legacy backend wrapper**

To je presne správny convergence krok:

* nový front-end už existuje
* legacy backend ešte dočasne pracuje
* nič zásadné sa neláme

---

# Názov commitu

```text
build: add minimal build context and legacy-backed validate/build pipeline
```

---

# 1. Súbory, ktoré pridať

```text
socfw/build/context.py
socfw/build/result.py
socfw/build/legacy_backend.py
socfw/build/full_pipeline.py
tests/integration/test_build_legacy_backend_wrapper.py
```

---

# 2. Súbory, ktoré upraviť

```text
socfw/cli/main.py
socfw/config/system_loader.py
```

`system_loader.py` len minimálne, iba ak potrebuješ preniesť raw legacy file paths alebo zlepšiť source context.

---

# 3. Kľúčové rozhodnutie pre Commit 6

Toto je veľmi dôležité:

## ešte nejdeme písať nový emitter stack

Namiesto toho spravíme:

* nový `socfw build`
* ktorý si najprv načíta a overí systém novým flow
* a potom zavolá **malý compatibility wrapper**, ktorý použije starý build/generator backend

Tým pádom:

* vieš už používať nový CLI
* vieš zbierať diagnostics v novom svete
* a stále nemusíš ešte refaktorovať `rtl.py`, `tcl.py`, `sdc.py`, `sw.py`

---

# 4. `socfw/build/context.py`

```python
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BuildRequest:
    project_file: str
    out_dir: str
```

---

# 5. `socfw/build/result.py`

Na Phase 1 nech je to jednoduché.

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class BuildResult:
    ok: bool = False
    diagnostics: list = field(default_factory=list)
    generated_files: list[str] = field(default_factory=list)
```

---

# 6. `socfw/build/legacy_backend.py`

Toto je najdôležitejší súbor commitu.

Cieľ:

* mať **jedno miesto**, kde nový svet zavolá starý build
* nevlievať legacy importy do CLI ani loaderov

Keďže presnú podobu tvojho starého entrypointu v tejto chvíli nevoláme priamo, dám ti scaffold v dvoch vrstvách:

* najprv malý adapter
* doň si doplníš presný existujúci legacy call

## odporúčaný scaffold

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.result import BuildResult
from socfw.core.diagnostics import Diagnostic, Severity


class LegacyBackend:
    """
    Thin adapter around the current legacy generation flow.

    The goal in Phase 1 is not to redesign generation here,
    but to centralize the legacy call site so that later commits
    can replace it with new IR-based emitters.
    """

    def build(self, *, system, request) -> BuildResult:
        out_dir = Path(request.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)

        try:
            generated_files = self._invoke_legacy_generator(system=system, request=request)
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

    def _invoke_legacy_generator(self, *, system, request) -> list[str]:
        """
        Replace this method body with the actual current repo call.

        Recommended policy for Commit 6:
        - do the smallest possible bridge
        - call the existing top-level generator path
        - collect a list of the files it emits
        """

        # ---- Example placeholder strategy ----
        #
        # If your current repo has a legacy orchestrator function like:
        #   from rtl_builder import generate_project
        #   generate_project(project_cfg_path, out_dir)
        #
        # then call it here.
        #
        # For now, this scaffold creates no files by itself and serves
        # as a TODO marker until you wire the real function.
        #
        raise RuntimeError(
            "Legacy backend adapter is not wired yet. "
            "Connect _invoke_legacy_generator() to the existing generator entrypoint."
        )
```

---

# 7. Ako presne napojiť legacy backend na tvoj aktuálny repo stav

Tu je praktická časť.

Podľa súborov, ktoré máš (`rtl_builder.py`, `rtl.py`, `tcl.py`, `sdc.py`, `sw.py`), máš veľmi pravdepodobne niekde:

* top-level build funkciu
* alebo aspoň build script, ktorý ich orchestruje

## čo spraviť

V `_invoke_legacy_generator()` sprav iba jedno z týchto dvoch riešení:

### možnosť A — existuje jeden top-level script/funkcia

Napríklad niečo v štýle:

```python
from rtl_builder import build_project
build_project(project_config_path, out_dir)
```

Potom sprav presne to.

### možnosť B — top-level orchestration neexistuje

Ak starý flow je len voľne rozhádzaný, sprav **jeden nový legacy entrypoint**, napr.:

```text
legacy_build.py
```

s funkciou:

```python
def build_legacy(project_file: str, out_dir: str) -> list[str]:
    ...
```

a `LegacyBackend` bude volať už len túto funkciu.

## veľmi dôležité

Nech je len **jedno miesto**, kde sa nový flow dotýka starého flow.

---

# 8. Ak potrebuješ rýchly dočasný shim

Ak chceš mať Commit 6 green ešte pred plným napojením legacy backendu, môžeš spraviť dočasný no-op shim, ktorý aspoň vytvorí build root marker.

To je užitočné na rozbehanie CLI.

## dočasná verzia `_invoke_legacy_generator()`

```python
    def _invoke_legacy_generator(self, *, system, request) -> list[str]:
        out_dir = Path(request.out_dir)
        marker = out_dir / "LEGACY_BACKEND_NOT_WIRED.txt"
        marker.write_text(
            f"Project: {system.project.name}\n"
            f"Board: {system.board.board_id}\n"
            f"This is a temporary Phase 1 marker.\n",
            encoding="utf-8",
        )
        return [str(marker)]
```

### kedy to použiť

* ak chceš commitnúť orchestration skôr
* a actual legacy wiring spraviť v Commit 6b alebo hneď potom

Ale ak sa dá, radšej už napoj reálny legacy build.

---

# 9. `socfw/build/full_pipeline.py`

Toto je prvý orchestration layer.

```python
from __future__ import annotations

from socfw.build.legacy_backend import LegacyBackend
from socfw.build.result import BuildResult
from socfw.config.system_loader import SystemLoader


class FullBuildPipeline:
    def __init__(self) -> None:
        self.loader = SystemLoader()
        self.legacy = LegacyBackend()

    def validate(self, project_file: str):
        return self.loader.load(project_file)

    def build(self, request) -> BuildResult:
        loaded = self.loader.load(request.project_file)

        diags = list(loaded.diagnostics)
        if not loaded.ok or loaded.value is None:
            return BuildResult(ok=False, diagnostics=diags, generated_files=[])

        built = self.legacy.build(system=loaded.value, request=request)
        built.diagnostics = diags + list(built.diagnostics)
        return built
```

---

# 10. úprava `socfw/cli/main.py`

Teraz pridáme nový command:

* `build`

## odporúčaná verzia

```python
from __future__ import annotations

import argparse

from socfw import __version__
from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline
from socfw.config.system_loader import SystemLoader


def cmd_version(_args) -> int:
    print(__version__)
    return 0


def _print_diags(diags) -> None:
    for d in diags:
        head = f"{d.severity.value.upper()} {d.code}: {d.message}"
        print(head)
        if d.file:
            loc = d.file
            if d.path:
                loc += f" :: {d.path}"
            print(f"  at: {loc}")
        for h in getattr(d, "hints", ()):
            print(f"  hint: {h}")


def cmd_validate(args) -> int:
    loaded = SystemLoader().load(args.project)
    _print_diags(loaded.diagnostics)

    if loaded.ok and loaded.value is not None:
        timing_info = "timing=none"
        if loaded.value.timing is not None:
            timing_info = (
                f"timing=generated_clocks:{len(loaded.value.timing.generated_clocks)} "
                f"false_paths:{len(loaded.value.timing.false_paths)}"
            )

        print(
            f"OK: project={loaded.value.project.name} "
            f"board={loaded.value.board.board_id} "
            f"ip_catalog={len(loaded.value.ip_catalog)} "
            f"{timing_info}"
        )
        return 0
    return 1


def cmd_build(args) -> int:
    pipeline = FullBuildPipeline()
    result = pipeline.build(BuildRequest(project_file=args.project, out_dir=args.out))

    _print_diags(result.diagnostics)

    if result.ok:
        print(f"OK: generated_files={len(result.generated_files)} out={args.out}")
        for fp in result.generated_files:
            print(fp)
        return 0

    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="socfw")
    sub = parser.add_subparsers(dest="command", required=True)

    p_ver = sub.add_parser("version", help="Show version")
    p_ver.set_defaults(func=cmd_version)

    p_val = sub.add_parser("validate", help="Validate project and resolve board")
    p_val.add_argument("project")
    p_val.set_defaults(func=cmd_validate)

    p_build = sub.add_parser("build", help="Build project using the current backend")
    p_build.add_argument("project")
    p_build.add_argument("--out", default="build/gen")
    p_build.set_defaults(func=cmd_build)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
```

---

# 11. Voliteľná drobná úprava `socfw/config/system_loader.py`

Ak chceš mať legacy backendu po ruke viac kontextu, môžeš do `SystemModel.sources` doplniť raw timing a project file absolute paths. Ale v Commite 6 to nie je povinné.

---

# 12. `tests/integration/test_build_legacy_backend_wrapper.py`

Tento test je správne držať veľmi mäkký, aby neblokoval commit, kým ešte len pripájaš legacy backend.

## varianta A — ak používaš dočasný marker shim

```python
from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_runs_through_new_pipeline_with_legacy_wrapper(tmp_path):
    pipeline = FullBuildPipeline()
    out_dir = tmp_path / "out"

    result = pipeline.build(
        BuildRequest(
            project_file="project_config.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok
    assert len(result.generated_files) >= 1
```

## varianta B — keď už wiringneš reálny legacy build

Potom assertion sprísni na reálne výstupy, napr.:

```python
assert (out_dir / "rtl" / "soc_top.sv").exists()
```

Ale na Commit 6 by som bol ešte opatrný a nechal skôr mäkší test.

---

# 13. Ako nájsť správny legacy entrypoint v tvojom repozitári

Pretože aktuálne nemáme potvrdené presné meno legacy orchestratora, odporúčam tento praktický postup:

## v repozitári nájdi miesto, ktoré dnes naozaj generuje výstupy

Hľadaj:

* `if __name__ == "__main__"`
* funkciu typu:

  * `main()`
  * `build()`
  * `generate_*()`
* miesto, ktoré volá:

  * `rtl.py`
  * `tcl.py`
  * `sdc.py`
  * `sw.py`

## keď ho nájdeš

Presuň ho alebo obal do jedného call pointu, napr.:

```python
# legacy_build.py
def build_legacy(project_file: str, out_dir: str) -> list[str]:
    ...
```

A nový `LegacyBackend` nech už volá len toto.

---

# 14. Čo v tomto commite ešte **nerobiť**

Vedome by som ešte nechal bokom:

* nový IR builder
* nový emit orchestrator
* nový report builder
* nový timing emitter
* CPU loader
* bus planning
* packs pre IP/CPU

Commit 6 má spraviť len jedno:

* nový CLI už vie build
* aj keď build zatiaľ ešte robí starý backend

To je presne správny most medzi svetmi.

---

# 15. Čo po Commite 6 overiť

Spusti:

```bash
pip install -e .
socfw validate project_config.yaml
socfw build project_config.yaml --out build/test_phase1
```

### ak používaš marker shim

Očakávaj:

* vznikne `build/test_phase1/LEGACY_BACKEND_NOT_WIRED.txt`

### ak už máš napojený reálny legacy build

Očakávaj:

* vzniknú legacy generované artefakty

---

# 16. Pravdepodobné riziko v Commite 6

Najväčšie riziko nie je nový `socfw/` kód, ale to, že tvoj legacy backend nebude mať jeden čistý entrypoint.

### riešenie

Ak treba, sprav **malý nový súbor mimo `socfw/`**, napr.:

```text
legacy_build.py
```

ktorý iba zjednotí starý orchestration call.

To je úplne v poriadku a veľmi praktické.

---

# 17. Definition of Done pre Commit 6

Commit 6 je hotový, keď:

* `socfw build <project>` existuje
* build používa nový loader chain
* build volá legacy backend cez jedno centralizované miesto
* výsledok sa vracia cez `BuildResult`
* test prejde aspoň cez wrapper path

To je veľmi slušný convergence milestone.

---

# 18. Čo má byť Commit 7

Hneď po tomto by som spravil:

## Commit 7

```text
loader: add cpu model and cpu descriptor loading
```

Ten prinesie:

* `CpuDescriptor`
* `cpu_loader.py`
* support pre `*.cpu.yaml`
* základ pre SoC flow, PicoRV32 aj dummy CPU

To je ďalší logický krok po tom, čo už nový CLI vie:

* validate
* build wrapper

---

# 19. Môj praktický odporúčaný rytmus

Po Commite 6:

1. najprv rozbehať `socfw build` aj cez dočasný shim
2. potom dopojiť reálny legacy entrypoint
3. až keď je build green, ísť na CPU loading
4. stále ešte nerefaktorovať nový RTL emitter stack

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 7 ako file-by-file scaffold: `CpuDescriptor` + `cpu_loader.py` + `*.cpu.yaml` catalog loading**
