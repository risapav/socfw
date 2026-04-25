from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class SocBuildProvenance:
    project_name: str
    project_mode: str
    board_id: str

    cpu_type: str | None = None
    cpu_module: str | None = None

    ip_types: list[str] = field(default_factory=list)
    module_instances: list[str] = field(default_factory=list)

    timing_generated_clocks: int = 0
    timing_false_paths: int = 0

    vendor_qip_files: list[str] = field(default_factory=list)
    vendor_sdc_files: list[str] = field(default_factory=list)

    bridge_pairs: list[str] = field(default_factory=list)

    generated_files: list[str] = field(default_factory=list)
    aliases_used: list[str] = field(default_factory=list)
