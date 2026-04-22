from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class ShellExternalPortIR:
    name: str
    direction: str
    width: int = 1


@dataclass(frozen=True)
class ShellCoreConnIR:
    kind: str
    port_name: str
    signal_name: str


@dataclass
class PeripheralShellIR:
    module_name: str
    core_module: str
    regblock_module: str
    instance_name: str
    external_ports: list[ShellExternalPortIR] = field(default_factory=list)
    core_conns: list[ShellCoreConnIR] = field(default_factory=list)
