from __future__ import annotations

from socfw.builders.vendor_artifact_collector import VendorArtifactCollector
from socfw.ir.files import FilesIR


class FilesIRBuilder:
    def __init__(self) -> None:
        self.vendor = VendorArtifactCollector()

    def build(self, design, rtl_ir) -> FilesIR:
        v = self.vendor.collect(design)
        return FilesIR(
            rtl_files=list(rtl_ir.extra_sources),
            qip_files=sorted(v.qip_files),
            sdc_files=sorted(v.sdc_files),
        )
