from __future__ import annotations

from socfw.core.diag_builders import err
from socfw.validate.rules.base import ValidationRule


class UnknownIpTypeRule(ValidationRule):
    def validate(self, system) -> list:
        diags = []
        known = ", ".join(sorted(system.ip_catalog.keys())) or "none"

        for idx, mod in enumerate(system.project.modules):
            if mod.type_name not in system.ip_catalog:
                diags.append(
                    err(
                        "IP001",
                        f"Unknown IP type '{mod.type_name}' for instance '{mod.instance}'",
                        "project.modules",
                        file=system.sources.project_file,
                        path=f"modules[{idx}].type",
                        hints=[
                            f"Project module `{mod.instance}` uses `type: {mod.type_name}`.",
                            "That value must match `ip.name` in one loaded *.ip.yaml descriptor.",
                            "Check `registries.ip` paths in project.yaml.",
                            "Check `registries.packs` if the IP should come from a pack.",
                            f"Known IP descriptors: {known}",
                            "Run `socfw doctor project.yaml` to inspect loaded IP catalog.",
                        ],
                    )
                )

        return diags
