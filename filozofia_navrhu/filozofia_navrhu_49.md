Super. Ideme na:

# incremental build/cache design: fingerprints, stage caching, artifact invalidation, and deterministic rebuild policy

Toto je veľmi dobrý ďalší krok, pretože architektúra aj UX sú už silné. Ďalší veľký praktický posun je:

* kratší build čas,
* menej zbytočných regenerácií,
* lepšie lokálne iterovanie,
* stabilný a vysvetliteľný rebuild model.

Kľúčové slovo tu je: **deterministický cache model**, nie “magický smart build”.

---

# 1. Cieľ

Chceš dosiahnuť, že build vie rozlíšiť:

* čo sa **naozaj zmenilo**,
* ktoré stupne pipeline treba prepočítať,
* ktoré artefakty môžu zostať,
* a prečo sa niečo rebuildlo.

Teda nie len:

* “build všetko vždy”

ale ani nie:

* “skús hádať a dúfať”.

---

# 2. Správny princíp

Odporúčam rozdeliť pipeline na **cacheovateľné stage**:

1. **config load**
2. **validation**
3. **elaboration**
4. **IR build**
5. **emit**
6. **firmware build**
7. **reports**
8. **simulation prep**

Každý stage dostane:

* **input fingerprint**
* **output metadata**
* **status: hit/miss/rebuilt**

To je základ.

---

# 3. Čo sa má hashovať

Najdôležitejšie pravidlo:

## Hashuj vstupy stage-u, nie len timestampy súborov.

Timestampy môžeš používať len ako pomocný hint, nie ako jediný zdroj pravdy.

Odporúčané vstupy:

### config/load stage

* obsah:

  * `project.yaml`
  * `board.yaml`
  * `timing.yaml`
  * všetky `*.ip.yaml`
  * všetky `*.cpu.yaml`

### elaboration stage

* canonical serialized `SystemModel`
* verzia planner logiky

### IR stage

* canonical serialized `ElaboratedDesign`
* verzia builderov

### emit stage

* canonical serialized príslušného IR
* obsah template súboru
* verzia emitteru

### firmware stage

* obsah `fw/*.c`, `fw/*.S`
* `soc_map.h`
* `sections.lds`
* firmware config
* toolchain prefix
* compiler/linker flags

### report stage

* diagnostics
* design summary
* manifest
* report emitter version

---

# 4. Deterministická serializácia

Aby fingerprinty fungovali stabilne, potrebuješ **canonical serialization**.

Odporúčam:

* dataclass → dict
* dict keys vždy sorted
* JSON dump s:

  * `sort_keys=True`
  * bez whitespace noise
  * stable conversion enumov/Path objektov

---

## nový `socfw/tools/fingerprint.py`

```python
from __future__ import annotations

import dataclasses
import hashlib
import json
from pathlib import Path
from typing import Any


def canonicalize(obj: Any) -> Any:
    if dataclasses.is_dataclass(obj):
        return canonicalize(dataclasses.asdict(obj))
    if isinstance(obj, dict):
        return {str(k): canonicalize(v) for k, v in sorted(obj.items(), key=lambda kv: str(kv[0]))}
    if isinstance(obj, (list, tuple)):
        return [canonicalize(x) for x in obj]
    if isinstance(obj, Path):
        return str(obj)
    return obj


def stable_json(obj: Any) -> str:
    return json.dumps(
        canonicalize(obj),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def fingerprint_obj(obj: Any) -> str:
    return sha256_text(stable_json(obj))


def fingerprint_files(paths: list[str]) -> str:
    h = hashlib.sha256()
    for p in sorted(paths):
        fp = Path(p)
        h.update(str(fp).encode("utf-8"))
        if fp.exists():
            h.update(fp.read_bytes())
        else:
            h.update(b"<missing>")
    return h.hexdigest()
```

---

# 5. Cache manifest model

Potrebuješ jeden centrálny súbor, ktorý povie:

* aké stage fingerprints boli použité,
* aké artefakty stage vyrobil,
* či bol hit/miss.

## nový `socfw/build/cache_model.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class CacheStageRecord:
    name: str
    fingerprint: str
    inputs: list[str] = field(default_factory=list)
    outputs: list[str] = field(default_factory=list)
    hit: bool = False
    note: str = ""


@dataclass
class CacheManifest:
    stages: dict[str, CacheStageRecord] = field(default_factory=dict)
```

---

# 6. Cache storage

Najjednoduchšie a veľmi praktické:

```text
build/.socfw_cache/
  cache_manifest.json
  fingerprints/
  stage_outputs/
```

Ale pre prvú verziu úplne stačí:

* `build/.socfw_cache/cache_manifest.json`

---

## nový `socfw/build/cache_store.py`

```python
from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from socfw.build.cache_model import CacheManifest, CacheStageRecord


class CacheStore:
    def __init__(self, out_dir: str) -> None:
        self.root = Path(out_dir) / ".socfw_cache"
        self.root.mkdir(parents=True, exist_ok=True)
        self.manifest_file = self.root / "cache_manifest.json"

    def load(self) -> CacheManifest:
        if not self.manifest_file.exists():
            return CacheManifest()

        data = json.loads(self.manifest_file.read_text(encoding="utf-8"))
        manifest = CacheManifest()
        for name, rec in data.get("stages", {}).items():
            manifest.stages[name] = CacheStageRecord(**rec)
        return manifest

    def save(self, manifest: CacheManifest) -> None:
        payload = {"stages": {k: asdict(v) for k, v in manifest.stages.items()}}
        self.manifest_file.write_text(json.dumps(payload, indent=2), encoding="utf-8")
```

---

# 7. Stage cache helper

Aby si nemusel v každom stage robiť tú istú logiku, sprav helper.

## nový `socfw/build/stage_cache.py`

```python
from __future__ import annotations

from socfw.build.cache_model import CacheStageRecord
from socfw.build.cache_store import CacheStore


class StageCache:
    def __init__(self, store: CacheStore) -> None:
        self.store = store
        self.manifest = store.load()

    def check(self, stage_name: str, fingerprint: str) -> bool:
        rec = self.manifest.stages.get(stage_name)
        return rec is not None and rec.fingerprint == fingerprint

    def update(
        self,
        stage_name: str,
        fingerprint: str,
        *,
        inputs: list[str] | None = None,
        outputs: list[str] | None = None,
        hit: bool = False,
        note: str = "",
    ) -> None:
        self.manifest.stages[stage_name] = CacheStageRecord(
            name=stage_name,
            fingerprint=fingerprint,
            inputs=inputs or [],
            outputs=outputs or [],
            hit=hit,
            note=note,
        )
        self.store.save(self.manifest)
```

---

# 8. Build policy

Teraz najdôležitejšia vec: **čo sa cacheuje v prvej verzii**.

Odporúčam nezačať príliš ambiciózne.

## Sprint-usable V1 cache

Cacheuj len tieto stage:

* `load_config`
* `elaborate`
* `ir`
* `software_emit`
* `firmware_build`
* `rtl_emit`
* `reports`

Nechaj validation vždy bežať.
Prečo?
Lebo:

* je relatívne lacná,
* používateľ chce vidieť čerstvé chyby,
* a vyhneš sa zvláštnym edge-case stavom.

To je veľmi dobrý kompromis.

---

# 9. Build stamp / version salt

Každý stage fingerprint musí obsahovať aj **version salt**, aby si vedel invalidovať cache pri zmene logiky.

## nový `socfw/build/cache_version.py`

```python
SOCFW_CACHE_VERSION = "v1"
```

A do fingerprintov pridaj:

* stage name
* cache version
* relevant component version string

Prakticky stačí:

```python
fingerprint_obj({
    "cache_version": SOCFW_CACHE_VERSION,
    "stage": "ir",
    "design": design,
})
```

---

# 10. Kde cache použiť ako prvé

Najväčšia hodnota je v:

## A. firmware stage

Ak sa nemení:

* `fw/*.c`
* `fw/*.S`
* `soc_map.h`
* `sections.lds`
* toolchain flags

nemá sa firmware rebuildovať.

## B. emit stage

Ak sa nemení:

* IR
* template

nemá sa znova generovať `soc_top.sv`, `soc_map.h`, atď.

## C. report stage

Ak sa nemení manifest/design/diagnostics,
report nemusí znova vznikať.

---

# 11. Emit cache helper

## nový `socfw/emit/cached_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.tools.fingerprint import fingerprint_obj, fingerprint_files


class CachedEmitterMixin:
    emitter_version = "v1"

    def emitter_fingerprint(self, *, ir, template_files: list[str] | None = None) -> str:
        payload = {
            "emitter_version": self.emitter_version,
            "ir": ir,
            "templates": fingerprint_files(template_files or []),
        }
        return fingerprint_obj(payload)

    def outputs_exist(self, outputs: list[str]) -> bool:
        return all(Path(p).exists() for p in outputs)
```

Toto nechceš pre všetky emitre hneď, ale ako pattern je to správne.

---

# 12. Firmware cache

## update `socfw/tools/firmware_builder.py`

Doplň fingerprint helper:

```python
from socfw.tools.fingerprint import fingerprint_files, fingerprint_obj
from socfw.build.cache_version import SOCFW_CACHE_VERSION
```

A metódu:

```python
    def fingerprint(self, system, out_dir: str) -> str:
        fw = system.firmware
        if fw is None or fw.src_dir is None:
            return ""

        src_dir = Path(fw.src_dir)
        sources = [str(p) for p in src_dir.glob("*.c")] + [str(p) for p in src_dir.glob("*.S")]
        generated_inputs = [
            str(Path(out_dir) / "sw" / "soc_map.h"),
            str(Path(out_dir) / "sw" / "sections.lds"),
        ]

        return fingerprint_obj({
            "cache_version": SOCFW_CACHE_VERSION,
            "stage": "firmware_build",
            "files": fingerprint_files(sorted(sources + generated_inputs)),
            "tool_prefix": fw.tool_prefix,
            "cflags": fw.cflags,
            "ldflags": fw.ldflags,
            "linker_script": fw.linker_script,
        })
```

---

# 13. Two-pass flow s cache

Najväčší prínos bude tu.

## update `socfw/build/two_pass_flow.py`

Pridaj importy:

```python
from socfw.build.cache_store import CacheStore
from socfw.build.stage_cache import StageCache
```

V `run()` na začiatok:

```python
        cache = StageCache(CacheStore(request.out_dir))
```

Pred firmware build:

```python
        fw_fp = self.firmware_builder.fingerprint(system, request.out_dir)
        fw_stage = "firmware_build"

        fw_out_dir = Path(request.out_dir) / "fw"
        fw_outputs = [
            str(fw_out_dir / "firmware.elf"),
            str(fw_out_dir / "firmware.bin"),
            str(fw_out_dir / "firmware.hex"),
        ]

        if cache.check(fw_stage, fw_fp) and all(Path(p).exists() for p in fw_outputs):
            from socfw.model.image import FirmwareArtifacts
            fw_res_value = FirmwareArtifacts(
                elf=str(fw_out_dir / "firmware.elf"),
                bin=str(fw_out_dir / "firmware.bin"),
                hex=str(fw_out_dir / "firmware.hex"),
            )
            fw_diags = []
        else:
            fw_res = self.firmware_builder.build(system, request.out_dir)
            first.diagnostics.extend(fw_res.diagnostics)
            if not fw_res.ok or fw_res.value is None:
                first.ok = False
                return first
            fw_res_value = fw_res.value
            cache.update(
                fw_stage,
                fw_fp,
                outputs=[fw_res_value.elf, fw_res_value.bin, fw_res_value.hex],
                note="rebuilt firmware",
            )
```

A potom používaj `fw_res_value`.

Toto je veľmi praktická prvá cache vrstva.

---

# 14. Emit cache policy

Pre emit stage odporúčam spočiatku jednoduchý model:

* ak fingerprint sedí
* a output súbor existuje
* skipni zápis

To je dosť.

Napríklad v `RtlEmitter.emit()`:

## update `socfw/emit/rtl_emitter.py`

Môžeš doplniť jednoduchý compare-before-write pattern:

```python
from pathlib import Path
from socfw.build.manifest import GeneratedArtifact
from socfw.emit.renderer import Renderer


class RtlEmitter:
    def __init__(self, templates_dir: str) -> None:
        self.renderer = Renderer(templates_dir)

    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "rtl" / "soc_top.sv"
        content = self.renderer.render("soc_top.sv.j2", module=ir)

        old = out.read_text(encoding="utf-8") if out.exists() else None
        if old != content:
            self.renderer.write_text(out, content, encoding="utf-8")

        return [GeneratedArtifact(family="rtl", path=str(out), generator=self.__class__.__name__)]
```

Toto síce nie je plný cache manifest hit/miss, ale je to veľmi rozumný V1 optimization.

Rovnaké pre:

* timing
* software
* docs
* reports

---

# 15. Cache reason reporting

Veľmi dôležitá UX vec: používateľ má vedieť, prečo sa niečo rebuildlo.

Odporúčam do reportu alebo CLI doplniť jednoduché hlášky typu:

```text
[cache] firmware_build: hit
[cache] rtl_emit: miss (IR changed)
[cache] reports: miss (diagnostics changed)
```

---

## nový `socfw/reports/cache_formatter.py`

```python
from __future__ import annotations


class CacheFormatter:
    def format_stage(self, name: str, hit: bool, note: str = "") -> str:
        state = "hit" if hit else "miss"
        if note:
            return f"[cache] {name}: {state} ({note})"
        return f"[cache] {name}: {state}"
```

V ďalšom kroku môžeš tieto správy uložiť aj do `BuildResult`.

---

# 16. Deterministic rebuild policy

Toto je veľmi dôležité pravidlo. Odporúčam ho explicitne zdokumentovať.

## policy

* validation: always run
* load/elaboration/IR: recompute unless explicit object-cache layer exists
* emit: skip write if content unchanged
* firmware: cache by fingerprint
* reports: skip write if content unchanged
* simulation: no cache, prepare from current outputs

Toto je rozumné, vysvetliteľné a bezpečné.

---

# 17. Čomu by som sa zatiaľ vyhol

Na začiatok by som nerobil:

* partial IR object deserialization cache
* cross-build shared cache
* filesystem mtimes-only cache
* deep graph dependency invalidation engine

To je zbytočne skoro.

Najprv urob:

* fingerprints
* content-based no-op emit
* firmware cache
* manifest

To dá najväčší pomer value/complexity.

---

# 18. Integration test pre cache

## `tests/integration/test_firmware_cache.py`

```python
import shutil
import pytest
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow


@pytest.mark.skipif(
    shutil.which("riscv32-unknown-elf-gcc") is None,
    reason="RISC-V toolchain not installed",
)
def test_firmware_cache_reuses_outputs(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)

    first = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))
    assert first.ok

    fw_hex = out_dir / "fw" / "firmware.hex"
    assert fw_hex.exists()
    mtime1 = fw_hex.stat().st_mtime

    second = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))
    assert second.ok
    mtime2 = fw_hex.stat().st_mtime

    assert mtime2 == mtime1
```

Toto je veľmi pekný test pre prvú cache vrstvu.

---

# 19. Čo týmto získaš

Po tomto kroku budeš mať:

* predvídateľný cache model
* menej rebuildov
* rýchlejší firmware-aware flow
* stabilnejší daily workflow
* lepšie explain/debug informácie o buildu

To je veľmi praktický upgrade.

---

# 20. Môj odporúčaný ďalší krok

Teraz sú podľa mňa najlepšie tri smery:

### A

**vendor IP import cleanup**

* Quartus/QIP artifacts
* generated IP normalization
* shared catalog hygiene

### B

**editor/dev tooling**

* VS Code schema integration
* project scaffolding
* `socfw init`

### C

**full build state reporting**

* cache hits/misses in report
* stage timings
* build provenance

Môj praktický odporúčaný ďalší krok je:

👉 **C — full build state reporting + stage timings + provenance**

Lebo to prirodzene nadväzuje na cache a ešte viac zlepší dôveryhodnosť a použiteľnosť buildu.

Ak chceš, ďalšia správa môže byť presne:
**build provenance/reporting v2: stage timings, cache hit/miss summary, input fingerprints, generated artifact traceability**
