from socfw.config.timing_loader import TimingLoader


def test_timing_loader_empty_doc(tmp_path):
    timing_file = tmp_path / "timing.yaml"
    timing_file.write_text(
        """
version: 2
kind: timing

timing:
  clocks: []
  generated_clocks: []
  clock_groups: []
  false_paths: []
""",
        encoding="utf-8",
    )

    res = TimingLoader().load(str(timing_file))
    assert res.ok, [str(d) for d in res.diagnostics]
    assert res.value is not None


def test_timing_loader_missing_file_returns_error(tmp_path):
    res = TimingLoader().load(str(tmp_path / "nonexistent.yaml"))
    assert not res.ok
    assert any(d.severity.value == "error" for d in res.diagnostics)
