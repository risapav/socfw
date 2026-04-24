from pathlib import Path


def test_ci_workflow_exists():
    p = Path(".github/workflows/ci.yml")
    assert p.exists()
    text = p.read_text(encoding="utf-8")
    assert "new-flow-required" in text
    assert "legacy-compatibility" in text
