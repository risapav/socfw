from __future__ import annotations

from socfw.builders.vendor_artifact_collector import VendorArtifactCollector
from socfw.ir.files import FilesIR


class FilesIRBuilder:
    def __init__(self) -> None:
        self.vendor = VendorArtifactCollector()

    def build(self, design, rtl_ir) -> FilesIR:
        v = self.vendor.collect(design)
        # Exclude files managed by QIP or SDC (qip_files, sdc_files, and qip-managed rtl)
        vendor_managed = set(v.qip_files) | set(v.sdc_files) | set(v.rtl_files)
        rtl_files = [f for f in rtl_ir.extra_sources if f not in vendor_managed]
        return FilesIR(
            rtl_files=rtl_files,
            qip_files=sorted(v.qip_files),
            sdc_files=sorted(v.sdc_files),
        )
