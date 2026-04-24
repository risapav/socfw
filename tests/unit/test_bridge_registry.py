from socfw.elaborate.bridge_registry import BridgeRegistry
from socfw.model.bridge import BridgeSupport


def test_bridge_registry_supports_simple_bus_to_wishbone():
    reg = BridgeRegistry()
    assert reg.supports(src_protocol="simple_bus", dst_protocol="wishbone")
    assert not reg.supports(src_protocol="wishbone", dst_protocol="simple_bus")


def test_bridge_registry_supports_simple_bus_to_axi_lite():
    reg = BridgeRegistry()
    assert reg.supports(src_protocol="simple_bus", dst_protocol="axi_lite")


def test_bridge_registry_find_bridge_returns_support():
    reg = BridgeRegistry()
    result = reg.find_bridge(src_protocol="simple_bus", dst_protocol="wishbone")
    assert result is not None
    assert isinstance(result, BridgeSupport)
    assert result.bridge_kind == "simple_bus_to_wishbone"


def test_bridge_registry_returns_none_for_unknown_pair():
    reg = BridgeRegistry()
    result = reg.find_bridge(src_protocol="wishbone", dst_protocol="apb")
    assert result is None


def test_bridge_registry_allows_custom_registration():
    reg = BridgeRegistry()
    reg.register(BridgeSupport(src_protocol="custom_a", dst_protocol="custom_b", bridge_kind="a_to_b"))
    assert reg.supports(src_protocol="custom_a", dst_protocol="custom_b")
