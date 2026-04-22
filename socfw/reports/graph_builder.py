from __future__ import annotations

from socfw.reports.graph_model import GraphEdge, GraphNode, SystemGraph


class GraphBuilder:
    def build(self, system, design) -> SystemGraph:
        graph = SystemGraph()

        if system.cpu is not None:
            graph.nodes.append(
                GraphNode(
                    id=system.cpu.instance,
                    label=system.cpu.type_name,
                    kind="cpu",
                )
            )

        if system.ram is not None:
            graph.nodes.append(
                GraphNode(
                    id="ram",
                    label=f"RAM\\n0x{system.ram.base:08X}..0x{system.ram.base + system.ram.size - 1:08X}",
                    kind="memory",
                )
            )

        for p in system.peripheral_blocks:
            graph.nodes.append(
                GraphNode(
                    id=p.instance,
                    label=f"{p.instance}\\n0x{p.base:08X}",
                    kind="peripheral",
                )
            )

        if design.interconnect is not None:
            for fabric, endpoints in design.interconnect.fabrics.items():
                fabric_id = f"fabric_{fabric}"
                proto = endpoints[0].protocol if endpoints else "unknown"
                graph.nodes.append(
                    GraphNode(
                        id=fabric_id,
                        label=f"{fabric}\\n({proto})",
                        kind="fabric",
                    )
                )

                for ep in endpoints:
                    if ep.role == "master":
                        graph.edges.append(
                            GraphEdge(
                                src=ep.instance,
                                dst=fabric_id,
                                label=ep.protocol,
                            )
                        )
                    else:
                        graph.edges.append(
                            GraphEdge(
                                src=fabric_id,
                                dst=ep.instance,
                                label=ep.protocol,
                            )
                        )

        if design.irq_plan is not None and system.cpu is not None:
            for src in design.irq_plan.sources:
                graph.edges.append(
                    GraphEdge(
                        src=src.instance,
                        dst=system.cpu.instance,
                        label=f"IRQ {src.irq_id}",
                        style="dashed",
                    )
                )

        return graph
