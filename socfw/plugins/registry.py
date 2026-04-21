from __future__ import annotations
from dataclasses import dataclass, field
from typing import Protocol, Any

from socfw.validate.rules.base import ValidationRule


class BusPlannerPlugin(Protocol):
    protocol: str

    def plan(self, system: Any) -> Any:
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
    emitters: dict[str, EmitterPlugin] = field(default_factory=dict)
    reports: dict[str, ReportPlugin] = field(default_factory=dict)
    validators: list[ValidationRule] = field(default_factory=list)

    def register_bus_planner(self, plugin: BusPlannerPlugin) -> None:
        self.bus_planners[plugin.protocol] = plugin

    def register_emitter(self, plugin: EmitterPlugin) -> None:
        self.emitters[plugin.family] = plugin

    def register_report(self, plugin: ReportPlugin) -> None:
        self.reports[plugin.name] = plugin

    def register_validator(self, rule: ValidationRule) -> None:
        self.validators.append(rule)
