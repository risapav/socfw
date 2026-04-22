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

        regs_by_name = {
            str(r["name"]): r
            for r in ip_meta.get("registers", [])
        }

        core_conns: list[ShellCoreConnIR] = []
        for cp in shell.get("core_ports", []):
            kind = cp["kind"]
            port_name = cp["port_name"]
            width = 1

            if kind == "reg":
                signal_name = f"reg_{cp['reg_name']}"
                reg = regs_by_name.get(str(cp["reg_name"]))
                if reg:
                    width = int(reg.get("width", 32))
            elif kind == "status":
                signal_name = f"hw_{cp['signal_name']}"
                reg = regs_by_name.get(str(cp["signal_name"]))
                if reg:
                    width = int(reg.get("width", 1))
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
                    width=width,
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
