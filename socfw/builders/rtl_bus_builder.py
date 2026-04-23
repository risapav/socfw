from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan
from socfw.ir.rtl import (
    BOARD_CLOCK,
    BOARD_RESET,
    RtlBusConn,
    RtlFabricInstance,
    RtlFabricPort,
    RtlInstance,
    RtlInterfaceInstance,
)


class RtlBusBuilder:
    def build_interfaces(self, plan: InterconnectPlan) -> list[RtlInterfaceInstance]:
        result: list[RtlInterfaceInstance] = []

        for fabric_name, endpoints in plan.fabrics.items():
            for ep in endpoints:
                if ep.protocol == "simple_bus":
                    result.append(
                        RtlInterfaceInstance(
                            if_type="bus_if",
                            name=self._if_name(ep.instance, fabric_name),
                            comment=f"{ep.role} endpoint on {fabric_name}",
                        )
                    )
            result.append(
                RtlInterfaceInstance(
                    if_type="bus_if",
                    name=f"if_error_{fabric_name}",
                    comment=f"error slave for {fabric_name}",
                )
            )

        for br in plan.bridges:
            result.append(
                RtlInterfaceInstance(
                    if_type="axi_lite_if",
                    name=f"if_{br.dst_instance}_axil",
                    comment=f"AXI-lite side for {br.instance}",
                )
            )

        return result

    def build_fabrics(self, plan: InterconnectPlan) -> list[RtlFabricInstance]:
        fabrics: list[RtlFabricInstance] = []

        for fabric_name, endpoints in plan.fabrics.items():
            if not endpoints:
                continue

            protocol = endpoints[0].protocol
            if protocol != "simple_bus":
                continue

            masters = [ep for ep in endpoints if ep.role == "master"]
            slaves = [ep for ep in endpoints if ep.role == "slave"]

            base_words: list[int] = []
            mask_words: list[int] = []
            for s in slaves:
                base_words.append(s.base or 0)
                size = s.size or 0
                mask = (size - 1) if size > 0 and (size & (size - 1)) == 0 else 0
                mask_words.append(mask)

            fabric = RtlFabricInstance(
                module="simple_bus_fabric",
                name=f"u_fabric_{fabric_name}",
                params={
                    "NSLAVES": len(slaves),
                    "BASE_ADDR": self._pack_words(base_words),
                    "ADDR_MASK": self._pack_words(mask_words),
                },
                clock_signal=BOARD_CLOCK,
                reset_signal=BOARD_RESET,
                comment=f"simple_bus fabric '{fabric_name}'",
            )

            for idx, ep in enumerate(masters):
                fabric.ports.append(
                    RtlFabricPort(
                        port_name="m_bus",
                        interface_name=self._if_name(ep.instance, fabric_name),
                        modport="slave",
                        index=None if len(masters) == 1 else idx,
                    )
                )

            for idx, ep in enumerate(slaves):
                fabric.ports.append(
                    RtlFabricPort(
                        port_name="s_bus",
                        interface_name=self._if_name(ep.instance, fabric_name),
                        modport="master",
                        index=idx,
                    )
                )

            fabric.ports.append(
                RtlFabricPort(
                    port_name="err_bus",
                    interface_name=f"if_error_{fabric_name}",
                    modport="master",
                    index=None,
                )
            )

            fabrics.append(fabric)

        return fabrics

    def build_bridge_instances(self, plan: InterconnectPlan) -> list[RtlInstance]:
        result: list[RtlInstance] = []

        for br in plan.bridges:
            result.append(
                RtlInstance(
                    module=br.module,
                    name=br.instance,
                    conns=[],
                    bus_conns=[
                        RtlBusConn(
                            port="sbus",
                            interface_name=f"if_{br.instance}_{br.src_fabric}",
                            modport="slave",
                        ),
                        RtlBusConn(
                            port="m_axil",
                            interface_name=f"if_{br.dst_instance}_axil",
                            modport="master",
                        ),
                    ],
                    comment=f"{br.src_protocol} -> {br.dst_protocol} bridge",
                )
            )

        return result

    @staticmethod
    def _if_name(instance: str, fabric: str) -> str:
        return f"if_{instance}_{fabric}"

    @staticmethod
    def _pack_words(words: list[int]) -> str:
        if not words:
            return "'0"
        chunks = [f"32'h{w:08X}" for w in reversed(words)]
        return "{ " + ", ".join(chunks) + " }"
