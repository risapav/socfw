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
