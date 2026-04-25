from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


FIXTURE = "tests/golden/fixtures/vendor_sdram_soc/project.yaml"


def test_legacy_deprecation_warning_is_printed(tmp_path, capsys):
    out_dir = tmp_path / "out"
    out_dir.mkdir()

    FullBuildPipeline().run(
        BuildRequest(
            project_file=FIXTURE,
            out_dir=str(out_dir),
            legacy_backend=True,
        )
    )

    captured = capsys.readouterr()
    assert "DEPRECATED" in captured.out
    assert "socfw build" in captured.out


def test_default_build_no_deprecation_warning(tmp_path, capsys):
    out_dir = tmp_path / "out"
    out_dir.mkdir()

    result = FullBuildPipeline().run(
        BuildRequest(
            project_file=FIXTURE,
            out_dir=str(out_dir),
        )
    )

    captured = capsys.readouterr()
    assert "DEPRECATED" not in captured.out
