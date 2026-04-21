from __future__ import annotations
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined


class Renderer:
    def __init__(self, templates_dir: str | Path):
        self.env = Environment(
            loader=FileSystemLoader(str(templates_dir)),
            undefined=StrictUndefined,
            trim_blocks=True,
            lstrip_blocks=True,
            keep_trailing_newline=True,
        )

    def render(self, template_name: str, **ctx) -> str:
        tmpl = self.env.get_template(template_name)
        return tmpl.render(**ctx)

    def write_text(self, path: Path, content: str, encoding: str = "utf-8") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding=encoding)
