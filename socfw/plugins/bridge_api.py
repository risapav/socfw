from __future__ import annotations

from abc import ABC, abstractmethod


class BridgePlannerPlugin(ABC):
    src_protocol: str
    dst_protocol: str
    bridge_module: str

    @abstractmethod
    def can_bridge(self, *, fabric, ip, iface) -> bool:
        raise NotImplementedError

    @abstractmethod
    def plan_bridge(self, *, fabric, mod, ip, iface):
        raise NotImplementedError
