# Release Candidate Checklist

## Required test commands

```bash
pytest tests/unit
pytest tests/integration
pytest tests/golden
```

## Required fixture builds

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/rc/blink_converged
socfw build tests/golden/fixtures/pll_converged/project.yaml --out build/rc/pll_converged
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/rc/vendor_pll_soc
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/rc/vendor_sdram_soc
```

## Required manual review

- [ ] README quickstart uses `socfw`
- [ ] `socfw init` creates a valid project
- [ ] vendor PLL files export contains `QIP_FILE`
- [ ] vendor SDRAM files export contains `QIP_FILE`
- [ ] legacy warning is emitted
- [ ] CI new-flow lane is required
- [ ] legacy lane is non-blocking
- [ ] release notes are accurate

## Tag

```bash
git tag v1.0.0-cutover
```
