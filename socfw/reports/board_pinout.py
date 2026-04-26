from __future__ import annotations

from pathlib import Path

from socfw.board.feature_expansion import expand_features_for_project
from socfw.board.pin_ownership import PinUse, collect_pin_ownership
from socfw.model.board import BoardModel


class BoardPinoutReport:
    def build(self, board: BoardModel, project) -> str:
        selected = expand_features_for_project(board, project)
        pin_uses = collect_pin_ownership(board, selected)

        if not pin_uses:
            return "# Board Pinout\n\nNo board resources selected.\n"

        # Group by resource path
        by_resource: dict[str, list[PinUse]] = {}
        for use in pin_uses:
            by_resource.setdefault(use.resource_path, []).append(use)

        lines = ["# Board Pinout", ""]

        for resource_path in sorted(by_resource):
            uses = by_resource[resource_path]
            lines.append(f"## {resource_path}")
            lines.append("")
            lines.append("| Signal | Bit | Pin | IO Standard |")
            lines.append("|---|---:|---|---|")

            for use in sorted(uses, key=lambda u: (u.top_name, u.bit if u.bit is not None else -1)):
                io_std = _get_io_standard(use, board) or ""
                bit_str = str(use.bit) if use.bit is not None else ""
                lines.append(f"| {use.top_name} | {bit_str} | {use.pin} | {io_std} |")

            lines.append("")

        return "\n".join(lines).rstrip() + "\n"

    def write(self, out_dir: str, board: BoardModel, project) -> str:
        reports_dir = Path(out_dir) / "reports"
        reports_dir.mkdir(parents=True, exist_ok=True)
        out_file = reports_dir / "board_pinout.md"
        out_file.write_text(self.build(board, project), encoding="utf-8")
        return str(out_file)


def _get_io_standard(use: PinUse, board: BoardModel) -> str | None:
    path = use.resource_path
    if path.startswith("onboard."):
        res_key = path[len("onboard."):].split(".")[0]
        res = board.onboard.get(res_key)
        if res is None:
            return None
        for sig in res.scalars.values():
            if sig.top_name == use.top_name:
                return sig.io_standard
        for vec in res.vectors.values():
            if vec.top_name == use.top_name:
                return vec.io_standard
    elif path.startswith("external."):
        sub = path[len("external."):]
        external = board.resources.get("external") or {}
        cur = external
        for part in sub.split("."):
            if not isinstance(cur, dict) or part not in cur:
                return None
            cur = cur[part]
        if isinstance(cur, dict):
            return cur.get("io_standard")
    return None
