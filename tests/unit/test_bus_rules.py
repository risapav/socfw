from socfw.validate.rules.bus_rules import DuplicateAddressRegionRule
from socfw.model.source_context import SourceContext


class _FakeSystem:
    class project:
        modules = []
    ip_catalog = {}
    ram = None
    sources = SourceContext()


def test_duplicate_address_region_rule_no_overlap():
    diags = DuplicateAddressRegionRule().validate(_FakeSystem())
    assert not any(d.code == "BUS003" for d in diags)
