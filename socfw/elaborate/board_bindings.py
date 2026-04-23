from __future__ import annotations
from dataclasses import dataclass, field

from socfw.model.board import BoardResource, BoardConnectorRole, BoardScalarSignal, BoardVectorSignal
from socfw.model.system import SystemModel


@dataclass(frozen=True)
class ResolvedExternalPort:
    top_name: str
    direction: str
    width: int
    io_standard: str | None = None
    pins: dict[int, str] | None = None
    pin: str | None = None
    weak_pull_up: bool = False


@dataclass(frozen=True)
class ResolvedPortBinding:
    instance: str
    port_name: str
    target_ref: str
    resolved: tuple[ResolvedExternalPort, ...]
    adapt: str | None = None


class BoardBindingResolver:
    def resolve(self, system: SystemModel) -> list[ResolvedPortBinding]:
        result: list[ResolvedPortBinding] = []

        for mod in system.project.modules:
            for binding in mod.port_bindings:
                if not binding.target.startswith("board:"):
                    continue

                target = system.board.resolve_ref(binding.target)

                if isinstance(target, BoardVectorSignal):
                    resolved = (
                        ResolvedExternalPort(
                            top_name=binding.top_name or target.top_name,
                            direction=target.direction.value,
                            width=binding.width or target.width,
                            io_standard=target.io_standard,
                            pins=target.pins,
                            weak_pull_up=target.weak_pull_up,
                        ),
                    )
                elif isinstance(target, BoardScalarSignal):
                    resolved = (
                        ResolvedExternalPort(
                            top_name=binding.top_name or target.top_name,
                            direction=target.direction.value,
                            width=1,
                            io_standard=target.io_standard,
                            pin=target.pin,
                            weak_pull_up=target.weak_pull_up,
                        ),
                    )
                elif isinstance(target, BoardConnectorRole):
                    resolved: tuple[ResolvedExternalPort, ...] = (
                        ResolvedExternalPort(
                            top_name=binding.top_name or target.top_name,
                            direction=target.direction.value,
                            width=binding.width or target.width,
                            io_standard=target.io_standard,
                            pins=target.pins,
                        ),
                    )
                elif isinstance(target, BoardResource):
                    sig = target.default_signal()
                    if sig is not None:
                        if hasattr(sig, "pins"):
                            resolved = (
                                ResolvedExternalPort(
                                    top_name=binding.top_name or sig.top_name,
                                    direction=sig.direction.value,
                                    width=binding.width or sig.width,
                                    io_standard=sig.io_standard,
                                    pins=sig.pins,
                                    weak_pull_up=getattr(sig, "weak_pull_up", False),
                                ),
                            )
                        else:
                            resolved = (
                                ResolvedExternalPort(
                                    top_name=binding.top_name or sig.top_name,
                                    direction=sig.direction.value,
                                    width=1,
                                    io_standard=sig.io_standard,
                                    pin=sig.pin,
                                    weak_pull_up=sig.weak_pull_up,
                                ),
                            )
                    else:
                        parts: list[ResolvedExternalPort] = []
                        for sc in target.scalars.values():
                            parts.append(
                                ResolvedExternalPort(
                                    top_name=sc.top_name,
                                    direction=sc.direction.value,
                                    width=1,
                                    io_standard=sc.io_standard,
                                    pin=sc.pin,
                                    weak_pull_up=sc.weak_pull_up,
                                )
                            )
                        for vec in target.vectors.values():
                            parts.append(
                                ResolvedExternalPort(
                                    top_name=vec.top_name,
                                    direction=vec.direction.value,
                                    width=vec.width,
                                    io_standard=vec.io_standard,
                                    pins=vec.pins,
                                    weak_pull_up=vec.weak_pull_up,
                                )
                            )
                        resolved = tuple(parts)
                else:
                    raise TypeError(f"Unsupported board target type: {type(target)}")

                result.append(
                    ResolvedPortBinding(
                        instance=mod.instance,
                        port_name=binding.port_name,
                        target_ref=binding.target,
                        resolved=resolved,
                        adapt=binding.adapt,
                    )
                )

        return result
