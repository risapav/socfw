from socfw.build.full_pipeline import FullBuildPipeline
from socfw.diagnostics.doctor import DoctorReport


def test_doctor_report_contains_resolved_project_info():
    loaded = FullBuildPipeline().validate("tests/golden/fixtures/blink_converged/project.yaml")
    assert loaded.value is not None

    text = DoctorReport().build(loaded.value)

    assert "# socfw doctor" in text
    assert "blink_converged" in text
    assert "qmtech_ep4ce55" in text
    assert "## IP catalog" in text
    assert "blink_test" in text


def test_doctor_report_shows_board_clock():
    loaded = FullBuildPipeline().validate("tests/golden/fixtures/blink_converged/project.yaml")
    assert loaded.value is not None

    text = DoctorReport().build(loaded.value)

    assert "SYS_CLK" in text
    assert "Hz" in text


def test_doctor_report_shows_timing_none_when_absent():
    loaded = FullBuildPipeline().validate("tests/golden/fixtures/blink_converged/project.yaml")
    assert loaded.value is not None

    text = DoctorReport().build(loaded.value)

    assert "## Timing" in text
