from __future__ import annotations

from socfw.core.diag_builders import err
from socfw.core.diagnostics import Diagnostic, RelatedDiagnosticRef, Severity, SuggestedFix
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
    def validate(self, system: SystemModel) -> list:
        diags = []
        project_file = system.sources.project_file

        regs: list[tuple[str, int, int, str]] = []
        if system.ram is not None:
            regs.append(("ram", system.ram.base, system.ram.base + system.ram.size - 1, "ram"))

        for idx, mod in enumerate(system.project.modules):
            if mod.bus and mod.bus.base is not None and mod.bus.size is not None:
                regs.append((mod.instance, mod.bus.base, mod.bus.base + mod.bus.size - 1, f"modules[{idx}].bus"))

        for i, (n1, b1, e1, p1) in enumerate(regs):
            for n2, b2, e2, p2 in regs[i + 1:]:
                if not (e1 < b2 or e2 < b1):
                    diags.append(
                        err(
                            "BUS003",
                            f"Address overlap between '{n1}' and '{n2}'",
                            "project.modules.bus",
                            file=project_file,
                            path=p1,
                            category="bus",
                            hints=[
                                "Ensure each slave region is unique and non-overlapping.",
                                "Check RAM base/size and all peripheral bus regions.",
                            ],
                            fixes=[
                                SuggestedFix(message=f"Move '{n1}' to a non-overlapping base address", path=p1),
                                SuggestedFix(message=f"Move '{n2}' to a non-overlapping base address", path=p2),
                            ],
                            related=[
                                RelatedDiagnosticRef(
                                    code="BUS003",
                                    message=f"{n1}: 0x{b1:08X}-0x{e1:08X}",
                                    subject=p1,
                                ),
                                RelatedDiagnosticRef(
                                    code="BUS003",
                                    message=f"{n2}: 0x{b2:08X}-0x{e2:08X}",
                                    subject=p2,
                                ),
                            ],
                            detail=(
                                f"Computed regions overlap: "
                                f"{n1}=0x{b1:08X}-0x{e1:08X}, "
                                f"{n2}=0x{b2:08X}-0x{e2:08X}"
                            ),
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
