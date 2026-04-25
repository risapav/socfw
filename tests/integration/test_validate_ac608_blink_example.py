from socfw.config.system_loader import SystemLoader


def test_validate_ac608_blink_example():
    result = SystemLoader().load("examples/ac608_blink/project.yaml")
    errors = [d for d in result.diagnostics if d.severity.value == "error"]
    assert not errors, [f"{d.code}: {d.message}" for d in errors]
    assert result.value is not None
    assert result.value.project.name == "ac608_blink"
