from __future__ import annotations

from socfw.ir.peripheral_shell import (
    PeripheralShellIR,
    ShellCoreConnIR,
    ShellExternalPortIR,
)


class PeripheralShellIRBuilder:
    def build_for_peripheral(self, p, ip_meta: dict) -> PeripheralShellIR | None:
        shell = ip_meta.get("shell")
        if not shell:
            return None

        regblock_module = f"{p.instance}_regs"
        shell_module = f"{p.instance}_shell"

        external_ports = [
            ShellExternalPortIR(
                name=ep["name"],
                direction=ep["direction"],
                width=int(ep.get("width", 1)),
            )
            for ep in shell.get("external_ports", [])
        ]

        core_conns: list[ShellCoreConnIR] = []
        for cp in shell.get("core_ports", []):
            kind = cp["kind"]
            port_name = cp["port_name"]

            if kind == "reg":
                signal_name = f"reg_{cp['reg_name']}"
            elif kind == "status":
                signal_name = f"hw_{cp['signal_name']}"
            elif kind == "irq":
                signal_name = cp["signal_name"]
            elif kind == "external":
                signal_name = cp["signal_name"]
            else:
                raise ValueError(f"Unsupported shell core port kind: {kind}")

            core_conns.append(
                ShellCoreConnIR(
                    kind=kind,
                    port_name=port_name,
                    signal_name=signal_name,
                )
            )

        return PeripheralShellIR(
            module_name=shell_module,
            core_module=shell["module"],
            regblock_module=regblock_module,
            instance_name=p.instance,
            external_ports=external_ports,
            core_conns=core_conns,
        )
