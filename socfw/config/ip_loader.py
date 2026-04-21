from __future__ import annotations

from pathlib import Path

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.ip_schema import IpConfigSchema
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result
from socfw.model.ip import (
    IpArtifactBundle,
    IpClockOutput,
    IpClocking,
    IpDescriptor,
    IpOrigin,
    IpResetSemantics,
)


class IpLoader:
    def load_file(self, path: str) -> Result[IpDescriptor]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = IpConfigSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="IP100",
                        severity=Severity.ERROR,
                        message=f"Invalid IP YAML: {exc}",
                        subject="ip",
                        locations=(SourceLocation(file=path),),
                    )
                ]
            )

        ip = IpDescriptor(
            name=doc.ip.name,
            module=doc.ip.module,
            category=doc.ip.category,
            origin=IpOrigin(
                kind=doc.origin.kind,
                tool=doc.origin.tool,
                packaging=doc.origin.packaging,
            ),
            needs_bus=doc.integration.needs_bus,
            generate_registers=doc.integration.generate_registers,
            instantiate_directly=doc.integration.instantiate_directly,
            dependency_only=doc.integration.dependency_only,
            reset=IpResetSemantics(
                port=doc.reset.port,
                active_high=doc.reset.active_high,
                bypass_sync=doc.reset.bypass_sync,
                optional=doc.reset.optional,
                asynchronous=doc.reset.asynchronous,
            ),
            clocking=IpClocking(
                primary_input_port=doc.clocking.primary_input_port,
                additional_input_ports=tuple(doc.clocking.additional_input_ports),
                outputs=tuple(
                    IpClockOutput(
                        port=o.port,
                        kind=o.kind,
                        default_domain=o.default_domain or o.domain,
                        signal_name=o.signal_name,
                    )
                    for o in doc.clocking.outputs
                ),
            ),
            artifacts=IpArtifactBundle(
                synthesis=tuple(doc.artifacts.synthesis),
                simulation=tuple(doc.artifacts.simulation),
                metadata=tuple(doc.artifacts.metadata),
            ),
            meta={"notes": doc.notes},
        )

        errs = ip.validate()
        if errs:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="IP101",
                        severity=Severity.ERROR,
                        message=msg,
                        subject="ip",
                        locations=(SourceLocation(file=path),),
                    )
                    for msg in errs
                ]
            )

        return Result(value=ip)

    def load_catalog(self, search_dirs: list[str]) -> Result[dict[str, IpDescriptor]]:
        catalog: dict[str, IpDescriptor] = {}
        diags: list[Diagnostic] = []

        for root in search_dirs:
            p = Path(root)
            if not p.exists():
                diags.append(
                    Diagnostic(
                        code="IP102",
                        severity=Severity.WARNING,
                        message=f"IP registry path does not exist: {root}",
                        subject="ip.registry",
                        locations=(SourceLocation(file=root),),
                    )
                )
                continue

            for fp in sorted(p.rglob("*.ip.yaml")):
                res = self.load_file(str(fp))
                diags.extend(res.diagnostics)
                if res.ok and res.value is not None:
                    ip = res.value
                    if ip.name in catalog:
                        diags.append(
                            Diagnostic(
                                code="IP103",
                                severity=Severity.ERROR,
                                message=f"Duplicate IP descriptor name '{ip.name}'",
                                subject="ip.registry",
                                locations=(SourceLocation(file=str(fp)),),
                            )
                        )
                    else:
                        catalog[ip.name] = ip

        return Result(value=catalog, diagnostics=diags)
