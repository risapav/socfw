"""Unit tests for CLK010/CLK011 CDC validation rules."""
from unittest.mock import MagicMock

from socfw.core.diagnostics import Severity
from socfw.model.project import ClockBinding, GeneratedClockRequest
from socfw.validate.rules.project_rules import (
    GeneratedClockMissingResetSyncRule,
    SyncFromUnknownDomainRule,
)


def _make_system(gen_clocks, modules_clocked_by=None):
    """Build a minimal system mock."""
    system = MagicMock()
    system.project.primary_clock_domain = "sys_clk"
    system.project.generated_clocks = gen_clocks

    if modules_clocked_by is None:
        modules_clocked_by = []

    mods = []
    for domains in modules_clocked_by:
        mod = MagicMock()
        mod.clocks = [ClockBinding(port_name="clk", domain=d) for d in domains]
        mods.append(mod)
    system.project.modules = mods

    return system


# ── SyncFromUnknownDomainRule (CLK010) ──────────────────────────────────────

def test_clk010_no_error_when_sync_from_is_primary():
    gen = GeneratedClockRequest(
        domain="clk_fast", source_instance="pll", source_output="c0",
        sync_from="sys_clk",
    )
    system = _make_system([gen])
    diags = SyncFromUnknownDomainRule().validate(system)
    assert diags == []


def test_clk010_no_error_when_sync_from_is_sibling_domain():
    gen_a = GeneratedClockRequest(domain="clk_a", source_instance="pll", source_output="c0")
    gen_b = GeneratedClockRequest(
        domain="clk_b", source_instance="pll", source_output="c1",
        sync_from="clk_a",
    )
    system = _make_system([gen_a, gen_b])
    diags = SyncFromUnknownDomainRule().validate(system)
    assert diags == []


def test_clk010_error_when_sync_from_unknown():
    gen = GeneratedClockRequest(
        domain="clk_fast", source_instance="pll", source_output="c0",
        sync_from="typo_clk",
    )
    system = _make_system([gen])
    diags = SyncFromUnknownDomainRule().validate(system)
    assert len(diags) == 1
    assert diags[0].code == "CLK010"
    assert diags[0].severity == Severity.ERROR
    assert "typo_clk" in diags[0].message
    assert "clk_fast" in diags[0].message


def test_clk010_no_warning_when_sync_from_absent():
    gen = GeneratedClockRequest(domain="clk_fast", source_instance="pll", source_output="c0")
    system = _make_system([gen])
    diags = SyncFromUnknownDomainRule().validate(system)
    assert diags == []


# ── GeneratedClockMissingResetSyncRule (CLK011) ────────────────────────────

def test_clk011_no_warning_when_sync_from_declared():
    gen = GeneratedClockRequest(
        domain="clk_fast", source_instance="pll", source_output="c0",
        sync_from="sys_clk", sync_stages=2,
    )
    system = _make_system([gen], modules_clocked_by=[["sys_clk"], ["clk_fast"]])
    diags = GeneratedClockMissingResetSyncRule().validate(system)
    assert diags == []


def test_clk011_no_warning_when_no_reset_true():
    gen = GeneratedClockRequest(
        domain="clk_fast", source_instance="pll", source_output="c0",
        no_reset=True,
    )
    system = _make_system([gen], modules_clocked_by=[["sys_clk"], ["clk_fast"]])
    diags = GeneratedClockMissingResetSyncRule().validate(system)
    assert diags == []


def test_clk011_warning_when_cdc_exists_but_no_sync():
    gen = GeneratedClockRequest(domain="clk_fast", source_instance="pll", source_output="c0")
    system = _make_system([gen], modules_clocked_by=[["sys_clk"], ["clk_fast"]])
    diags = GeneratedClockMissingResetSyncRule().validate(system)
    assert len(diags) == 1
    assert diags[0].code == "CLK011"
    assert diags[0].severity == Severity.WARNING
    assert "clk_fast" in diags[0].message
    assert "sys_clk" in diags[0].message


def test_clk011_no_warning_when_generated_domain_unused():
    gen = GeneratedClockRequest(domain="clk_fast", source_instance="pll", source_output="c0")
    # Only primary domain used, no module on clk_fast
    system = _make_system([gen], modules_clocked_by=[["sys_clk"]])
    diags = GeneratedClockMissingResetSyncRule().validate(system)
    assert diags == []


def test_clk011_no_warning_when_primary_domain_unused():
    gen = GeneratedClockRequest(domain="clk_fast", source_instance="pll", source_output="c0")
    # Only generated domain used, no module on sys_clk
    system = _make_system([gen], modules_clocked_by=[["clk_fast"]])
    diags = GeneratedClockMissingResetSyncRule().validate(system)
    assert diags == []
