# Board diagnostics

## BRD001 — Unknown board feature reference

Example:

```text
ERROR BRD001 project.features.use
'board:external.pmod.j11_led8' not found in board resources
```

Meaning:

`project.yaml` contains:

```yaml
features:
  use:
    - board:external.pmod.j11_led8
```

but the board descriptor does not declare a resource at that path.

Fix checklist:

1. Check `resources.external.pmod` section in board.yaml.
2. Verify the resource key matches the reference.
3. Add the missing resource definition.

## BRD002 — Unknown board binding target

Example:

```text
ERROR BRD002 project.modules.bind.ports
Instance 'blink_01' port 'ONB_LEDS': 'board:onboard.leds' not found in board resources
```

Meaning:

A module port binding references a board resource that does not exist.

Fix:

1. Check that the resource path exists in board.yaml.
2. Check spelling of the `target:` value.
3. Run `socfw doctor project.yaml`.

## BRD201 — Invalid board resource kind

Meaning:

A resource in board.yaml uses an unsupported `kind` value.

Supported kinds: `scalar`, `vector`, `inout`, `bundle`.

## BRD_ALIAS001 — Legacy dict-style pins

Meaning:

A resource uses `pins: {0: PIN0, 1: PIN1}` instead of canonical `pins: [PIN0, PIN1]`.

This is accepted but emits a warning.

Fix:

```yaml
# instead of:
pins:
  0: A1
  1: A2
# use:
pins: [A1, A2]
```
