"""Tests for the requires: dependency mechanism in IP descriptors."""
from unittest.mock import MagicMock

from socfw.core.diagnostics import Severity
from socfw.model.ip import IpArtifactBundle, IpDescriptor, IpOrigin, IpResetSemantics, IpClocking
from socfw.model.ip_graph import (
    collect_include_dirs,
    collect_simulation_files,
    collect_synthesis_files,
    transitive_requires,
)
from socfw.validate.rules.ip_rules import UnknownIpRequiresRule


def _ip(name: str, synthesis=(), simulation=(), include_dirs=(), requires=()):
    return IpDescriptor(
        name=name,
        module=name,
        category="custom",
        origin=IpOrigin(kind="source"),
        needs_bus=False,
        generate_registers=False,
        instantiate_directly=True,
        dependency_only=False,
        reset=IpResetSemantics(),
        clocking=IpClocking(),
        artifacts=IpArtifactBundle(
            synthesis=tuple(synthesis),
            simulation=tuple(simulation),
            include_dirs=tuple(include_dirs),
        ),
        requires=tuple(requires),
    )


def _catalog(*ips):
    return {ip.name: ip for ip in ips}


# ── collect_synthesis_files ─────────────────────────────────────────────────

def test_no_requires_returns_own_synthesis():
    ip = _ip("leaf", synthesis=["/leaf.sv"])
    assert collect_synthesis_files(ip, _catalog(ip)) == ["/leaf.sv"]


def test_requires_appends_dep_synthesis():
    dep = _ip("dep", synthesis=["/dep.sv"])
    top = _ip("top", synthesis=["/top.sv"], requires=["dep"])
    files = collect_synthesis_files(top, _catalog(top, dep))
    assert "/top.sv" in files
    assert "/dep.sv" in files


def test_transitive_deps_collected():
    a = _ip("a", synthesis=["/a.sv"])
    b = _ip("b", synthesis=["/b.sv"], requires=["a"])
    c = _ip("c", synthesis=["/c.sv"], requires=["b"])
    files = collect_synthesis_files(c, _catalog(a, b, c))
    assert set(files) == {"/a.sv", "/b.sv", "/c.sv"}


def test_circular_requires_does_not_loop():
    a = _ip("a", synthesis=["/a.sv"], requires=["b"])
    b = _ip("b", synthesis=["/b.sv"], requires=["a"])
    files = collect_synthesis_files(a, _catalog(a, b))
    assert set(files) == {"/a.sv", "/b.sv"}


def test_missing_dep_in_catalog_skipped():
    top = _ip("top", synthesis=["/top.sv"], requires=["ghost"])
    files = collect_synthesis_files(top, _catalog(top))
    assert files == ["/top.sv"]


# ── collect_include_dirs / collect_simulation_files ─────────────────────────

def test_collect_include_dirs_follows_requires():
    dep = _ip("dep", include_dirs=["/dep/include"])
    top = _ip("top", include_dirs=["/top/include"], requires=["dep"])
    dirs = collect_include_dirs(top, _catalog(top, dep))
    assert set(dirs) == {"/top/include", "/dep/include"}


def test_collect_simulation_follows_requires():
    dep = _ip("dep", simulation=["/dep_sim.v"])
    top = _ip("top", simulation=["/top_sim.v"], requires=["dep"])
    files = collect_simulation_files(top, _catalog(top, dep))
    assert set(files) == {"/top_sim.v", "/dep_sim.v"}


# ── transitive_requires ──────────────────────────────────────────────────────

def test_transitive_requires_all_names():
    a = _ip("a")
    b = _ip("b", requires=["a"])
    c = _ip("c", requires=["b"])
    assert transitive_requires(c, _catalog(a, b, c)) == {"a", "b"}


def test_transitive_requires_empty_when_no_deps():
    a = _ip("a")
    assert transitive_requires(a, _catalog(a)) == set()


# ── UnknownIpRequiresRule ────────────────────────────────────────────────────

def _make_system(catalog_ips, used_types):
    catalog = _catalog(*catalog_ips)
    mod = MagicMock()
    mod.type_name = used_types[0] if used_types else "none"
    system = MagicMock()
    system.project.modules = [MagicMock(type_name=t) for t in used_types]
    system.ip_catalog = catalog
    return system


def test_rule_no_error_when_dep_present():
    dep = _ip("dep")
    top = _ip("top", requires=["dep"])
    system = _make_system([top, dep], ["top"])
    diags = UnknownIpRequiresRule().validate(system)
    assert diags == []


def test_rule_error_when_dep_missing():
    top = _ip("top", requires=["ghost"])
    system = _make_system([top], ["top"])
    diags = UnknownIpRequiresRule().validate(system)
    assert len(diags) == 1
    assert diags[0].code == "IP004"
    assert diags[0].severity == Severity.ERROR
    assert "ghost" in diags[0].message
    assert "top" in diags[0].message


def test_rule_ignores_unused_ips():
    broken = _ip("broken", requires=["missing"])
    used = _ip("used")
    system = _make_system([broken, used], ["used"])
    diags = UnknownIpRequiresRule().validate(system)
    assert diags == []
