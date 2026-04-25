from socfw.config.system_loader import SystemLoader
from socfw.core.diagnostics import Severity


def test_validate_ac608_sdram_example_loads():
    result = SystemLoader().load("examples/ac608_sdram/project.yaml")
    fatal = [d for d in result.diagnostics if d.severity == Severity.ERROR and d.code not in {"IP001", "IP102"}]
    assert not fatal, [f"{d.code}: {d.message}" for d in fatal]
    assert result.value is not None
    assert result.value.project.name == "ac608_sdram"
