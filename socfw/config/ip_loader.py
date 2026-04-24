from __future__ import annotations

from pathlib import Path

from pydantic import ValidationError

from socfw.config.common import load_yaml_file
from socfw.config.ip_schema import IpConfigSchema
from socfw.config.schema_errors import ip_schema_error
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result
from socfw.model.ip import (
    IpArtifactBundle,
    IpBusInterface,
    IpClockOutput,
    IpClocking,
    IpDescriptor,
    IpOrigin,
    IpResetSemantics,
    IpVendorInfo,
)


class IpLoader:
    def load_file(self, path: str) -> Result[IpDescriptor]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = IpConfigSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(diagnostics=[ip_schema_error(exc, file=path)])

        base_dir = Path(path).parent

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
                synthesis=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.synthesis),
                simulation=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.simulation),
                metadata=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.metadata),
            ),
            vendor_info=(
                IpVendorInfo(
                    vendor=doc.vendor.vendor,
                    tool=doc.vendor.tool,
                    generator=doc.vendor.generator,
                    family=doc.vendor.family,
                    qip=str((base_dir / doc.vendor.qip).resolve()) if doc.vendor.qip else None,
                    sdc=tuple(str((base_dir / p).resolve()) for p in doc.vendor.sdc),
                    filesets=tuple(doc.vendor.filesets),
                )
                if doc.vendor is not None else None
            ),
            bus_interfaces=tuple(
                IpBusInterface(
                    port_name=b.port_name,
                    protocol=b.protocol,
                    role=b.role,
                    addr_width=b.addr_width,
                    data_width=b.data_width,
                )
                for b in doc.bus_interfaces
            ) or (
                (IpBusInterface(port_name="bus", protocol="simple_bus", role="slave"),)
                if doc.integration.needs_bus
                else ()
            ),
            meta={
                "notes": doc.notes,
                "registers": [
                    {
                        "name": r.name,
                        "offset": r.offset,
                        "width": r.width,
                        "access": r.access,
                        "reset": r.reset,
                        "desc": r.desc,
                        "hw_source": r.hw_source,
                        "write_pulse": r.write_pulse,
                        "clear_on_write": r.clear_on_write,
                        "set_by_hw": r.set_by_hw,
                        "sticky": r.sticky,
                    }
                    for r in doc.registers
                ],
                "irqs": [
                    {"name": irq.name, "id": irq.id}
                    for irq in doc.irqs
                ],
                "shell": (
                    {
                        "module": doc.shell.module,
                        "external_ports": [
                            {
                                "name": p.name,
                                "direction": p.direction,
                                "width": p.width,
                            }
                            for p in doc.shell.external_ports
                        ],
                        "core_ports": [
                            {
                                "kind": cp.kind,
                                "reg_name": cp.reg_name,
                                "signal_name": cp.signal_name,
                                "port_name": cp.port_name,
                            }
                            for cp in doc.shell.core_ports
                        ],
                    }
                    if doc.shell is not None else None
                ),
            },
            source_file=str(Path(path).resolve()),
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
                        spans=(SourceLocation(file=path),),
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
                        spans=(SourceLocation(file=root),),
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
                                spans=(SourceLocation(file=str(fp)),),
                            )
                        )
                    else:
                        catalog[ip.name] = ip

        return Result(value=catalog, diagnostics=diags)
