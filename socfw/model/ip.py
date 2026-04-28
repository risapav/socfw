from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, Literal

from socfw.model.ports import PortDescriptor


@dataclass(frozen=True)
class IpParameterDecl:
    name: str
    type: Literal["int", "bit", "string"] = "int"
    default: Any = None


@dataclass(frozen=True)
class IpOrigin:
    kind: str
    tool: str | None = None
    packaging: str | None = None


@dataclass(frozen=True)
class IpArtifactBundle:
    synthesis: tuple[str, ...] = ()
    simulation: tuple[str, ...] = ()
    metadata: tuple[str, ...] = ()

    def all_files(self) -> tuple[str, ...]:
        return self.synthesis + self.simulation + self.metadata


@dataclass(frozen=True)
class IpResetSemantics:
    port: str | None = None
    active_high: bool = False
    bypass_sync: bool = False
    optional: bool = False
    asynchronous: bool = False


@dataclass(frozen=True)
class IpClockOutput:
    port: str
    kind: str
    default_domain: str | None = None
    signal_name: str | None = None


@dataclass(frozen=True)
class IpClocking:
    primary_input_port: str | None = None
    additional_input_ports: tuple[str, ...] = ()
    outputs: tuple[IpClockOutput, ...] = ()

    def find_output(self, port_name: str) -> IpClockOutput | None:
        for out in self.outputs:
            if out.port == port_name:
                return out
        return None


@dataclass(frozen=True)
class IpBusInterface:
    port_name: str
    protocol: str
    role: str
    addr_width: int = 32
    data_width: int = 32


@dataclass(frozen=True)
class IpVendorInfo:
    vendor: str
    tool: str
    generator: str | None = None
    family: str | None = None
    qip: str | None = None
    sdc: tuple[str, ...] = ()
    filesets: tuple[str, ...] = ()


@dataclass(frozen=True)
class IpDescriptor:
    name: str
    module: str
    category: str
    origin: IpOrigin
    needs_bus: bool
    generate_registers: bool
    instantiate_directly: bool
    dependency_only: bool
    reset: IpResetSemantics
    clocking: IpClocking
    artifacts: IpArtifactBundle
    bus_interfaces: tuple[IpBusInterface, ...] = ()
    ports: tuple[PortDescriptor, ...] = ()
    declared_params: tuple[IpParameterDecl, ...] = ()
    vendor_info: IpVendorInfo | None = None
    meta: dict[str, Any] = field(default_factory=dict)
    source_file: str | None = None

    def port_by_name(self, name: str) -> PortDescriptor | None:
        for p in self.ports:
            if p.name == name:
                return p
        return None

    def bus_interface(self, role: str | None = None) -> IpBusInterface | None:
        for b in self.bus_interfaces:
            if role is None or b.role == role:
                return b
        return None

    def validate(self) -> list[str]:
        errs: list[str] = []

        if not self.module:
            errs.append(f"{self.name}: module must not be empty")

        if self.dependency_only and self.instantiate_directly:
            errs.append(f"{self.name}: dependency_only and instantiate_directly cannot both be true")

        if self.origin.kind == "vendor_generated" and not self.artifacts.synthesis:
            errs.append(f"{self.name}: vendor_generated IP must declare synthesis artifacts")

        if self.reset.bypass_sync and self.reset.port is None:
            errs.append(f"{self.name}: bypass_sync requires reset.port")

        return errs
