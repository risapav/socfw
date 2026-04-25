# Legacy Freeze Policy

The legacy flow is now frozen.

## Rules

- No new features in legacy build flow.
- No new board/IP/CPU models should be added only to legacy paths.
- Critical bug fixes are allowed only when they unblock migration.
- Compatibility shims may call legacy code temporarily.
- All new architecture work must live under `socfw/`.

## Allowed changes

- Critical fixes
- Deprecation warnings
- Compatibility adapters
- Test-only migration support

## Not allowed

- New feature development
- New project skeletons
- New vendor-specific hacks
- New implicit config conventions

## Isolation

Legacy code must not:
- patch native outputs
- generate native reports
- mutate native build artifacts
- own vendor QIP/SDC export

Native emitters are the source of truth for:
- rtl/soc_top.sv
- hal/files.tcl
- hal/board.tcl
- timing/soc_top.sdc
- reports/build_summary.md
