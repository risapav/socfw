from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class PackManifestSchema(BaseModel):
    version: Literal[1]
    kind: Literal["pack"]
    name: str
    title: str | None = None
    description: str | None = None
    provides: list[str] = Field(default_factory=list)
