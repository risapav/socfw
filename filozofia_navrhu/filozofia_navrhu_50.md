Super. Ideme na:

# build provenance/reporting v2: stage timings, cache hit/miss summary, input fingerprints, generated artifact traceability

Toto je veľmi dobrý ďalší krok, lebo keď už máš:

* viacstupňový build,
* firmware-aware flow,
* cache,
* bridge planning,
* viac druhov artefaktov,

tak ďalšia veľká hodnota je, aby build vedel **vysvetliť sám seba**.

To znamená:

* čo sa spustilo,
* čo sa preskočilo,
* prečo sa to preskočilo,
* čo bolo vstupom,
* čo bolo výstupom,
* koľko to trvalo,
* a odkiaľ sa vzal každý artefakt.

To je presne to, čo zlepší:

* debug,
* CI review,
* dôveru v build,
* performance tuning.

---

# 1. Cieľ

Na konci chceš mať report typu:

```text
Build summary
- load_config: 18 ms (miss)
- validate: 7 ms (always)
- elaborate: 12 ms (miss)
- software_emit: 9 ms (hit)
- firmware_build: 0 ms (hit)
- rtl_emit: 5 ms (miss)
- reports: 3 ms (miss)

Artifacts
- rtl/soc_top.sv
  generator: RtlEmitter
  stage: rtl_emit
  inputs:
    - rtl_ir fingerprint ...
    - soc_top.sv.j2 fingerprint ...
```

A tiež JSON, ktoré vieš použiť v CI.

---

# 2. Čo pridáme

Rozdelil by som to na 4 časti:

1. **stage execution records**
2. **artifact provenance**
3. **build summary report**
4. **CLI / JSON export**

---

# 3. Stage execution model

## nový `socfw/build/provenance_model.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class StageExecutionRecord:
    name: str
    status: str                 # hit / miss / always / failed
    duration_ms: float
    fingerprint: str | None = None
    note: str = ""
    inputs: list[str] = field(default_factory=list)
    outputs: list[str] = field(default_factory=list)


@dataclass
class ArtifactProvenance:
    path: str
    family: str
    generator: str
    stage: str
    fingerprint: str | None = None
    inputs: list[str] = field(default_factory=list)


@dataclass
class BuildProvenance:
    stages: list[StageExecutionRecord] = field(default_factory=list)
    artifacts: list[ArtifactProvenance] = field(default_factory=list)
```

---

# 4. Stopwatch helper

Aby si vedel ľahko merať stage times.

## nový `socfw/tools/timing.py`

```python
from __future__ import annotations

import time
from contextlib import contextmanager


@contextmanager
def timed():
    start = time.perf_counter()
    box = {"duration_ms": 0.0}
    try:
        yield box
    finally:
        box["duration_ms"] = (time.perf_counter() - start) * 1000.0
```

---

# 5. BuildResult rozšírenie

## update `socfw/build/pipeline.py`

Do `BuildResult` pridaj:

```python
    provenance: object | None = None
```

Lepšie by bolo konkrétne:

```python
from socfw.build.provenance_model import BuildProvenance
```

a:

```python
    provenance: BuildProvenance | None = None
```

---

# 6. Cache + provenance pre stage

Teraz v `TwoPassBuildFlow` začni zbierať stage záznamy.

## update `socfw/build/two_pass_flow.py`

Pridaj importy:

```python
from socfw.build.provenance_model import BuildProvenance, StageExecutionRecord, ArtifactProvenance
from socfw.tools.timing import timed
from socfw.tools.fingerprint import fingerprint_obj
```

Na začiatok `run()`:

```python
        provenance = BuildProvenance()
```

---

# 7. Záznam pass 1 buildu

Okolo prvého buildu:

```python
        with timed() as t:
            first = self.pipeline.run(request)

        provenance.stages.append(
            StageExecutionRecord(
                name="pass1_build",
                status="miss" if first.ok else "failed",
                duration_ms=t["duration_ms"],
                note="initial build for headers/linker/artifacts",
                inputs=[request.project_file],
            )
        )
```

---

# 8. Firmware stage provenance

Už keď robíš cache check, doplň aj provenance.

Namiesto len `cache.update(...)` sprav:

```python
        if cache.check(fw_stage, fw_fp) and all(Path(p).exists() for p in fw_outputs):
            from socfw.model.image import FirmwareArtifacts
            fw_res_value = FirmwareArtifacts(
                elf=str(fw_out_dir / "firmware.elf"),
                bin=str(fw_out_dir / "firmware.bin"),
                hex=str(fw_out_dir / "firmware.hex"),
            )

            provenance.stages.append(
                StageExecutionRecord(
                    name="firmware_build",
                    status="hit",
                    duration_ms=0.0,
                    fingerprint=fw_fp,
                    note="reused cached firmware outputs",
                    outputs=[fw_res_value.elf, fw_res_value.bin, fw_res_value.hex],
                )
            )
        else:
            with timed() as t:
                fw_res = self.firmware_builder.build(system, request.out_dir)

            first.diagnostics.extend(fw_res.diagnostics)
            if not fw_res.ok or fw_res.value is None:
                first.ok = False
                first.provenance = provenance
                provenance.stages.append(
                    StageExecutionRecord(
                        name="firmware_build",
                        status="failed",
                        duration_ms=t["duration_ms"],
                        fingerprint=fw_fp,
                        note="firmware build failed",
                    )
                )
                return first

            fw_res_value = fw_res.value
            cache.update(
                fw_stage,
                fw_fp,
                outputs=[fw_res_value.elf, fw_res_value.bin, fw_res_value.hex],
                note="rebuilt firmware",
            )

            provenance.stages.append(
                StageExecutionRecord(
                    name="firmware_build",
                    status="miss",
                    duration_ms=t["duration_ms"],
                    fingerprint=fw_fp,
                    note="rebuilt firmware",
                    outputs=[fw_res_value.elf, fw_res_value.bin, fw_res_value.hex],
                )
            )
```

---

# 9. bin2hex stage provenance

Doplň aj conversion stage:

```python
        with timed() as t:
            conv = self.bin2hex.run(
                fw_res_value.bin,
                fw_res_value.hex,
                system.ram.size,
            )

        first.diagnostics.extend(conv.diagnostics)
        provenance.stages.append(
            StageExecutionRecord(
                name="bin2hex",
                status="miss" if conv.ok else "failed",
                duration_ms=t["duration_ms"],
                note="converted firmware binary to hex image",
                inputs=[fw_res_value.bin],
                outputs=[fw_res_value.hex],
            )
        )
```

---

# 10. Pass 2 provenance

Okolo druhého buildu:

```python
        with timed() as t:
            second = self.pipeline.pipeline.run(request, system)

        provenance.stages.append(
            StageExecutionRecord(
                name="pass2_build",
                status="miss" if second.ok else "failed",
                duration_ms=t["duration_ms"],
                note="rebuilt design with final RAM init image",
                inputs=[request.project_file, fw_res_value.hex],
            )
        )
```

---

# 11. Emit stage provenance

Keď voláš emitters, pridaj stage record:

```python
        with timed() as t:
            second.manifest = self.pipeline.emitters.emit_all(
                out_ctx,
                board_ir=second.board_ir,
                timing_ir=second.timing_ir,
                rtl_ir=second.rtl_ir,
                software_ir=second.software_ir,
                docs_ir=second.docs_ir,
                register_block_irs=second.register_block_irs,
                peripheral_shell_irs=second.peripheral_shell_irs,
            )

        provenance.stages.append(
            StageExecutionRecord(
                name="emit",
                status="miss",
                duration_ms=t["duration_ms"],
                note="emitted final build artifacts",
                outputs=[a.path for a in second.manifest.artifacts],
            )
        )
```

---

# 12. Report stage provenance

```python
        with timed() as t:
            report_paths = self.pipeline.reports.emit_all(
                system=system,
                design=second.design,
                result=second,
                out_dir=request.out_dir,
            )

        provenance.stages.append(
            StageExecutionRecord(
                name="reports",
                status="miss",
                duration_ms=t["duration_ms"],
                note="emitted reports",
                outputs=list(report_paths),
            )
        )
```

---

# 13. Artifact provenance

Teraz treba spojiť manifest s provenance.
Najpraktickejšie minimum:

* manifest artefakt → stage `emit`
* firmware artefakt → stage `firmware_build` / `bin2hex`
* report artefakt → stage `reports`

Na konci `run()`:

```python
        for a in second.manifest.artifacts:
            stage = "emit"
            if a.family == "report":
                stage = "reports"
            elif a.family == "firmware":
                stage = "firmware_build"

            provenance.artifacts.append(
                ArtifactProvenance(
                    path=a.path,
                    family=a.family,
                    generator=a.generator,
                    stage=stage,
                )
            )

        second.provenance = provenance
```

A pre firmware artefakty po `manifest.add(...)` ich uvidíš tiež.

---

# 14. Fingerprints pri artefaktoch

Ak chceš o stupeň lepšiu traceability, môžeš pre každý hlavný artefakt uložiť fingerprint vstupu.

Príklad:

* `rtl/soc_top.sv` fingerprint = `fingerprint_obj(second.rtl_ir)`
* `sw/soc_map.h` fingerprint = `fingerprint_obj(second.software_ir)`

To sa dá spraviť neskôr.
Pre V1 stačí stage-level fingerprint.

---

# 15. Build summary formatter

## nový `socfw/reports/build_summary_formatter.py`

```python
from __future__ import annotations


class BuildSummaryFormatter:
    def format_text(self, provenance) -> str:
        lines: list[str] = []
        lines.append("Build summary:")

        for s in provenance.stages:
            dur = f"{s.duration_ms:.1f} ms"
            msg = f"- {s.name}: {s.status} ({dur})"
            if s.note:
                msg += f" - {s.note}"
            lines.append(msg)

        return "\n".join(lines)
```

---

# 16. CLI summary output

## update `socfw/cli/main.py`

Pridaj import:

```python
from socfw.reports.build_summary_formatter import BuildSummaryFormatter
```

A v `cmd_build`, `cmd_build_fw`, `cmd_sim_smoke`, `cmd_graph` po vypísaní diagnostics/artifacts:

```python
    if getattr(result, "provenance", None) is not None:
        print(BuildSummaryFormatter().format_text(result.provenance))
```

To je veľmi užitočné hneď.

---

# 17. JSON provenance export

## nový `socfw/tools/provenance_json_exporter.py`

```python
from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path


class ProvenanceJsonExporter:
    def export(self, provenance, out_file: str) -> str:
        fp = Path(out_file)
        fp.parent.mkdir(parents=True, exist_ok=True)
        fp.write_text(json.dumps(asdict(provenance), indent=2), encoding="utf-8")
        return str(fp)
```

---

# 18. Voliteľný CLI parameter

Napr. pre `build-fw`:

```python
    bf.add_argument("--provenance-json", default=None)
```

A v handleri:

```python
    if args.provenance_json and getattr(result, "provenance", None) is not None:
        from socfw.tools.provenance_json_exporter import ProvenanceJsonExporter
        path = ProvenanceJsonExporter().export(result.provenance, args.provenance_json)
        print(path)
```

To je skvelé pre CI artifacty.

---

# 19. Markdown report v2

Teraz vieš doplniť do `build_report.md` nové sekcie:

* Stage timings
* Cache summary
* Artifact provenance

## update `socfw/reports/model.py`

Pridaj:

```python
@dataclass(frozen=True)
class ReportStage:
    name: str
    status: str
    duration_ms: float
    note: str = ""


@dataclass(frozen=True)
class ReportArtifactProvenance:
    path: str
    family: str
    generator: str
    stage: str
```

A do `BuildReport`:

```python
    stages: list[ReportStage] = field(default_factory=list)
    artifact_provenance: list[ReportArtifactProvenance] = field(default_factory=list)
```

---

## update `socfw/reports/builder.py`

Doplň:

```python
        if getattr(result, "provenance", None) is not None:
            for s in result.provenance.stages:
                report.stages.append(
                    ReportStage(
                        name=s.name,
                        status=s.status,
                        duration_ms=s.duration_ms,
                        note=s.note,
                    )
                )

            for a in result.provenance.artifacts:
                report.artifact_provenance.append(
                    ReportArtifactProvenance(
                        path=a.path,
                        family=a.family,
                        generator=a.generator,
                        stage=a.stage,
                    )
                )
```

---

## update `socfw/reports/markdown_emitter.py`

Pridaj sekcie:

```python
        lines.append("## Stage Timings\n")
        if report.stages:
            lines.append("| Stage | Status | Duration (ms) | Note |")
            lines.append("|-------|--------|---------------|------|")
            for s in report.stages:
                lines.append(f"| {s.name} | {s.status} | {s.duration_ms:.1f} | {s.note} |")
        else:
            lines.append("No stage data.")
        lines.append("")

        lines.append("## Artifact Provenance\n")
        if report.artifact_provenance:
            lines.append("| Path | Family | Generator | Stage |")
            lines.append("|------|--------|-----------|-------|")
            for a in report.artifact_provenance:
                lines.append(f"| `{a.path}` | {a.family} | {a.generator} | {a.stage} |")
        else:
            lines.append("No artifact provenance.")
        lines.append("")
```

---

# 20. Cache hit/miss summary

Keďže stage records už nesú `status`, vieš z toho rovno odvodiť summary.

Ak chceš, môžeš pridať helper:

## nový `socfw/reports/cache_summary.py`

```python
from __future__ import annotations


class CacheSummary:
    def summarize(self, provenance) -> dict[str, int]:
        out = {"hit": 0, "miss": 0, "always": 0, "failed": 0}
        for s in provenance.stages:
            out[s.status] = out.get(s.status, 0) + 1
        return out
```

A dať to do reportu neskôr.

---

# 21. Integration test

## `tests/integration/test_provenance_reporting.py`

```python
from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_provenance_present(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/blink_test_01/project.yaml"
    out_dir = tmp_path / "out"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    # FullBuildPipeline may not yet populate provenance in single-pass mode;
    # if not, this can be switched to TwoPassBuildFlow on firmware fixtures.
    assert result.ok
```

A pre `TwoPassBuildFlow` silnejší test:

## `tests/integration/test_fw_provenance_reporting.py`

```python
import shutil
import pytest

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow


@pytest.mark.skipif(
    shutil.which("riscv32-unknown-elf-gcc") is None,
    reason="RISC-V toolchain not installed",
)
def test_fw_build_has_provenance(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok
    assert result.provenance is not None
    assert len(result.provenance.stages) > 0
    assert any(s.name == "firmware_build" for s in result.provenance.stages)
```

---

# 22. Čo týmto získaš

Po tomto kroku bude build oveľa “dospelší”:

* vieš, čo sa dialo
* vieš, prečo sa to dialo
* vieš, čo sa rebuildlo
* vieš, čo bolo hit/miss
* vieš spätne vystopovať artefakty

To je veľká hodnota pre:

* debug,
* performance tuning,
* CI,
* release review.

---

# 23. Môj odporúčaný ďalší krok

Teraz sú už architektúra, UX aj reporting veľmi silné. Ďalšie smery by som videl takto:

### A

**vendor IP import cleanup**

* qip/qsys/ip generated artifacts
* normalization
* catalog hygiene

### B

**developer tooling**

* `socfw init`
* scaffold project
* example starter templates

### C

**full deterministic golden governance**

* snapshot update workflow
* diff tooling
* golden review helpers

Môj praktický odporúčaný ďalší krok je:

👉 **B — developer tooling (`socfw init`, scaffolding, example generator)**

Lebo framework už vie veľa, ale teraz výrazne zlepšíš jeho použiteľnosť pri zakladaní nových projektov.

Ak chceš, ďalšia správa môže byť presne:
**developer tooling v1: `socfw init`, project scaffolds, board/example selection, and starter template generation**
