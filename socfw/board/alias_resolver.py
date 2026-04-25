from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation


class AliasResolver:
    def __init__(self, board_aliases: dict[str, str], file: str = ""):
        self._aliases = board_aliases
        self._file = file

    def resolve_ref(self, ref: str) -> tuple[str, list[Diagnostic]]:
        """
        Resolve a board: ref, expanding @alias if present.
        Returns (resolved_ref, diagnostics).
        """
        if not ref.startswith("board:"):
            return ref, []

        path = ref[len("board:"):]
        if not path.startswith("@"):
            return ref, []

        alias_key = path[1:]
        if alias_key not in self._aliases:
            return ref, [
                Diagnostic(
                    code="BRD_ALIAS404",
                    severity=Severity.ERROR,
                    message=f"Unknown board alias '@{alias_key}'",
                    subject="board.aliases",
                    spans=(SourceLocation(file=self._file),),
                    hints=(
                        f"Available aliases: {', '.join(sorted(self._aliases))}",
                    ) if self._aliases else ("No aliases defined in board YAML.",),
                )
            ]

        resolved_path = self._aliases[alias_key]
        return f"board:{resolved_path}", []

    def resolve_refs(self, refs: list[str]) -> tuple[list[str], list[Diagnostic]]:
        """Resolve a list of refs, expanding aliases."""
        resolved = []
        diags: list[Diagnostic] = []
        for ref in refs:
            r, d = self.resolve_ref(ref)
            resolved.append(r)
            diags.extend(d)
        return resolved, diags
