from socfw.build.full_pipeline import FullBuildPipeline
from socfw.scaffold.init_project import ProjectInitializer


def test_init_all_templates_validate(tmp_path):
    for template in ["blink", "pll", "sdram"]:
        target = tmp_path / template
        ProjectInitializer().init(
            template=template,
            target_dir=str(target),
            name=f"demo_{template}",
            board="qmtech_ep4ce55",
        )

        result = FullBuildPipeline().validate(str(target / "project.yaml"))
        assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
