from __future__ import annotations

from socfw.config.aliases import normalize_timing_aliases


def _run(data):
    result, diags = normalize_timing_aliases(data, file="test.yaml")
    return result, [d.code for d in diags]


def test_top_level_keys_moved_under_timing():
    d, codes = _run({"clocks": [{"name": "sys"}], "io_delays": {}})
    assert "timing" in d
    assert d["timing"]["clocks"] == [{"name": "sys"}]
    assert d["timing"]["io_delays"] == {}
    assert "TIM_ALIAS001" in codes


def test_timing_wrapper_already_present_no_alias():
    d, codes = _run({"timing": {"clocks": []}})
    assert d == {"timing": {"clocks": []}}
    assert codes == []


def test_no_timing_keys_no_alias():
    d, codes = _run({"other": 1})
    assert "timing" not in d
    assert codes == []


def test_original_not_mutated():
    original = {"clocks": [{"name": "sys"}]}
    normalize_timing_aliases(original, file="test.yaml")
    assert "timing" not in original


def test_false_paths_moved():
    d, codes = _run({"false_paths": [{"from_clock": "a", "to_clock": "b"}]})
    assert d["timing"]["false_paths"] == [{"from_clock": "a", "to_clock": "b"}]
    assert "TIM_ALIAS001" in codes


def test_generated_clocks_moved():
    d, codes = _run({"generated_clocks": []})
    assert "timing" in d
    assert "TIM_ALIAS001" in codes
