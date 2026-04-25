from __future__ import annotations

from socfw.config.aliases import normalize_project_aliases
from socfw.config.normalized import NormalizedDocument


def normalize_project_document(data: dict, *, file: str) -> NormalizedDocument:
    normalized, diags = normalize_project_aliases(data, file=file)

    aliases = [
        d.message
        for d in diags
        if str(getattr(d, "code", "")).startswith("PRJ_ALIAS")
    ]

    return NormalizedDocument(
        data=normalized,
        diagnostics=diags,
        aliases_used=aliases,
    )
