from dataclasses import dataclass

from socfw.build.top_injection import inject_bridge_instances


@dataclass(frozen=True)
class DummyBridge:
    instance: str = "u_bridge_sdram0"
    kind: str = "simple_bus_to_wishbone"


def test_inject_bridge_instances(tmp_path):
    rtl_dir = tmp_path / "rtl"
    rtl_dir.mkdir()
    soc_top = rtl_dir / "soc_top.sv"
    soc_top.write_text("module soc_top;\nendmodule\n", encoding="utf-8")

    patched = inject_bridge_instances(str(tmp_path), [DummyBridge()])

    assert patched is not None
    text = soc_top.read_text(encoding="utf-8")
    assert "socfw planned bridge instance" in text
    assert "simple_bus_to_wishbone_bridge" in text
    assert "u_bridge_sdram0" in text


def test_inject_is_idempotent(tmp_path):
    rtl_dir = tmp_path / "rtl"
    rtl_dir.mkdir()
    soc_top = rtl_dir / "soc_top.sv"
    soc_top.write_text("module soc_top;\nendmodule\n", encoding="utf-8")

    inject_bridge_instances(str(tmp_path), [DummyBridge()])
    text_first = soc_top.read_text(encoding="utf-8")
    inject_bridge_instances(str(tmp_path), [DummyBridge()])
    text_second = soc_top.read_text(encoding="utf-8")
    assert text_first == text_second


def test_inject_returns_none_when_no_bridges(tmp_path):
    rtl_dir = tmp_path / "rtl"
    rtl_dir.mkdir()
    (rtl_dir / "soc_top.sv").write_text("module soc_top;\nendmodule\n", encoding="utf-8")
    assert inject_bridge_instances(str(tmp_path), []) is None


def test_inject_returns_none_when_soc_top_missing(tmp_path):
    assert inject_bridge_instances(str(tmp_path), [DummyBridge()]) is None
