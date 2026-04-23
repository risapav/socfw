from __future__ import annotations

from socfw.core.diag_builders import warn
from socfw.validate.rules.base import ValidationRule


class VendorFamilyMismatchRule(ValidationRule):
    def validate(self, system) -> list:
        diags = []
        board_family = getattr(system.board.fpga, "family", None)

        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None or ip.vendor_info is None:
                continue

            fam = ip.vendor_info.family
            if fam and board_family and fam != board_family:
                diags.append(
                    warn(
                        "VND001",
                        f"Vendor IP '{ip.name}' targets family '{fam}', board uses '{board_family}'",
                        "vendor.family",
                        file=system.sources.project_file,
                        category="vendor",
                        hints=[
                            "Check whether the generated Quartus IP was created for the target FPGA family.",
                            "Regenerate the vendor IP for the board family if necessary.",
                        ],
                    )
                )

        return diags
