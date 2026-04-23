from __future__ import annotations

from socfw.build.pipeline import BuildResult
from socfw.elaborate.design import ElaboratedDesign
from socfw.reports.model import (
    BuildReport,
    PlanningDecision,
    ReportAddressRegion,
    ReportArtifact,
    ReportBusEndpoint,
    ReportClockDomain,
    ReportDiagnostic,
    ReportIrqSource,
)


class BuildReportBuilder:
    def build(
        self,
        *,
        system,
        design: ElaboratedDesign | None,
        result: BuildResult,
    ) -> BuildReport:
        report = BuildReport(
            project_name=system.project.name,
            board_name=system.board.board_id,
            cpu_type=system.cpu_type,
            ram_base=system.ram_base,
            ram_size=system.ram_size,
            reset_vector=system.reset_vector,
        )

        for d in result.diagnostics:
            report.diagnostics.append(
                ReportDiagnostic(
                    code=d.code,
                    severity=d.severity.value if hasattr(d.severity, "value") else str(d.severity),
                    message=d.message,
                    subject=d.subject,
                    category=getattr(d, "category", "general"),
                    detail=getattr(d, "detail", None),
                    hints=tuple(getattr(d, "hints", ())),
                )
            )

        for a in result.manifest.artifacts:
            report.artifacts.append(
                ReportArtifact(
                    family=a.family,
                    path=a.path,
                    generator=a.generator,
                )
            )

        if design is not None:
            for clk in design.clock_domains:
                report.clocks.append(
                    ReportClockDomain(
                        name=clk.name,
                        frequency_hz=clk.frequency_hz,
                        source_kind=clk.source_kind,
                        source_ref=clk.source_ref,
                        reset_policy=clk.reset_policy,
                        sync_from=clk.sync_from,
                        sync_stages=clk.sync_stages,
                    )
                )

            if system.ram is not None:
                report.address_regions.append(
                    ReportAddressRegion(
                        name="RAM",
                        base=system.ram.base,
                        end=system.ram.base + system.ram.size - 1,
                        size=system.ram.size,
                        kind="memory",
                        module=system.ram.module,
                    )
                )

            for p in system.peripheral_blocks:
                report.address_regions.append(
                    ReportAddressRegion(
                        name=p.instance,
                        base=p.base,
                        end=p.end,
                        size=p.size,
                        kind="peripheral",
                        module=p.module,
                    )
                )

            if design.irq_plan is not None:
                for src in design.irq_plan.sources:
                    report.irq_sources.append(
                        ReportIrqSource(
                            instance=src.instance,
                            signal=src.signal_name,
                            irq_id=src.irq_id,
                        )
                    )

            if design.interconnect is not None:
                for fabric, endpoints in design.interconnect.fabrics.items():
                    for ep in endpoints:
                        report.bus_endpoints.append(
                            ReportBusEndpoint(
                                fabric=fabric,
                                instance=ep.instance,
                                module_type=ep.module_type,
                                protocol=ep.protocol,
                                role=ep.role,
                                port_name=ep.port_name,
                                base=ep.base,
                                end=ep.end,
                                size=ep.size,
                            )
                        )

            report.decisions.extend(self._build_decisions(system, design))

        return report

    def _build_decisions(self, system, design: ElaboratedDesign) -> list[PlanningDecision]:
        decisions: list[PlanningDecision] = []

        if design.interconnect is not None:
            for fabric, endpoints in design.interconnect.fabrics.items():
                proto = endpoints[0].protocol if endpoints else "unknown"
                decisions.append(
                    PlanningDecision(
                        category="bus",
                        message=f"Built fabric '{fabric}' with protocol '{proto}'",
                        rationale="Fabric protocol selected from project bus_fabrics configuration",
                        related=(fabric, proto),
                    )
                )

        for clk in design.clock_domains:
            decisions.append(
                PlanningDecision(
                    category="clock",
                    message=f"Resolved clock domain '{clk.name}' from {clk.source_kind}",
                    rationale=f"Clock domain source resolved from '{clk.source_ref}'",
                    related=(clk.name, clk.source_ref),
                )
            )

        if design.irq_plan is not None and design.irq_plan.sources:
            decisions.append(
                PlanningDecision(
                    category="irq",
                    message=f"Built IRQ plan with width {design.irq_plan.width}",
                    rationale="IRQ width derived from max peripheral IRQ id",
                    related=tuple(src.instance for src in design.irq_plan.sources),
                )
            )

        if system.ram is not None:
            decisions.append(
                PlanningDecision(
                    category="memory",
                    message=f"Configured RAM region at 0x{system.ram.base:08X} size {system.ram.size}",
                    rationale="RAM model taken from project memory configuration",
                    related=("RAM", system.ram.module),
                )
            )

        return decisions
