from __future__ import annotations

from socfw.plugins.registry import PluginRegistry
from socfw.plugins.simple_bus.planner import SimpleBusPlanner
from socfw.validate.rules.asset_rules import VendorIpArtifactExistsRule
from socfw.validate.rules.binding_rules import BindingWidthCompatibilityRule
from socfw.validate.rules.board_rules import (
    UnknownBoardBindingTargetRule,
    UnknownBoardFeatureRule,
)
from socfw.validate.rules.bus_rules import (
    DuplicateAddressRegionRule,
    FabricProtocolMismatchRule,
    MissingBusInterfaceRule,
    UnknownBusFabricRule,
)
from socfw.validate.rules.project_rules import (
    DuplicateModuleInstanceRule,
    UnknownGeneratedClockSourceRule,
    UnknownIpTypeRule,
)


def create_builtin_registry() -> PluginRegistry:
    reg = PluginRegistry()

    reg.register_bus_planner(SimpleBusPlanner())

    reg.register_validator(DuplicateModuleInstanceRule())
    reg.register_validator(UnknownIpTypeRule())
    reg.register_validator(UnknownGeneratedClockSourceRule())
    reg.register_validator(UnknownBoardFeatureRule())
    reg.register_validator(UnknownBoardBindingTargetRule())
    reg.register_validator(VendorIpArtifactExistsRule())
    reg.register_validator(BindingWidthCompatibilityRule())
    reg.register_validator(UnknownBusFabricRule())
    reg.register_validator(MissingBusInterfaceRule())
    reg.register_validator(DuplicateAddressRegionRule())
    reg.register_validator(FabricProtocolMismatchRule())

    return reg
