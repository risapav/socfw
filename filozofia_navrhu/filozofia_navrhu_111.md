## Commit 47 — cleanup compatibility legacy patches

Cieľ:

* odstrániť staré compatibility hacky z default cesty
* nechať legacy backend izolovaný
* zmenšiť mentálny dlh po prepnutí native pipeline

Názov commitu:

```text
cleanup: remove compatibility legacy patches from build path
```

## Upraviť alebo odstrániť

```text
legacy_build.py
socfw/build/legacy_backend.py
socfw/build/top_injection.py
socfw/build/compat_top_patch.py
docs/dev_notes/legacy_freeze_policy.md
tests/unit/test_top_injection.py
tests/unit/test_compat_top_patch.py
```

---

## 1. Odstrániť nepoužívané patch súbory

Ak už sa nepoužívajú:

```text
socfw/build/top_injection.py
socfw/build/compat_top_patch.py
```

zmaž.

Zmaž aj testy:

```text
tests/unit/test_top_injection.py
tests/unit/test_compat_top_patch.py
```

---

## 2. Zjednodušiť `legacy_build.py`

Nech legacy build robí už iba legacy veci.

Odstráň z neho:

* vendor files patchovanie
* bridge summary generovanie
* top patchovanie
* native bridge artifact copy

Teda ponechaj iba:

```python
from __future__ import annotations

from pathlib import Path

from socfw.utils.deprecation import print_legacy_warning


def build_legacy(project_file: str, out_dir: str, system=None, planned_bridges=None) -> list[str]:
    print_legacy_warning()

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    # TODO alebo existujúci skutočný legacy entrypoint:
    # from old_legacy_entry import build_project
    # build_project(project_file=project_file, out_dir=str(out))

    return _collect_generated(out_dir)


def _collect_generated(out_dir: str) -> list[str]:
    root = Path(out_dir)
    found = []
    for sub in ["rtl", "hal", "timing", "sw", "docs", "reports"]:
        sp = root / sub
        if sp.exists():
            for fp in sorted(sp.rglob("*")):
                if fp.is_file():
                    found.append(str(fp))
    return sorted(dict.fromkeys(found))
```

Ak stále potrebuješ `_convert_new_project_to_legacy_shape()`, nechaj ho len v legacy vetve, ale jasne komentuj:

```python
# Legacy-only compatibility conversion.
```

---

## 3. `legacy_backend.py`

Nech zostane tenký wrapper:

```python
class LegacyBackend:
    def build(self, *, system, request, planned_bridges=None) -> BuildResult:
        ...
        from legacy_build import build_legacy
        generated_files = build_legacy(
            project_file=request.project_file,
            out_dir=str(out_dir),
            system=system,
            planned_bridges=planned_bridges or [],
        )
```

To je v poriadku, ale nič native už nemá byť v `legacy_build.py`.

---

## 4. Overiť default pipeline

V `FullBuildPipeline.build()` musí byť jasná štruktúra:

```python
if request.legacy_backend:
    built = self.legacy.build(...)
else:
    built = self._build_native(...)
```

Odporúčam extrahovať:

```python
def _build_native(self, *, system, request, planned_bridges) -> BuildResult:
    ...
```

---

## 5. Docs update

Do `docs/dev_notes/legacy_freeze_policy.md` doplň:

```md
## Isolation

Legacy code must not:
- patch native outputs
- generate native reports
- mutate native build artifacts
- own vendor QIP/SDC export

Native emitters are the source of truth for:
- rtl/soc_top.sv
- hal/files.tcl
- hal/board.tcl
- timing/soc_top.sdc
- reports/build_summary.md
```

---

## 6. Test cleanup

Odstráň testy, ktoré overovali patchovanie.

Ponechaj:

* `test_rtl_emitter.py`
* `test_files_tcl_emitter.py`
* `test_sdc_emitter.py`
* `test_board_tcl_emitter.py`
* `test_bridge_planner.py`

---

## Definition of Done

Commit 47 je hotový, keď:

* default build cesta neobsahuje compatibility patch helpers
* legacy backend je izolovaný
* odstránené patch testy
* všetky native emitter testy sú green
* vendor PLL/SDRAM golden stále green

Ďalší commit:

```text
build: add native build artifact inventory and remove generated-files duplication
```
