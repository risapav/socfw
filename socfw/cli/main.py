from __future__ import annotations

import argparse
from pathlib import Path


def _default_templates_dir() -> str:
    return str(Path(__file__).resolve().parents[1] / "templates")


def cmd_validate(args) -> int:
    print(f"validate: {args.project}")
    print("(not yet implemented — system loader pending)")
    return 0


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

    return ap


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
