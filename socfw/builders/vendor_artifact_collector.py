from __future__ import annotations

from socfw.model.vendor_artifacts import VendorArtifactBundle


class VendorArtifactCollector:
    def collect(self, design) -> VendorArtifactBundle:
        bundle = VendorArtifactBundle()
        seen: set[str] = set()

        used_types = {m.type_name for m in design.system.project.modules}
        if design.system.cpu is not None:
            used_types.add(design.system.cpu.type_name)

        for t in sorted(used_types):
            ip = design.system.ip_catalog.get(t)
            if ip is not None and ip.vendor_info is not None:
                if ip.vendor_info.qip and ip.vendor_info.qip not in seen:
                    bundle.qip_files.append(ip.vendor_info.qip)
                    seen.add(ip.vendor_info.qip)
                    # Mark all synthesis artifacts as QIP-managed (don't emit separately)
                    for art in ip.artifacts.synthesis:
                        bundle.rtl_files.append(art)  # track for exclusion
                for sdc in ip.vendor_info.sdc:
                    if sdc not in seen:
                        bundle.sdc_files.append(sdc)
                        seen.add(sdc)

        return bundle
