# Board Selector Diagnostics

## BRD001 — Unknown board target

**Severity:** ERROR

A `board:` target references a resource that does not exist in the board file.

```text
ERROR BRD001
Unknown board target 'board:external.sdram.cs'
```

**Fix:** Check `resources.external` in your board YAML.  
Use `socfw board-info <board_id>` to list available resources.

---

## BRD002 — Missing required board resource

**Severity:** ERROR

A required board resource is not present in the resolved board model.

**Fix:** Verify the resource path in your board YAML, or add the resource definition.

---

## BRD003 — Connector path is not bindable

**Severity:** ERROR

A `board:connectors.*` path was used as a bind target. Connectors are physical
descriptions and cannot be bound directly.

```text
ERROR BRD003
board:connectors.pmod.J10 is a connector path, not a bindable resource
```

**Fix:** Define a derived resource and bind to that:

```yaml
derived_resources:
  - name: external.pmod.j10_gpio8
    from: connectors.pmod.J10
    role: gpio8
    top_name: PMOD_J10_D
```

Then use `target: board:external.pmod.j10_gpio8`.

---

## BIND001 — Unknown bind target

**Severity:** ERROR

The `target` in a port binding does not resolve to a known board resource.

**Fix:** Check the target path with `socfw board-info`.

---

## BIND003 — Width mismatch

**Severity:** ERROR

The IP port width does not match the board resource width.

```text
ERROR BIND003
Width mismatch: port ONB_LEDS width=6 vs board resource width=8
Hint: add `adapt: zero_extend` or `adapt: truncate` to the binding
```

---

## BIND006 — Invalid adapt mode

**Severity:** ERROR

The `adapt` value in a port binding is not a supported mode.

```text
ERROR BIND006
Invalid adapt mode 'pad'; supported: zero_extend, truncate, replicate
```

---

## BIND007 — Adapt on inout

**Severity:** ERROR

`adapt` cannot be used with `inout` (bidirectional) resources.

```text
ERROR BIND007
adapt is not supported for inout resource board:external.sdram.dq
```

---

## PIN001 — Pin conflict

**Severity:** ERROR

Two board resources in the active feature set share physical pins.

```text
ERROR PIN001
pin R1 used by both board:external.sdram.dq and board:external.headers.P8.gpio
```

**Fix:** Remove one of the conflicting features, or add a `mux_groups` entry
to the board YAML to declare the exclusivity explicitly.
