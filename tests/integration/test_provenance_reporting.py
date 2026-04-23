from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline
from socfw.reports.build_summary_formatter import BuildSummaryFormatter
from socfw.reports.cache_summary import CacheSummary


def test_build_ok_no_provenance_required(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/blink_test_01/project.yaml"
    out_dir = tmp_path / "out"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok


def test_build_summary_formatter_basic():
    from socfw.build.provenance_model import BuildProvenance, StageExecutionRecord

    prov = BuildProvenance()
    prov.stages.append(StageExecutionRecord(name="pass1_build", status="miss", duration_ms=42.5, note="initial"))
    prov.stages.append(StageExecutionRecord(name="firmware_build", status="hit", duration_ms=0.0))

    text = BuildSummaryFormatter().format_text(prov)
    assert "pass1_build" in text
    assert "miss" in text
    assert "firmware_build" in text
    assert "hit" in text


def test_cache_summary():
    from socfw.build.provenance_model import BuildProvenance, StageExecutionRecord

    prov = BuildProvenance()
    prov.stages.append(StageExecutionRecord(name="a", status="hit", duration_ms=0.0))
    prov.stages.append(StageExecutionRecord(name="b", status="miss", duration_ms=1.0))
    prov.stages.append(StageExecutionRecord(name="c", status="miss", duration_ms=2.0))

    summary = CacheSummary().summarize(prov)
    assert summary["hit"] == 1
    assert summary["miss"] == 2
