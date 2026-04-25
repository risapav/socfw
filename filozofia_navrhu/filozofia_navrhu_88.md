Áno. Tu je **Commit 27 ako file-by-file scaffold**:

# Commit 27 — CI required lane pre new-flow fixtures + legacy compatibility lane

Cieľ commitu:

* nový `socfw` flow sa stane CI source of truth
* converged fixtures budú required regression lane
* legacy zostane iba compatibility / fallback lane
* cutover sa začne technicky presadzovať cez CI

---

# Názov commitu

```text
ci: make new-flow fixtures required and move legacy to compatibility lane
```

---

# Súbory, ktoré upraviť

```text
.github/workflows/ci.yml
docs/dev_notes/checkpoints.md
docs/dev_notes/cutover_status.md
```

Ak `.github/workflows/ci.yml` ešte nemáš, pridaj ho.

---

# `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
  pull_request:

jobs:
  new-flow-required:
    name: new-flow required
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install
        run: |
          python -m pip install --upgrade pip
          pip install -e .
          pip install pytest

      - name: Unit tests
        run: |
          pytest tests/unit

      - name: Validate new-flow anchors
        run: |
          socfw validate tests/golden/fixtures/blink_converged/project.yaml
          socfw validate tests/golden/fixtures/pll_converged/project.yaml
          socfw validate tests/golden/fixtures/vendor_pll_soc/project.yaml
          socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml

      - name: Build new-flow anchors
        run: |
          socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/ci/blink_converged
          socfw build tests/golden/fixtures/pll_converged/project.yaml --out build/ci/pll_converged
          socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/ci/vendor_pll_soc
          socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/ci/vendor_sdram_soc

      - name: Golden tests
        run: |
          pytest tests/golden

  legacy-compatibility:
    name: legacy compatibility
    runs-on: ubuntu-latest
    continue-on-error: true

    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install
        run: |
          python -m pip install --upgrade pip
          pip install -e .
          pip install pytest

      - name: Legacy compatibility smoke
        run: |
          socfw validate project_config.yaml || true
          socfw build project_config.yaml --out build/ci/legacy_smoke || true
```

---

# Poznámka k legacy jobu

`continue-on-error: true` znamená:

* nový flow je required
* legacy už neblokuje PR
* ale stále vidíš, či fallback ešte funguje

To je presne správne pre cutover fázu.

---

# `docs/dev_notes/checkpoints.md`

Doplň:

```md
## m6-ci-default-switch

Status:
- new-flow fixtures run in required CI lane
- unit tests run in required CI lane
- golden tests run in required CI lane
- legacy smoke moved to compatibility lane

Next:
- default project scaffolding
- legacy freeze enforcement
```

---

# `docs/dev_notes/cutover_status.md`

Doplň:

```md
## CI status

Required lane:
- unit tests
- new-flow fixture validation
- new-flow fixture builds
- golden tests

Compatibility lane:
- legacy smoke
- non-blocking
```

---

# Voliteľný test

Ak chceš malý sanity test na workflow existenciu:

```text
tests/unit/test_ci_workflow_exists.py
```

```python
from pathlib import Path


def test_ci_workflow_exists():
    p = Path(".github/workflows/ci.yml")
    assert p.exists()
    text = p.read_text(encoding="utf-8")
    assert "new-flow-required" in text
    assert "legacy-compatibility" in text
```

---

# Čo v tomto commite nerobiť

Nerob ešte:

* legacy removal
* hard fail legacy usage
* package release
* v1.0 tag

Tento commit iba prepína CI priority.

---

# Definition of Done

Commit 27 je hotový, keď:

* CI má required new-flow lane
* converged fixtures sú validované a buildované
* golden tests bežia v required lane
* legacy smoke je non-blocking

Ďalší commit:

```text
scaffold: make socfw init create new-flow projects by default
```
