from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class PortBinding:
    port_name: str
    target: str
    top_name: str | None = None
    width: int | None = None
    adapt: str | None = None


@dataclass(frozen=True)
class ClockBinding:
    port_name: str
    domain: str
    no_reset: bool = False


@dataclass(frozen=True)
class BusAttach:
    fabric: str
    base: int | None = None
    size: int | None = None


@dataclass
class ModuleInstance:
    instance: str
    type_name: str
    params: dict[str, Any] = field(default_factory=dict)
    clocks: list[ClockBinding] = field(default_factory=list)
    port_bindings: list[PortBinding] = field(default_factory=list)
    bus: BusAttach | None = None

    def clock_for_port(self, port_name: str) -> ClockBinding | None:
        for cb in self.clocks:
            if cb.port_name == port_name:
                return cb
        return None


@dataclass(frozen=True)
class GeneratedClockRequest:
    domain: str
    source_instance: str
    source_output: str
    frequency_hz: int | None = None
    sync_from: str | None = None
    sync_stages: int | None = None
    no_reset: bool = False


@dataclass(frozen=True)
class BusFabricRequest:
    name: str
    protocol: str
    addr_width: int = 32
    data_width: int = 32
    masters: list[str] = field(default_factory=list)
    slaves: list[str] = field(default_factory=list)


@dataclass
class ProjectModel:
    name: str
    mode: str
    board_ref: str
    board_file: str | None = None
    registries_ip: list[str] = field(default_factory=list)
    registries_packs: list[str] = field(default_factory=list)
    registries_cpu: list[str] = field(default_factory=list)
    feature_refs: list[str] = field(default_factory=list)
    modules: list[ModuleInstance] = field(default_factory=list)
    primary_clock_domain: str = "sys_clk"
    generated_clocks: list[GeneratedClockRequest] = field(default_factory=list)
    timing_file: str | None = None
    debug: bool = False
    bus_fabrics: list[BusFabricRequest] = field(default_factory=list)

    def module_by_name(self, instance: str) -> ModuleInstance | None:
        for m in self.modules:
            if m.instance == instance:
                return m
        return None

    def fabric_by_name(self, name: str) -> BusFabricRequest | None:
        for f in self.bus_fabrics:
            if f.name == name:
                return f
        return None

    def validate(self) -> list[str]:
        errs: list[str] = []
        seen: set[str] = set()

        for mod in self.modules:
            if mod.instance in seen:
                errs.append(f"Duplicate module instance '{mod.instance}'")
            seen.add(mod.instance)

            clock_ports = [c.port_name for c in mod.clocks]
            if len(clock_ports) != len(set(clock_ports)):
                errs.append(f"{mod.instance}: duplicate clock binding port")

            bind_ports = [b.port_name for b in mod.port_bindings]
            if len(bind_ports) != len(set(bind_ports)):
                errs.append(f"{mod.instance}: duplicate port binding")

        gen_names = [g.domain for g in self.generated_clocks]
        if len(gen_names) != len(set(gen_names)):
            errs.append("Duplicate generated clock domain name")

        fabric_names = [f.name for f in self.bus_fabrics]
        if len(fabric_names) != len(set(fabric_names)):
            errs.append("Duplicate bus fabric name")

        return errs
