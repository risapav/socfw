from socfw.model.board import (
    BoardClockDef,
    BoardModel,
    BoardResetDef,
    BoardResource,
    BoardVectorSignal,
)
from socfw.model.ip import IpDescriptor, IpOrigin, IpResetSemantics, IpClocking, IpArtifactBundle
from socfw.model.ports import PortDescriptor
from socfw.model.project import ModuleInstance, PortBinding, ProjectModel
from socfw.model.system import SystemModel
from socfw.validate.rules.binding_rules import BoardBindingRule


def _board():
    return BoardModel(
        board_id="demo",
        vendor=None,
        title=None,
        fpga_family="cyclone_iv",
        fpga_part="EP4CE55",
        sys_clock=BoardClockDef(id="sys_clk", top_name="SYS_CLK", pin="T8", frequency_hz=50_000_000),
        sys_reset=BoardResetDef(id="sys_rst", top_name="RESET_N", pin="N2", active_low=True),
        onboard={
            "leds": BoardResource(
                key="leds",
                kind="io",
                vectors={
                    "leds": BoardVectorSignal(
                        key="ONB_LEDS",
                        top_name="ONB_LEDS",
                        direction="output",
                        width=6,
                        pins={0: "A1", 1: "A2", 2: "A3", 3: "A4", 4: "A5", 5: "A6"},
                    )
                },
            )
        },
    )


def _ip(ip_port):
    return IpDescriptor(
        name="blink_test",
        module="blink_test",
        category="standalone",
        origin=IpOrigin(kind="source"),
        needs_bus=False,
        generate_registers=False,
        instantiate_directly=False,
        dependency_only=False,
        reset=IpResetSemantics(),
        clocking=IpClocking(),
        artifacts=IpArtifactBundle(),
        ports=(ip_port,),
    )


def _system(ip_port):
    return SystemModel(
        board=_board(),
        project=ProjectModel(
            name="demo",
            mode="standalone",
            board_ref="demo",
            modules=[
                ModuleInstance(
                    instance="blink",
                    type_name="blink_test",
                    port_bindings=[
                        PortBinding(
                            port_name="ONB_LEDS",
                            target="board:onboard.leds",
                        )
                    ],
                )
            ],
        ),
        timing=None,
        ip_catalog={"blink_test": _ip(ip_port)},
    )


def test_binding_width_match_passes():
    diags = BoardBindingRule().validate(
        _system(PortDescriptor(name="ONB_LEDS", direction="output", width=6))
    )
    assert not any(d.code == "BIND003" for d in diags)


def test_binding_width_mismatch_reports_error():
    diags = BoardBindingRule().validate(
        _system(PortDescriptor(name="ONB_LEDS", direction="output", width=4))
    )
    assert any(d.code == "BIND003" for d in diags)


def test_missing_ip_port_passes_no_error():
    diags = BoardBindingRule().validate(
        _system(PortDescriptor(name="OTHER", direction="output", width=6))
    )
    assert not any(d.code in {"BIND002", "BIND003"} for d in diags)


def _system_adapt(ip_port, adapt):
    return SystemModel(
        board=_board(),
        project=ProjectModel(
            name="demo",
            mode="standalone",
            board_ref="demo",
            modules=[
                ModuleInstance(
                    instance="blink",
                    type_name="blink_test",
                    port_bindings=[
                        PortBinding(
                            port_name="ONB_LEDS",
                            target="board:onboard.leds",
                            adapt=adapt,
                        )
                    ],
                )
            ],
        ),
        timing=None,
        ip_catalog={"blink_test": _ip(ip_port)},
    )


def test_width_mismatch_with_valid_adapt_no_bind003():
    diags = BoardBindingRule().validate(
        _system_adapt(PortDescriptor(name="ONB_LEDS", direction="output", width=4), adapt="zero_extend")
    )
    assert not any(d.code == "BIND003" for d in diags)


def test_invalid_adapt_mode_reports_bind006():
    diags = BoardBindingRule().validate(
        _system_adapt(PortDescriptor(name="ONB_LEDS", direction="output", width=4), adapt="stretch")
    )
    assert any(d.code == "BIND006" for d in diags)


def test_valid_adapt_modes_accepted():
    for mode in ("zero_extend", "truncate", "replicate"):
        diags = BoardBindingRule().validate(
            _system_adapt(PortDescriptor(name="ONB_LEDS", direction="output", width=4), adapt=mode)
        )
        assert not any(d.code == "BIND006" for d in diags), f"mode {mode} incorrectly rejected"


def test_adapt_on_inout_reports_bind007():
    diags = BoardBindingRule().validate(
        _system_adapt(PortDescriptor(name="ONB_LEDS", direction="inout", width=4), adapt="zero_extend")
    )
    assert any(d.code == "BIND007" for d in diags)


def test_bind003_hint_mentions_adapt():
    diags = BoardBindingRule().validate(
        _system(PortDescriptor(name="ONB_LEDS", direction="output", width=4))
    )
    bind003 = next(d for d in diags if d.code == "BIND003")
    assert "adapt" in bind003.message
