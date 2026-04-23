from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class BoardCatalogEntry:
    key: str
    title: str
    board_file: str
    family: str
    note: str = ""


class BoardCatalog:
    def all(self) -> list[BoardCatalogEntry]:
        return [
            BoardCatalogEntry(
                key="qmtech_ep4ce55",
                title="QMTech EP4CE55F23C8",
                board_file="boards/qmtech_ep4ce55/board.yaml",
                family="cyclone_iv_e",
            ),
        ]

    def get(self, key: str) -> BoardCatalogEntry | None:
        for b in self.all():
            if b.key == key:
                return b
        return None
