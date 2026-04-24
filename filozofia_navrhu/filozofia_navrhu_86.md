Áno. Tu je **Commit 25 ako file-by-file scaffold**:

# Commit 25 — deprecation warnings pre legacy entrypointy

Cieľ commitu:

* jasne signalizovať používateľom, že legacy flow je deprecated
* nasmerovať ich na `socfw validate` a `socfw build`
* **nezlomiť existujúce projekty**, len pridať varovanie
* pripraviť pôdu pre neskorší hard cutover

---

# Názov commitu

```text
cutover: add deprecation warnings to legacy entrypoints
```

---

# 1. Čo má byť výsledok po Commite 25

Keď niekto použije legacy flow (napr. starý script alebo `project_config.yaml`):

* build stále funguje
* ale zobrazí sa jasné upozornenie:

```
[DEPRECATED] Legacy build flow is in maintenance mode.
Use: socfw validate <project.yaml>
     socfw build <project.yaml> --out <dir>
See: docs/dev_notes/cutover_status.md
```

---

# 2. Súbory, ktoré upraviť

```text
legacy_build.py
socfw/build/full_pipeline.py
socfw/cli.py   (ak existuje)
```

---

# 3. Súbory, ktoré pridať

```text
socfw/utils/deprecation.py
tests/integration/test_legacy_deprecation_warning.py
```

---

# 4. `socfw/utils/deprecation.py`

Centralizovaný helper (aby si nemal copy-paste stringy).

```python
from __future__ import annotations


def legacy_deprecation_message() -> str:
    return (
        "[DEPRECATED] Legacy build flow is in maintenance mode.\n"
        "Use: socfw validate <project.yaml>\n"
        "     socfw build <project.yaml> --out <dir>\n"
        "See: docs/dev_notes/cutover_status.md"
    )


def print_legacy_warning() -> None:
    print(legacy_deprecation_message())
```

---

# 5. úprava `legacy_build.py`

Pridaj warning na začiatok buildu.

## pridaj import

```python
from socfw.utils.deprecation import print_legacy_warning
```

## v `build_legacy(...)` úplne hore:

```python
def build_legacy(project_file: str, out_dir: str, system=None) -> list[str]:
    print_legacy_warning()
```

---

# 6. úprava `_convert_new_project_to_legacy_shape(...)`

Ak sa používa compatibility fallback (nový project → legacy shape), je dobré signalizovať to jemnejšie.

Pridaj (voliteľné):

```python
from socfw.utils.deprecation import legacy_deprecation_message
```

a napr.:

```python
print("[compat] Using legacy compatibility backend")
```

Nie full warning (aby si nespamoval), len info.

---

# 7. úprava `socfw/build/full_pipeline.py`

Ak chceš byť presný:

* warning len ak sa reálne použije legacy backend

## nájdi:

```python
built = self.legacy.build(system=system, request=request)
```

a pred tým pridaj:

```python
from socfw.utils.deprecation import print_legacy_warning

print_legacy_warning()
```

### ALE pozor

Ak už warning dáva `legacy_build.py`, neduplikuj.

👉 odporúčanie:

* nech warning generuje **len legacy layer**, nie pipeline

---

# 8. CLI integrácia (ak máš `socfw/cli.py`)

Ak existujú staré CLI entrypointy (napr. `python build.py` alebo `legacy build`):

pridaj warning aj tam.

## príklad

```python
from socfw.utils.deprecation import print_legacy_warning

def legacy_cli_entry():
    print_legacy_warning()
    # continue...
```

---

# 9. `tests/integration/test_legacy_deprecation_warning.py`

Tento test zabezpečí, že warning nezmizne.

```python
import io
import sys

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_legacy_deprecation_warning_is_printed(tmp_path, capsys):
    out_dir = tmp_path / "out"

    FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    captured = capsys.readouterr()
    assert "DEPRECATED" in captured.out
    assert "socfw build" in captured.out
```

---

# 10. UX rozhodnutie: stdout vs stderr

Odporúčanie:

* použiť **stdout** (jednoduchšie pre golden/logy)
* ale prefixovať `[DEPRECATED]`

Ak chceš byť prísnejší neskôr:

* môžeš to presunúť na stderr

Na tento commit stdout stačí.

---

# 11. Čo v tomto commite ešte **nerobiť**

Vedome nerobiť:

* fail build pre legacy flow ❌
* remove legacy backend ❌
* feature freeze enforcement ❌
* CLI breaking changes ❌

Toto je len **soft warning commit**

---

# 12. Čo po Commite 25 overiť

Spusti:

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/test
pytest tests/integration/test_legacy_deprecation_warning.py
```

### očakávanie

* build green
* warning sa zobrazí
* test je green

---

# 13. Definition of Done

Commit 25 je hotový, keď:

* legacy build vypíše deprecation warning
* warning obsahuje:

  * nový CLI
  * link na docs
* integration test to pokrýva
* nič sa nerozbije

---

# 14. Čo má byť Commit 26

Teraz prichádza zlomový krok:

## Commit 26

```text
cutover: switch default docs and examples to socfw flow
```

Ten prinesie:

* všetky príklady v repo používajú `socfw`
* legacy už nie je prvý-class path
* README, examples, snippets sú pre nový flow

---

# 15. Môj odporúčaný ďalší krok

👉 Commit 26 je teraz najdôležitejší, lebo:

* technicky si už pripravený
* teraz treba otočiť “mentálny default”

---

Ak chceš, môžem ti hneď rozbiť:

👉 **Commit 26 ako konkrétne úpravy README, examples a docs (presné diffy)**
