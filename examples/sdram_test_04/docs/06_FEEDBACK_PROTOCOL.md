# docs/06_FEEDBACK_PROTOCOL.md — Feedback Protocol

## After every command

```
COMMAND: <exact command>
RESULT: PASS/FAIL
FILES CHANGED: <list>
NEXT: <one next action only>
```

## On test failure

STOP. Do not attempt to fix unless explicitly asked by user.
Record failure signature in STATUS.md and docs/04_EXPERIMENT_LOG.md.

## On test pass

Record in docs/04_EXPERIMENT_LOG.md.
Update STATUS.md.
Update docs/02_MILESTONES.md.
Wait for user approval before next milestone.

## Never claim PASS without

Log file starting with:
`# BUILD_CONFIG PROJECT=sdram_test_04 RSHIFT=0 CMDREG=1`

## Hard gates (do not cross without explicit user approval)

- M1 → M2: no PHY/model until M1 passes
- M2 → M3: no multi-addr until M2 passes
- M3 → M4: no backpressure until M3 passes
- M4 → M5: no closeout until M4 passes
