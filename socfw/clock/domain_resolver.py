from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class ClockDomainResolver:
    primary_net: str
    generated: dict[str, str] = field(default_factory=dict)

    def net_for_domain(self, domain: str) -> str:
        """Return the RTL net name for a clock domain."""
        return self.generated.get(domain, self.primary_net)


def build_resolver(board, project) -> ClockDomainResolver:
    primary_net = board.sys_clock.top_name
    generated: dict[str, str] = {project.primary_clock_domain: primary_net}
    for gc in project.generated_clocks:
        generated[gc.domain] = f"{gc.source_instance}_{gc.source_output}"
    return ClockDomainResolver(primary_net=primary_net, generated=generated)
