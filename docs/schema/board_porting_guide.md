# Board porting guide

This guide explains how to convert a legacy BSP YAML or vendor pin map to canonical `board.yaml` v2 format.

## Field name mapping

| Legacy field | Canonical field | Notes |
|---|---|---|
| `soc_top_name` | `top_name` | Signal name in RTL top |
| `dir` | `direction` | `input`, `output`, `inout` |
| `standard` | `io_standard` | I/O standard string |
| `groups` | nested vector resources | Multi-pin bus under `groups:` |
| `signals` | scalar resources under `signals:` | Single-pin signals |

## `pins` format

Legacy indexed dict:

```yaml
pins:
  4: F8
  3: B16
  2: G16
  1: J13
  0: L3
```

Canonical list (LSB to MSB):

```yaml
pins: [L3, J13, G16, B16, F8]
```

Both formats are accepted. Dict-style emits `BRD_ALIAS001` warning.

## Onboard scalar signals

Legacy:

```yaml
uart_rx:
  soc_top_name: UART_RX
  dir: input
  standard: "3.3-V LVTTL"
  pin: J2
```

Canonical:

```yaml
onboard:
  uart:
    signals:
      rx:
        top_name: UART_RX
        direction: input
        io_standard: "3.3-V LVTTL"
        pin: J2
```

Bind: `board:onboard.uart.rx`

## Onboard vector bus

Legacy `groups:`:

```yaml
onboard:
  sdram:
    groups:
      addr:
        soc_top_name: SDRAM_ADDR
        dir: output
        width: 13
        pins: { 12: P8, ... }
```

Canonical:

```yaml
onboard:
  sdram:
    groups:
      addr:
        top_name: SDRAM_ADDR
        direction: output
        width: 13
        pins: [T6, R6, R5, P5, P6, V7, V6, U7, U6, N6, N8, P7, P8]
```

Bind: `board:onboard.sdram.addr`

## External resources (bindable)

For resources bound directly by project modules, use the `external:` section with explicit `kind:`:

```yaml
external:
  sdram:
    addr:
      kind: vector
      top_name: ZS_ADDR
      direction: output
      width: 13
      pins: [T6, R6, R5, P5, P6, V7, V6, U7, U6, N6, N8, P7, P8]
    dq:
      kind: inout
      top_name: ZS_DQ
      direction: inout
      width: 16
      pins: [T10, T9, ...]
```

Bind: `board:external.sdram.addr`

## PMOD / connector resources

Physical pin maps go under `connectors:`:

```yaml
connectors:
  pmod:
    J10:
      pins:
        1: H1
        2: F1
```

Bindable logical resources go under `external.pmod:`:

```yaml
external:
  pmod:
    j10_led8:
      kind: vector
      top_name: PMOD_J10_LED8
      direction: output
      width: 8
      pins: [H1, F1, E1, C1, H2, F2, D2, C2]
```

Bind: `board:external.pmod.j10_led8`

## HDMI TMDS differential pairs

Use `groups:` under an onboard resource for multi-signal HDMI:

```yaml
onboard:
  hdmi:
    groups:
      tmds_p:
        top_name: TMDS_P
        direction: output
        width: 4
        io_standard: "LVDS_E_3R"
        pins: [L2, N2, P2, K2]
      tmds_n:
        top_name: TMDS_N
        direction: output
        width: 4
        io_standard: "LVDS_E_3R"
        pins: [L1, N1, P1, K1]
```

Bind: `board:onboard.hdmi.tmds_p`

## Validation

Run:

```bash
socfw validate project.yaml
```

Check for:
- `BRD201`: Invalid resource kind
- `BRD202`: Scalar missing `pin`
- `BRD203`: Vector/inout missing `pins` list
- `BRD204`: Width mismatch (declared vs actual pin count)
- `BRD_ALIAS001`: Legacy dict-style pins (warning only)
- `PIN001`: Physical pin conflicts between features
