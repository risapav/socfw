from socfw.elaborate.bridge_planner import BridgePlanner
from socfw.model.source_context import SourceContext


class _IfaceStub:
    def __init__(self, protocol):
        self.protocol = protocol


class _IpStub:
    def __init__(self, protocol):
        self._protocol = protocol

    def bus_interface(self, role=None):
        return _IfaceStub(self._protocol)


class _BusStub:
    def __init__(self, fabric):
        self.fabric = fabric


class _ModuleStub:
    def __init__(self, instance, type_name, bus=None):
        self.instance = instance
        self.type_name = type_name
        self.bus = bus


class _FabricStub:
    def __init__(self, name, protocol):
        self.name = name
        self.protocol = protocol


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
        self.sources = SourceContext()


def _make_wishbone_system():
    fabric = _FabricStub("main", "simple_bus")
    mod = _ModuleStub("sdram0", "sdram_ctrl", _BusStub("main"))
    return _SystemStub(
        modules=[mod],
        fabrics={"main": fabric},
        ip_catalog={"sdram_ctrl": _IpStub("wishbone")},
    )


def test_bridge_planner_plans_simple_bus_to_wishbone():
    system = _make_wishbone_system()
    bridges = BridgePlanner().plan(system)

    assert len(bridges) == 1
    assert bridges[0].instance == "u_bridge_sdram0"
    assert bridges[0].kind == "simple_bus_to_wishbone"
    assert bridges[0].src_protocol == "simple_bus"
    assert bridges[0].dst_protocol == "wishbone"
    assert bridges[0].target_module == "sdram0"


def test_bridge_planner_rtl_file_points_to_bridge_sv():
    system = _make_wishbone_system()
    bridges = BridgePlanner().plan(system)

    import os
    assert os.path.exists(bridges[0].rtl_file), f"RTL file not found: {bridges[0].rtl_file}"
    assert bridges[0].rtl_file.endswith("simple_bus_to_wishbone_bridge.sv")


def test_bridge_planner_returns_empty_when_no_mismatch():
    fabric = _FabricStub("main", "simple_bus")
    mod = _ModuleStub("gpio0", "gpio_ip", _BusStub("main"))
    system = _SystemStub(
        modules=[mod],
        fabrics={"main": fabric},
        ip_catalog={"gpio_ip": _IpStub("simple_bus")},
    )
    assert BridgePlanner().plan(system) == []


def test_bridge_planner_returns_empty_when_no_bus():
    mod = _ModuleStub("led0", "blink", bus=None)
    system = _SystemStub(modules=[mod], fabrics={}, ip_catalog={})
    assert BridgePlanner().plan(system) == []
