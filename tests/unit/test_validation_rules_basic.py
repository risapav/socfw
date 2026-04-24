from socfw.core.diagnostics import Severity
from socfw.model.cpu import CpuInstance
from socfw.model.source_context import SourceContext
from socfw.validate.rules.cpu_rules import UnknownCpuTypeRule
from socfw.validate.rules.ip_rules import UnknownIpTypeRule


class _ModuleStub:
    def __init__(self, instance, type_name):
        self.instance = instance
        self.type_name = type_name


class _ProjectStub:
    def __init__(self, modules):
        self.modules = modules


class _SystemStub:
    def __init__(self, cpu, cpu_catalog, modules, ip_catalog):
        self.cpu = cpu
        self.cpu_catalog = cpu_catalog
        self.project = _ProjectStub(modules)
        self.ip_catalog = ip_catalog
        self.sources = SourceContext(project_file="project.yaml")


def test_unknown_cpu_type_rule_triggers():
    system = _SystemStub(
        cpu=CpuInstance(instance="cpu0", type_name="missing_cpu", fabric="main"),
        cpu_catalog={},
        modules=[],
        ip_catalog={},
    )

    diags = UnknownCpuTypeRule().validate(system)
    assert any(d.code == "CPU001" and d.severity == Severity.ERROR for d in diags)


def test_unknown_ip_type_rule_triggers():
    system = _SystemStub(
        cpu=None,
        cpu_catalog={},
        modules=[_ModuleStub(instance="u0", type_name="missing_ip")],
        ip_catalog={},
    )

    diags = UnknownIpTypeRule().validate(system)
    assert any(d.code == "IP001" and d.severity == Severity.ERROR for d in diags)


def test_unknown_cpu_type_rule_passes_when_cpu_is_none():
    system = _SystemStub(cpu=None, cpu_catalog={}, modules=[], ip_catalog={})
    diags = UnknownCpuTypeRule().validate(system)
    assert not any(d.code == "CPU001" for d in diags)


def test_unknown_ip_type_rule_passes_when_all_known():
    system = _SystemStub(
        cpu=None,
        cpu_catalog={},
        modules=[_ModuleStub(instance="u0", type_name="known_ip")],
        ip_catalog={"known_ip": object()},
    )

    diags = UnknownIpTypeRule().validate(system)
    assert not any(d.code == "IP001" for d in diags)
