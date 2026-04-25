from socfw.build.artifacts import BuildArtifactInventory


def test_build_artifact_inventory_deduplicates_paths():
    inv = BuildArtifactInventory()
    inv.add("out/rtl/soc_top.sv", kind="rtl", producer="rtl")
    inv.add("out/rtl/soc_top.sv", kind="rtl", producer="rtl")

    assert inv.paths() == ["out/rtl/soc_top.sv"]
    assert len(inv.normalized()) == 1


def test_build_artifact_inventory_filters_by_kind():
    inv = BuildArtifactInventory()
    inv.add("a.sv", kind="rtl", producer="x")
    inv.add("b.tcl", kind="tcl", producer="y")

    assert len(inv.by_kind("rtl")) == 1
    assert inv.by_kind("rtl")[0].path == "a.sv"
