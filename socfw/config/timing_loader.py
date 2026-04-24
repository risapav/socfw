from __future__ import annotations

from pydantic import ValidationError

from socfw.config.aliases import normalize_timing_aliases
from socfw.config.common import load_yaml_file
from socfw.config.timing_schema import TimingDocumentSchema
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result
from socfw.model.timing import (
    ClockGroupConstraint,
    FalsePathConstraint,
    IoDelayOverride,
    TimingGeneratedClock,
    TimingModel,
    TimingPrimaryClock,
)


class TimingLoader:
    def load(self, path: str) -> Result[TimingModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        data = raw.value or {}
        data, alias_diags = normalize_timing_aliases(data, file=path)

        try:
            doc = TimingDocumentSchema.model_validate(data)
        except ValidationError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="TIM100",
                        severity=Severity.ERROR,
                        message=f"Invalid timing YAML: {exc}",
                        subject="timing",
                        spans=(SourceLocation(file=path),),
                    )
                ]
            )

        timing = TimingModel(
            primary_clocks=[
                TimingPrimaryClock(
                    name=c.name,
                    source_port=c.source,
                    period_ns=c.period_ns,
                    uncertainty_ns=c.uncertainty_ns,
                    reset_port=(c.reset.source if c.reset else None),
                    reset_active_low=(c.reset.active_low if c.reset else True),
                    reset_sync_stages=(c.reset.sync_stages if c.reset else 2),
                )
                for c in doc.timing.clocks
            ],
            generated_clocks=[
                TimingGeneratedClock(
                    name=g.name,
                    source_instance=g.source.instance,
                    source_clock=g.source.output,
                    pin_index=g.pin_index,
                    multiply_by=g.multiply_by,
                    divide_by=g.divide_by,
                    phase_shift_ps=g.phase_shift_ps,
                    sync_from=g.reset_sync_from,
                    sync_stages=g.reset_sync_stages,
                )
                for g in doc.timing.generated_clocks
            ],
            clock_groups=[
                ClockGroupConstraint(group_type=g.type, groups=g.groups)
                for g in doc.timing.clock_groups
            ],
            io_auto=doc.timing.io_delays.auto,
            io_default_clock=doc.timing.io_delays.default_clock,
            io_default_input_max_ns=doc.timing.io_delays.default_input_max_ns,
            io_default_output_max_ns=doc.timing.io_delays.default_output_max_ns,
            io_overrides=[
                IoDelayOverride(
                    port=o.port,
                    direction=o.direction,
                    clock=o.clock,
                    max_ns=o.max_ns,
                    min_ns=o.min_ns,
                    comment=o.comment,
                )
                for o in doc.timing.io_delays.overrides
            ],
            false_paths=[
                FalsePathConstraint(
                    from_port=f.from_port,
                    from_clock=f.from_clock,
                    to_clock=f.to_clock,
                    from_cell=f.from_cell,
                    to_cell=f.to_cell,
                    comment=f.comment,
                )
                for f in doc.timing.false_paths
            ],
            derive_uncertainty=doc.timing.derive_uncertainty,
        )

        errs = timing.validate()
        if errs:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="TIM101",
                        severity=Severity.ERROR,
                        message=msg,
                        subject="timing",
                        spans=(SourceLocation(file=path),),
                    )
                    for msg in errs
                ]
            )

        return Result(value=timing, diagnostics=list(alias_diags))
