from socfw.validate.rules.bridge_rules import MissingBridgeRule
from socfw.validate.rules.bus_rules import DuplicateAddressRegionRule
from socfw.validate.rules.cpu_rules import UnknownCpuTypeRule


class _FakeRegistry:
    def find_bridge(self, *, src_protocol, dst_protocol):
        if src_protocol == "simple_bus" and dst_protocol == "axi_lite":
            return object()
        return None


class _FabricStub:
    def __init__(self, name, protocol):
        self.name = name
        self.protocol = protocol


class _BusStub:
    def __init__(self, fabric, base=None, size=None):
        self.fabric = fabric
        self.base = base
        self.size = size


class _IfaceStub:
    def __init__(self, protocol):
        self.protocol = protocol

    def bus_interface(self, role=None):
        return self


class _IpStub:
    def __init__(self, protocol):
        self._iface = _IfaceStub(protocol)

    def bus_interface(self, role=None):
        return self._iface


class _ModuleStub:
    def __init__(self, instance, ip_type, bus=None):
        self.instance = instance
        self.type_name = ip_type
        self.bus = bus


class _ProjectStub:
    def __init__(self, modules, fabrics=None):
        self.modules = modules
        self._fabrics = fabrics or {}

    def fabric_by_name(self, name):
        return self._fabrics.get(name)

    @property
    def bus_fabrics(self):
        return list(self._fabrics.values())


class _SystemStub:
    def __init__(self, modules, fabrics, ip_catalog, ram=None, cpu=None):
        self.project = _ProjectStub(modules, fabrics)
        self.ip_catalog = ip_catalog
        self.ram = ram
        self.cpu = cpu

    def cpu_desc(self):
        return None


def test_duplicate_address_region_no_overlap():
    sys = _SystemStub(modules=[], fabrics={}, ip_catalog={})
    diags = DuplicateAddressRegionRule().validate(sys)
    assert not any(d.code == "BUS003" for d in diags)


def test_duplicate_address_region_with_overlap():
    class M:
        bus = type("B", (), {"base": 0x40000000, "size": 0x1000, "fabric": "main"})()
        instance = "gpio0"
        type_name = "gpio"

    class M2:
        bus = type("B", (), {"base": 0x40000800, "size": 0x1000, "fabric": "main"})()
        instance = "gpio1"
        type_name = "gpio"

    sys = _SystemStub(modules=[M(), M2()], fabrics={}, ip_catalog={}, ram=None)
    diags = DuplicateAddressRegionRule().validate(sys)
    assert any(d.code == "BUS003" for d in diags)


def test_missing_bridge_rule_ok_when_registered():
    fabric = _FabricStub("main", "simple_bus")
    mod = _ModuleStub("axigpio0", "axi_gpio", _BusStub("main"))
    sys = _SystemStub(
        modules=[mod],
        fabrics={"main": fabric},
        ip_catalog={"axi_gpio": _IpStub("axi_lite")},
    )
    diags = MissingBridgeRule(_FakeRegistry()).validate(sys)
    assert not any(d.code == "BRG001" for d in diags)


def test_missing_bridge_rule_fails_when_not_registered():
    fabric = _FabricStub("main", "simple_bus")
    mod = _ModuleStub("apb0", "apb_gpio", _BusStub("main"))
    sys = _SystemStub(
        modules=[mod],
        fabrics={"main": fabric},
        ip_catalog={"apb_gpio": _IpStub("apb")},
    )
    diags = MissingBridgeRule(_FakeRegistry()).validate(sys)
    assert any(d.code == "BRG001" for d in diags)


def test_unknown_cpu_type_rule():
    class _CpuRef:
        type_name = "nonexistent_cpu"

    class _Sys:
        cpu = _CpuRef()
        cpu_catalog: dict = {}

        class ip_catalog:
            @staticmethod
            def get(name):
                return None

        class project:
            modules = []

    diags = UnknownCpuTypeRule().validate(_Sys())
    assert any(d.code == "CPU001" for d in diags)
