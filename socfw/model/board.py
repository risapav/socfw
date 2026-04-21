from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any

from .enums import PortDir


@dataclass(frozen=True)
class BoardScalarSignal:
    key: str
    top_name: str
    direction: PortDir
    pin: str
    io_standard: str | None = None
    weak_pull_up: bool = False
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class BoardVectorSignal:
    key: str
    top_name: str
    direction: PortDir
    width: int
    pins: dict[int, str]
    io_standard: str | None = None
    weak_pull_up: bool = False
    meta: dict[str, Any] = field(default_factory=dict)

    def validate_shape(self) -> list[str]:
        errs: list[str] = []
        if self.width <= 0:
            errs.append(f"{self.key}: width must be > 0")
        if len(self.pins) != self.width:
            errs.append(f"{self.key}: width={self.width} but {len(self.pins)} pins provided")
        missing = sorted(set(range(self.width)) - set(self.pins.keys()))
        if missing:
            errs.append(f"{self.key}: missing pin indices {missing}")
        return errs


@dataclass(frozen=True)
class BoardResource:
    key: str
    kind: str
    scalars: dict[str, BoardScalarSignal] = field(default_factory=dict)
    vectors: dict[str, BoardVectorSignal] = field(default_factory=dict)
    meta: dict[str, Any] = field(default_factory=dict)

    def default_signal(self) -> BoardScalarSignal | BoardVectorSignal | None:
        if len(self.scalars) == 1 and not self.vectors:
            return next(iter(self.scalars.values()))
        if len(self.vectors) == 1 and not self.scalars:
            return next(iter(self.vectors.values()))
        return None


@dataclass(frozen=True)
class BoardConnectorRole:
    key: str
    top_name: str
    direction: PortDir
    width: int
    pins: dict[int, str]
    io_standard: str | None = None
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class BoardConnector:
    key: str
    roles: dict[str, BoardConnectorRole] = field(default_factory=dict)


@dataclass(frozen=True)
class BoardClockDef:
    id: str
    top_name: str
    pin: str
    frequency_hz: int
    io_standard: str | None = None
    period_ns: float | None = None


@dataclass(frozen=True)
class BoardResetDef:
    id: str
    top_name: str
    pin: str
    active_low: bool
    io_standard: str | None = None
    weak_pull_up: bool = False


@dataclass(frozen=True)
class BoardModel:
    board_id: str
    vendor: str | None
    title: str | None
    fpga_family: str
    fpga_part: str
    sys_clock: BoardClockDef
    sys_reset: BoardResetDef
    onboard: dict[str, BoardResource] = field(default_factory=dict)
    connectors: dict[str, BoardConnector] = field(default_factory=dict)
    metadata: dict[str, Any] = field(default_factory=dict)

    def resolve_ref(self, ref: str) -> BoardResource | BoardConnectorRole:
        """
        Supported refs:
          board:onboard.leds
          board:connector.pmod.J10.role.led8
        """
        if not ref.startswith("board:"):
            raise KeyError(f"Not a board ref: {ref}")

        path = ref[len("board:"):]
        parts = path.split(".")

        if len(parts) == 2 and parts[0] == "onboard":
            key = parts[1]
            if key not in self.onboard:
                raise KeyError(f"Unknown onboard resource '{key}'")
            return self.onboard[key]

        if len(parts) == 5 and parts[0] == "connector" and parts[1] == "pmod" and parts[3] == "role":
            conn = parts[2]
            role = parts[4]
            if conn not in self.connectors:
                raise KeyError(f"Unknown connector '{conn}'")
            if role not in self.connectors[conn].roles:
                raise KeyError(f"Unknown role '{role}' on connector '{conn}'")
            return self.connectors[conn].roles[role]

        raise KeyError(f"Unsupported board ref '{ref}'")

    def validate(self) -> list[str]:
        errs: list[str] = []
        seen_top_names: set[str] = {self.sys_clock.top_name, self.sys_reset.top_name}

        for name, res in self.onboard.items():
            for sig in res.scalars.values():
                if sig.top_name in seen_top_names:
                    errs.append(f"Duplicate top_name '{sig.top_name}' in onboard.{name}")
                seen_top_names.add(sig.top_name)

            for vec in res.vectors.values():
                if vec.top_name in seen_top_names:
                    errs.append(f"Duplicate top_name '{vec.top_name}' in onboard.{name}")
                seen_top_names.add(vec.top_name)
                errs.extend(vec.validate_shape())

        for conn_name, conn in self.connectors.items():
            for role_name, role in conn.roles.items():
                if role.top_name in seen_top_names:
                    errs.append(
                        f"Duplicate top_name '{role.top_name}' in connector.{conn_name}.role.{role_name}"
                    )
                seen_top_names.add(role.top_name)
                if len(role.pins) != role.width:
                    errs.append(
                        f"connector.{conn_name}.role.{role_name}: width={role.width} "
                        f"but {len(role.pins)} pins provided"
                    )

        return errs
