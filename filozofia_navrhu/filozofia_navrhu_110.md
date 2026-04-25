## Commit 46 — native default pipeline, legacy iba cez `--legacy-backend`

Cieľ:

* prestať volať legacy backend v bežnom `socfw build`
* native emitters sa stanú defaultom:

  * RTL top
  * `files.tcl`
  * `soc_top.sdc`
  * `board.tcl`
  * build summary
* legacy backend ostane dostupný len explicitne cez flag

Názov commitu:

```text
build: remove legacy backend from default pipeline and keep it behind --legacy-backend
```

## Upraviť

```text
socfw/build/context.py
socfw/build/full_pipeline.py
socfw/cli/main.py
tests/integration/test_legacy_deprecation_warning.py
tests/integration/test_build_blink_converged.py
tests/integration/test_build_vendor_pll_soc.py
tests/integration/test_build_vendor_sdram_soc.py
```

---

## `socfw/build/context.py`

Rozšír `BuildRequest`:

```python
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BuildRequest:
    project_file: str
    out_dir: str
    legacy_backend: bool = False
```

---

## `socfw/build/full_pipeline.py`

V default build flow už nevolaj:

```python
built = self.legacy.build(...)
```

Namiesto toho:

```python
generated_files = []

rtl_top = self.rtl_builder.build(system=system, planned_bridges=planned_bridges)
generated_files.append(self.rtl_emitter.emit_top(request.out_dir, rtl_top))

for bridge in planned_bridges:
    # copy bridge RTL artifact
    ...

generated_files.append(self.files_tcl_emitter.emit(...))
generated_files.append(self.sdc_emitter.emit(...))
generated_files.append(self.board_tcl_emitter.emit(...))
```

Legacy vetva:

```python
if request.legacy_backend:
    built = self.legacy.build(
        system=system,
        request=request,
        planned_bridges=planned_bridges,
    )
else:
    built = BuildResult(ok=True, diagnostics=[], generated_files=generated_files)
```

Dôležité: report generuj v oboch prípadoch.

---

## helper na bridge copy

Do `full_pipeline.py` alebo samostatne:

```python
from pathlib import Path


def _copy_bridge_artifacts(out_dir: str, planned_bridges) -> list[str]:
    rtl_dir = Path(out_dir) / "rtl"
    rtl_dir.mkdir(parents=True, exist_ok=True)

    copied = []
    for bridge in planned_bridges:
        src = Path(bridge.rtl_file)
        dst = rtl_dir / src.name
        dst.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
        copied.append(str(dst))

    return sorted(dict.fromkeys(copied))
```

---

## `socfw/cli/main.py`

Build command doplň:

```python
p_build.add_argument(
    "--legacy-backend",
    action="store_true",
    help="Use deprecated legacy backend instead of native emitters",
)
```

A request:

```python
BuildRequest(
    project_file=args.project,
    out_dir=args.out,
    legacy_backend=args.legacy_backend,
)
```

---

## Legacy warning test

Uprav tak, aby používal flag:

```python
FullBuildPipeline().build(
    BuildRequest(
        project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
        out_dir=str(out_dir),
        legacy_backend=True,
    )
)
```

A nový default build test nech overí, že warning sa nevypíše.

---

## Integration očakávania

Default build:

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/test
```

už nemá vypisovať:

```text
[DEPRECATED]
```

Legacy build:

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/test --legacy-backend
```

má warning vypísať.

---

## Definition of Done

Commit 46 je hotový, keď:

* default `socfw build` nepoužíva legacy backend
* legacy backend je dostupný cez `--legacy-backend`
* deprecated warning sa objaví len pri legacy backendu
* všetky anchor build testy sú green

Ďalší commit:

```text
cleanup: remove compatibility legacy patches from build path
```
