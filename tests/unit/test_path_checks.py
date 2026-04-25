from pathlib import Path

from socfw.config.path_checks import check_existing_dir, check_existing_file, resolve_relative


def test_resolve_relative_path(tmp_path):
    owner = tmp_path / "project.yaml"
    owner.write_text("", encoding="utf-8")

    resolved = resolve_relative(str(owner), "timing_config.yaml")
    assert resolved == str((tmp_path / "timing_config.yaml").resolve())


def test_check_existing_file_reports_missing(tmp_path):
    owner = tmp_path / "project.yaml"
    owner.write_text("", encoding="utf-8")

    resolved, diags = check_existing_file(
        code="PATH_TEST",
        owner_file=str(owner),
        ref_path="missing.yaml",
        subject="test",
        hint="fix it",
    )

    assert resolved.endswith("missing.yaml")
    assert len(diags) == 1
    assert diags[0].code == "PATH_TEST"


def test_check_existing_dir_ok(tmp_path):
    owner = tmp_path / "project.yaml"
    owner.write_text("", encoding="utf-8")
    d = tmp_path / "ip"
    d.mkdir()

    _, diags = check_existing_dir(
        code="PATH_TEST",
        owner_file=str(owner),
        ref_path="ip",
        subject="test",
        hint="fix it",
    )

    assert diags == []
