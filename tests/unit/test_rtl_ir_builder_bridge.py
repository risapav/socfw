from socfw.builders.rtl_ir_builder import RtlIrBuilder
from socfw.elaborate.bridge_plan import PlannedBridge


def test_rtl_ir_builder_adds_planned_bridge_instance():
    bridge = PlannedBridge(
        instance="u_bridge_sdram0",
        kind="simple_bus_to_wishbone",
        src_protocol="simple_bus",
        dst_protocol="wishbone",
        target_module="sdram0",
        fabric="main",
        rtl_file="bridge.sv",
    )

    top = RtlIrBuilder().build(system=None, planned_bridges=[bridge])

    assert len(top.instances) == 1
    assert top.instances[0].module == "simple_bus_to_wishbone_bridge"
    assert top.instances[0].instance == "u_bridge_sdram0"


def test_rtl_ir_builder_empty_when_no_bridges():
    top = RtlIrBuilder().build(system=None, planned_bridges=[])

    assert len(top.instances) == 0
    assert top.module_name == "soc_top"
