from pathlib import Path

from socfw.config.system_loader import SystemLoader

FIXTURE = Path("tests/golden/fixtures/blink_test_01/project.yaml")


def test_validate_blink01():
    loaded = SystemLoader().load(str(FIXTURE))
    assert loaded.ok, [str(d) for d in loaded.diagnostics]
    assert loaded.value is not None
    assert loaded.value.project.name == "blink_test_01"
