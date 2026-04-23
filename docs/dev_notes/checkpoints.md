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
