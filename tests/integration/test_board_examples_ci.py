"""Board example validation CI lane — commit 99."""
from pathlib import Path

import pytest

from socfw.build.full_pipeline import FullBuildPipeline
from socfw.build.context import BuildRequest
from socfw.core.diagnostics import Severity


def _validate(project_file: str):
    from socfw.config.system_loader import SystemLoader
    result = SystemLoader().load(project_file)
    errors = [d for d in result.diagnostics if d.severity == Severity.ERROR]
    return result, errors


def test_ac608_blink_validates():
    _, errors = _validate("examples/ac608_blink/project.yaml")
    assert not errors, [f"{e.code}: {e.message}" for e in errors]


def test_ac608_hdmi_out_validates():
    _, errors = _validate("examples/ac608_hdmi_out/project.yaml")
    assert not errors, [f"{e.code}: {e.message}" for e in errors]


def test_ac608_sdram_example_has_only_expected_errors():
    _, errors = _validate("examples/ac608_sdram/project.yaml")
    # sdram_ctrl IP not yet in catalog — only PRJ002 expected
    unexpected = [e for e in errors if e.code not in {"PRJ002"}]
    assert not unexpected, [f"{e.code}: {e.message}" for e in unexpected]
