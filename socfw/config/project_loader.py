from __future__ import annotations

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.normalizers.project import normalize_project_document
from socfw.config.project_schema import ModuleClockPortSchema, ProjectConfigSchema
from socfw.config.schema_errors import project_schema_error
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result
from socfw.model.cpu import CpuInstance
from socfw.model.firmware import FirmwareModel
from socfw.model.memory import RamModel
from socfw.model.project import (
    BusAttach,
    BusFabricRequest,
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

        data = raw.value or {}
        norm = normalize_project_document(data, file=path)
        data = norm.data
        alias_diags = norm.diagnostics

        try:
            doc = ProjectConfigSchema.model_validate(data)
        except ValidationError as exc:
            return Result(diagnostics=[project_schema_error(exc, file=path)])

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
                    bus=(
                        BusAttach(
                            fabric=m.bus.fabric,
                            base=m.bus.base,
                            size=m.bus.size,
                        )
                        if m.bus
                        else None
                    ),
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
            registries_packs=doc.registries.packs,
            registries_cpu=doc.registries.cpu,
            feature_refs=doc.features.use,
            modules=modules,
            primary_clock_domain=doc.clocks.primary.domain,
            generated_clocks=gen_clocks,
            timing_file=(doc.timing.file if doc.timing else None),
            debug=doc.project.debug,
            bus_fabrics=[
                BusFabricRequest(
                    name=b.name,
                    protocol=b.protocol,
                    addr_width=b.addr_width,
                    data_width=b.data_width,
                )
                for b in doc.buses
            ],
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
                        spans=(SourceLocation(file=path),),
                    )
                    for msg in errs
                ]
            )

        cpu = None
        if doc.cpu is not None:
            cpu = CpuInstance(
                instance=doc.cpu.instance,
                type_name=doc.cpu.type,
                fabric=doc.cpu.fabric,
                reset_vector=doc.cpu.reset_vector,
                params=doc.cpu.params,
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

        firmware = None
        if doc.firmware is not None:
            firmware = FirmwareModel(
                enabled=doc.firmware.enabled,
                src_dir=doc.firmware.src_dir,
                out_dir=doc.firmware.out_dir,
                linker_script=doc.firmware.linker_script,
                elf_file=doc.firmware.elf_file,
                bin_file=doc.firmware.bin_file,
                hex_file=doc.firmware.hex_file,
                tool_prefix=doc.firmware.tool_prefix,
                cflags=list(doc.firmware.cflags),
                ldflags=list(doc.firmware.ldflags),
            )

        return Result(
            value={
                "project": model,
                "cpu": cpu,
                "ram": ram,
                "firmware": firmware,
                "reset_vector": doc.boot.reset_vector,
                "stack_percent": doc.boot.stack_percent,
            },
            diagnostics=list(alias_diags),
        )
