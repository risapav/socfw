from socfw.build.vendor_artifacts import collect_vendor_artifacts
from socfw.model.ip import IpVendorInfo
from socfw.model.source_context import SourceContext


class _IpStub:
    def __init__(self, vendor_info):
        self.vendor_info = vendor_info


class _ModuleStub:
    def __init__(self, type_name):
        self.type_name = type_name


class _ProjectStub:
    def __init__(self, modules):
        self.modules = modules


class _SystemStub:
    def __init__(self, modules, ip_catalog):
        self.project = _ProjectStub(modules)
        self.ip_catalog = ip_catalog
        self.cpu = None
        self.sources = SourceContext()


def test_collect_vendor_artifacts_from_used_modules():
    vendor = IpVendorInfo(
        vendor="intel",
        tool="quartus",
        qip="/tmp/sys_pll.qip",
        sdc=("/tmp/sys_pll.sdc",),
    )
    ip = _IpStub(vendor_info=vendor)
    system = _SystemStub(
        modules=[_ModuleStub(type_name="sys_pll")],
        ip_catalog={"sys_pll": ip},
    )

    bundle = collect_vendor_artifacts(system)
    assert bundle.qip_files == ["/tmp/sys_pll.qip"]
    assert bundle.sdc_files == ["/tmp/sys_pll.sdc"]


def test_collect_vendor_artifacts_ignores_non_vendor_ip():
    ip = _IpStub(vendor_info=None)
    system = _SystemStub(
        modules=[_ModuleStub(type_name="blink_test")],
        ip_catalog={"blink_test": ip},
    )

    bundle = collect_vendor_artifacts(system)
    assert bundle.qip_files == []
    assert bundle.sdc_files == []
