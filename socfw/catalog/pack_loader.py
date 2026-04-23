from __future__ import annotations

from pydantic import ValidationError

from socfw.catalog.pack_model import PackManifest
from socfw.catalog.pack_schema import PackManifestSchema
from socfw.config.common import load_yaml_file
from socfw.core.diag_builders import err
from socfw.core.result import Result


class PackLoader:
    def load(self, path: str) -> Result[PackManifest]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = PackManifestSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(diagnostics=[
                err(
                    "PACK100",
                    f"Invalid pack manifest: {exc}",
                    "pack",
                    file=path,
                    category="catalog",
                )
            ])

        return Result(value=PackManifest(
            name=doc.name,
            title=doc.title,
            description=doc.description,
            provides=tuple(doc.provides),
        ))
