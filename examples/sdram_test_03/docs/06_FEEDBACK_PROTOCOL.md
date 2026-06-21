# docs/06_FEEDBACK_PROTOCOL.md — Feedback Protocol

After every `make` command, Claude must report:

```
COMMAND:
<exact command>

RESULT:
PASS/FAIL

FILES CHANGED:
<list>

NEXT:
<one next action only>
```

If a test fails:
- Stop immediately.
- Do not auto-fix.
- Report the failure signature (first FAIL line, actual vs expected, cycle numbers).
- Wait for user instruction.

If a test passes:
- Record in docs/04_EXPERIMENT_LOG.md.
- Update STATUS.md.
- Report the NEXT milestone.
- Wait for user approval before proceeding.
