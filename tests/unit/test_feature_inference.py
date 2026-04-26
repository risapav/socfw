"""Test automatic feature inference from board bind targets."""
from socfw.board.feature_expansion import expand_features_for_project
from socfw.config.board_loader import BoardLoader
from socfw.model.project import ProjectModel, ModuleInstance, PortBinding


BOARD_FILE = "packs/builtin/boards/ac608_ep4ce15/board.yaml"


def _board():
    return BoardLoader().load(BOARD_FILE).value


def _project_no_features(bind_targets: list[str]) -> ProjectModel:
    bindings = [PortBinding(port_name=f"p{i}", target=t) for i, t in enumerate(bind_targets)]
    mod = ModuleInstance(instance="inst0", type_name="dummy", port_bindings=bindings)
    project = ProjectModel(name="test", mode="standalone", board_ref="ac608_ep4ce15", modules=[mod])
    project.inferred_feature_refs = bind_targets
    return project


def test_infer_from_single_bind():
    project = _project_no_features(["board:onboard.leds"])
    result = expand_features_for_project(_board(), project)
    assert "onboard.leds" in result.paths


def test_infer_nothing_when_no_binds():
    project = _project_no_features([])
    result = expand_features_for_project(_board(), project)
    assert len(result) == 0


def test_explicit_features_override_inferred():
    project = _project_no_features(["board:onboard.buttons"])
    project.feature_refs = ["board:onboard.leds"]
    project.inferred_feature_refs = []
    result = expand_features_for_project(_board(), project)
    assert "onboard.leds" in result.paths
    assert "onboard.buttons" not in result.paths
