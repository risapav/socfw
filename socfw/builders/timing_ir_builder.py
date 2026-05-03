from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.timing import (
    ClockConstraint,
    FalsePathConstraintIR,
    GeneratedClockConstraint,
    IoDelayConstraintIR,
    TimingIR,
)


class TimingIRBuilder:
    def build(self, design: ElaboratedDesign) -> TimingIR:
        system = design.system
        timing = system.timing

        ir = TimingIR()
        if timing is None:
            return ir

        ir.derive_uncertainty = timing.derive_uncertainty

        for clk in timing.primary_clocks:
            ir.clocks.append(
                ClockConstraint(
                    name=clk.name,
                    source_port=clk.source_port,
                    period_ns=clk.period_ns,
                    uncertainty_ns=clk.uncertainty_ns,
                )
            )
            if clk.reset_port:
                ir.false_paths.append(
                    FalsePathConstraintIR(
                        from_port=clk.reset_port,
                        comment=f"Async reset for domain {clk.name}",
                    )
                )

        for gclk in timing.generated_clocks:
            ir.generated_clocks.append(
                GeneratedClockConstraint(
                    name=gclk.name,
                    source_instance=gclk.source_instance,
                    source_output=gclk.source_clock,
                    source_clock=gclk.source_clock,
                    multiply_by=gclk.multiply_by,
                    divide_by=gclk.divide_by,
                    pin_index=gclk.pin_index,
                    phase_shift_ps=gclk.phase_shift_ps,
                )
            )
            if gclk.sync_from:
                ir.false_paths.append(
                    FalsePathConstraintIR(
                        from_clock=gclk.sync_from,
                        to_clock=gclk.name,
                        comment=(
                            f"CDC reset sync: {gclk.sync_from} -> {gclk.name} "
                            f"({gclk.sync_stages or 2}-stage FF)"
                        ),
                    )
                )

        for grp in timing.clock_groups:
            ir.clock_groups.append({"type": grp.group_type, "groups": grp.groups})

        for fp in timing.false_paths:
            ir.false_paths.append(
                FalsePathConstraintIR(
                    from_port=fp.from_port,
                    to_port=fp.to_port,
                    from_clock=fp.from_clock,
                    to_clock=fp.to_clock,
                    from_cell=fp.from_cell,
                    to_cell=fp.to_cell,
                    comment=fp.comment,
                )
            )

        if timing.io_auto:
            override_ports = {ov.port for ov in timing.io_overrides}
            default_clock = timing.io_default_clock

            for binding in design.port_bindings:
                for ext in binding.resolved:
                    if ext.top_name in override_ports:
                        continue
                    direction = "input" if ext.direction == "input" else "output"
                    max_ns = (
                        timing.io_default_input_max_ns
                        if direction == "input"
                        else timing.io_default_output_max_ns
                    )
                    if default_clock and max_ns is not None:
                        ir.io_delays.append(
                            IoDelayConstraintIR(
                                port=ext.top_name,
                                direction=direction,
                                clock=default_clock,
                                max_ns=max_ns,
                                comment=f"{binding.instance}.{binding.port_name}",
                            )
                        )

        for ov in timing.io_overrides:
            ir.io_delays.append(
                IoDelayConstraintIR(
                    port=ov.port,
                    direction=ov.direction,
                    clock=ov.clock,
                    max_ns=ov.max_ns,
                    min_ns=ov.min_ns,
                    comment=ov.comment,
                )
            )

        return ir
