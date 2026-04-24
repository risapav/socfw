# Development Checkpoints

## checkpoint/first-convergence-sprint (files 52–56)

**Status: complete**

All green:
- `blink_test_01` builds via pack-aware board resolution (no board_file needed)
- `blink_test_02` builds with generated clock flow
- `vendor_pll_soc` builds with sys_pll from vendor-intel pack; files.tcl has QIP_FILE
- `vendor_sdram_soc` builds with sdram_ctrl via wishbone bridge; files.tcl has QIP_FILE
- Golden snapshots locked for blink_test_01 and vendor_pll_soc

**New capabilities:**
- Board resolution via pack (builtin + user packs)
- Vendor IP with QIP/SDC-aware files.tcl export
- `registries.packs` in project.yaml
- Descriptor-relative artifact path normalization

**Next sprint:** vendor_sdram convergence + firmware-heavy fixtures

## m4-new-flow-anchors (files 77–85)

**Status: complete**

- `blink_converged` added
- `pll_converged` added
- `vendor_pll_soc` added
- `vendor_sdram_soc` added
- build summary reporting added
- vendor PLL and SDRAM golden anchors added

**Next:**
- default CLI documentation
- legacy warning messages
- CI lane split

## m5-docs-default-switch (files 86–87)

**Status: complete**

- README quickstart uses `socfw`
- user getting started guide uses `socfw` and converged fixtures
- examples guide uses converged fixtures
- legacy flow is documented only as migration fallback
- deprecation warning added to `legacy_build.py`

**Next:**
- CI required lane switch
- legacy compatibility lane

## m6-ci-default-switch (file 88)

**Status: complete**

- new-flow fixtures run in required CI lane
- unit tests run in required CI lane
- integration tests run in required CI lane
- golden tests run in required CI lane
- legacy smoke moved to compatibility lane (`continue-on-error: true`)

**Next:**
- default project scaffolding
- legacy freeze enforcement

## m7-new-flow-scaffolding (file 89)

**Status: complete**

- `socfw init --template blink` creates pack-aware projects via `ProjectInitializer`
- generated blink project validates through new flow
- new projects include `rtl/blink_test.sv` alongside `project.yaml` and IP descriptor
- new projects no longer need legacy skeleton copying

**Next:**
- freeze legacy feature additions
- prepare cutover tag

## m8-legacy-freeze (file 90)

**Status: complete**

- legacy feature path frozen
- v1.0 readiness checklist added
- new work targets `socfw/`
- legacy retained only as compatibility fallback

**Next:**
- release candidate tag
- final cutover review

## m9-v1.0-rc (file 91)

**Status: complete**

- release notes added (`docs/releases/v1.0.0-cutover.md`)
- RC checklist added
- cutover tag procedure documented

**Next:**
- run full CI
- create `v1.0.0-cutover` tag
