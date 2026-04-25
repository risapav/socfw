from socfw.reports.path_normalizer import ReportPathNormalizer


def test_report_path_normalizer_out_dir(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    fp = out / "rtl" / "soc_top.sv"
    fp.parent.mkdir()
    fp.write_text("", encoding="utf-8")

    n = ReportPathNormalizer(out_dir=str(out), repo_root=str(tmp_path))
    assert n.normalize(str(fp)) == "$OUT/rtl/soc_top.sv"


def test_report_path_normalizer_repo_root(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    fp = tmp_path / "packs" / "vendor" / "ip.qip"
    fp.parent.mkdir(parents=True)
    fp.write_text("", encoding="utf-8")

    n = ReportPathNormalizer(out_dir=str(out), repo_root=str(tmp_path))
    assert n.normalize(str(fp)) == "$REPO/packs/vendor/ip.qip"
