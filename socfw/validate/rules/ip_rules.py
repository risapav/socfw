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
                            "Add a matching *.ip.yaml descriptor to a registered IP catalog path.",
                            "Or change the module type to an existing IP descriptor.",
                            f"Known IP descriptors: {known}",
                        ],
                    )
                )

        return diags
