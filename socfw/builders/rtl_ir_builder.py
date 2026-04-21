from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.rtl import (
    BOARD_CLOCK,
    BOARD_RESET,
    RtlAssign,
    RtlConn,
    RtlInstance,
    RtlModule,
    RtlPort,
    RtlResetSync,
    RtlWire,
)


class RtlIRBuilder:
    def build(self, design: ElaboratedDesign) -> RtlModule:
        system = design.system
        rtl = RtlModule(name="soc_top")

        rtl.add_port_once(RtlPort(name=BOARD_CLOCK, direction="input", width=1))
        rtl.add_port_once(RtlPort(name=BOARD_RESET, direction="input", width=1))

        for binding in design.port_bindings:
            for ext in binding.resolved:
                rtl.add_port_once(
                    RtlPort(
                        name=ext.top_name,
                        direction=ext.direction,
                        width=ext.width,
                    )
                )

        for dom in design.clock_domains:
            if dom.reset_policy == "synced" and dom.name != system.project.primary_clock_domain:
                rst_out = f"rst_n_{dom.name}"
                rtl.add_wire_once(RtlWire(name=dom.name, width=1, comment="clock domain"))
                rtl.add_wire_once(RtlWire(name=rst_out, width=1, comment="reset sync output"))
                rtl.reset_syncs.append(
                    RtlResetSync(
                        name=f"u_rst_sync_{dom.name}",
                        stages=dom.sync_stages or 2,
                        clk_signal=dom.name,
                        rst_out=rst_out,
                    )
                )
            elif dom.source_kind == "generated":
                rtl.add_wire_once(RtlWire(name=dom.name, width=1, comment="generated clock"))

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            conns: list[RtlConn] = []

            for cb in mod.clocks:
                signal = cb.domain
                if cb.domain == system.project.primary_clock_domain:
                    signal = BOARD_CLOCK
                conns.append(RtlConn(port=cb.port_name, signal=signal))

                if not cb.no_reset and ip.reset.port:
                    rst_sig = (
                        BOARD_RESET
                        if cb.domain == system.project.primary_clock_domain
                        else f"rst_n_{cb.domain}"
                    )
                    if ip.reset.active_high:
                        rst_sig = f"~{rst_sig}"
                    conns.append(RtlConn(port=ip.reset.port, signal=rst_sig))

            for binding in mod.port_bindings:
                resolved = next(
                    (
                        b
                        for b in design.port_bindings
                        if b.instance == mod.instance and b.port_name == binding.port_name
                    ),
                    None,
                )
                if resolved is None:
                    continue

                if len(resolved.resolved) == 1:
                    ext = resolved.resolved[0]
                    needs_adapter = binding.width is not None and binding.width != ext.width
                    if not needs_adapter:
                        conns.append(RtlConn(port=binding.port_name, signal=ext.top_name))
                    else:
                        wire_name = f"w_{mod.instance}_{binding.port_name}"
                        src_w = ext.width
                        dst_w = binding.width
                        rtl.add_wire_once(
                            RtlWire(
                                name=wire_name,
                                width=src_w,
                                comment=(
                                    f"adapter: {binding.port_name} "
                                    f"{src_w}b->{dst_w}b ({binding.adapt or 'zero'})"
                                ),
                            )
                        )
                        conns.append(RtlConn(port=binding.port_name, signal=wire_name))
                        if ext.direction == "input":
                            rtl.assigns.append(
                                RtlAssign(
                                    lhs=wire_name,
                                    rhs=f"{ext.top_name}[{min(src_w, dst_w) - 1}:0]",
                                    direction="input",
                                    comment="input truncate",
                                )
                            )
                        else:
                            rtl.assigns.append(
                                RtlAssign(
                                    lhs=ext.top_name,
                                    rhs=self._pad_rhs(
                                        wire=wire_name,
                                        src_w=src_w,
                                        dst_w=dst_w,
                                        pad_mode=binding.adapt or "zero",
                                    ),
                                    direction="output",
                                    comment=f"{binding.adapt or 'zero'} pad",
                                )
                            )
                else:
                    for ext in resolved.resolved:
                        conns.append(RtlConn(port=ext.top_name, signal=ext.top_name))

            rtl.instances.append(
                RtlInstance(
                    module=ip.module,
                    name=mod.instance,
                    params=mod.params,
                    conns=conns,
                )
            )

            for path in ip.artifacts.synthesis:
                if path not in rtl.extra_sources:
                    rtl.extra_sources.append(path)

        return rtl

    def _pad_rhs(self, *, wire: str, src_w: int, dst_w: int, pad_mode: str) -> str:
        if dst_w > src_w:
            pad = dst_w - src_w
            if pad_mode == "replicate":
                return f"{{ {{{pad}{{ {wire}[{src_w - 1}] }} }}, {wire} }}"
            if pad_mode == "high_z":
                return f"{{ {pad}'bz, {wire} }}"
            return f"{{ {pad}'b0, {wire} }}"
        return f"{wire}[{dst_w - 1}:0]"
