from __future__ import annotations
from dataclasses import dataclass

from socfw.model.system import SystemModel


@dataclass(frozen=True)
class ResolvedClockDomain:
    name: str
    frequency_hz: int | None
    source_kind: str
    source_ref: str
    reset_policy: str
    sync_from: str | None = None
    sync_stages: int | None = None


class ClockResolver:
    def resolve(self, system: SystemModel) -> list[ResolvedClockDomain]:
        domains: list[ResolvedClockDomain] = []

        domains.append(
            ResolvedClockDomain(
                name=system.project.primary_clock_domain,
                frequency_hz=system.board.sys_clock.frequency_hz,
                source_kind="board",
                source_ref=system.board.sys_clock.top_name,
                reset_policy="synced",
                sync_stages=2,
            )
        )

        for req in system.project.generated_clocks:
            mod = system.project.module_by_name(req.source_instance)
            if mod is None:
                continue

            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            out = ip.clocking.find_output(req.source_output)
            if out is None:
                continue

            if req.no_reset:
                reset_policy = "none"
            else:
                reset_policy = "synced" if req.sync_from else "none"

            domains.append(
                ResolvedClockDomain(
                    name=req.domain,
                    frequency_hz=req.frequency_hz,
                    source_kind="generated",
                    source_ref=f"{req.source_instance}.{req.source_output}",
                    reset_policy=reset_policy,
                    sync_from=req.sync_from,
                    sync_stages=req.sync_stages,
                )
            )

        return domains
