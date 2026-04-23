from __future__ import annotations

from socfw.core.diagnostics import (
    Diagnostic,
    RelatedDiagnosticRef,
    Severity,
    SourceSpan,
    SuggestedFix,
)


def err(
    code: str,
    message: str,
    subject: str,
    *,
    file: str | None = None,
    path: str | None = None,
    hints: list[str] | None = None,
    fixes: list[SuggestedFix] | None = None,
    related: list[RelatedDiagnosticRef] | None = None,
    category: str = "general",
    detail: str | None = None,
) -> Diagnostic:
    spans: tuple[SourceSpan, ...] = ()
    if file is not None:
        spans = (SourceSpan(file=file, path=path),)

    return Diagnostic(
        code=code,
        severity=Severity.ERROR,
        message=message,
        subject=subject,
        spans=spans,
        hints=tuple(hints or []),
        suggested_fixes=tuple(fixes or []),
        related=tuple(related or []),
        category=category,
        detail=detail,
    )


def warn(
    code: str,
    message: str,
    subject: str,
    *,
    file: str | None = None,
    path: str | None = None,
    hints: list[str] | None = None,
    category: str = "general",
    detail: str | None = None,
) -> Diagnostic:
    spans: tuple[SourceSpan, ...] = ()
    if file is not None:
        spans = (SourceSpan(file=file, path=path),)

    return Diagnostic(
        code=code,
        severity=Severity.WARNING,
        message=message,
        subject=subject,
        spans=spans,
        hints=tuple(hints or []),
        category=category,
        detail=detail,
    )
