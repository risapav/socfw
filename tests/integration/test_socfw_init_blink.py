from socfw.build.full_pipeline import FullBuildPipeline
from socfw.scaffold.init_project import ProjectInitializer


def test_socfw_init_creates_valid_blink_project(tmp_path):
    target = tmp_path / "demo"

    written = ProjectInitializer().init_blink(
        target_dir=str(target),
        name="demo",
        board="qmtech_ep4ce55",
    )

    assert (target / "project.yaml").exists()
    assert (target / "ip" / "blink_test.ip.yaml").exists()
    assert (target / "rtl" / "blink_test.sv").exists()
    assert len(written) == 3

    result = FullBuildPipeline().validate(str(target / "project.yaml"))
    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
