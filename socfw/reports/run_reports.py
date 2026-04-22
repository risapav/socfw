from __future__ import annotations

from socfw.reports.builder import BuildReportBuilder
from socfw.reports.graph_builder import GraphBuilder
from socfw.reports.graphviz_emitter import GraphvizEmitter
from socfw.reports.json_emitter import JsonReportEmitter
from socfw.reports.markdown_emitter import MarkdownReportEmitter


class ReportSuite:
    def __init__(self) -> None:
        self.report_builder = BuildReportBuilder()
        self.json = JsonReportEmitter()
        self.md = MarkdownReportEmitter()
        self.graph_builder = GraphBuilder()
        self.graphviz = GraphvizEmitter()

    def emit_all(self, *, system, design, result, out_dir: str) -> list[str]:
        paths: list[str] = []

        report = self.report_builder.build(
            system=system,
            design=design,
            result=result,
        )
        paths.append(self.json.emit(report, out_dir))
        paths.append(self.md.emit(report, out_dir))

        graph = self.graph_builder.build(system, design)
        paths.append(self.graphviz.emit(graph, out_dir))

        return paths
