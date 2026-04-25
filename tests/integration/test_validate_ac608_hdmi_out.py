from socfw.config.system_loader import SystemLoader
from socfw.core.diagnostics import Severity


def test_validate_ac608_hdmi_out_loads():
    result = SystemLoader().load("examples/ac608_hdmi_out/project.yaml")
    errors = [d for d in result.diagnostics if d.severity == Severity.ERROR]
    assert not errors, [f"{d.code}: {d.message}" for d in errors]
    assert result.value is not None
    assert result.value.project.name == "ac608_hdmi_out"
