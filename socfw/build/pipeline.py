from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.manifest import BuildManifest
from socfw.builders.board_ir_builder import BoardIRBuilder
from socfw.builders.rtl_ir_builder import RtlIRBuilder
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
from socfw.validate.rules.project_rules import (
    DuplicateModuleInstanceRule,
    UnknownGeneratedClockSourceRule,
    UnknownIpTypeRule,
)
from socfw.validate.runner import ValidationRunner


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
    peripheral_shell_irs: list[object] = field(default_factory=list)
    design: object | None = None


def _default_validator() -> ValidationRunner:
    return ValidationRunner(
        rules=[
            DuplicateModuleInstanceRule(),
            UnknownIpTypeRule(),
            UnknownGeneratedClockSourceRule(),
            UnknownBoardFeatureRule(),
            UnknownBoardBindingTargetRule(),
            VendorIpArtifactExistsRule(),
            BindingWidthCompatibilityRule(),
        ]
    )


class BuildPipeline:
    def __init__(
        self,
        validator: ValidationRunner | None = None,
        elaborator: Elaborator | None = None,
        ir_builders: dict | None = None,
    ) -> None:
        self.validator = validator or _default_validator()
        self.elaborator = elaborator or Elaborator()
        self.board_ir_builder = BoardIRBuilder()
        self.timing_ir_builder = TimingIRBuilder()
        self.rtl_ir_builder = RtlIRBuilder()
        self._extra_builders = ir_builders or {}

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
        diags.extend(self.validator.run(system))
        return diags

    def run(self, request: BuildRequest, system: SystemModel) -> BuildResult:
        diags = self._validate(system)
        if any(d.severity == Severity.ERROR for d in diags):
            return BuildResult(ok=False, diagnostics=diags)

        design = self.elaborator.elaborate(system)
        ctx = BuildContext(out_dir=Path(request.out_dir))

        board_ir = self.board_ir_builder.build(design)
        timing_ir = self.timing_ir_builder.build(design)
        rtl_ir = self.rtl_ir_builder.build(design)

        result = BuildResult(
            ok=True,
            diagnostics=diags,
            design=design,
            board_ir=board_ir,
            timing_ir=timing_ir,
            rtl_ir=rtl_ir,
        )

        for family, builder in self._extra_builders.items():
            try:
                ir = builder.build(design)
                setattr(result, f"{family}_ir", ir)
            except Exception as e:
                result.diagnostics.append(
                    Diagnostic(
                        code="BLD001",
                        severity=Severity.ERROR,
                        message=f"IR builder '{family}' failed: {e}",
                        subject=f"build.{family}",
                    )
                )
                result.ok = False

        return result
