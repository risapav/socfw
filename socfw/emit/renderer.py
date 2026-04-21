from __future__ import annotations
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined


def _sv_param(value) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return f'"{value}"'
    return str(value)


class Renderer:
    def __init__(self, templates_dir: str | Path):
        self.env = Environment(
            loader=FileSystemLoader(str(templates_dir)),
            undefined=StrictUndefined,
            trim_blocks=True,
            lstrip_blocks=True,
            keep_trailing_newline=True,
        )
        self.env.filters["sv_param"] = _sv_param

    def render(self, template_name: str, **ctx) -> str:
        tmpl = self.env.get_template(template_name)
        return tmpl.render(**ctx)

    def write_text(self, path: Path, content: str, encoding: str = "utf-8") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding=encoding)
