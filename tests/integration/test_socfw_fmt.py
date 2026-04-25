from socfw.config.formatter import ConfigFormatter


def test_fmt_write_rewrites_project_file(tmp_path):
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

    res = ConfigFormatter().format_file(str(p), write=True)
    assert res.ok

    text = p.read_text(encoding="utf-8")
    assert "config:" not in text
    assert "file: timing_config.yaml" in text
    assert "- instance: blink_test" in text
