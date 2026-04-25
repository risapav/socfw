from __future__ import annotations

from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity, SourceSpan


def resolve_relative(base_file: str, path: str) -> str:
    p = Path(path).expanduser()
    if p.is_absolute():
        return str(p.resolve())
    return str((Path(base_file).resolve().parent / p).resolve())


def missing_path_diag(*, code: str, file: str, path: str, subject: str, hint: str, severity: Severity = Severity.ERROR) -> Diagnostic:
    return Diagnostic(
        code=code,
        severity=severity,
        message=f"Referenced path does not exist: {path}",
        subject=subject,
        spans=(SourceSpan(file=file),),
        hints=(hint,),
    )


def check_existing_file(*, code: str, owner_file: str, ref_path: str, subject: str, hint: str) -> tuple[str, list[Diagnostic]]:
    resolved = resolve_relative(owner_file, ref_path)
    if not Path(resolved).is_file():
        return resolved, [missing_path_diag(code=code, file=owner_file, path=resolved, subject=subject, hint=hint)]
    return resolved, []


def check_existing_dir(*, code: str, owner_file: str, ref_path: str, subject: str, hint: str, severity: Severity = Severity.ERROR) -> tuple[str, list[Diagnostic]]:
    resolved = resolve_relative(owner_file, ref_path)
    if not Path(resolved).is_dir():
        return resolved, [missing_path_diag(code=code, file=owner_file, path=resolved, subject=subject, hint=hint, severity=severity)]
    return resolved, []
