from socfw.build.compat_top_patch import needs_bridge_scaffold, patch_soc_top_with_bridge_scaffold
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


def test_needs_bridge_scaffold_true_for_wishbone():
    system = _make_wishbone_system()
    assert needs_bridge_scaffold(system)


def test_needs_bridge_scaffold_false_when_no_bus():
    mod = _ModuleStub("led0", "blink_test", bus=None)
    system = _SystemStub(modules=[mod], fabrics={}, ip_catalog={})
    assert not needs_bridge_scaffold(system)


def test_needs_bridge_scaffold_false_when_protocols_match():
    fabric = _FabricStub("main", "simple_bus")
    mod = _ModuleStub("gpio0", "gpio_ip", _BusStub("main"))
    system = _SystemStub(
        modules=[mod],
        fabrics={"main": fabric},
        ip_catalog={"gpio_ip": _IpStub("simple_bus")},
    )
    assert not needs_bridge_scaffold(system)


def test_patch_soc_top_with_bridge_scaffold(tmp_path):
    rtl_dir = tmp_path / "rtl"
    rtl_dir.mkdir()
    soc_top = rtl_dir / "soc_top.sv"
    soc_top.write_text("module soc_top;\n\nendmodule\n", encoding="utf-8")

    system = _make_wishbone_system()
    patched = patch_soc_top_with_bridge_scaffold(str(tmp_path), system)

    assert patched is not None
    text = soc_top.read_text(encoding="utf-8")
    assert "simple_bus_to_wishbone_bridge" in text
    assert "u_bridge_sdram0" in text


def test_patch_is_idempotent(tmp_path):
    rtl_dir = tmp_path / "rtl"
    rtl_dir.mkdir()
    soc_top = rtl_dir / "soc_top.sv"
    soc_top.write_text("module soc_top;\n\nendmodule\n", encoding="utf-8")

    system = _make_wishbone_system()
    patch_soc_top_with_bridge_scaffold(str(tmp_path), system)
    text_first = soc_top.read_text(encoding="utf-8")
    patch_soc_top_with_bridge_scaffold(str(tmp_path), system)
    text_second = soc_top.read_text(encoding="utf-8")
    assert text_first == text_second


def test_patch_returns_none_when_no_bridge_needed(tmp_path):
    rtl_dir = tmp_path / "rtl"
    rtl_dir.mkdir()
    (rtl_dir / "soc_top.sv").write_text("module soc_top;\n\nendmodule\n", encoding="utf-8")

    mod = _ModuleStub("led0", "blink_test", bus=None)
    system = _SystemStub(modules=[mod], fabrics={}, ip_catalog={})
    result = patch_soc_top_with_bridge_scaffold(str(tmp_path), system)
    assert result is None
