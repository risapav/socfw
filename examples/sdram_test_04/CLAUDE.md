# CLAUDE.md — sdram_test_04 Rules

## Purpose

AXI adapter over the proven native_word_port layer.
Investigates the original sdram_test_01 failure: AXI 2-read returned 0xzzzz_1234.

Lower layers already proven:
- sdram_test_02: PHY + 2×16 assembly PASS (RSHIFT=0, CMDREG=1)
- sdram_test_03: native_word_port unit + single R/W + multi-address PASS

**Question:** Can an AXI-lite 32-bit transaction be correctly translated into one
native_word_port transaction, and does the original bug manifest here?

## Hard restrictions

- Do NOT run Quartus (no syn, fit, sta, asm).
- Do NOT touch HW / board.yaml.
- Do NOT implement BIST.
- Do NOT start XFCP integration.
- Do NOT modify board.yaml (ever -- owned by user exclusively).
- Do NOT modify native_word_port.sv (proven baseline from sdram_test_03).
- Do NOT modify sdram_phy.sv or sdram_model_pro.sv when they are added.

## Workflow

1. Before any test: read STATUS.md.
2. After every `make` run: record result in docs/04_EXPERIMENT_LOG.md.
3. After every experiment: update STATUS.md.
4. Do NOT claim PASS without a log that starts with
   `# BUILD_CONFIG PROJECT=sdram_test_04 RSHIFT=0 CMDREG=1`.

## Feedback format (after every command)

```
COMMAND: <exact command>
RESULT: PASS/FAIL
FILES CHANGED: <list>
NEXT: <one next action only>
```

If a test fails, STOP. Do not try another fix unless the user explicitly asks.

## Address conversion rule

AXI byte addr → native halfword base addr:
  native_req_addr = axi_addr >> 1

Word-aligned AXI addresses only (axi_addr[1:0] == 2'b00).
Non-overlapping 32-bit words: AXI addrs 0x00, 0x04, 0x08, ...

## Experiment discipline

Every run in docs/04_EXPERIMENT_LOG.md. Never delete entries.
