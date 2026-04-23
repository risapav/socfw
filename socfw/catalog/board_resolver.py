from __future__ import annotations

from pathlib import Path


class BoardResolver:
    def resolve(
        self,
        *,
        board_key: str,
        explicit_board_file: str | None,
        board_dirs: list[str],
    ) -> str | None:
        if explicit_board_file:
            p = Path(explicit_board_file)
            if p.exists():
                return str(p)

        for d in board_dirs:
            candidate = Path(d) / board_key / "board.yaml"
            if candidate.exists():
                return str(candidate)

        return None
