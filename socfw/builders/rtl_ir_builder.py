from __future__ import annotations

from socfw.core.expr_eval import resolve_port_width



def _port_dir_str(direction) -> str:
    """Convert PortDir enum or string to 'input'/'output' string."""
    v = getattr(direction, "value", direction)
    return str(v) if v in ("input", "output") else "output"


class RtlIrBuilder:
    """Native RTL IR builder — assembles RtlTop from planned bridges and project modules."""

    def build(self, *, system, planned_bridges, design=None) -> "RtlTop":
        from socfw.ir.rtl import RtlConnection, RtlInstance, RtlTop

        top = RtlTop(module_name="soc_top")

        if system is not None:
            needs_reset = self._any_ip_needs_reset(system, planned_bridges)
            self._add_basic_clock_reset_nets(system, top, needs_reset)
            self._add_board_bound_ports(system, top, design)
            self._add_project_module_instances(system, top, design)
            self._apply_reset_driver(system, top)
        self._add_bridge_instances(planned_bridges, top, system)

        top.ports = sorted(top.ports, key=lambda p: p.name)
        top.signals = self._dedup_signals(top.signals)
        top.instances = sorted(top.instances, key=lambda i: i.instance)
        return top

    def _dedup_signals(self, signals) -> list:
        by_name: dict = {}
        for s in signals:
            by_name[s.name] = s
        return sorted(by_name.values(), key=lambda s: s.name)

    def _any_ip_needs_reset(self, system, planned_bridges) -> bool:
        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is not None and ip.reset.port:
                return True
        if planned_bridges:
            return True
        return False

    def _add_basic_clock_reset_nets(self, system, top, needs_reset: bool = True) -> None:
        from socfw.ir.rtl import RtlAdaptAssign, RtlPort, RtlSignal

        clk_name = system.board.sys_clock.top_name
        top.ports.append(RtlPort(name=clk_name, direction="input", width=1))

        if not needs_reset:
            return

        has_reset_driver = bool(getattr(system.project, "reset_driver", None))

        if system.board.sys_reset is not None:
            rst_name = system.board.sys_reset.top_name
            top.ports.append(RtlPort(name=rst_name, direction="input", width=1))
            top.signals.append(RtlSignal(name="reset_n", width=1))
            if not has_reset_driver:
                if system.board.sys_reset.active_low:
                    top.adapt_assigns.append(RtlAdaptAssign(lhs="reset_n", rhs=rst_name))
                else:
                    top.adapt_assigns.append(RtlAdaptAssign(lhs="reset_n", rhs=f"~{rst_name}"))
        else:
            top.signals.append(RtlSignal(name="reset_n", width=1))

    def _inject_reset_driver_wire(self, system, top, conn_map: dict) -> None:
        """Pre-register the reset_driver output wire so it appears in instance connections."""
        from socfw.ir.rtl import RtlSignal

        reset_driver = getattr(system.project, "reset_driver", None)
        if not reset_driver:
            return
        parts = reset_driver.split(".", 1)
        if len(parts) != 2:
            return
        inst, port = parts
        wire_name = f"w_{inst}_{port}"
        if not any(s.name == wire_name for s in top.signals):
            top.signals.append(RtlSignal(name=wire_name, width=1))
        conn_map[(inst, port)] = wire_name

    def _apply_reset_driver(self, system, top) -> None:
        """Wire the reset_driver output to reset_n after all instances are built."""
        from socfw.ir.rtl import RtlAdaptAssign

        reset_driver = getattr(system.project, "reset_driver", None)
        if not reset_driver:
            return
        parts = reset_driver.split(".", 1)
        if len(parts) != 2:
            return
        inst, port = parts
        wire_name = f"w_{inst}_{port}"
        top.adapt_assigns.append(RtlAdaptAssign(lhs="reset_n", rhs=wire_name))

    def _add_board_bound_ports(self, system, top, design) -> None:
        from socfw.ir.rtl import RtlPort

        seen: set[str] = set()

        if design is not None:
            for binding in design.port_bindings:
                for ext in binding.resolved:
                    if ext.top_name not in seen:
                        top.ports.append(
                            RtlPort(
                                name=ext.top_name,
                                direction=ext.direction,
                                width=ext.width,
                            )
                        )
                        seen.add(ext.top_name)
        else:
            from socfw.model.board import BoardResource, BoardVectorSignal, BoardScalarSignal
            for mod in system.project.modules:
                for pb in mod.port_bindings:
                    if not pb.target.startswith("board:"):
                        continue
                    try:
                        ref_obj = system.board.resolve_ref(pb.target)
                    except (KeyError, Exception):
                        continue

                    if isinstance(ref_obj, BoardResource):
                        sig = ref_obj.default_signal()
                        if sig is None:
                            continue
                        res_name = sig.top_name
                        res_width = sig.width if isinstance(sig, BoardVectorSignal) else 1
                        direction = _port_dir_str(getattr(sig, "direction", "output"))
                    elif isinstance(ref_obj, dict):
                        res_name = ref_obj.get("top_name") or ""
                        if not res_name:
                            continue
                        res_width = int(ref_obj.get("width", 1))
                        direction = _port_dir_str(ref_obj.get("direction", "output"))
                    else:
                        res_name = ref_obj.top_name
                        res_width = getattr(ref_obj, "width", 1)
                        direction = _port_dir_str(getattr(ref_obj, "direction", "output"))

                    name = pb.top_name or res_name
                    width = pb.width if pb.width is not None else res_width
                    if name in seen:
                        continue
                    top.ports.append(RtlPort(name=name, direction=direction, width=width))
                    seen.add(name)

    def _build_connection_wires(self, system, top) -> dict[tuple[str, str], str]:
        """Create wires for module-to-module connections; return (instance, port) -> wire_name."""
        from socfw.ir.rtl import RtlSignal

        conn_map: dict[tuple[str, str], str] = {}
        for conn in system.project.connections:
            wire_name = f"w_{conn.from_instance}_{conn.from_port}"
            conn_map[(conn.from_instance, conn.from_port)] = wire_name
            conn_map[(conn.to_instance, conn.to_port)] = wire_name

            if not any(s.name == wire_name for s in top.signals):
                src_ip = None
                for mod in system.project.modules:
                    if mod.instance == conn.from_instance:
                        src_ip = system.ip_catalog.get(mod.type_name)
                        break
                width = 1
                if src_ip:
                    for p in (src_ip.ports or []):
                        if p.name == conn.from_port:
                            width = p.width
                            break
                top.signals.append(RtlSignal(name=wire_name, width=width))
        return conn_map

    def _add_project_module_instances(self, system, top, design) -> None:
        from socfw.clock.domain_resolver import build_resolver
        from socfw.ir.rtl import RtlAdaptAssign, RtlConnection, RtlInstance, RtlParameter, RtlSignal

        resolver = build_resolver(system.board, system.project)
        conn_map = self._build_connection_wires(system, top)
        self._inject_reset_driver_wire(system, top, conn_map)

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            explicit: dict[str, str] = {}
            port_widths: dict[str, int] = {
                p.name: resolve_port_width(p, mod.params or {})
                for p in (ip.ports or [])
            }
            port_dirs: dict[str, str] = {p.name: p.direction for p in (ip.ports or [])}

            for cb in mod.clocks:
                explicit[cb.port_name] = resolver.net_for_domain(cb.domain)

            for (inst, port), wire in conn_map.items():
                if inst == mod.instance:
                    explicit[port] = wire

            reset_override = getattr(mod, "reset_override", "auto")
            if reset_override == "auto":
                if ip.reset.port:
                    rst = "~reset_n" if ip.reset.active_high else "reset_n"
                    explicit[ip.reset.port] = rst
            elif reset_override is not None:
                if ip.reset.port:
                    explicit[ip.reset.port] = reset_override

            # Wire clocking IP outputs to <instance>_<output> nets
            if ip.clocking and ip.clocking.outputs:
                for out in ip.clocking.outputs:
                    net = f"{mod.instance}_{out.port}"
                    explicit[out.port] = net
                    if not any(s.name == net for s in top.signals):
                        top.signals.append(RtlSignal(name=net, width=1))

            for pb in mod.port_bindings:
                if design is not None:
                    resolved = next(
                        (
                            b for b in design.port_bindings
                            if b.instance == mod.instance and b.port_name == pb.port_name
                        ),
                        None,
                    )
                    if resolved and resolved.resolved:
                        ext = resolved.resolved[0]
                        explicit[pb.port_name] = ext.top_name
                elif pb.target.startswith("board:"):
                    from socfw.model.board import BoardResource
                    try:
                        ref_obj = system.board.resolve_ref(pb.target)
                    except (KeyError, Exception):
                        ref_obj = None
                    if ref_obj is not None:
                        if isinstance(ref_obj, BoardResource):
                            sig = ref_obj.default_signal()
                            top_name = sig.top_name if sig is not None else None
                            board_width = sig.width if sig is not None and hasattr(sig, "width") else 1
                        elif isinstance(ref_obj, dict):
                            top_name = ref_obj.get("top_name")
                            board_width = int(ref_obj.get("width", 1))
                        else:
                            top_name = ref_obj.top_name
                            board_width = getattr(ref_obj, "width", 1)

                        eff_name = pb.top_name or top_name
                        eff_width = pb.width if pb.width is not None else board_width
                        if eff_name:
                            ip_width = port_widths.get(pb.port_name)
                            adapt_mode = pb.adapt
                            if adapt_mode and ip_width is not None and ip_width != eff_width:
                                wire_name = f"w_{mod.instance}_{pb.port_name}"
                                port_dir = port_dirs.get(pb.port_name, "output")
                                top.signals.append(RtlSignal(name=wire_name, kind="wire", width=ip_width))
                                explicit[pb.port_name] = wire_name
                                if port_dir == "input":
                                    if eff_width > ip_width:
                                        rhs = f"{eff_name}[{ip_width - 1}:0]"
                                    else:
                                        pad = ip_width - eff_width
                                        rhs = f"{{ {pad}'b0, {eff_name} }}"
                                    top.adapt_assigns.append(RtlAdaptAssign(lhs=wire_name, rhs=rhs))
                                else:
                                    rhs = self._adapt_rhs(
                                        wire=wire_name, src_w=ip_width, dst_w=eff_width, mode=adapt_mode
                                    )
                                    top.adapt_assigns.append(RtlAdaptAssign(lhs=eff_name, rhs=rhs))
                            else:
                                explicit[pb.port_name] = eff_name

            top.instances.append(
                RtlInstance(
                    module=ip.module,
                    instance=mod.instance,
                    parameters=tuple(
                        RtlParameter(name=k, value=v)
                        for k, v in sorted((mod.params or {}).items())
                    ),
                    connections=self._connections_from_declared_ports(ip, explicit, mod.params or {}),
                )
            )

    def _adapt_rhs(self, *, wire: str, src_w: int, dst_w: int, mode: str) -> str:
        if dst_w > src_w:
            pad = dst_w - src_w
            if mode == "replicate":
                return f"{{ {{{pad}{{ {wire}[{src_w - 1}] }} }}, {wire} }}"
            return f"{{ {pad}'b0, {wire} }}"
        return f"{wire}[{dst_w - 1}:0]"

    def _default_expr_for_port(self, port, instance_params: dict | None = None) -> str:
        if port.direction != "input":
            return ""
        w = resolve_port_width(port, instance_params or {})
        if w <= 1:
            return "1'b0"
        return f"{w}'h0"

    def _connections_from_declared_ports(self, ip, explicit: dict[str, str],
                                          instance_params: dict | None = None):
        from socfw.ir.rtl import RtlConnection
        if getattr(ip, "ports", None):
            conns = []
            for p in sorted(ip.ports, key=lambda x: x.name):
                expr = explicit.get(p.name)
                if expr is None:
                    expr = self._default_expr_for_port(p, instance_params)
                conns.append(RtlConnection(p.name, expr))
            return tuple(conns)
        return tuple(RtlConnection(name, expr) for name, expr in sorted(explicit.items()))

    def _add_bridge_instances(self, planned_bridges, top, system=None) -> None:
        from socfw.ir.rtl import RtlConnection, RtlInstance

        clk_expr = system.board.sys_clock.top_name if system is not None else "SYS_CLK"

        for bridge in sorted(planned_bridges, key=lambda b: b.instance):
            top.instances.append(
                RtlInstance(
                    module=f"{bridge.kind}_bridge",
                    instance=bridge.instance,
                    connections=(
                        RtlConnection("clk", clk_expr),
                        RtlConnection("reset_n", "reset_n"),
                        RtlConnection("sb_addr", "32'h0"),
                        RtlConnection("sb_wdata", "32'h0"),
                        RtlConnection("sb_be", "4'h0"),
                        RtlConnection("sb_we", "1'b0"),
                        RtlConnection("sb_valid", "1'b0"),
                        RtlConnection("sb_rdata", ""),
                        RtlConnection("sb_ready", ""),
                        RtlConnection("wb_adr", ""),
                        RtlConnection("wb_dat_w", ""),
                        RtlConnection("wb_dat_r", "32'h0"),
                        RtlConnection("wb_sel", ""),
                        RtlConnection("wb_we", ""),
                        RtlConnection("wb_cyc", ""),
                        RtlConnection("wb_stb", ""),
                        RtlConnection("wb_ack", "1'b0"),
                    ),
                )
            )
