from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.manifest import BuildManifest
from socfw.builders.board_ir_builder import BoardIRBuilder
from socfw.builders.docs_ir_builder import DocsIRBuilder
from socfw.builders.register_block_ir_builder import RegisterBlockIRBuilder
from socfw.builders.rtl_ir_builder import RtlIRBuilder
from socfw.builders.software_ir_builder import SoftwareIRBuilder
from socfw.builders.timing_ir_builder import TimingIRBuilder
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.elaborate.planner import Elaborator
from socfw.model.system import SystemModel
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


@dataclass
class BuildResult:
    ok: bool
    diagnostics: list[Diagnostic] = field(default_factory=list)
    manifest: BuildManifest = field(default_factory=BuildManifest)
    board_ir: object | None = None
    timing_ir: object | None = None
    rtl_ir: object | None = None
    software_ir: object | None = None
    docs_ir: object | None = None
    register_block_irs: list[object] = field(default_factory=list)
    design: object | None = None


class BuildPipeline:
    def __init__(self) -> None:
        self.rules = [
            DuplicateModuleInstanceRule(),
            UnknownIpTypeRule(),
            UnknownGeneratedClockSourceRule(),
            UnknownBoardFeatureRule(),
            UnknownBoardBindingTargetRule(),
            VendorIpArtifactExistsRule(),
            BindingWidthCompatibilityRule(),
            UnknownBusFabricRule(),
            MissingBusInterfaceRule(),
            DuplicateAddressRegionRule(),
            FabricProtocolMismatchRule(),
        ]
        self.elaborator = Elaborator()
        self.board_ir_builder = BoardIRBuilder()
        self.timing_ir_builder = TimingIRBuilder()
        self.rtl_ir_builder = RtlIRBuilder()
        self.software_ir_builder = SoftwareIRBuilder()
        self.docs_ir_builder = DocsIRBuilder()
        self.regblk_ir_builder = RegisterBlockIRBuilder()

    def _validate(self, system: SystemModel) -> list[Diagnostic]:
        diags: list[Diagnostic] = []

        for msg in system.validate():
            diags.append(
                Diagnostic(
                    code="SYS001",
                    severity=Severity.ERROR,
                    message=msg,
                    subject="system",
                )
            )

        for rule in self.rules:
            diags.extend(rule.validate(system))

        return diags

    def run(self, request: BuildRequest, system: SystemModel) -> BuildResult:
        diags = self._validate(system)
        if any(d.severity == Severity.ERROR for d in diags):
            return BuildResult(ok=False, diagnostics=diags)

        design = self.elaborator.elaborate(system)

        board_ir = self.board_ir_builder.build(design)
        timing_ir = self.timing_ir_builder.build(design)
        rtl_ir = self.rtl_ir_builder.build(design)
        software_ir = self.software_ir_builder.build(design)
        docs_ir = self.docs_ir_builder.build(design)

        regblk_irs = []
        for p in system.peripheral_blocks:
            regblk = self.regblk_ir_builder.build_for_peripheral(p)
            if regblk is not None:
                regblk_irs.append(regblk)

        return BuildResult(
            ok=True,
            diagnostics=diags,
            board_ir=board_ir,
            timing_ir=timing_ir,
            rtl_ir=rtl_ir,
            software_ir=software_ir,
            docs_ir=docs_ir,
            register_block_irs=regblk_irs,
            design=design,
        )
