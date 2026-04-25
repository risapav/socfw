from __future__ import annotations

from pathlib import Path


class ReportPathNormalizer:
    def __init__(self, *, out_dir: str, repo_root: str | None = None) -> None:
        self.out_dir = Path(out_dir).resolve()
        self.repo_root = Path(repo_root).resolve() if repo_root else Path.cwd().resolve()

    def normalize(self, path: str) -> str:
        p = Path(path).resolve()

        try:
            return f"$OUT/{p.relative_to(self.out_dir)}"
        except ValueError:
            pass

        try:
            return f"$REPO/{p.relative_to(self.repo_root)}"
        except ValueError:
            pass

        return str(p)

    def normalize_list(self, paths: list[str]) -> list[str]:
        return sorted(dict.fromkeys(self.normalize(p) for p in paths))
