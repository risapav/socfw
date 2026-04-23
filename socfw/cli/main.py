from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _default_templates_dir() -> str:
    return str(Path(__file__).resolve().parents[1] / "templates")


def cmd_build(args) -> int:
    from socfw.build.context import BuildRequest
    from socfw.build.full_pipeline import FullBuildPipeline

    pipeline = FullBuildPipeline(templates_dir=args.templates)
    result = pipeline.run(BuildRequest(project_file=args.project, out_dir=args.out))

    for d in result.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if result.ok:
        for art in result.manifest.artifacts:
            print(f"[{art.family}] {art.path}")

    return 0 if result.ok else 1


def cmd_validate(args) -> int:
    from socfw.config.system_loader import SystemLoader

    loader = SystemLoader()
    loaded = loader.load(args.project)

    for d in loaded.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    return 0 if loaded.ok else 1


def cmd_explain(args) -> int:
    from socfw.config.system_loader import SystemLoader
    from socfw.elaborate.planner import Elaborator
    from socfw.reports.explain import ExplainService

    loader = SystemLoader()
    loaded = loader.load(args.project)

    for d in loaded.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if not loaded.ok or loaded.value is None:
        return 1

    system = loaded.value
    design = Elaborator().elaborate(system)
    expl = ExplainService()

    if args.topic == "clocks":
        print(expl.explain_clocks(design))
    elif args.topic == "address-map":
        print(expl.explain_address_map(system))
    elif args.topic == "irqs":
        print(expl.explain_irqs(design))
    elif args.topic == "cpu-irq":
        print(expl.explain_cpu_irq(system))
    else:
        print(f"Unknown explain topic: {args.topic}", file=sys.stderr)
        return 1

    return 0


def cmd_graph(args) -> int:
    from socfw.build.context import BuildRequest
    from socfw.build.full_pipeline import FullBuildPipeline

    pipeline = FullBuildPipeline(templates_dir=args.templates)
    result = pipeline.run(BuildRequest(project_file=args.project, out_dir=args.out))

    for d in result.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if not result.ok:
        return 1

    for art in result.manifest.artifacts:
        if art.family == "report" and art.path.endswith(".dot"):
            print(art.path)

    return 0


def cmd_build_fw(args) -> int:
    from socfw.build.context import BuildRequest
    from socfw.build.two_pass_flow import TwoPassBuildFlow

    flow = TwoPassBuildFlow(templates_dir=args.templates)
    result = flow.run(BuildRequest(project_file=args.project, out_dir=args.out))

    for d in result.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if result.ok:
        for art in result.manifest.artifacts:
            print(f"[{art.family}] {art.path}")

    return 0 if result.ok else 1


def cmd_sim_smoke(args) -> int:
    from socfw.build.context import BuildRequest
    from socfw.build.two_pass_flow import TwoPassBuildFlow
    from socfw.tools.sim_runner import SimRunner

    flow = TwoPassBuildFlow(templates_dir=args.templates)
    result = flow.run(BuildRequest(project_file=args.project, out_dir=args.out))

    for d in result.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if not result.ok:
        return 1

    sim = SimRunner().run_iverilog(args.out)
    for d in sim.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    return 0 if sim.ok else 1


def cmd_schema_export(args) -> int:
    from socfw.tools.schema_exporter import SchemaExporter

    paths = SchemaExporter().export_all(args.out)
    for p in paths:
        print(p)
    return 0


def cmd_docs_export(args) -> int:
    from socfw.tools.config_docs_exporter import ConfigDocsExporter

    paths = ConfigDocsExporter().export_all(args.out)
    for p in paths:
        print(p)
    return 0


def cmd_migrate(args) -> int:
    import yaml
    from socfw.config.migrate.v1_to_v2 import migrate_project, migrate_board, migrate_timing, migrate_ip

    path = Path(args.input)
    if not path.exists():
        print(f"error: file not found: {args.input}", file=sys.stderr)
        return 1

    with path.open("r", encoding="utf-8") as f:
        legacy = yaml.safe_load(f) or {}

    kind = args.kind or _detect_kind(legacy, path)
    fn = {"project": migrate_project, "board": migrate_board, "timing": migrate_timing, "ip": migrate_ip}.get(kind)
    if fn is None:
        print(f"error: unknown kind '{kind}'. Use --kind {{project,board,timing,ip}}", file=sys.stderr)
        return 1

    result = fn(legacy)
    print(yaml.dump(result, default_flow_style=False, sort_keys=False, allow_unicode=True), end="")
    return 0


def _detect_kind(data: dict, path: Path) -> str:
    if "kind" in data:
        return data["kind"]
    stem = path.stem.lower()
    if ".board" in stem or stem.endswith("board"):
        return "board"
    if ".timing" in stem or "timing" in stem:
        return "timing"
    if ".ip" in stem or "ip" in stem:
        return "ip"
    return "project"


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="socfw", description="SoC Framework — config-driven FPGA generator")
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="Generate all artifacts")
    b.add_argument("project")
    b.add_argument("--out", default="build/gen")
    b.add_argument("--templates", default=_default_templates_dir())
    b.set_defaults(func=cmd_build)

    v = sub.add_parser("validate", help="Validate project config only")
    v.add_argument("project")
    v.set_defaults(func=cmd_validate)

    e = sub.add_parser("explain", help="Explain a design aspect in plain text")
    e.add_argument("topic", choices=["clocks", "address-map", "irqs", "cpu-irq"])
    e.add_argument("project")
    e.set_defaults(func=cmd_explain)

    g = sub.add_parser("graph", help="Build and emit the topology graph")
    g.add_argument("project")
    g.add_argument("--out", default="build/gen")
    g.add_argument("--templates", default=_default_templates_dir())
    g.set_defaults(func=cmd_graph)

    bf = sub.add_parser("build-fw", help="Two-pass build with firmware compilation")
    bf.add_argument("project")
    bf.add_argument("--out", default="build/gen")
    bf.add_argument("--templates", default=_default_templates_dir())
    bf.set_defaults(func=cmd_build_fw)

    s = sub.add_parser("sim-smoke", help="Two-pass build + iverilog smoke simulation")
    s.add_argument("project")
    s.add_argument("--out", default="build/gen")
    s.add_argument("--templates", default=_default_templates_dir())
    s.set_defaults(func=cmd_sim_smoke)

    m = sub.add_parser("migrate", help="Migrate legacy YAML config to v2 format")
    m.add_argument("input", help="Legacy YAML file to migrate")
    m.add_argument("--kind", choices=["project", "board", "timing", "ip"], default=None,
                   help="Force YAML kind (auto-detected if omitted)")
    m.set_defaults(func=cmd_migrate)

    schema = sub.add_parser("schema", help="Schema export commands")
    schema_sub = schema.add_subparsers(dest="schema_cmd", required=True)

    schema_export = schema_sub.add_parser("export", help="Export JSON schemas for all config types")
    schema_export.add_argument("--out", default="build/schema")
    schema_export.set_defaults(func=cmd_schema_export)

    docs = sub.add_parser("docs", help="Documentation export commands")
    docs_sub = docs.add_subparsers(dest="docs_cmd", required=True)

    docs_export = docs_sub.add_parser("export", help="Export human-readable config reference docs")
    docs_export.add_argument("--out", default="build/docs")
    docs_export.set_defaults(func=cmd_docs_export)

    return ap


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
