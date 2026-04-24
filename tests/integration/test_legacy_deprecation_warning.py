from legacy_build import build_legacy


def test_legacy_deprecation_warning_is_printed(tmp_path, capsys):
    out_dir = tmp_path / "out"
    out_dir.mkdir()

    build_legacy(
        project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
        out_dir=str(out_dir),
    )

    captured = capsys.readouterr()
    assert "DEPRECATED" in captured.out
    assert "socfw build" in captured.out
