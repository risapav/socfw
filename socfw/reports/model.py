from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class ReportDiagnostic:
    code: str
    severity: str
    message: str
    subject: str
    category: str = "general"
    detail: str | None = None
    hints: tuple[str, ...] = ()


@dataclass(frozen=True)
class ReportArtifact:
    family: str
    path: str
    generator: str


@dataclass(frozen=True)
class ReportClockDomain:
    name: str
    frequency_hz: int | None
    source_kind: str
    source_ref: str
    reset_policy: str
    sync_from: str | None = None
    sync_stages: int | None = None


@dataclass(frozen=True)
class ReportAddressRegion:
    name: str
    base: int
    end: int
    size: int
    kind: str
    module: str


@dataclass(frozen=True)
class ReportIrqSource:
    instance: str
    signal: str
    irq_id: int


@dataclass(frozen=True)
class ReportBusEndpoint:
    fabric: str
    instance: str
    module_type: str
    protocol: str
    role: str
    port_name: str
    base: int | None = None
    end: int | None = None
    size: int | None = None


@dataclass(frozen=True)
class PlanningDecision:
    category: str
    message: str
    rationale: str
    related: tuple[str, ...] = ()


@dataclass(frozen=True)
class ReportStage:
    name: str
    status: str
    duration_ms: float
    note: str = ""


@dataclass(frozen=True)
class ReportArtifactProvenance:
    path: str
    family: str
    generator: str
    stage: str


@dataclass
class BuildReport:
    project_name: str
    board_name: str
    cpu_type: str
    ram_base: int
    ram_size: int
    reset_vector: int
    diagnostics: list[ReportDiagnostic] = field(default_factory=list)
    artifacts: list[ReportArtifact] = field(default_factory=list)
    clocks: list[ReportClockDomain] = field(default_factory=list)
    address_regions: list[ReportAddressRegion] = field(default_factory=list)
    irq_sources: list[ReportIrqSource] = field(default_factory=list)
    bus_endpoints: list[ReportBusEndpoint] = field(default_factory=list)
    decisions: list[PlanningDecision] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    stages: list[ReportStage] = field(default_factory=list)
    artifact_provenance: list[ReportArtifactProvenance] = field(default_factory=list)
