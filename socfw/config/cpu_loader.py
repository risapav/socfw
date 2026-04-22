from __future__ import annotations

from pathlib import Path

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.cpu_schema import CpuDescriptorSchema
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result
from socfw.model.cpu_desc import CpuBusMasterDesc, CpuDescriptor


class CpuLoader:
    def load_file(self, path: str) -> Result[CpuDescriptor]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = CpuDescriptorSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="CPU100",
                        severity=Severity.ERROR,
                        message=f"Invalid CPU YAML: {exc}",
                        subject="cpu",
                        locations=(SourceLocation(file=path),),
                    )
                ]
            )

        desc = CpuDescriptor(
            name=doc.cpu.name,
            module=doc.cpu.module,
            family=doc.cpu.family,
            clock_port=doc.clock_port,
            reset_port=doc.reset_port,
            irq_port=doc.irq_port,
            bus_master=(
                CpuBusMasterDesc(
                    port_name=doc.bus_master.port_name,
                    protocol=doc.bus_master.protocol,
                    addr_width=doc.bus_master.addr_width,
                    data_width=doc.bus_master.data_width,
                )
                if doc.bus_master else None
            ),
            default_params=dict(doc.default_params),
            artifacts=tuple(doc.artifacts),
            meta={"notes": doc.notes},
        )

        return Result(value=desc)

    def load_catalog(self, search_dirs: list[str]) -> Result[dict[str, CpuDescriptor]]:
        catalog: dict[str, CpuDescriptor] = {}
        diags: list[Diagnostic] = []

        for root in search_dirs:
            p = Path(root)
            if not p.exists():
                continue

            for fp in sorted(p.rglob("*.cpu.yaml")):
                res = self.load_file(str(fp))
                diags.extend(res.diagnostics)
                if res.ok and res.value is not None:
                    if res.value.name in catalog:
                        diags.append(
                            Diagnostic(
                                code="CPU101",
                                severity=Severity.ERROR,
                                message=f"Duplicate CPU descriptor '{res.value.name}'",
                                subject="cpu.registry",
                                locations=(SourceLocation(file=str(fp)),),
                            )
                        )
                    else:
                        catalog[res.value.name] = res.value

        return Result(value=catalog, diagnostics=diags)
