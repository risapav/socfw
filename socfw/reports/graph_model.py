from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class GraphNode:
    id: str
    label: str
    kind: str


@dataclass(frozen=True)
class GraphEdge:
    src: str
    dst: str
    label: str = ""
    style: str = "solid"


@dataclass
class SystemGraph:
    nodes: list[GraphNode] = field(default_factory=list)
    edges: list[GraphEdge] = field(default_factory=list)
