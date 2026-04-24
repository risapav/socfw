# v1.0 Cutover Readiness

## Required anchors

- [x] `blink_converged` validates
- [x] `blink_converged` builds
- [x] `vendor_pll_soc` validates
- [x] `vendor_pll_soc` builds
- [x] `vendor_pll_soc` golden passes
- [x] `vendor_sdram_soc` validates
- [x] `vendor_sdram_soc` builds
- [x] `vendor_sdram_soc` golden passes

## Tooling

- [x] `socfw validate` is documented
- [x] `socfw build` is documented
- [x] `socfw init` is documented
- [x] new-flow CI lane is required
- [x] legacy lane is compatibility-only

## Legacy freeze

- [x] legacy warning is emitted
- [x] freeze policy is documented
- [x] new projects use `socfw init`
- [x] legacy fallback is retained only temporarily

## Release candidate

- [ ] release notes added
- [ ] RC checklist added
- [ ] all required tests green
- [ ] tag candidate reviewed
