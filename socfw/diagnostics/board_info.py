from __future__ import annotations

from socfw.model.board import BoardModel, BoardResource, BoardScalarSignal, BoardVectorSignal


def _fmt_hz(hz: int) -> str:
    if hz >= 1_000_000:
        return f"{hz // 1_000_000} MHz"
    if hz >= 1_000:
        return f"{hz // 1_000} kHz"
    return f"{hz} Hz"


def _pins_str(pins) -> str:
    if isinstance(pins, dict):
        ordered = [pins[i] for i in sorted(pins)]
    else:
        ordered = list(pins)
    return ",".join(ordered)


class BoardInfoReport:
    def build(self, board: BoardModel) -> str:
        lines: list[str] = []

        lines.append(f"Board: {board.board_id}")
        if board.title:
            lines.append(f"Title: {board.title}")
        if board.vendor:
            lines.append(f"Vendor: {board.vendor}")
        lines.append(f"FPGA: {board.fpga_part} ({board.fpga_family})")
        lines.append(f"Clock: {board.sys_clock.top_name} @ {_fmt_hz(board.sys_clock.frequency_hz)} pin {board.sys_clock.pin}")
        if board.sys_reset is not None:
            active = "active-low" if board.sys_reset.active_low else "active-high"
            lines.append(f"Reset: {board.sys_reset.top_name} ({active}) pin {board.sys_reset.pin}")
        lines.append("")

        lines.append("Resources:")
        self._add_onboard(board, lines)
        self._add_external(board, lines)
        self._add_connectors(board, lines)

        return "\n".join(lines).rstrip() + "\n"

    def _add_onboard(self, board: BoardModel, lines: list[str]) -> None:
        for res_key, res in board.onboard.items():
            self._add_board_resource(f"onboard.{res_key}", res, lines)

    def _add_external(self, board: BoardModel, lines: list[str]) -> None:
        external = board.resources.get("external")
        if not isinstance(external, dict):
            return
        self._walk_external(external, "external", lines)

    def _walk_external(self, node: dict, path: str, lines: list[str]) -> None:
        if not isinstance(node, dict):
            return
        kind = node.get("kind")
        if kind in ("scalar", "vector", "inout", "bundle"):
            self._add_raw_resource(path, node, lines)
            return
        for key, val in node.items():
            if isinstance(val, dict):
                self._walk_external(val, f"{path}.{key}", lines)

    def _add_raw_resource(self, path: str, node: dict, lines: list[str]) -> None:
        kind = node.get("kind", "?")
        top = node.get("top_name", "")
        direction = node.get("direction", "")
        width = node.get("width")

        if kind == "bundle":
            w_str = ""
            pins_str = ""
            for sig_name, sig in (node.get("signals") or {}).items():
                if isinstance(sig, dict):
                    self._add_raw_resource(f"{path}.{sig_name}", sig, lines)
            lines.append(f"- {path}: {top} bundle")
            return

        w_str = f"[{width}]" if isinstance(width, int) else ""
        pins = node.get("pins") or ([node["pin"]] if "pin" in node else [])
        if isinstance(pins, dict):
            pins = [pins[i] for i in sorted(pins)]
        pins_str = ",".join(str(p) for p in pins) if pins else "—"
        lines.append(f"- {path}: {top}{w_str} {direction} pins {pins_str}")

    def _add_board_resource(self, path: str, res: BoardResource, lines: list[str]) -> None:
        for sig_key, sig in res.scalars.items():
            sig_path = f"{path}.{sig_key}" if sig_key != "default" else path
            lines.append(f"- {sig_path}: {sig.top_name} {sig.direction.value} pin {sig.pin}")

        for vec_key, vec in res.vectors.items():
            vec_path = f"{path}.{vec_key}" if vec_key != "default" else path
            w_str = f"[{vec.width}]"
            pins_str = _pins_str(vec.pins)
            lines.append(f"- {vec_path}: {vec.top_name}{w_str} {vec.direction.value} pins {pins_str}")

    def _add_connectors(self, board: BoardModel, lines: list[str]) -> None:
        for conn_key, conn in board.connectors.items():
            for role_key, role in conn.roles.items():
                path = f"connector.pmod.{conn_key}.role.{role_key}"
                w_str = f"[{role.width}]"
                pins_str = _pins_str(role.pins)
                lines.append(f"- {path}: {role.top_name}{w_str} {role.direction.value} pins {pins_str}")
