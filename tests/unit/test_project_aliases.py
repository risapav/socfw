from __future__ import annotations

from socfw.config.aliases import normalize_project_aliases


def _run(data):
    result, diags = normalize_project_aliases(data, file="test.yaml")
    return result, [d.code for d in diags]


def test_timing_config_to_file():
    d, codes = _run({"timing": {"config": "t.yaml"}})
    assert d["timing"]["file"] == "t.yaml"
    assert "PRJ_ALIAS001" in codes


def test_timing_file_wins():
    d, codes = _run({"timing": {"config": "old.yaml", "file": "new.yaml"}})
    assert d["timing"]["file"] == "new.yaml"
    assert "PRJ_ALIAS001" not in codes


def test_paths_ip_plugins_to_registries():
    d, codes = _run({"paths": {"ip_plugins": ["a", "b"]}})
    assert d["registries"]["ip"] == ["a", "b"]
    assert "PRJ_ALIAS002" in codes


def test_paths_ip_plugins_skipped_when_registries_ip_set():
    d, codes = _run({"paths": {"ip_plugins": ["a"]}, "registries": {"ip": ["b"]}})
    assert d["registries"]["ip"] == ["b"]
    assert "PRJ_ALIAS002" not in codes


def test_board_type_to_project_board():
    d, codes = _run({"board": {"type": "de10nano"}})
    assert d["project"]["board"] == "de10nano"
    assert "PRJ_ALIAS003" in codes


def test_board_file_to_project_board_file():
    d, codes = _run({"board": {"file": "boards/de10.yaml"}})
    assert d["project"]["board_file"] == "boards/de10.yaml"
    assert "PRJ_ALIAS004" in codes


def test_design_name_to_project_name():
    d, codes = _run({"design": {"name": "mysoc"}})
    assert d["project"]["name"] == "mysoc"
    assert "PRJ_ALIAS005" in codes


def test_design_mode_to_project_mode():
    d, codes = _run({"design": {"mode": "fpga"}})
    assert d["project"]["mode"] == "fpga"
    assert "PRJ_ALIAS006" in codes


def test_dict_modules_to_list():
    d, codes = _run({"modules": {"uart0": {"type": "uart", "params": {"BAUD": 115200}}}})
    assert isinstance(d["modules"], list)
    assert d["modules"][0]["instance"] == "uart0"
    assert d["modules"][0]["type"] == "uart"
    assert d["modules"][0]["params"] == {"BAUD": 115200}
    assert "PRJ_ALIAS007" in codes


def test_no_aliases_no_diags():
    d, codes = _run({"project": {"name": "clean"}})
    assert d == {"project": {"name": "clean"}}
    assert codes == []


def test_original_not_mutated():
    original = {"timing": {"config": "t.yaml"}}
    normalize_project_aliases(original, file="test.yaml")
    assert "file" not in original["timing"]
