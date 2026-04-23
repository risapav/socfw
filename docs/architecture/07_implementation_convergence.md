# Implementation Convergence Plan

## Goal

Safely transition the repository from ad-hoc project scripts to the config-driven framework without disruption.

## What to Keep

- Existing `.sv/.v` IP blocks (domain assets)
- Quartus-generated IP files (`.qip`, `.sdc`, `.v`)
- Working Tcl and linker patterns
- Board pin maps
- Golden fixture projects as regression references

## What to Replace

- Config parsing mixed with topology decisions and emit logic
- Hardcoded board/PLL/SDRAM names in builders
- Project-root-relative artifact paths (replace with descriptor-relative)
- Ad-hoc vendor IP handling (replace with pack model)

## Target Layout

```
socfw/          # framework core
packs/          # board, IP, CPU, vendor packs
src/ip/         # shared RTL primitives
docs/           # architecture, user, generated
tests/          # unit, integration, golden fixtures
examples/       # reference projects
legacy/         # deprecated code (do not build on this)
```

## Migration Phases

### Phase 1 — Parallel core
New framework lives alongside old. New golden fixtures test new flow. (This phase is complete.)

### Phase 2 — Example parity
All important use-cases (blink, pll, soc_led, sdram, vendor pll, vendor sdram) work with new framework. (Substantially complete.)

### Phase 3 — Legacy freeze
Old entrypoints marked deprecated. New framework is default. No new features on old paths.

### Phase 4 — Legacy removal
Old code moved to `legacy/` or archived.

## Convergence Milestone

When the following conditions all pass:
- Stable golden fixtures: blink, pll, soc_led, sdram
- Vendor golden fixtures: vendor_pll_soc, vendor_sdram_soc
- Pack-based board/IP/CPU resolution working
- `socfw init` creates a working scaffold project
- CLI (`build`, `build-fw`, `validate`, `explain`, `init`) all functional

This milestone marks `v0.2.0-converged`.
