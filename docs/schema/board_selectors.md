# Board Resource Selector Syntax

Board resource selectors are used in `port_bindings`, `features.use`, and anywhere a board target is required.

## Canonical forms

```yaml
# Onboard resource (direct)
target: board:onboard.leds

# External resource (sub-path)
target: board:external.sdram.dq

# Onboard bundle signal
target: board:onboard.hdmi.tmds_p

# Alias (prefixed with @)
target: board:@leds
```

## Resource path structure

```
board:<section>.<resource>[.<signal>]
```

| Segment   | Description                                    | Example                 |
|-----------|------------------------------------------------|-------------------------|
| `section` | `onboard` or `external`                        | `onboard`               |
| `resource`| Top-level resource key                         | `leds`, `sdram`         |
| `signal`  | Sub-signal for bundle/multi-signal resources   | `dq`, `tmds_p`          |

## Alias syntax

If the board defines `aliases`, you can reference them with `@`:

```yaml
# Board definition
aliases:
  leds: onboard.leds
  sdram: external.sdram

# Project usage
target: board:@leds
```

## What is NOT a valid bind target

```yaml
# INVALID — connectors are physical, not logical resources
target: board:connectors.pmod.J10
```

Connectors describe physical pin assignments. To bind to a connector's pins,
define a `derived_resource` in the board file:

```yaml
derived_resources:
  - name: external.pmod.j10_gpio8
    from: connectors.pmod.J10
    role: gpio8
    top_name: PMOD_J10_D
```

Then reference the derived resource:

```yaml
target: board:external.pmod.j10_gpio8
```

## features.use syntax

```yaml
features:
  use:
    - board:onboard.leds
    - board:@sdram
    - board:external.headers.P8.gpio
```

## See also

- [Board YAML v2 schema](board_v2.md)
- [Board diagnostics reference](../errors/board_diagnostics.md)
- [Board selector diagnostics](../errors/board_selector_diagnostics.md)
