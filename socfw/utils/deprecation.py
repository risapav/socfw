from __future__ import annotations


def legacy_deprecation_message() -> str:
    return (
        "[DEPRECATED] Legacy build flow is in maintenance mode.\n"
        "Use: socfw validate <project.yaml>\n"
        "     socfw build <project.yaml> --out <dir>\n"
        "See: docs/dev_notes/cutover_status.md"
    )


def print_legacy_warning() -> None:
    print(legacy_deprecation_message())
