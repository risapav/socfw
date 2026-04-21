from __future__ import annotations
from typing import Protocol, Any

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact


class BaseEmitter(Protocol):
    family: str

    def emit(self, ctx: BuildContext, ir: Any) -> list[GeneratedArtifact]:
        ...
