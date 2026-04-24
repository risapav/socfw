from __future__ import annotations

from socfw.model.bridge import BridgeSupport


class BridgeRegistry:
    def __init__(self) -> None:
        self._pairs: dict[tuple[str, str], BridgeSupport] = {}
        self._register_builtin()

    def _register_builtin(self) -> None:
        self.register(
            BridgeSupport(
                src_protocol="simple_bus",
                dst_protocol="wishbone",
                bridge_kind="simple_bus_to_wishbone",
                notes="Phase-1 compatibility registration",
            )
        )
        self.register(
            BridgeSupport(
                src_protocol="simple_bus",
                dst_protocol="axi_lite",
                bridge_kind="simple_bus_to_axi_lite",
                notes="Phase-1 compatibility registration",
            )
        )

    def register(self, support: BridgeSupport) -> None:
        self._pairs[(support.src_protocol, support.dst_protocol)] = support

    def find_bridge(self, *, src_protocol: str, dst_protocol: str) -> BridgeSupport | None:
        return self._pairs.get((src_protocol, dst_protocol))

    def supports(self, *, src_protocol: str, dst_protocol: str) -> bool:
        return self.find_bridge(src_protocol=src_protocol, dst_protocol=dst_protocol) is not None
