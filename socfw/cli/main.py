from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _default_templates_dir() -> str:
    return str(Path(__file__).resolve().parents[1] / "templates")


def cmd_validate(args) -> int:
    print(f"validate: {args.project}")
    print("(not yet implemented — system loader pending)")
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


def cmd_build(args) -> int:
    print(f"build: {args.project} -> {args.out}")
    print("(not yet implemented — full pipeline pending)")
    return 0


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

    m = sub.add_parser("migrate", help="Migrate legacy YAML config to v2 format")
    m.add_argument("input", help="Legacy YAML file to migrate")
    m.add_argument("--kind", choices=["project", "board", "timing", "ip"], default=None,
                   help="Force YAML kind (auto-detected if omitted)")
    m.set_defaults(func=cmd_migrate)

    return ap


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
