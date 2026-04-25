from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _default_templates_dir() -> str:
    return str(Path(__file__).resolve().parents[1] / "templates")


def _print_diags(diags) -> None:
    from socfw.reports.diagnostic_formatter import DiagnosticFormatter
    fmt = DiagnosticFormatter()
    for d in diags:
        print(fmt.format_text(d))
        print()


def _print_summary(result) -> None:
    from socfw.reports.build_summary_formatter import BuildSummaryFormatter
    if getattr(result, "provenance", None) is not None:
        print(BuildSummaryFormatter().format_text(result.provenance))


def cmd_build(args) -> int:
    from socfw.build.context import BuildRequest
    from socfw.build.full_pipeline import FullBuildPipeline

    pipeline = FullBuildPipeline(templates_dir=args.templates)
    result = pipeline.run(BuildRequest(
        project_file=args.project,
        out_dir=args.out,
        legacy_backend=getattr(args, "legacy_backend", False),
    ))

    _print_diags(result.diagnostics)

    if result.ok:
        for art in result.manifest.artifacts:
            print(f"[{art.family}] {art.path}")
        _print_summary(result)

    return 0 if result.ok else 1


def cmd_fmt(args) -> int:
    from socfw.config.formatter import ConfigFormatter

    res = ConfigFormatter().format_file(args.file, write=args.write)
    _print_diags(res.diagnostics)

    if not res.ok or res.value is None:
        return 1

    if args.write:
        print(f"OK: formatted {args.file}")
    else:
        print(res.value, end="")

    return 0


def cmd_explain_schema(args) -> int:
    from socfw.schema_docs import available_schemas, get_schema_doc

    if args.schema == "list":
        print("Available schemas:")
        for name in available_schemas():
            print(f"  {name}")
        return 0

    doc = get_schema_doc(args.schema)
    if doc is None:
        print(f"Unknown schema: {args.schema}")
        print("Available schemas:")
        for name in available_schemas():
            print(f"  {name}")
        return 1

    print(doc)
    return 0


def cmd_doctor(args) -> int:
    from socfw.build.full_pipeline import FullBuildPipeline
    from socfw.diagnostics.doctor import DoctorReport

    loaded = FullBuildPipeline().validate(args.project)
    _print_diags(loaded.diagnostics)

    if loaded.value is None:
        return 1

    print(DoctorReport().build(loaded.value))
    return 0 if loaded.ok else 1


def cmd_validate(args) -> int:
    from socfw.build.full_pipeline import FullBuildPipeline

    loaded = FullBuildPipeline().validate(args.project)
    _print_diags(loaded.diagnostics)

    if loaded.ok and loaded.value is not None:
        timing_info = "timing=none"
        if loaded.value.timing is not None:
            timing_info = (
                f"timing=generated_clocks:{len(loaded.value.timing.generated_clocks)} "
                f"false_paths:{len(loaded.value.timing.false_paths)}"
            )

        cpu_info = "cpu=none"
        if loaded.value.cpu is not None:
            resolved = loaded.value.cpu_desc()
            cpu_info = f"cpu={loaded.value.cpu.type_name}"
            if resolved is None:
                cpu_info += "(unresolved)"
            else:
                cpu_info += f"(module={resolved.module})"

        print(
            f"OK: project={loaded.value.project.name} "
            f"board={loaded.value.board.board_id} "
            f"ip_catalog={len(loaded.value.ip_catalog)} "
            f"cpu_catalog={len(loaded.value.cpu_catalog)} "
            f"{cpu_info} "
            f"{timing_info}"
        )
        return 0
    return 1


def cmd_explain(args) -> int:
    from socfw.config.system_loader import SystemLoader
    from socfw.elaborate.planner import Elaborator
    from socfw.reports.explain import ExplainService

    loader = SystemLoader()
    loaded = loader.load(args.project)

    _print_diags(loaded.diagnostics)

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
    elif args.topic == "bus":
        print(expl.explain_bus(design))
    elif args.topic == "diagnostics":
        print(expl.explain_diagnostics(loaded.diagnostics))
    else:
        print(f"Unknown explain topic: {args.topic}", file=sys.stderr)
        return 1

    return 0


def cmd_graph(args) -> int:
    from socfw.build.context import BuildRequest
    from socfw.build.full_pipeline import FullBuildPipeline

    pipeline = FullBuildPipeline(templates_dir=args.templates)
    result = pipeline.run(BuildRequest(project_file=args.project, out_dir=args.out))

    _print_diags(result.diagnostics)

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

    _print_diags(result.diagnostics)

    if result.ok:
        for art in result.manifest.artifacts:
            print(f"[{art.family}] {art.path}")
        _print_summary(result)

    if getattr(args, "provenance_json", None) and getattr(result, "provenance", None) is not None:
        from socfw.tools.provenance_json_exporter import ProvenanceJsonExporter
        path = ProvenanceJsonExporter().export(result.provenance, args.provenance_json)
        print(path)

    return 0 if result.ok else 1


def cmd_sim_smoke(args) -> int:
    from socfw.build.context import BuildRequest
    from socfw.build.two_pass_flow import TwoPassBuildFlow
    from socfw.tools.sim_runner import SimRunner

    flow = TwoPassBuildFlow(templates_dir=args.templates)
    result = flow.run(BuildRequest(project_file=args.project, out_dir=args.out))

    _print_diags(result.diagnostics)

    if not result.ok:
        return 1

    sim = SimRunner().run_iverilog(args.out)
    _print_diags(sim.diagnostics)

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


def cmd_init(args) -> int:
    import os

    board = args.board or "qmtech_ep4ce55"

    if args.template in ("blink", "pll", "sdram"):
        from socfw.scaffold.init_project import ProjectInitializer
        out_dir = os.path.join(args.out, args.name)
        try:
            created = ProjectInitializer().init(
                template=args.template,
                target_dir=out_dir,
                name=args.name,
                board=board,
            )
        except Exception as exc:
            print(f"ERROR INIT001: {exc}", file=sys.stderr)
            return 1

        print(f"OK: initialized project in {out_dir}")
        for p in created:
            print(p)
        print("")
        print("Next:")
        print(f"  socfw validate {out_dir}/project.yaml")
        print(f"  socfw build {out_dir}/project.yaml --out {out_dir}/build/gen")
        return 0

    from socfw.scaffold.generator import ScaffoldGenerator
    from socfw.scaffold.model import InitRequest

    gen = ScaffoldGenerator(templates_dir=args.templates)
    req = InitRequest(
        name=args.name,
        out_dir=args.out,
        template=args.template,
        board=args.board,
        cpu=args.cpu,
        force=args.force,
    )

    try:
        created = gen.generate(req)
    except Exception as exc:
        print(f"ERROR INIT001: {exc}", file=sys.stderr)
        return 1

    for p in created:
        print(p)
    return 0


def cmd_list_templates(args) -> int:
    from socfw.scaffold.template_registry import TemplateRegistry

    for t in TemplateRegistry().all():
        print(f"{t.key}: {t.title} [{t.mode}] - {t.description}")
    return 0


def cmd_list_boards(args) -> int:
    from socfw.scaffold.board_catalog import BoardCatalog

    for b in BoardCatalog().all():
        print(f"{b.key}: {b.title} ({b.family})")
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
    b.add_argument(
        "--legacy-backend",
        action="store_true",
        help="Use deprecated legacy backend instead of native emitters",
    )
    b.set_defaults(func=cmd_build)

    p_fmt = sub.add_parser("fmt", help="Format YAML config into canonical shape")
    p_fmt.add_argument("file")
    p_fmt.add_argument("--write", action="store_true", help="Rewrite file in place")
    p_fmt.set_defaults(func=cmd_fmt)

    p_es = sub.add_parser("explain-schema", help="Show canonical YAML schema examples")
    p_es.add_argument("schema", help="Schema name: project, timing, ip, board, or list")
    p_es.set_defaults(func=cmd_explain_schema)

    p_doc = sub.add_parser("doctor", help="Inspect resolved project configuration")
    p_doc.add_argument("project")
    p_doc.set_defaults(func=cmd_doctor)

    v = sub.add_parser("validate", help="Validate project config only")
    v.add_argument("project")
    v.set_defaults(func=cmd_validate)

    e = sub.add_parser("explain", help="Explain a design aspect in plain text")
    e.add_argument("topic", choices=["clocks", "address-map", "irqs", "cpu-irq", "bus", "diagnostics"])
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
    bf.add_argument("--provenance-json", default=None, help="Export build provenance to JSON file")
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

    i = sub.add_parser("init", help="Initialize a new project from a scaffold template")
    i.add_argument("name")
    i.add_argument("--template", default="blink", choices=["blink", "pll", "sdram"])
    i.add_argument("--board", default=None)
    i.add_argument("--cpu", default=None)
    i.add_argument("--out", default=".")
    i.add_argument("--force", action="store_true")
    i.add_argument("--templates", default=_default_templates_dir())
    i.set_defaults(func=cmd_init)

    lt = sub.add_parser("list-templates", help="List available scaffold templates")
    lt.set_defaults(func=cmd_list_templates)

    lb = sub.add_parser("list-boards", help="List known boards in the catalog")
    lb.set_defaults(func=cmd_list_boards)

    return ap


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
