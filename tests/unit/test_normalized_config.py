from socfw.config.normalizers.project import normalize_project_document
from socfw.config.normalizers.timing import normalize_timing_document


def test_project_normalizer_reports_aliases():
    norm = normalize_project_document(
        {"timing": {"config": "timing_config.yaml"}},
        file="project.yaml",
    )

    assert norm.data["timing"]["file"] == "timing_config.yaml"
    assert norm.aliases_used
    assert any("timing.config" in a for a in norm.aliases_used)


def test_timing_normalizer_reports_aliases():
    norm = normalize_timing_document(
        {
            "version": 2,
            "kind": "timing",
            "clocks": [],
        },
        file="timing_config.yaml",
    )

    assert "timing" in norm.data
    assert norm.aliases_used


def test_project_normalizer_no_aliases():
    norm = normalize_project_document(
        {"project": {"name": "clean"}},
        file="project.yaml",
    )
    assert norm.aliases_used == []
    assert norm.diagnostics == []


def test_timing_normalizer_no_aliases():
    norm = normalize_timing_document(
        {"timing": {"clocks": []}},
        file="timing_config.yaml",
    )
    assert norm.aliases_used == []
    assert norm.diagnostics == []
