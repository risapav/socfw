# Examples

## Blink

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
```

Purpose:
- standalone project
- board pack resolution
- local IP descriptor

## PLL

```bash
socfw build tests/golden/fixtures/pll_converged/project.yaml --out build/pll_converged
```

Purpose:
- generated clock timing
- PLL-style integration

## Vendor PLL

```bash
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/vendor_pll_soc
```

Purpose:
- vendor pack
- QIP export
- SDC export

## Vendor SDRAM

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
```

Purpose:
- external SDRAM board resources
- vendor memory IP
- simple_bus to wishbone bridge scaffold
