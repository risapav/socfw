# CLAUDE.md — sdram_test_02 Rules

## Purpose

Narrow simulation laboratory to diagnose the SDRAM read path timing problem from sdram_test_01.

**One question only:** Why does the 16-bit -> 32-bit word assembly fail in the AXI path when RSHIFT=0?

## Hard restrictions

- Do NOT run Quartus (no syn, fit, sta, asm).
- Do NOT touch HW / board.yaml.
- Do NOT implement AXI.
- Do NOT copy BIST or scheduler.
- Do NOT start XFCP integration.
- Do NOT modify board.yaml (ever — owned by user exclusively).

## Workflow

1. Before any test: read STATUS.md.
2. After every `make` run: record result in docs/04_EXPERIMENT_LOG.md.
3. After every experiment: update STATUS.md.
4. Do NOT claim PASS without a log that starts with `# BUILD_CONFIG PROJECT=sdram_test_02 RSHIFT=N CMDREG=1`.

## Feedback format (after every command)

```
COMMAND: <exact command>
RESULT: PASS/FAIL
FILES CHANGED: <list>
NEXT: <one action>
```

If a test fails, STOP. Do not try another fix unless the user explicitly asks.

## Experiment discipline

Every run in docs/04_EXPERIMENT_LOG.md. Never delete entries.
