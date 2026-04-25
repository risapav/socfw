## Commit 51 — golden snapshot JSON provenance reportov

Cieľ:

* uzamknúť `build_provenance.json` pre vendor anchors
* potvrdiť, že path normalization funguje
* mať machine-portable golden snapshoty

Názov commitu:

```text
golden: snapshot JSON provenance reports for vendor anchors
```

## Pridať

```text
tests/golden/expected/vendor_pll_soc/reports/build_provenance.json
tests/golden/expected/vendor_sdram_soc/reports/build_provenance.json
```

## Upraviť

```text
tests/golden/test_vendor_pll_soc_golden.py
tests/golden/test_vendor_sdram_soc_golden.py
```

## `test_vendor_pll_soc_golden.py`

Doplň:

```python
_assert_same(
    out_dir / "reports" / "build_provenance.json",
    expected_root / "reports" / "build_provenance.json",
)
```

## `test_vendor_sdram_soc_golden.py`

Doplň:

```python
_assert_same(
    out_dir / "reports" / "build_provenance.json",
    expected_root / "reports" / "build_provenance.json",
)
```

## Vytvorenie snapshotov

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc

cp build/vendor_pll_soc/reports/build_provenance.json \
  tests/golden/expected/vendor_pll_soc/reports/build_provenance.json

cp build/vendor_sdram_soc/reports/build_provenance.json \
  tests/golden/expected/vendor_sdram_soc/reports/build_provenance.json
```

## Overenie

```bash
pytest tests/golden/test_vendor_pll_soc_golden.py
pytest tests/golden/test_vendor_sdram_soc_golden.py
```

## Definition of Done

Commit 51 je hotový, keď:

* JSON provenance je súčasťou golden coverage
* cesty sú `$OUT/...` alebo `$REPO/...`
* vendor PLL aj vendor SDRAM golden testy sú green

Ďalší commit:

```text
diagnostics: add path resolution checks for missing timing board ip and cpu files
```
