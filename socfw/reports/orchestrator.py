from __future__ import annotations

from socfw.plugins.registry import PluginRegistry
from socfw.reports.builder import BuildReportBuilder
from socfw.reports.graph_builder import GraphBuilder


class ReportOrchestrator:
    def __init__(self, registry: PluginRegistry) -> None:
        self.registry = registry
        self.report_builder = BuildReportBuilder()
        self.graph_builder = GraphBuilder()

    def emit_all(self, *, system, design, result, out_dir: str) -> list[str]:
        paths: list[str] = []

        report = self.report_builder.build(
            system=system,
            design=design,
            result=result,
        )

        if "json" in self.registry.reports:
            p = self.registry.reports["json"].emit(report, out_dir)
            paths.append(p)

        if "markdown" in self.registry.reports:
            p = self.registry.reports["markdown"].emit(report, out_dir)
            paths.append(p)

        if "graphviz" in self.registry.reports:
            graph = self.graph_builder.build(system, design)
            p = self.registry.reports["graphviz"].emit(graph, out_dir)
            paths.append(p)

        return paths
