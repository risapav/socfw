from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.model.system import SystemModel
from .base import ValidationRule


class UnknownBusFabricRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        known = {f.name for f in system.project.bus_fabrics}

        for mod in system.project.modules:
            if mod.bus is None:
                continue
            if mod.bus.fabric not in known:
                diags.append(
                    Diagnostic(
                        code="BUS001",
                        severity=Severity.ERROR,
                        message=f"Instance '{mod.instance}' references unknown bus fabric '{mod.bus.fabric}'",
                        subject="project.modules.bus",
                    )
                )
        return diags


class MissingBusInterfaceRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for mod in system.project.modules:
            if mod.bus is None:
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            iface = ip.bus_interface()
            if iface is None:
                diags.append(
                    Diagnostic(
                        code="BUS002",
                        severity=Severity.ERROR,
                        message=(
                            f"Instance '{mod.instance}' is attached to a bus, "
                            f"but IP '{mod.type_name}' declares no bus interface"
                        ),
                        subject="project.modules.bus",
                    )
                )
        return diags


class DuplicateAddressRegionRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        regs = []
        if system.ram is not None:
            regs.append(("ram", system.ram.base, system.ram.base + system.ram.size - 1))

        for mod in system.project.modules:
            if mod.bus and mod.bus.base is not None and mod.bus.size is not None:
                regs.append((mod.instance, mod.bus.base, mod.bus.base + mod.bus.size - 1))

        for i, (n1, b1, e1) in enumerate(regs):
            for n2, b2, e2 in regs[i + 1:]:
                if not (e1 < b2 or e2 < b1):
                    diags.append(
                        Diagnostic(
                            code="BUS003",
                            severity=Severity.ERROR,
                            message=(
                                f"Address overlap between '{n1}' "
                                f"(0x{b1:08X}-0x{e1:08X}) and '{n2}' "
                                f"(0x{b2:08X}-0x{e2:08X})"
                            ),
                            subject="project.modules.bus",
                        )
                    )
        return diags


_BRIDGEABLE_PAIRS: frozenset[tuple[str, str]] = frozenset({
    ("simple_bus", "axi_lite"),
})


class FabricProtocolMismatchRule(ValidationRule):
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        fabrics = {f.name: f for f in system.project.bus_fabrics}

        for mod in system.project.modules:
            if mod.bus is None:
                continue
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue
            iface = ip.bus_interface()
            if iface is None:
                continue

            fabric = fabrics.get(mod.bus.fabric)
            if fabric is None:
                continue

            if iface.protocol == fabric.protocol:
                continue
            if (fabric.protocol, iface.protocol) in _BRIDGEABLE_PAIRS:
                continue

            diags.append(
                Diagnostic(
                    code="BUS004",
                    severity=Severity.ERROR,
                    message=(
                        f"Instance '{mod.instance}' uses protocol '{iface.protocol}', "
                        f"but fabric '{fabric.name}' uses '{fabric.protocol}'"
                    ),
                    subject="project.modules.bus",
                )
            )

        return diags
