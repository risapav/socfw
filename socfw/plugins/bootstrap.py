from __future__ import annotations

from socfw.emit.board_quartus_emitter import QuartusBoardEmitter
from socfw.emit.docs_emitter import DocsEmitter
from socfw.emit.files_tcl_emitter import QuartusFilesEmitter
from socfw.emit.peripheral_shell_emitter import PeripheralShellEmitter
from socfw.emit.sim_filelist_emitter import SimFilelistEmitter
from socfw.emit.register_block_emitter import RegisterBlockEmitter
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.emit.software_emitter import SoftwareEmitter
from socfw.emit.timing_emitter import TimingEmitter
from socfw.plugins.bridges.simple_to_axi import SimpleBusToAxiLiteBridgePlanner
from socfw.plugins.bridges.simple_to_wishbone import SimpleBusToWishboneBridgePlanner
from socfw.plugins.registry import PluginRegistry
from socfw.plugins.simple_bus.planner import SimpleBusPlanner
from socfw.reports.graphviz_emitter import GraphvizEmitter
from socfw.reports.json_emitter import JsonReportEmitter
from socfw.reports.markdown_emitter import MarkdownReportEmitter
from socfw.validate.rules.asset_rules import VendorIpArtifactExistsRule
from socfw.validate.rules.binding_rules import BindingWidthCompatibilityRule, BoardBindingRule
from socfw.validate.rules.board_rules import (
    UnknownBoardBindingTargetRule,
    UnknownBoardFeatureRule,
)
from socfw.validate.rules.mux_rules import BoardMuxGroupRule
from socfw.validate.rules.pin_rules import BoardPinConflictRule
from socfw.validate.rules.bridge_rules import MissingBridgeRule
from socfw.validate.rules.bus_rules import (
    DuplicateAddressRegionRule,
    MissingBusInterfaceRule,
    UnknownBusFabricRule,
)
from socfw.validate.rules.cpu_rules import (
    CpuDescriptorBusMissingRule,
    UnknownCpuFabricRule,
    UnknownCpuTypeRule,
)
from socfw.validate.rules.project_rules import (
    DuplicateModuleInstanceRule,
    UnknownGeneratedClockSourceRule,
    UnknownIpTypeRule,
)


def create_builtin_registry(templates_dir: str) -> PluginRegistry:
    reg = PluginRegistry()

    reg.register_bridge_planner(SimpleBusToAxiLiteBridgePlanner())
    reg.register_bridge_planner(SimpleBusToWishboneBridgePlanner())

    reg.register_bus_planner(SimpleBusPlanner(reg))

    reg.register_emitter(QuartusBoardEmitter())
    reg.register_emitter(RtlEmitter(templates_dir))
    reg.register_emitter(TimingEmitter(templates_dir))
    reg.register_emitter(QuartusFilesEmitter())
    reg.register_emitter(SoftwareEmitter(templates_dir))
    reg.register_emitter(DocsEmitter(templates_dir))
    reg.register_emitter(RegisterBlockEmitter(templates_dir))
    reg.register_emitter(PeripheralShellEmitter(templates_dir))
    reg.register_emitter(SimFilelistEmitter())

    reg.register_report(JsonReportEmitter())
    reg.register_report(MarkdownReportEmitter())
    reg.register_report(GraphvizEmitter())

    reg.register_validator(DuplicateModuleInstanceRule())
    reg.register_validator(UnknownIpTypeRule())
    reg.register_validator(UnknownGeneratedClockSourceRule())
    reg.register_validator(UnknownBoardFeatureRule())
    reg.register_validator(UnknownBoardBindingTargetRule())
    reg.register_validator(BoardPinConflictRule())
    reg.register_validator(BoardMuxGroupRule())
    reg.register_validator(VendorIpArtifactExistsRule())
    reg.register_validator(BindingWidthCompatibilityRule())
    reg.register_validator(BoardBindingRule())
    reg.register_validator(UnknownBusFabricRule())
    reg.register_validator(MissingBusInterfaceRule())
    reg.register_validator(DuplicateAddressRegionRule())
    reg.register_validator(MissingBridgeRule(reg))
    reg.register_validator(UnknownCpuTypeRule())
    reg.register_validator(UnknownCpuFabricRule())
    reg.register_validator(CpuDescriptorBusMissingRule())

    return reg
