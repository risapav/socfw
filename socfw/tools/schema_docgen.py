from __future__ import annotations

from pathlib import Path


class SchemaDocGenerator:
    def generate_markdown(self, *, title: str, schema: dict, out_file: str) -> str:
        lines: list[str] = []
        lines.append(f"# {title}\n")

        desc = schema.get("description")
        if desc:
            lines.append(desc)
            lines.append("")

        lines.append("## Top-level fields\n")

        props = schema.get("properties", {})
        required = set(schema.get("required", []))

        if props:
            lines.append("| Field | Type | Required | Default |")
            lines.append("|------|------|----------|---------|")
            for name in sorted(props.keys()):
                p = props[name]
                ptype = self._type_str(p)
                req = "yes" if name in required else "no"
                default = p.get("default", "")
                lines.append(f"| `{name}` | `{ptype}` | {req} | `{default}` |")
        else:
            lines.append("No top-level fields.")
        lines.append("")

        defs = schema.get("$defs", {})
        if defs:
            lines.append("## Nested objects\n")
            for def_name in sorted(defs.keys()):
                d = defs[def_name]
                lines.append(f"### {def_name}\n")
                dprops = d.get("properties", {})
                dreq = set(d.get("required", []))

                if dprops:
                    lines.append("| Field | Type | Required | Default |")
                    lines.append("|------|------|----------|---------|")
                    for name in sorted(dprops.keys()):
                        p = dprops[name]
                        ptype = self._type_str(p)
                        req = "yes" if name in dreq else "no"
                        default = p.get("default", "")
                        lines.append(f"| `{name}` | `{ptype}` | {req} | `{default}` |")
                else:
                    lines.append("No fields.")
                lines.append("")

        fp = Path(out_file)
        fp.parent.mkdir(parents=True, exist_ok=True)
        fp.write_text("\n".join(lines), encoding="utf-8")
        return str(fp)

    def _type_str(self, p: dict) -> str:
        if "$ref" in p:
            return p["$ref"].split("/")[-1]
        if "enum" in p:
            return "enum(" + ", ".join(map(str, p["enum"])) + ")"
        if "type" in p:
            return str(p["type"])
        if "anyOf" in p:
            return " | ".join(self._type_str(x) for x in p["anyOf"])
        if "items" in p:
            return f"list[{self._type_str(p['items'])}]"
        return "object"
