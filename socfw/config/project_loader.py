from __future__ import annotations

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.project_schema import ModuleClockPortSchema, ProjectConfigSchema
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result
from socfw.model.cpu import CpuBusMaster, CpuModel
from socfw.model.memory import RamModel
from socfw.model.project import (
    ClockBinding,
    GeneratedClockRequest,
    ModuleInstance,
    PortBinding,
    ProjectModel,
)


class ProjectLoader:
    def load(self, path: str) -> Result[dict]:
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

        cpu = None
        if doc.cpu is not None:
            cpu = CpuModel(
                cpu_type=doc.cpu.type,
                module=doc.cpu.module,
                params=doc.cpu.params,
                clock_port=doc.cpu.clock_port,
                reset_port=doc.cpu.reset_port,
                irq_port=doc.cpu.irq_port,
                bus_master=(
                    CpuBusMaster(
                        port_name=doc.cpu.bus_master_port,
                        protocol=doc.cpu.bus_protocol,
                        addr_width=doc.cpu.addr_width,
                        data_width=doc.cpu.data_width,
                    )
                    if doc.cpu.bus_master_port
                    else None
                ),
            )

        ram = None
        if doc.ram is not None:
            ram = RamModel(
                module=doc.ram.module,
                base=doc.ram.base,
                size=doc.ram.size,
                data_width=doc.ram.data_width,
                addr_width=doc.ram.addr_width,
                latency=doc.ram.latency,
                init_file=doc.ram.init_file,
                image_format=doc.ram.image_format,
            )

        return Result(
            value={
                "project": model,
                "cpu": cpu,
                "ram": ram,
                "reset_vector": doc.boot.reset_vector,
                "stack_percent": doc.boot.stack_percent,
            }
        )
