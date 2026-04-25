from socfw.config.formatter import ConfigFormatter


def test_format_project_alias_to_canonical(tmp_path):
    p = tmp_path / "project.yaml"
    p.write_text(
        """
version: 2
kind: project
project:
  name: demo
  mode: standalone
  board: qmtech_ep4ce55
timing:
  config: timing_config.yaml
modules:
  blink_test:
    module: blink_test
""",
        encoding="utf-8",
    )

    res = ConfigFormatter().format_file(str(p), write=False)

    assert res.ok
    assert "file: timing_config.yaml" in res.value
    assert "instance: blink_test" in res.value
    assert "type: blink_test" in res.value


def test_format_timing_top_level_to_canonical(tmp_path):
    p = tmp_path / "timing_config.yaml"
    p.write_text(
        """
version: 2
kind: timing
clocks: []
false_paths: []
""",
        encoding="utf-8",
    )

    res = ConfigFormatter().format_file(str(p), write=False)

    assert res.ok
    assert "timing:" in res.value
    assert "clocks: []" in res.value
    assert "false_paths: []" in res.value


def test_format_no_write_does_not_modify_file(tmp_path):
    p = tmp_path / "project.yaml"
    original = "kind: project\nproject:\n  name: x\n"
    p.write_text(original, encoding="utf-8")

    ConfigFormatter().format_file(str(p), write=False)

    assert p.read_text(encoding="utf-8") == original


def test_format_unknown_type_returns_error(tmp_path):
    p = tmp_path / "unknown.yaml"
    p.write_text("some_unknown_key: value\n", encoding="utf-8")

    res = ConfigFormatter().format_file(str(p), write=False)

    assert not res.ok
    assert any(d.code == "FMT001" for d in res.diagnostics)
