from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class VendorArtifactBundle:
    qip_files: list[str] = field(default_factory=list)
    sdc_files: list[str] = field(default_factory=list)


def collect_vendor_artifacts(system) -> VendorArtifactBundle:
    bundle = VendorArtifactBundle()
    seen_qip: set[str] = set()
    seen_sdc: set[str] = set()

    used_types = {m.type_name for m in system.project.modules}
    if system.cpu is not None:
        used_types.add(system.cpu.type_name)

    for type_name in sorted(used_types):
        ip = system.ip_catalog.get(type_name)
        if ip is not None and ip.vendor_info is not None:
            if ip.vendor_info.qip and ip.vendor_info.qip not in seen_qip:
                bundle.qip_files.append(ip.vendor_info.qip)
                seen_qip.add(ip.vendor_info.qip)

            for sdc in ip.vendor_info.sdc:
                if sdc not in seen_sdc:
                    bundle.sdc_files.append(sdc)
                    seen_sdc.add(sdc)

    bundle.qip_files = sorted(bundle.qip_files)
    bundle.sdc_files = sorted(bundle.sdc_files)
    return bundle
