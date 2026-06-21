# CLAUDE.md — sdram_test_03 Rules

## Purpose

Native 32-bit SDRAM read/write core integration in simulation only.
Builds on sdram_test_02 result: RSHIFT=0, CMDREG=1 confirmed correct.

**One question only:** Can we perform one native 32-bit write and one native 32-bit read
through the SDRAM core (native_word_port + PHY + model) without AXI?

## Hard restrictions

- Do NOT run Quartus (no syn, fit, sta, asm).
- Do NOT touch HW / board.yaml.
- Do NOT implement AXI.
- Do NOT copy BIST or scheduler.
- Do NOT start XFCP integration.
- Do NOT modify board.yaml (ever — owned by user exclusively).
- Do NOT modify sdram_phy.sv or sdram_model_pro.sv.

## Workflow

1. Before any test: read STATUS.md.
2. After every `make` run: record result in docs/04_EXPERIMENT_LOG.md.
3. After every experiment: update STATUS.md.
4. Do NOT claim PASS without a log that starts with `# BUILD_CONFIG PROJECT=sdram_test_03 RSHIFT=0 CMDREG=1`.

## Feedback format (after every command)

```
COMMAND: <exact command>
RESULT: PASS/FAIL
FILES CHANGED: <list>
NEXT: <one next action only>
```

If a test fails, STOP. Do not try another fix unless the user explicitly asks.

## Experiment discipline

Every run in docs/04_EXPERIMENT_LOG.md. Never delete entries.
