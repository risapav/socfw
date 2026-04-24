from pydantic import BaseModel, ValidationError

from socfw.config.schema_errors import (
    board_schema_error,
    ip_schema_error,
    project_schema_error,
    timing_schema_error,
)


class DemoSchema(BaseModel):
    timing: dict


def _make_exc() -> ValidationError:
    try:
        DemoSchema.model_validate({})
    except ValidationError as exc:
        return exc
    raise AssertionError("expected ValidationError")


def test_timing_schema_error_has_actionable_hints():
    d = timing_schema_error(_make_exc(), file="timing_config.yaml")

    assert d.code == "TIM100"
    assert d.message == "Invalid timing YAML schema"
    assert any("wrap them under `timing:`" in h for h in d.hints)
    assert any("Raw schema detail" in h for h in d.hints)


def test_project_schema_error_mentions_modules_shape():
    d = project_schema_error(_make_exc(), file="project.yaml")

    assert d.code == "PRJ100"
    assert any("list-style modules" in h for h in d.hints)
    assert any("Raw schema detail" in h for h in d.hints)


def test_ip_schema_error():
    d = ip_schema_error(_make_exc(), file="ip.yaml")

    assert d.code == "IP100"
    assert d.message == "Invalid IP descriptor YAML schema"
    assert any("artifacts.synthesis" in h for h in d.hints)
    assert any("Raw schema detail" in h for h in d.hints)


def test_board_schema_error():
    d = board_schema_error(_make_exc(), file="board.yaml")

    assert d.code == "BRD100"
    assert d.message == "Invalid board YAML schema"
    assert any("system.clock" in h for h in d.hints)
    assert any("Raw schema detail" in h for h in d.hints)


def test_format_pydantic_issue_includes_field_path():
    from socfw.config.schema_errors import format_pydantic_issue
    detail = format_pydantic_issue(_make_exc())
    assert "timing" in detail
