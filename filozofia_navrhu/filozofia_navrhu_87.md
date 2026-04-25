Áno. Tu je **Commit 26 ako konkrétny scaffold**:

# Commit 26 — default docs and examples switch to `socfw` flow

Cieľ commitu:

* nový `socfw` flow sa stane dokumentačným defaultom
* legacy flow zmizne z quickstartu
* všetky nové príklady ukazujú:

  * `socfw validate`
  * `socfw build`
* legacy zostane len ako migration fallback

---

# Názov commitu

```text
cutover: switch default docs and examples to socfw flow
```

---

# Súbory, ktoré upraviť

```text
README.md
docs/user/getting_started.md
docs/user/examples.md
docs/dev_notes/cutover_status.md
docs/dev_notes/checkpoints.md
```

Ak tieto docs ešte nemáš, pridaj ich.

---

# README hlavná sekcia

Nahraď starý quickstart týmto:

````md
## Quickstart

Validate a project:

```bash
socfw validate tests/golden/fixtures/blink_converged/project.yaml
````

Build a project:

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
```

Reference new-flow fixtures:

* `tests/golden/fixtures/blink_converged`
* `tests/golden/fixtures/pll_converged`
* `tests/golden/fixtures/vendor_pll_soc`
* `tests/golden/fixtures/vendor_sdram_soc`

Legacy scripts are kept only as migration fallback.

````

---

# `docs/user/getting_started.md`

```md
# Getting Started

The default flow is the `socfw` CLI.

## Validate

```bash
socfw validate <project.yaml>
````

## Build

```bash
socfw build <project.yaml> --out build/gen
```

## Example

```bash
socfw validate tests/golden/fixtures/blink_converged/project.yaml
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
```

## Project shape

```yaml
version: 2
kind: project

project:
  name: my_project
  mode: standalone
  board: qmtech_ep4ce55

registries:
  packs:
    - packs/builtin
  ip:
    - ip

modules:
  - instance: blink_test
    type: blink_test
```

## Notes

* Boards are resolved through packs.
* IP descriptors are loaded from registered IP paths or packs.
* Vendor IP should use descriptor metadata rather than ad-hoc project scripts.

````

---

# `docs/user/examples.md`

```md
# Examples

## Blink

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
````

Purpose:

* standalone project
* board pack resolution
* local IP descriptor

## PLL

```bash
socfw build tests/golden/fixtures/pll_converged/project.yaml --out build/pll_converged
```

Purpose:

* generated clock timing
* PLL-style integration

## Vendor PLL

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
```

Purpose:

* vendor pack
* QIP export
* SDC export

## Vendor SDRAM

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
```

Purpose:

* external SDRAM board resources
* vendor memory IP
* simple_bus to wishbone bridge scaffold

````

---

# `docs/dev_notes/cutover_status.md`

Doplň stav po docs switchi:

```md
## Current default

The documented default flow is now:

```bash
socfw validate <project.yaml>
socfw build <project.yaml> --out <dir>
````

Legacy flow is retained only as fallback during migration.

````

---

# `docs/dev_notes/checkpoints.md`

Doplň:

```md
## m5-docs-default-switch

Status:
- README quickstart uses `socfw`
- user getting started guide uses `socfw`
- examples guide uses converged fixtures
- legacy flow is documented only as migration fallback

Next:
- CI required lane switch
- legacy compatibility lane
````

---

# Voliteľný docs test

Pridaj jednoduchý grep-style test:

```text
tests/unit/test_docs_default_flow.py
```

```python
from pathlib import Path


def test_readme_uses_socfw_default_flow():
    text = Path("README.md").read_text(encoding="utf-8")
    assert "socfw validate" in text
    assert "socfw build" in text
```

---

# Čo v tomto commite nerobiť

Nerob ešte:

* legacy removal
* CI lane switch
* hard fail legacy
* migration of every old example

Tento commit mení len **dokumentačný default**.

---

# Definition of Done

Commit 26 je hotový, keď:

* README ukazuje `socfw`
* user docs ukazujú `socfw`
* examples ukazujú converged fixtures
* legacy je popísané len ako fallback

Ďalší commit:

```text
ci: make new-flow fixtures required and move legacy to compatibility lane
```
