from __future__ import annotations

from pydantic import ValidationError

from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation


def _loc_to_path(loc) -> str:
    return ".".join(str(x) for x in loc)


def format_pydantic_issue(exc: Exception) -> str:
    if isinstance(exc, ValidationError):
        parts = []
        for err in exc.errors():
            loc = _loc_to_path(err.get("loc", ()))
            msg = err.get("msg", "invalid value")
            parts.append(f"{loc}: {msg}")
        return "; ".join(parts)

    return str(exc)


def project_schema_error(exc: Exception, *, file: str) -> Diagnostic:
    detail = format_pydantic_issue(exc)

    hints = (
        "Use canonical project schema v2.",
        "Expected top-level keys: version, kind, project, registries, clocks, modules.",
        "Project metadata must be under `project:`.",
        "Use `timing.file`, not `timing.config`, unless alias normalization is enabled.",
        "Use list-style modules: `modules: [ { instance, type, ... } ]`.",
        f"Raw schema detail: {detail}",
    )

    return Diagnostic(
        code="PRJ100",
        severity=Severity.ERROR,
        message="Invalid project YAML schema",
        subject="project",
        spans=(SourceLocation(file=file),),
        hints=hints,
    )


def timing_schema_error(exc: Exception, *, file: str) -> Diagnostic:
    detail = format_pydantic_issue(exc)

    hints = (
        "Use canonical timing schema v2.",
        "Expected shape: version: 2, kind: timing, timing: { clocks, io_delays, false_paths }.",
        "If your file has top-level `clocks`, `io_delays`, or `false_paths`, wrap them under `timing:`.",
        "Example: timing: { clocks: [...], io_delays: {...}, false_paths: [...] }.",
        f"Raw schema detail: {detail}",
    )

    return Diagnostic(
        code="TIM100",
        severity=Severity.ERROR,
        message="Invalid timing YAML schema",
        subject="timing",
        spans=(SourceLocation(file=file),),
        hints=hints,
    )


def ip_schema_error(exc: Exception, *, file: str) -> Diagnostic:
    detail = format_pydantic_issue(exc)

    return Diagnostic(
        code="IP100",
        severity=Severity.ERROR,
        message="Invalid IP descriptor YAML schema",
        subject="ip",
        spans=(SourceLocation(file=file),),
        hints=(
            "Use canonical IP schema v2.",
            "Expected: version: 2, kind: ip, ip: { name, module, category }.",
            "Use `integration.needs_bus`, not `config.needs_bus`.",
            "Use `reset.port` and `reset.active_high`, not `port_bindings.reset` or `config.active_high_reset`.",
            "Use `clocking.primary_input_port` and `clocking.outputs` for clock-capable IP.",
            "Use `ports:` to declare RTL port names, directions and widths.",
            "Use `artifacts.synthesis:` for RTL/QIP files.",
            "Run `socfw explain-schema ip` for a canonical example.",
            f"Raw schema detail: {detail}",
        ),
    )


def board_schema_error(exc: Exception, *, file: str) -> Diagnostic:
    detail = format_pydantic_issue(exc)

    return Diagnostic(
        code="BRD100",
        severity=Severity.ERROR,
        message="Invalid board YAML schema",
        subject="board",
        spans=(SourceLocation(file=file),),
        hints=(
            "Expected shape: version, kind: board, board, fpga, system, resources.",
            "System clock must be under `system.clock`.",
            "Board resources should define kind/top_name/pin or pins.",
            f"Raw schema detail: {detail}",
        ),
    )
