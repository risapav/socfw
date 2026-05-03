from unittest.mock import MagicMock

from socfw.core.diagnostics import Severity
from socfw.validate.rules.ip_rules import MissingClockPortBindingRule


def _make_system(port_names: list[str], bound_ports: dict[str, str]):
    """Build a minimal system mock with one module that has the given clock port bindings."""
    from socfw.model.project import ClockBinding

    ip_clocking = MagicMock()
    ip_clocking.primary_input_port = port_names[0] if port_names else None
    ip_clocking.additional_input_ports = tuple(port_names[1:])

    ip = MagicMock()
    ip.clocking = ip_clocking

    mod = MagicMock()
    mod.instance = "dut0"
    mod.type_name = "dut_type"
    mod.clocks = [ClockBinding(port_name=p, domain=d) for p, d in bound_ports.items()]

    system = MagicMock()
    system.project.modules = [mod]
    system.project.primary_clock_domain = "sys_clk"
    system.ip_catalog.get.return_value = ip
    system.timing = None
    system.sources.project_file = "project.yaml"

    return system


def test_all_ports_bound_no_error():
    system = _make_system(
        port_names=["clk_i", "clk_x_i"],
        bound_ports={"clk_i": "clk_pixel", "clk_x_i": "clk_pixel5x"},
    )
    diags = MissingClockPortBindingRule().validate(system)
    assert diags == []


def test_additional_port_unbound_raises_error():
    system = _make_system(
        port_names=["clk_i", "clk_x_i"],
        bound_ports={"clk_i": "clk_pixel"},
    )
    diags = MissingClockPortBindingRule().validate(system)
    assert len(diags) == 1
    assert diags[0].code == "IP003"
    assert diags[0].severity == Severity.ERROR
    assert "clk_x_i" in diags[0].message
    assert "dut0" in diags[0].message


def test_primary_port_unbound_raises_error():
    system = _make_system(
        port_names=["clk_i"],
        bound_ports={},
    )
    diags = MissingClockPortBindingRule().validate(system)
    assert len(diags) == 1
    assert diags[0].code == "IP003"
    assert "clk_i" in diags[0].message


def test_no_clocking_metadata_skipped():
    mod = MagicMock()
    mod.type_name = "simple_mod"

    ip = MagicMock()
    ip.clocking = None

    system = MagicMock()
    system.project.modules = [mod]
    system.ip_catalog.get.return_value = ip

    diags = MissingClockPortBindingRule().validate(system)
    assert diags == []


def test_hint_mentions_available_domains():
    system = _make_system(
        port_names=["clk_i", "clk_x_i"],
        bound_ports={"clk_i": "sys_clk"},
    )
    diags = MissingClockPortBindingRule().validate(system)
    assert any("sys_clk" in h for h in diags[0].hints)
