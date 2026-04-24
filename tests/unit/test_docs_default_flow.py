from pathlib import Path


def test_readme_uses_socfw_default_flow():
    text = Path("README.md").read_text(encoding="utf-8")
    assert "socfw validate" in text
    assert "socfw build" in text


def test_readme_references_converged_fixtures():
    text = Path("README.md").read_text(encoding="utf-8")
    assert "blink_converged" in text
    assert "vendor_pll_soc" in text
    assert "vendor_sdram_soc" in text
