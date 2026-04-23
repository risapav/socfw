from pathlib import Path

from socfw.scaffold.generator import ScaffoldGenerator
from socfw.scaffold.model import InitRequest


def test_init_blink_scaffold(tmp_path):
    gen = ScaffoldGenerator(templates_dir="socfw/templates")
    created = gen.generate(
        InitRequest(
            name="demo_blink",
            out_dir=str(tmp_path),
            template="blink",
            board="qmtech_ep4ce55",
        )
    )

    root = tmp_path / "demo_blink"
    assert root.exists()
    assert (root / "project.yaml").exists()
    assert (root / "ip" / "blink_test.ip.yaml").exists()
    assert (root / ".gitignore").exists()
    assert len(created) >= 3


def test_init_picorv32_scaffold(tmp_path):
    gen = ScaffoldGenerator(templates_dir="socfw/templates")
    gen.generate(
        InitRequest(
            name="demo_soc",
            out_dir=str(tmp_path),
            template="picorv32-soc",
            board="qmtech_ep4ce55",
            cpu="picorv32_min",
        )
    )

    root = tmp_path / "demo_soc"
    assert (root / "project.yaml").exists()
    assert (root / "fw" / "main.c").exists()
    assert (root / "fw" / "start.S").exists()
    assert (root / "fw" / "cpu_irq.h").exists()


def test_init_soc_led_scaffold(tmp_path):
    gen = ScaffoldGenerator(templates_dir="socfw/templates")
    gen.generate(
        InitRequest(
            name="demo_led",
            out_dir=str(tmp_path),
            template="soc-led",
        )
    )

    root = tmp_path / "demo_led"
    assert (root / "project.yaml").exists()
    assert (root / "ip" / "gpio.ip.yaml").exists()
    assert (root / "rtl" / "gpio_core.sv").exists()


def test_init_axi_bridge_scaffold(tmp_path):
    gen = ScaffoldGenerator(templates_dir="socfw/templates")
    gen.generate(
        InitRequest(
            name="demo_axi",
            out_dir=str(tmp_path),
            template="axi-bridge",
        )
    )

    root = tmp_path / "demo_axi"
    assert (root / "project.yaml").exists()
    assert (root / "ip" / "axi_gpio.ip.yaml").exists()
    assert (root / "rtl" / "axi_gpio.sv").exists()


def test_init_wishbone_bridge_scaffold(tmp_path):
    gen = ScaffoldGenerator(templates_dir="socfw/templates")
    gen.generate(
        InitRequest(
            name="demo_wb",
            out_dir=str(tmp_path),
            template="wishbone-bridge",
        )
    )

    root = tmp_path / "demo_wb"
    assert (root / "project.yaml").exists()
    assert (root / "ip" / "wb_gpio.ip.yaml").exists()
    assert (root / "rtl" / "wb_gpio.sv").exists()


def test_init_force_overwrite(tmp_path):
    gen = ScaffoldGenerator(templates_dir="socfw/templates")
    gen.generate(InitRequest(name="demo", out_dir=str(tmp_path), template="blink"))

    import pytest
    with pytest.raises(ValueError, match="not empty"):
        gen.generate(InitRequest(name="demo", out_dir=str(tmp_path), template="blink"))

    gen.generate(InitRequest(name="demo", out_dir=str(tmp_path), template="blink", force=True))
