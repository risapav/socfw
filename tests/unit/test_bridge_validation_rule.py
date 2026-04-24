from socfw.model.source_context import SourceContext
from socfw.validate.rules.bridge_rules import MissingBridgeRule


class _FakeRegistry:
    def find_bridge(self, *, src_protocol, dst_protocol):
        if src_protocol == "simple_bus" and dst_protocol == "wishbone":
            return object()
        return None


class _FabricStub:
    def __init__(self, name, protocol):
        self.name = name
        self.protocol = protocol


class _BusStub:
    def __init__(self, fabric):
        self.fabric = fabric
        self.base = None
        self.size = None


class _IpStub:
    def __init__(self, protocol, needs_bus=True):
        self._protocol = protocol
        self.needs_bus = needs_bus
        self.name = "test_ip"

    def bus_interface(self, role=None):
        class _Iface:
            protocol = self._protocol
        return _Iface()


class _ModuleStub:
    def __init__(self, instance, type_name, bus=None):
        self.instance = instance
        self.type_name = type_name
        self.bus = bus


class _ProjectStub:
    def __init__(self, modules, fabrics):
        self.modules = modules
        self._fabrics = fabrics

    def fabric_by_name(self, name):
        return self._fabrics.get(name)


class _SystemStub:
    def __init__(self, modules, fabrics, ip_catalog):
        self.project = _ProjectStub(modules, fabrics)
        self.ip_catalog = ip_catalog
        self.sources = SourceContext(project_file="project.yaml")


def test_missing_bridge_rule_reports_protocol_mismatch():
    fabric = _FabricStub("main", "simple_bus")
    mod = _ModuleStub("apb0", "apb_gpio", _BusStub("main"))
    system = _SystemStub(
        modules=[mod],
        fabrics={"main": fabric},
        ip_catalog={"apb_gpio": _IpStub("apb")},
    )

    diags = MissingBridgeRule(_FakeRegistry()).validate(system)
    assert any(d.code == "BRG001" for d in diags)


def test_missing_bridge_rule_passes_when_bridge_registered():
    fabric = _FabricStub("main", "simple_bus")
    mod = _ModuleStub("sdram0", "sdram_ctrl", _BusStub("main"))
    system = _SystemStub(
        modules=[mod],
        fabrics={"main": fabric},
        ip_catalog={"sdram_ctrl": _IpStub("wishbone")},
    )

    diags = MissingBridgeRule(_FakeRegistry()).validate(system)
    assert not any(d.code == "BRG001" for d in diags)


def test_missing_bridge_rule_skips_modules_without_bus():
    mod = _ModuleStub("led0", "blink_test", bus=None)
    system = _SystemStub(
        modules=[mod],
        fabrics={},
        ip_catalog={"blink_test": _IpStub("none", needs_bus=False)},
    )

    diags = MissingBridgeRule(_FakeRegistry()).validate(system)
    assert not any(d.code == "BRG001" for d in diags)
