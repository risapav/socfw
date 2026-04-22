from __future__ import annotations

from socfw.builders.rtl_bus_builder import RtlBusBuilder
from socfw.builders.rtl_bus_connections import RtlBusConnectionResolver
from socfw.builders.rtl_irq_builder import RtlIrqBuilder
from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.rtl import (
    BOARD_CLOCK,
    BOARD_RESET,
    RtlAssign,
    RtlBusConn,
    RtlConn,
    RtlInstance,
    RtlModuleIR,
    RtlPort,
    RtlResetSync,
    RtlWire,
)


class RtlIRBuilder:
    def __init__(self) -> None:
        self.bus_builder = RtlBusBuilder()
        self.bus_conns = RtlBusConnectionResolver()
        self.irq_builder = RtlIrqBuilder()

    def build(self, design: ElaboratedDesign) -> RtlModuleIR:
        system = design.system
        rtl = RtlModuleIR(name="soc_top")

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

        if design.interconnect is not None:
            for iface in self.bus_builder.build_interfaces(design.interconnect):
                rtl.add_interface_once(iface)

            rtl.fabrics.extend(self.bus_builder.build_fabrics(design.interconnect))

            for fabric_name in design.interconnect.fabrics.keys():
                rtl.instances.append(
                    RtlInstance(
                        module="simple_bus_error_slave",
                        name=f"error_{fabric_name}",
                        conns=[],
                        bus_conns=[
                            RtlBusConn(
                                port="bus",
                                interface_name=f"if_error_{fabric_name}",
                                modport="slave",
                            )
                        ],
                        comment=f"error slave for {fabric_name}",
                    )
                )

        # CPU
        cpu_desc = system.cpu_desc()
        if system.cpu is not None and cpu_desc is not None:
            cpu_params = dict(cpu_desc.default_params)
            cpu_params.update(system.cpu.params)

            cpu_conns = [
                RtlConn(port=cpu_desc.clock_port, signal=BOARD_CLOCK),
                RtlConn(port=cpu_desc.reset_port, signal=BOARD_RESET),
            ]

            cpu_bus_conns = []
            if cpu_desc.bus_master is not None and design.interconnect is not None:
                for fabric_name, endpoints in design.interconnect.fabrics.items():
                    for ep in endpoints:
                        if ep.instance == system.cpu.instance:
                            cpu_bus_conns.append(
                                RtlBusConn(
                                    port=cpu_desc.bus_master.port_name,
                                    interface_name=f"if_{ep.instance}_{fabric_name}",
                                    modport="master",
                                )
                            )

            rtl.instances.append(
                RtlInstance(
                    module=cpu_desc.module,
                    name=system.cpu.instance,
                    params=cpu_params,
                    conns=cpu_conns,
                    bus_conns=cpu_bus_conns,
                    comment=system.cpu.type_name,
                )
            )

            for art in cpu_desc.artifacts:
                if art not in rtl.extra_sources:
                    rtl.extra_sources.append(art)

        # RAM
        if system.ram is not None:
            ram_conns = [
                RtlConn(port="SYS_CLK", signal=BOARD_CLOCK),
                RtlConn(port="RESET_N", signal=BOARD_RESET),
            ]

            ram_bus_conns = []
            if design.interconnect is not None:
                for fabric_name, endpoints in design.interconnect.fabrics.items():
                    for ep in endpoints:
                        if ep.instance == "ram":
                            ram_bus_conns.append(
                                RtlBusConn(
                                    port="bus",
                                    interface_name=f"if_ram_{fabric_name}",
                                    modport="slave",
                                )
                            )

            rtl.instances.append(
                RtlInstance(
                    module=system.ram.module,
                    name="ram",
                    params={
                        "RAM_BYTES": system.ram.size,
                        "INIT_FILE": system.ram.init_file or "",
                    },
                    conns=ram_conns,
                    bus_conns=ram_bus_conns,
                    comment=f"RAM @ 0x{system.ram.base:08X}",
                )
            )

        # Project modules
        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            conns: list[RtlConn] = []
            bus_conn_list = self.bus_conns.resolve_for_instance(
                mod=mod,
                ip=ip,
                plan=design.interconnect,
            )

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
                        b for b in design.port_bindings
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

            for irq in ip.meta.get("irqs", []):
                irq_name = str(irq["name"])
                sig = f"irq_{mod.instance}_{irq_name}"
                conns.append(RtlConn(port=f"irq_{irq_name}", signal=sig))

            rtl.instances.append(
                RtlInstance(
                    module=ip.module,
                    name=mod.instance,
                    params=mod.params,
                    conns=conns,
                    bus_conns=bus_conn_list,
                )
            )

            for path in ip.artifacts.synthesis:
                if path not in rtl.extra_sources:
                    rtl.extra_sources.append(path)

        self.irq_builder.build(design, rtl)

        if rtl.irq_combiner is not None and system.cpu is not None and cpu_desc is not None and cpu_desc.irq_port:
            for inst in rtl.instances:
                if inst.name == system.cpu.instance:
                    inst.conns.append(
                        RtlConn(
                            port=cpu_desc.irq_port,
                            signal=rtl.irq_combiner.cpu_irq_signal,
                        )
                    )

        if rtl.fabrics and "src/ip/bus/simple_bus_fabric.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/bus/simple_bus_fabric.sv")

        if rtl.fabrics and "src/ip/bus/simple_bus_error_slave.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/bus/simple_bus_error_slave.sv")

        if rtl.irq_combiner is not None and "src/ip/irq/irq_combiner.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/irq/irq_combiner.sv")

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
