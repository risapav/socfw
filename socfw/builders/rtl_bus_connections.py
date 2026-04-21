from __future__ import annotations

from socfw.elaborate.bus_plan import InterconnectPlan
from socfw.ir.rtl import RtlBusConn
from socfw.model.ip import IpDescriptor
from socfw.model.project import ModuleInstance


class RtlBusConnectionResolver:
    def resolve_for_instance(
        self,
        *,
        mod: ModuleInstance,
        ip: IpDescriptor,
        plan: InterconnectPlan | None,
    ) -> list[RtlBusConn]:
        if plan is None:
            return []

        result: list[RtlBusConn] = []

        for fabric_name, endpoints in plan.fabrics.items():
            for ep in endpoints:
                if ep.instance != mod.instance:
                    continue

                iface = ip.bus_interface()
                if iface is None:
                    continue

                modport = "master" if ep.role == "master" else "slave"
                result.append(
                    RtlBusConn(
                        port=iface.port_name,
                        interface_name=f"if_{ep.instance}_{fabric_name}",
                        modport=modport,
                    )
                )

        return result
