# docs/06_FEEDBACK_PROTOCOL.md — Feedback Protocol

After every command that produces a result, Claude must report in this format:

```
COMMAND:
<exact shell command or make target>

RESULT:
PASS / FAIL

FILES CHANGED:
<list of files created or modified>

NEXT:
<exactly one next action>
```

## Rules

- If result is FAIL: stop. Do not try another fix. Wait for user instruction.
- If result is PASS: update docs/04_EXPERIMENT_LOG.md, then report NEXT.
- Never claim PASS from a stale log (log must start with matching BUILD_CONFIG header).
- Never run background tasks.
- Never run Quartus.
- Never touch board.yaml.

## Log validity check

A log is valid if and only if:
1. It exists in sim/logs/
2. Its first line is: `# BUILD_CONFIG PROJECT=sdram_test_02 RSHIFT=<N> CMDREG=1`
3. The RSHIFT=<N> matches the current sdram_build_cfg.svh

If any condition fails: log is INVALID. Mark as FAIL in experiment log.
