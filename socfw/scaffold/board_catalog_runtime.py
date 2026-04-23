from __future__ import annotations

from pathlib import Path


class RuntimeBoardCatalog:
    def list_boards(self, board_dirs: list[str]) -> list[tuple[str, str]]:
        found = []
        for d in board_dirs:
            root = Path(d)
            if not root.exists():
                continue
            for board_dir in sorted(root.iterdir()):
                if board_dir.is_dir() and (board_dir / "board.yaml").exists():
                    found.append((board_dir.name, str(board_dir / "board.yaml")))
        return found
