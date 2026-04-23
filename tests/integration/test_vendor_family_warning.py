from pathlib import Path

from socfw.validate.rules.vendor_rules import VendorFamilyMismatchRule
from socfw.model.ip import IpDescriptor, IpOrigin, IpResetSemantics, IpClocking, IpArtifactBundle, IpVendorInfo
from socfw.model.source_context import SourceContext


class _FpgaStub:
    family = "cyclone_iv_e"


class _BoardStub:
    fpga = _FpgaStub()


class _ModStub:
    type_name = "sys_pll"


class _ProjectStub:
    modules = [_ModStub()]


class _SystemStub:
    board = _BoardStub()
    project = _ProjectStub()
    sources = SourceContext(project_file="project.yaml")

    def __init__(self, fam):
        vendor = IpVendorInfo(vendor="intel", tool="quartus", family=fam)
        ip = IpDescriptor(
            name="sys_pll",
            module="sys_pll",
            category="clocking",
            origin=IpOrigin(kind="generated"),
            needs_bus=False,
            generate_registers=False,
            instantiate_directly=True,
            dependency_only=False,
            reset=IpResetSemantics(),
            clocking=IpClocking(),
            artifacts=IpArtifactBundle(),
            vendor_info=vendor,
        )
        self.ip_catalog = {"sys_pll": ip}


def test_no_warning_same_family():
    system = _SystemStub("cyclone_iv_e")
    diags = VendorFamilyMismatchRule().validate(system)
    assert diags == []


def test_warning_mismatched_family():
    system = _SystemStub("stratix")
    diags = VendorFamilyMismatchRule().validate(system)
    assert len(diags) == 1
    assert diags[0].code == "VND001"
    assert "stratix" in diags[0].message
