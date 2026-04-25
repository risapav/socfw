from __future__ import annotations

from pathlib import Path

from socfw.build.provenance import SocBuildProvenance


class BuildSummaryReport:
    def build(self, provenance: SocBuildProvenance) -> str:
        lines: list[str] = []

        lines.append("# Build Summary")
        lines.append("")
        lines.append("## Project")
        lines.append("")
        lines.append(f"- Name: `{provenance.project_name}`")
        lines.append(f"- Mode: `{provenance.project_mode}`")
        lines.append(f"- Board: `{provenance.board_id}`")
        lines.append("")

        lines.append("## CPU")
        lines.append("")
        if provenance.cpu_type is None:
            lines.append("- CPU: none")
        else:
            lines.append(f"- CPU type: `{provenance.cpu_type}`")
            if provenance.cpu_module:
                lines.append(f"- CPU module: `{provenance.cpu_module}`")
        lines.append("")

        lines.append("## Modules and IP")
        lines.append("")
        if provenance.module_instances:
            for name in sorted(provenance.module_instances):
                lines.append(f"- Module instance: `{name}`")
        else:
            lines.append("- Module instances: none")
        lines.append("")

        if provenance.ip_types:
            for name in sorted(provenance.ip_types):
                lines.append(f"- IP type: `{name}`")
        else:
            lines.append("- IP types: none")
        lines.append("")

        lines.append("## Timing")
        lines.append("")
        lines.append(f"- Generated clocks: `{provenance.timing_generated_clocks}`")
        lines.append(f"- False paths: `{provenance.timing_false_paths}`")
        lines.append("")

        lines.append("## Vendor Artifacts")
        lines.append("")
        if provenance.vendor_qip_files:
            for qip in sorted(provenance.vendor_qip_files):
                lines.append(f"- QIP: `{qip}`")
        else:
            lines.append("- QIP: none")

        if provenance.vendor_sdc_files:
            for sdc in sorted(provenance.vendor_sdc_files):
                lines.append(f"- SDC: `{sdc}`")
        else:
            lines.append("- Vendor SDC: none")
        lines.append("")

        lines.append("## Bridges")
        lines.append("")
        if provenance.bridge_pairs:
            for pair in sorted(provenance.bridge_pairs):
                lines.append(f"- `{pair}`")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## Compatibility Aliases")
        lines.append("")
        if provenance.aliases_used:
            for alias in sorted(provenance.aliases_used):
                lines.append(f"- {alias}")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## Artifact Inventory")
        lines.append("")
        if getattr(provenance, "artifact_kinds", None):
            for kind in sorted(provenance.artifact_kinds):
                lines.append(f"- {kind}: `{provenance.artifact_kinds[kind]}`")
        else:
            lines.append("- none")
        lines.append("")

        lines.append("## Generated Files")
        lines.append("")
        if provenance.generated_files:
            for fp in sorted(provenance.generated_files):
                lines.append(f"- `{fp}`")
        else:
            lines.append("- none")
        lines.append("")

        return "\n".join(lines).rstrip() + "\n"

    def write(self, out_dir: str, provenance: SocBuildProvenance) -> str:
        reports_dir = Path(out_dir) / "reports"
        reports_dir.mkdir(parents=True, exist_ok=True)
        out_file = reports_dir / "build_summary.md"
        out_file.write_text(self.build(provenance), encoding="utf-8")
        return str(out_file)
