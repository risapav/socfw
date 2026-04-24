from socfw.config.ip_loader import IpLoader


def test_ip_loader_loads_vendor_metadata():
    res = IpLoader().load_file("packs/vendor-intel/ip/sys_pll/sys_pll.ip.yaml")
    assert res.ok
    assert res.value is not None
    assert res.value.vendor_info is not None
    assert res.value.vendor_info.vendor == "intel"
    assert res.value.vendor_info.tool == "quartus"
    assert res.value.vendor_info.qip is not None
    assert res.value.vendor_info.qip.endswith("sys_pll.qip")
    assert len(res.value.vendor_info.sdc) == 1
