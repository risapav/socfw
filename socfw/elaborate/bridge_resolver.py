from __future__ import annotations


class BridgeResolver:
    def __init__(self, registry) -> None:
        self.registry = registry

    def resolve(self, *, fabric, mod, ip, iface):
        plugin = self.registry.find_bridge(
            src_protocol=fabric.protocol,
            dst_protocol=iface.protocol,
        )
        if plugin is None:
            return None

        if not plugin.can_bridge(fabric=fabric, ip=ip, iface=iface):
            return None

        return plugin.plan_bridge(fabric=fabric, mod=mod, ip=ip, iface=iface)
