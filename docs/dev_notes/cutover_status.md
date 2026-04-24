# Cutover Status

Tracks migration of all projects from legacy flow to the new `socfw` flow.

## Hard Cutover Checklist

### New flow readiness

- [x] `socfw` CLI is the documented default (`socfw build`, `socfw validate`, `socfw init`, `socfw build-fw`, `socfw sim-smoke`)
- [x] `socfw init` scaffolds new projects
- [x] Pack-aware board resolution is stable (builtin + vendor packs)
- [x] Vendor PLL fixture is green (`vendor_pll_soc`)
- [x] Vendor SDRAM fixture is green (`vendor_sdram_soc`)
- [x] Stable golden tests are green (`tests/golden/`)
- [x] CI required lane uses new flow (unit + integration + golden)

### Legacy freeze readiness

- [x] `legacy/` directory exists with freeze policy documented
- [x] No new features added to legacy path
- [ ] Active projects have migration status assigned (see table below)
- [ ] Exceptions are documented

### Default switch

- [ ] README updated to show only new flow
- [ ] Onboarding docs updated
- [ ] Examples updated to pack-aware layout

---

## Project Migration Status

| Project          | Current flow | Target flow | Status      | Owner | Notes                        |
| ---------------- | ------------ | ----------- | ----------- | ----- | -----------------------------|
| blink_test_01    | socfw        | socfw       | done        | —     | stable golden                |
| blink_test_02    | socfw        | socfw       | done        | —     | PLL stable golden            |
| vendor_pll_soc   | socfw        | socfw       | done        | —     | QIP/SDC export verified      |
| vendor_sdram_soc | socfw        | socfw       | done        | —     | top wiring + QIP/SDC green   |

---

## Project Classification

### Group 1 — migrated now

Simple standalone/blink projects. Already green.

### Group 2 — migrated with controlled sprint

Vendor PLL and SDRAM projects. Now green after vendor convergence sprint.

### Group 3 — legacy-exception (if any)

Projects with complex workspace ties, undocumented vendor exotics, or custom tool invocations. Must be explicitly approved and have a migration deadline.

---

## Policy for New Projects

From the default switch point forward:

- New projects **must** be created via `socfw init` or the pack-aware project layout
- Copying old project skeletons is not allowed
- New board definitions must go through the pack system
- New vendor IP must have a descriptor (`.ip.yaml` with `vendor:` section)

## Current default

The documented default flow is now:

```bash
socfw validate <project.yaml>
socfw build <project.yaml> --out <dir>
```

Legacy flow is retained only as fallback during migration.

## CI status

Required lane:
- unit tests
- integration tests (non-firmware)
- new-flow fixture validation
- new-flow fixture builds
- golden tests

Compatibility lane:
- legacy smoke
- non-blocking (`continue-on-error: true`)

## Legacy freeze

Status: active

Legacy is now frozen for feature development.
All new project work should use `socfw init` or an existing new-flow fixture.
