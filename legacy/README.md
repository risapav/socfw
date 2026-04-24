# legacy/

This directory contains deprecated build flow components kept temporarily for compatibility and migration fallback.

## Rules

- No new features added to anything in this directory
- Critical fixes only, with explicit justification
- All new work must target `socfw/`
- Legacy entrypoints should emit deprecation warnings where feasible

## Status

Legacy freeze is active. The `socfw` CLI (`socfw build`, `socfw validate`, `socfw init`, etc.) is the official default entrypoint for all new and migrating projects.

## Migration

Projects still on the legacy flow should be migrated using the project classification in `docs/dev_notes/cutover_status.md`.
