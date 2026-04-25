from __future__ import annotations


class DoctorReport:
    def build(self, system) -> str:
        lines: list[str] = []

        lines.append("# socfw doctor")
        lines.append("")

        lines.append("## Project")
        lines.append(f"- name: {system.project.name}")
        lines.append(f"- mode: {system.project.mode}")
        lines.append(f"- file: {system.sources.project_file}")
        lines.append("")

        lines.append("## Board")
        lines.append(f"- id: {system.board.board_id}")
        lines.append(f"- file: {system.sources.board_file}")
        lines.append(f"- clock: {system.board.sys_clock.top_name} ({system.board.sys_clock.frequency_hz} Hz)")
        if system.board.sys_reset is not None:
            lines.append(f"- reset: {system.board.sys_reset.top_name}")
        else:
            lines.append("- reset: none")
        lines.append("")

        lines.append("## Timing")
        if system.sources.timing_file:
            lines.append(f"- file: {system.sources.timing_file}")
        else:
            lines.append("- file: none")
        if system.timing is not None:
            primary = getattr(system.timing, "primary_clocks", None) or getattr(system.timing, "clocks", [])
            lines.append(f"- clocks: {len(primary)}")
            lines.append(f"- generated clocks: {len(system.timing.generated_clocks)}")
            lines.append(f"- false paths: {len(system.timing.false_paths)}")
        lines.append("")

        lines.append("## Registries")
        lines.append("- packs:")
        for p in system.sources.pack_roots:
            lines.append(f"  - {p}")
        lines.append("- ip search dirs:")
        for p in system.sources.ip_search_dirs:
            lines.append(f"  - {p}")
        lines.append("- cpu search dirs:")
        for p in system.sources.cpu_search_dirs:
            lines.append(f"  - {p}")
        lines.append("")

        lines.append("## Compatibility aliases")
        if system.sources.aliases_used:
            for a in sorted(system.sources.aliases_used):
                lines.append(f"- {a}")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## IP catalog")
        if system.ip_catalog:
            for name in sorted(system.ip_catalog):
                desc = system.ip_catalog[name]
                src = getattr(desc, "source_file", None) or system.sources.ip_files.get(name, "")
                vendor = ""
                if getattr(desc, "vendor_info", None) is not None:
                    vendor = f" vendor={desc.vendor_info.vendor}/{desc.vendor_info.tool}"
                lines.append(f"- {name}: module={desc.module} category={desc.category}{vendor} file={src}")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## CPU catalog")
        if system.cpu_catalog:
            for name in sorted(system.cpu_catalog):
                desc = system.cpu_catalog[name]
                src = getattr(desc, "source_file", None) or system.sources.cpu_files.get(name, "")
                lines.append(f"- {name}: module={desc.module} family={desc.family} file={src}")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## Project modules")
        if system.project.modules:
            for mod in system.project.modules:
                lines.append(f"- {mod.instance}: type={mod.type_name}")
        else:
            lines.append("- none")
        lines.append("")

        return "\n".join(lines).rstrip() + "\n"
