# Board descriptor schema v2

A board descriptor describes the physical FPGA board: clock, reset, FPGA part, and bindable resources.

## Minimal canonical board

```yaml
version: 2
kind: board

board:
  id: qmtech_ep4ce55

fpga:
  family: cyclone_iv_e
  part: EP4CE55F23C8

system:
  clock:
    id: sys_clk
    top_name: SYS_CLK
    pin: T8
    frequency_hz: 50000000
  reset:
    id: reset_n
    top_name: RESET_N
    pin: N2
    active_low: true

resources:
  onboard:
    leds:
      kind: vector
      top_name: ONB_LEDS
      direction: output
      width: 6
      pins: [A1, A2, A3, A4, A5, A6]
```

## Resource kinds

### `scalar` — single-pin signal

```yaml
btn_key0:
  kind: scalar
  top_name: BTN_KEY0
  direction: input
  pin: M1
```

### `vector` — multi-pin bus

```yaml
leds:
  kind: vector
  top_name: ONB_LEDS
  direction: output
  width: 6
  pins: [A1, A2, A3, A4, A5, A6]
```

### `inout` — bidirectional vector

```yaml
gpio:
  kind: inout
  top_name: GPIO
  direction: inout
  width: 8
  pins: [H1, F1, E1, C1, H2, F2, D2, C2]
```

### `bundle` — grouped signals (e.g. HDMI over PMOD)

```yaml
j10_hdmi_out:
  kind: bundle
  connector: connectors.pmod.J10
  io_standard: "3.3-V LVTTL"
  signals:
    clk:
      kind: scalar
      top_name: HDMI_CLK
      direction: output
      pin: H1
    d:
      kind: vector
      top_name: HDMI_D
      direction: output
      width: 4
      pins: [H2, F2, D2, C2]
```

Bind individual signals with `.signals.<name>`:

```yaml
target: board:external.pmod.j10_hdmi_out.signals.clk
target: board:external.pmod.j10_hdmi_out.signals.d
```

## `pins` — list vs map

Canonical form uses a list:

```yaml
pins: [A1, A2, A3, A4, A5, A6]
```

Legacy dict-style (accepted with warning):

```yaml
pins:
  0: A1
  1: A2
  2: A3
  3: A4
  4: A5
  5: A6
```

## `connectors` section

Physical pin maps for connectors. Not directly bindable — use derived resources instead.

```yaml
connectors:
  pmod:
    J10:
      pins:
        1: H1
        2: F1
        3: E1
        4: C1
        7: H2
        8: F2
        9: D2
        10: C2
```

## External PMOD resources

```yaml
resources:
  external:
    pmod:
      j10_led8:
        kind: vector
        top_name: PMOD_J10_LED
        direction: output
        width: 8
        io_standard: "3.3-V LVTTL"
        connector: connectors.pmod.J10
        pins: [H1, F1, E1, C1, H2, F2, D2, C2]
```

Project binding:

```yaml
target: board:external.pmod.j10_led8
```

## `io_standard` field

Optional per-resource I/O standard hint for constraint generation:

```yaml
io_standard: "3.3-V LVTTL"
io_standard: "2.5 V"
io_standard: "LVDS"
```

## Bind reference format

```yaml
target: board:onboard.leds
target: board:external.pmod.j10_led8
target: board:external.pmod.j10_hdmi_out.signals.clk
```

Format: `board:<section>.<resource>[.signals.<name>]`
