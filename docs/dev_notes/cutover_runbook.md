# Final Cutover Runbook — `v1.0.0-cutover`

## 1. Clean workspace

```bash
git status
```

Must show: no uncommitted changes, no leftover build files in repo.

## 2. Fresh install

```bash
python -m pip install --upgrade pip
pip install -e .
pip install pytest
```

## 3. Full test pass (must be 100% green)

```bash
pytest tests/unit
pytest tests/integration
pytest tests/golden
```

Expected: 0 failures, 0 flaky reruns.

## 4. Manual anchor validation

```bash
socfw validate tests/golden/fixtures/blink_converged/project.yaml
socfw validate tests/golden/fixtures/pll_converged/project.yaml
socfw validate tests/golden/fixtures/vendor_pll_soc/project.yaml
socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml
```

All must pass.

## 5. Manual anchor builds

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/rc/blink
socfw build tests/golden/fixtures/pll_converged/project.yaml --out build/rc/pll
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/rc/vendor_pll
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/rc/vendor_sdram
```

## 6. Spot-check outputs

### Vendor PLL

```bash
cat build/rc/vendor_pll/files.tcl
```

Must contain: `QIP_FILE`, `SDC_FILE`.

### Vendor SDRAM

```bash
cat build/rc/vendor_sdram/reports/bridge_summary.txt
```

Must contain: `simple_bus -> wishbone`.

### Build summary

```bash
cat build/rc/vendor_sdram/reports/build_summary.md
```

Must contain: project name, board, IP list, vendor artifacts, bridge summary.

## 7. Verify `socfw init`

```bash
socfw init demo_test demo_test --template blink --board qmtech_ep4ce55
socfw validate demo_test/project.yaml
```

Must pass.

## 8. Verify legacy warning

```bash
python -c "from legacy_build import build_legacy; import tempfile; build_legacy('tests/golden/fixtures/vendor_sdram_soc/project.yaml', tempfile.mkdtemp())"
```

Must print: `[DEPRECATED] Legacy build flow is in maintenance mode.`

## 9. README sanity

```bash
grep -R "socfw build" README.md docs/
```

New flow must be the documented default.

## 10. Final GO / NO-GO

If all above pass: **GO** — proceed to tagging.

If anything fails: fix → repeat runbook from step 3.

## 11. Tagging

```bash
git tag v1.0.0-cutover
git push origin v1.0.0-cutover
```

## 12. GitHub release (optional)

Use the content from `docs/releases/v1.0.0-cutover.md`.

## 13. Post-cutover rules

Do NOT immediately:
- remove legacy
- large refactors
- new feature burst

Let the system stabilize first. Recommended next steps after cutover:

1. `stability: fix any post-cutover regressions`
2. `bridge: real RTL bridge implementation (replace scaffold)`
3. `cleanup: remove legacy backend (v1.1+)`
