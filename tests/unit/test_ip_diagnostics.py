from pydantic import BaseModel, ValidationError

from socfw.config.schema_errors import ip_schema_error


class DemoSchema(BaseModel):
    ip: dict


def test_ip_schema_error_mentions_clocking_outputs_and_ports():
    d = None
    try:
        DemoSchema.model_validate({})
    except ValidationError as exc:
        d = ip_schema_error(exc, file="bad.ip.yaml")

    assert d is not None
    assert d.code == "IP100"
    assert any("clocking.outputs" in h for h in d.hints)
    assert any("ports:" in h for h in d.hints)
    assert any("socfw explain-schema ip" in h for h in d.hints)
