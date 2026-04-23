from __future__ import annotations
from dataclasses import dataclass, field
from typing import Protocol, Any

from socfw.validate.rules.base import ValidationRule


class BusPlannerPlugin(Protocol):
    protocol: str

    def plan(self, system: Any) -> Any:
        ...


class LoaderPlugin(Protocol):
    kind: str

    def load(self, *args, **kwargs) -> Any:
        ...


class EmitterPlugin(Protocol):
    family: str

    def emit(self, *args, **kwargs) -> list[Any]:
        ...


class ReportPlugin(Protocol):
    name: str

    def emit(self, *args, **kwargs) -> str | list[str]:
        ...


@dataclass
class PluginRegistry:
    bus_planners: dict[str, BusPlannerPlugin] = field(default_factory=dict)
    loaders: dict[str, LoaderPlugin] = field(default_factory=dict)
    emitters: dict[str, EmitterPlugin] = field(default_factory=dict)
    reports: dict[str, ReportPlugin] = field(default_factory=dict)
    validators: list[ValidationRule] = field(default_factory=list)
    bridge_planners: list[object] = field(default_factory=list)

    def register_bus_planner(self, plugin: BusPlannerPlugin) -> None:
        self.bus_planners[plugin.protocol] = plugin

    def register_loader(self, plugin: LoaderPlugin) -> None:
        self.loaders[plugin.kind] = plugin

    def register_emitter(self, plugin: EmitterPlugin) -> None:
        self.emitters[plugin.family] = plugin

    def register_report(self, plugin: ReportPlugin) -> None:
        self.reports[plugin.name] = plugin

    def register_validator(self, rule: ValidationRule) -> None:
        self.validators.append(rule)

    def register_bridge_planner(self, plugin: object) -> None:
        self.bridge_planners.append(plugin)

    def find_bridge(self, *, src_protocol: str, dst_protocol: str):
        for p in self.bridge_planners:
            if p.src_protocol == src_protocol and p.dst_protocol == dst_protocol:
                return p
        return None
