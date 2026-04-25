## Commit 62 — AC608 board descriptor

```text
board: add AC608 Cyclone IV E board descriptor
```

Pridať:

```text
packs/builtin/boards/ac608_ep4ce15/board.yaml
tests/unit/test_ac608_board_loads.py
tests/integration/test_validate_ac608_blink.py
```

Kľúčové pravidlá:

```yaml
board:
  id: ac608_ep4ce15

fpga:
  family: "Cyclone IV E"
  part: EP4CE15E22C8

system:
  clock:
    id: sys_clk
    top_name: clk
    pin: E15
    frequency_hz: 50000000
```

Test:

```python
from socfw.config.board_loader import BoardLoader


def test_ac608_board_loads():
    result = BoardLoader().load("packs/builtin/boards/ac608_ep4ce15/board.yaml")

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]
    assert result.value.board_id == "ac608_ep4ce15"
    assert result.value.system_clock.top_name == "clk"
    assert result.value.resolve_resource_path("onboard.leds") is not None
    assert result.value.resolve_resource_path("external.sdram.dq") is not None
```

---

## Commit 63 — AC608 blink example

```text
examples: add AC608 blink project
```

Pridať:

```text
examples/ac608_blink/project.yaml
examples/ac608_blink/timing_config.yaml
examples/ac608_blink/ip/blink_test.ip.yaml
examples/ac608_blink/rtl/blink_test.sv
tests/integration/test_validate_ac608_blink_example.py
```

`project.yaml`:

```yaml
version: 2
kind: project

project:
  name: ac608_blink
  mode: standalone
  board: ac608_ep4ce15
  debug: true

timing:
  file: timing_config.yaml

registries:
  packs:
    - ../../packs/builtin
  ip:
    - ip
  cpu: []

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
    frequency_hz: 50000000
  generated: []

features:
  use:
    - board:onboard.leds

modules:
  - instance: blink0
    type: blink_test
    clocks:
      SYS_CLK: sys_clk
    params:
      CLK_FREQ: 50000000
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds
```

Pozor: `blink_test.ONB_LEDS` musí mať width `5`, alebo použi adaptér.

---

## Commit 64 — board pin map normalization

```text
config: normalize board indexed pin maps to canonical pin lists
```

Cieľ:

Prijať aj legacy tvar:

```yaml
pins:
  4: F8
  3: B16
  2: G16
  1: J13
  0: L3
```

a normalizovať na:

```yaml
pins: [L3, J13, G16, B16, F8]
```

Pridať:

```text
socfw/config/normalizers/board.py
tests/unit/test_board_pin_map_normalizer.py
```

Helper:

```python
def normalize_pins(value):
    if isinstance(value, list):
        return value

    if isinstance(value, dict):
        pairs = sorted((int(k), v) for k, v in value.items())
        return [pin for _, pin in pairs]

    return value
```

Toto aplikovať rekurzívne na každý resource leaf.

---

## Commit 65 — board resource aliases

```text
config: normalize legacy board resource aliases
```

Podporiť aliasy:

```yaml
soc_top_name -> top_name
dir          -> direction
standard     -> io_standard
```

Príklad legacy:

```yaml
leds:
  soc_top_name: ONB_LEDS
  dir: output
  standard: "3.3-V LVTTL"
```

Canonical:

```yaml
leds:
  top_name: ONB_LEDS
  direction: output
  io_standard: "3.3-V LVTTL"
```

Pridať warningy:

```text
BRD_ALIAS001 soc_top_name -> top_name
BRD_ALIAS002 dir -> direction
BRD_ALIAS003 standard -> io_standard
```

---

## Commit 66 — board resource docs

```text
docs: add board porting guide for legacy BSP YAML
```

Pridať:

```text
docs/schema/board_v2.md
docs/guides/porting_legacy_board_yaml.md
docs/errors/board_diagnostics.md
```

Musí vysvetliť:

```text
device.family     -> fpga.family
device.part       -> fpga.part
system.clock.port -> system.clock.top_name
system.clock.freq_mhz -> system.clock.frequency_hz
onboard.*         -> resources.onboard.*
headers.*         -> resources.external.headers.*
```

A hlavne rozdiel:

```yaml
connectors:
```

je fyzická mapa,

```yaml
resources:
```

sú bindovateľné logické signály.

---

## Commit 67 — pin conflict detection

```text
validate: add pin conflict detection for selected board features
```

Cieľ:

Ak projekt má:

```yaml
features:
  use:
    - board:external.sdram
    - board:external.headers.P8.gpio
```

a zdieľajú pin, validácia dá:

```text
PIN001 Pin R1 is used by both board:external.sdram.dq and board:external.headers.P8.gpio
```

Pridať:

```text
socfw/validate/rules/pin_rules.py
tests/unit/test_pin_conflict_rule.py
```

Pravidlo:

* ak `features.use` existuje, kontroluj iba vybrané features
* ak neexistuje, kontroluj iba bindované resources
* nepadať na celej doske, lebo board môže obsahovať alternatívne muxované funkcie

---

## Commit 68 — feature expansion

```text
board: add feature expansion for nested board resources
```

Cieľ:

Aby toto:

```yaml
features:
  use:
    - board:external.sdram
```

expandovalo na:

```text
external.sdram.addr
external.sdram.dq
external.sdram.ba
...
```

A toto:

```yaml
features:
  use:
    - board:onboard.hdmi
```

na:

```text
onboard.hdmi.tmds_p
onboard.hdmi.tmds_n
```

Pridať helper:

```text
socfw/model/board_resources.py
```

s funkciami:

```python
iter_resource_leaves(board, path)
collect_pins(resource)
```

---

## Commit 69 — AC608 SDRAM example

```text
examples: add AC608 SDRAM validation example
```

Pridať:

```text
examples/ac608_sdram/project.yaml
examples/ac608_sdram/timing_config.yaml
examples/ac608_sdram/ip/dummy_cpu.cpu.yaml
tests/integration/test_validate_ac608_sdram_example.py
```

Tento príklad zatiaľ validate-only, nie build functional.

---

## Commit 70 — AC608 HDMI skeleton

```text
examples: add AC608 HDMI output skeleton
```

Pridať:

```text
examples/ac608_hdmi_out/project.yaml
examples/ac608_hdmi_out/ip/hdmi_out.ip.yaml
examples/ac608_hdmi_out/rtl/hdmi_out_stub.sv
tests/integration/test_validate_ac608_hdmi_out.py
```

Bind:

```yaml
bind:
  ports:
    TMDS_P:
      target: board:onboard.hdmi.tmds_p
    TMDS_N:
      target: board:onboard.hdmi.tmds_n
```

---

## Commit 71 — board doctor detail

```text
doctor: show board resource tree and selected features
```

`socfw doctor project.yaml` doplniť o:

```text
## Selected board features
- board:onboard.leds
- board:external.sdram

## Board resources used
- onboard.leds: ONB_LEDS[4:0], pins L3,J13,G16,B16,F8
```

Toto veľmi pomôže pri AC608/QMTech portingu.
