from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class BoardPinAssignment:
    top_name: str
    index: int | None
    pin: str
    io_standard: str | None = None
    weak_pull_up: bool = False


@dataclass
class BoardIR:
    family: str
    device: str
    assignments: list[BoardPinAssignment] = field(default_factory=list)

    def add_scalar(
        self,
        *,
        top_name: str,
        pin: str,
        io_standard: str | None = None,
        weak_pull_up: bool = False,
    ) -> None:
        self.assignments.append(
            BoardPinAssignment(
                top_name=top_name,
                index=None,
                pin=pin,
                io_standard=io_standard,
                weak_pull_up=weak_pull_up,
            )
        )

    def add_vector(
        self,
        *,
        top_name: str,
        pins: dict[int, str],
        io_standard: str | None = None,
        weak_pull_up: bool = False,
    ) -> None:
        for idx, pin in sorted(pins.items()):
            self.assignments.append(
                BoardPinAssignment(
                    top_name=top_name,
                    index=idx,
                    pin=pin,
                    io_standard=io_standard,
                    weak_pull_up=weak_pull_up,
                )
            )
