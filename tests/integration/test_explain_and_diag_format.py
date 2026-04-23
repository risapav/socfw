from socfw.reports.diagnostic_formatter import DiagnosticFormatter
from socfw.core.diag_builders import err


def test_diagnostic_formatter_renders_hints_and_fixes():
    d = err(
        "BRG001",
        "No bridge registered",
        "project.modules.bus",
        file="project.yaml",
        path="modules[0].bus",
        hints=["Register a matching bridge."],
        category="bridge",
    )

    text = DiagnosticFormatter().format_text(d)
    assert "BRG001" in text
    assert "project.yaml" in text
    assert "Register a matching bridge." in text


def test_diagnostic_formatter_detail_and_related():
    from socfw.core.diagnostics import RelatedDiagnosticRef, SuggestedFix
    d = err(
        "BUS003",
        "Address overlap between 'ram' and 'gpio'",
        "project.modules.bus",
        file="project.yaml",
        path="modules[0].bus",
        category="bus",
        detail="ram=0x00000000-0x00007FFF, gpio=0x00004000-0x00004FFF",
        fixes=[SuggestedFix(message="Move gpio", path="modules[0].bus")],
        related=[RelatedDiagnosticRef(code="BUS003", message="ram region", subject="ram")],
    )
    text = DiagnosticFormatter().format_text(d)
    assert "detail:" in text
    assert "0x00000000" in text
    assert "suggested fixes:" in text
    assert "related:" in text
