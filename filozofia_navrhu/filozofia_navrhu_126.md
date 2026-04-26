## Commit 101 — connector-derived resources ako first-class board feature

```text
board: make connector-derived resources first-class board features
```

Cieľ:

* z fyzického konektora automaticky vytvoriť bindovateľný resource
* nepísať ručne `j10_led8`, `j10_buttons8`, `p8_gpio14`
* zjednotiť PMOD a generic header model

---

## Canonical board syntax

```yaml
resources:
  connectors:
    pmod:
      J10:
        io_standard: "3.3-V LVTTL"
        pins:
          1: H1
          2: F1
          3: E1
          4: C1
          7: H2
          8: F2
          9: D2
          10: C2

derived_resources:
  - name: external.pmod.j10_gpio8
    from: connectors.pmod.J10
    role: gpio8
    top_name: PMOD_J10_D

  - name: external.pmod.j10_led8
    from: connectors.pmod.J10
    role: led8
    top_name: PMOD_J10_LED
```

Výsledkom je, že projekt môže bindovať:

```yaml
target: board:external.pmod.j10_led8
```

---

## Pridať

```text
socfw/board/derived_resources.py
tests/unit/test_derived_resources.py
```

---

## `derived_resources.py` koncept

```python
PMOD_PIN_ORDER = [1, 2, 3, 4, 7, 8, 9, 10]


ROLE_DEFS = {
    "gpio8": {
        "kind": "inout",
        "direction": "inout",
        "width": 8,
    },
    "led8": {
        "kind": "vector",
        "direction": "output",
        "width": 8,
    },
    "button8": {
        "kind": "vector",
        "direction": "input",
        "width": 8,
    },
}


def derive_resources(board_data: dict) -> dict:
    data = copy.deepcopy(board_data)

    for spec in data.get("derived_resources", []):
        name = spec["name"]
        source = spec["from"]
        role = spec["role"]
        top_name = spec["top_name"]

        connector = resolve_path(data["resources"], source)
        pins_map = connector["pins"]

        pins = [pins_map[i] for i in PMOD_PIN_ORDER if i in pins_map]

        role_def = ROLE_DEFS[role]
        resource = {
            **role_def,
            "top_name": top_name,
            "io_standard": connector.get("io_standard", spec.get("io_standard")),
            "pins": pins,
        }

        insert_path(data["resources"], name, resource)

    return data
```

---

## Commit 102 — board roles library

```text
board: add connector role library for pmod and gpio headers
```

Pridať role:

```yaml
gpio8
led8
button8
gpio14
gpio2
```

Pre AC608:

```yaml
derived_resources:
  - name: external.headers.P8.gpio
    from: connectors.headers.P8
    role: gpio14
    top_name: HDR_P8_D

  - name: external.headers.P5.gpio
    from: connectors.headers.P5
    role: gpio2
    top_name: HDR_P5_D
```

---

## Commit 103 — AC608 canonical board pack

```text
board: add canonical AC608 board pack with derived headers
```

Pridať:

```text
packs/builtin/boards/ac608_ep4ce15/board.yaml
```

Board bude obsahovať:

```yaml
board:
  id: ac608_ep4ce15

resources:
  onboard:
    leds: ...
    buttons: ...
    uart: ...
    i2c: ...
    hdmi: ...

  external:
    sdram: ...

  connectors:
    headers:
      P8:
        pins: ...
      P5:
        pins: ...
      P6:
        pins: ...

derived_resources:
  - name: external.headers.P8.gpio
    from: connectors.headers.P8
    role: gpio14
    top_name: HDR_P8_D
```

---

## Commit 104 — feature resolver používa derived resources

```text
board: resolve derived resources before validation and build
```

Cieľ:

* `BoardLoader` načíta raw board
* normalizer odvodí derived resources
* `BoardModel.resources` už obsahuje aj výsledné bind targety

Teda:

```yaml
target: board:external.headers.P8.gpio
```

bude validný bez ručného resource bloku.

---

## Commit 105 — board-info zobrazuje derived resources

```text
doctor: show derived board resources in board-info and doctor
```

Výstup:

```text
Derived resources:
- external.headers.P8.gpio from connectors.headers.P8 role gpio14
- external.pmod.j10_led8 from connectors.pmod.J10 role led8
```

---

## Commit 106 — examples for AC608 headers

```text
examples: add AC608 header GPIO examples
```

Pridať:

```text
examples/ac608_header_p8_gpio/project.yaml
examples/ac608_header_p5_gpio/project.yaml
```

Bind:

```yaml
target: board:external.headers.P8.gpio
```

---

## Commit 107 — board feature profiles v AC608

```text
board: add AC608 profiles for minimal sdram hdmi and headers
```

Do boardu:

```yaml
profiles:
  minimal:
    use:
      - onboard.leds

  sdram:
    use:
      - external.sdram

  hdmi:
    use:
      - onboard.hdmi

  headers:
    use:
      - external.headers.P8.gpio
      - external.headers.P5.gpio
      - external.headers.P6.gpio
```

Project:

```yaml
features:
  profile: minimal
```

---

## Commit 108 — mux groups pre alternatívne funkcie

```text
board: add mux groups for mutually exclusive resources
```

AC608:

```yaml
mux_groups:
  sdram_vs_headers:
    resources:
      - external.sdram
      - external.headers.P8.gpio
    policy: mutually_exclusive
```

QMTech:

```yaml
mux_groups:
  sdram_vs_pmod_j11:
    resources:
      - external.sdram
      - external.pmod.j11_gpio8
    policy: mutually_exclusive
```

---

## Commit 109 — mux validation

```text
validate: enforce board mux group mutual exclusivity
```

Chyba:

```text
MUX001 resources external.sdram and external.headers.P8.gpio are mutually exclusive
```

Používa iba:

```yaml
features.use
```

a bind targety.

---

## Commit 110 — final board import tooling

```text
tools: add legacy BSP to board.yaml migration command
```

CLI:

```bash
socfw migrate-board ac608_legacy.yaml --out packs/builtin/boards/ac608_ep4ce15/board.yaml
```

Transformácie:

```text
device -> fpga
system.clock.port -> system.clock.top_name
standard -> io_standard
soc_top_name -> top_name
dir -> direction
indexed pins -> list pins
groups/signals -> canonical resources
headers -> connectors.headers + derived_resources
```

---

## Najbližší praktický krok

Začni **Commit 101 + 103 spolu**:

1. pridaj `derived_resources`
2. pridaj AC608 board pack
3. over:

```bash
socfw board-info ac608_ep4ce15
socfw validate examples/ac608_blink/project.yaml
```

Potom pokračuj mux/feature validáciou.
