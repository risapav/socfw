from __future__ import annotations

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.project_schema import ModuleClockPortSchema, ProjectConfigSchema
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result
from socfw.model.project import (
    ClockBinding,
    GeneratedClockRequest,
    ModuleInstance,
    PortBinding,
    ProjectModel,
)


class ProjectLoader:
    def load(self, path: str) -> Result[ProjectModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = ProjectConfigSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="PRJ100",
                        severity=Severity.ERROR,
                        message=f"Invalid project YAML: {exc}",
                        subject="project",
                        locations=(SourceLocation(file=path),),
                    )
                ]
            )

        modules: list[ModuleInstance] = []
        for m in doc.modules:
            clocks: list[ClockBinding] = []
            for port_name, value in m.clocks.items():
                if isinstance(value, str):
                    clocks.append(ClockBinding(port_name=port_name, domain=value))
                else:
                    clocks.append(
                        ClockBinding(
                            port_name=port_name,
                            domain=value.domain,
                            no_reset=value.no_reset,
                        )
                    )

            port_bindings = [
                PortBinding(
                    port_name=port_name,
                    target=b.target,
                    top_name=b.top_name,
                    width=b.width,
                    adapt=b.adapt,
                )
                for port_name, b in m.bind.ports.items()
            ]

            modules.append(
                ModuleInstance(
                    instance=m.instance,
                    type_name=m.type,
                    params=m.params,
                    clocks=clocks,
                    port_bindings=port_bindings,
                )
            )

        gen_clocks = [
            GeneratedClockRequest(
                domain=g.domain,
                source_instance=g.source.instance,
                source_output=g.source.output,
                frequency_hz=g.frequency_hz,
                sync_from=(g.reset.sync_from if g.reset and not g.reset.none else None),
                sync_stages=(g.reset.sync_stages if g.reset and not g.reset.none else None),
                no_reset=(g.reset.none if g.reset else False),
            )
            for g in doc.clocks.generated
        ]

        model = ProjectModel(
            name=doc.project.name,
            mode=doc.project.mode,
            board_ref=doc.project.board,
            board_file=doc.project.board_file,
            registries_ip=doc.registries.ip,
            feature_refs=doc.features.use,
            modules=modules,
            primary_clock_domain=doc.clocks.primary.domain,
            generated_clocks=gen_clocks,
            timing_file=(doc.timing.file if doc.timing else None),
            debug=doc.project.debug,
        )

        errs = model.validate()
        if errs:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="PRJ101",
                        severity=Severity.ERROR,
                        message=msg,
                        subject="project",
                        locations=(SourceLocation(file=path),),
                    )
                    for msg in errs
                ]
            )

        return Result(value=model)
