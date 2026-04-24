from __future__ import annotations

from typing import Any

from pydantic import ValidationError

from socfw.config.board_schema import (
    BoardConfigSchema,
    BoardConnectorRoleSchema,
    BoardConnectorSchema,
)
from socfw.config.common import load_yaml_file
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result
from socfw.model.board import (
    BoardClockDef,
    BoardConnector,
    BoardConnectorRole,
    BoardModel,
    BoardResetDef,
    BoardResource,
    BoardScalarSignal,
    BoardVectorSignal,
    PortDir,
)


class BoardLoader:
    def load(self, path: str) -> Result[BoardModel]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = BoardConfigSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="BRD100",
                        severity=Severity.ERROR,
                        message=f"Invalid board YAML: {exc}",
                        subject="board",
                        spans=(SourceLocation(file=path),),
                    )
                ]
            )

        onboard: dict[str, BoardResource] = {}
        for key, res in doc.resources.onboard.items():
            if res.signals or res.groups:
                scalars = {
                    sig_key: BoardScalarSignal(
                        key=sig_key,
                        top_name=sig.top_name,
                        direction=PortDir(sig.direction),
                        pin=sig.pin,
                        io_standard=sig.io_standard,
                        weak_pull_up=sig.weak_pull_up,
                    )
                    for sig_key, sig in res.signals.items()
                }
                vectors = {
                    grp_key: BoardVectorSignal(
                        key=grp_key,
                        top_name=grp.top_name,
                        direction=PortDir(grp.direction),
                        width=grp.width,
                        pins=grp.pins,
                        io_standard=grp.io_standard,
                        weak_pull_up=grp.weak_pull_up,
                    )
                    for grp_key, grp in res.groups.items()
                }
            else:
                scalars: dict[str, BoardScalarSignal] = {}
                vectors: dict[str, BoardVectorSignal] = {}
                if res.pin is not None:
                    scalars["default"] = BoardScalarSignal(
                        key="default",
                        top_name=res.top_name or key.upper(),
                        direction=PortDir(res.direction or "output"),
                        pin=res.pin,
                        io_standard=res.io_standard,
                        weak_pull_up=res.weak_pull_up,
                    )
                elif res.pins is not None and res.width is not None:
                    vectors["default"] = BoardVectorSignal(
                        key="default",
                        top_name=res.top_name or key.upper(),
                        direction=PortDir(res.direction or "output"),
                        width=res.width,
                        pins=res.pins,
                        io_standard=res.io_standard,
                        weak_pull_up=res.weak_pull_up,
                    )

            onboard[key] = BoardResource(
                key=key,
                kind=res.kind,
                scalars=scalars,
                vectors=vectors,
            )

        connectors: dict[str, BoardConnector] = {}
        pmod_raw: dict[str, Any] = doc.resources.connectors.get("pmod", {})
        for conn_key, conn_val in pmod_raw.items():
            if not isinstance(conn_val, dict):
                continue
            roles_raw = conn_val.get("roles", {})
            try:
                conn_schema = BoardConnectorSchema.model_validate({"roles": roles_raw})
            except ValidationError:
                continue

            roles = {
                role_key: BoardConnectorRole(
                    key=role_key,
                    top_name=role.top_name,
                    direction=PortDir(role.direction),
                    width=role.width,
                    pins=role.pins,
                    io_standard=role.io_standard,
                )
                for role_key, role in conn_schema.roles.items()
            }
            connectors[conn_key] = BoardConnector(key=conn_key, roles=roles)

        model = BoardModel(
            board_id=doc.board.id,
            vendor=doc.board.vendor,
            title=doc.board.title,
            fpga_family=doc.fpga.family,
            fpga_part=doc.fpga.part,
            sys_clock=BoardClockDef(
                id=doc.system.clock.id,
                top_name=doc.system.clock.top_name,
                pin=doc.system.clock.pin,
                frequency_hz=doc.system.clock.frequency_hz,
                io_standard=doc.system.clock.io_standard,
                period_ns=doc.system.clock.period_ns,
            ),
            sys_reset=BoardResetDef(
                id=doc.system.reset.id,
                top_name=doc.system.reset.top_name,
                pin=doc.system.reset.pin,
                active_low=doc.system.reset.active_low,
                io_standard=doc.system.reset.io_standard,
                weak_pull_up=doc.system.reset.weak_pull_up,
            ),
            onboard=onboard,
            connectors=connectors,
            metadata={"toolchains": doc.toolchains},
        )

        errs = model.validate()
        if errs:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="BRD101",
                        severity=Severity.ERROR,
                        message=msg,
                        subject="board",
                        spans=(SourceLocation(file=path),),
                    )
                    for msg in errs
                ]
            )

        return Result(value=model)
