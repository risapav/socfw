## Commit 86 — board resource selector syntax

```text
board: define canonical board resource selector syntax
```

Cieľ:

* zjednotiť všetky tvary `board:...`
* jasne rozlíšiť:

  * resource path
  * alias
  * profile
  * connector-only path
* odstrániť nejasnosti typu `board:connectors.pmod.J10`

## Canonical syntax

```yaml
target: board:onboard.leds
target: board:external.sdram.dq
target: board:onboard.hdmi.tmds_p
target: board:@leds
```

## Zakázané ako bind target

```yaml
target: board:connectors.pmod.J10
```

Lebo konektor je fyzický popis, nie logický resource.

## Pridať docs

```text
docs/schema/board_selectors.md
docs/errors/board_selector_diagnostics.md
```

---

## Commit 87 — connector-to-resource derivation

```text
board: add connector role derivation for PMOD and generic headers
```

Cieľ:

Z board YAML:

```yaml
resources:
  connectors:
    pmod:
      J10:
        pins:
          1: H1
          2: F1
```

vedieť odvodiť:

```yaml
resources:
  external:
    pmod:
      j10_gpio8:
        kind: inout
        top_name: PMOD_J10_D
        width: 8
        pins: [H1, F1, E1, C1, H2, F2, D2, C2]
```

Board môže mať:

```yaml
derived_resources:
  - name: external.pmod.j10_gpio8
    from: connectors.pmod.J10
    role: gpio8
    direction: inout
    top_name: PMOD_J10_D
```

---

## Commit 88 — PMOD role library

```text
board: add PMOD role library for gpio led button and simple video mappings
```

Role:

```yaml
pmod_roles:
  gpio8:
    kind: inout
    width: 8

  led8:
    kind: vector
    direction: output
    width: 8

  button8:
    kind: vector
    direction: input
    width: 8

  video4_out:
    kind: bundle
    signals:
      clk: 1
      de: 1
      hsync: 1
      vsync: 1
      d: 4
```

Cieľ:

* board autor nemusí ručne písať každý PMOD resource
* projekt môže používať stabilné names

---

## Commit 89 — board feature resolver

```text
board: add feature resolver for use profile alias and derived resources
```

Vstup:

```yaml
features:
  use:
    - board:@leds
    - board:external.pmod.j10_led8
```

Resolver vráti:

```text
onboard.leds
external.pmod.j10_led8
```

Pridať:

```text
socfw/board/feature_resolver.py
tests/unit/test_feature_resolver.py
```

---

## Commit 90 — selected resources in RTL generation

```text
rtl: restrict top ports to selected or bound board resources
```

Dnes môže emitter emitovať všetko, čo je bindované.

Cieľ:

* emitovať iba:

  * bindované resources
  * resources vo `features.use`
* neemitovať náhodné/alternatívne board resources

Toto je dôležité pri boardoch ako AC608, kde sú SDRAM/HDMI/header alternatívne funkcie.

---

## Commit 91 — feature-aware pin conflict validation

```text
validate: make pin conflict detection feature aware
```

Pravidlá:

* ak projekt má `features.use`, kontroluj iba tieto features + bind targets
* ak nemá, kontroluj iba bind targets
* nekontroluj celú dosku naraz

Výsledok:

```text
PIN001 pin R1 used by board:external.sdram.dq and board:external.headers.P8.gpio
```

iba ak projekt použije obe features.

---

## Commit 92 — board resource capability tags

```text
board: add resource capability tags for discovery and examples
```

Board:

```yaml
resources:
  onboard:
    leds:
      capabilities: [leds, demo, output]
    hdmi:
      capabilities: [video, hdmi, output]
  external:
    sdram:
      capabilities: [memory, sdram]
```

Použitie:

```bash
socfw board-info ac608_ep4ce15 --capability hdmi
```

---

## Commit 93 — project feature requirements

```text
validate: add module required feature checks
```

IP descriptor môže povedať:

```yaml
requires:
  board_capabilities:
    - leds
```

Alebo project module:

```yaml
requires:
  features:
    - board:onboard.leds
```

Ak chýba:

```text
FEAT001 module blink0 requires board:onboard.leds but it is not enabled
```

---

## Commit 94 — board resource adaptation IR

```text
rtl: represent bind adaptation in RTL IR
```

Cieľ:

`adapt: zero_extend` už nebude len validačné pravidlo, ale IR node:

```python
RtlAdapt(
  mode="zero_extend",
  source_width=6,
  target_width=8,
)
```

Výsledok v RTL:

```systemverilog
assign PMOD_J10_LED = {2'b00, blink_leds};
```

---

## Commit 95 — output adaptation emitter

```text
rtl: emit zero_extend truncate and replicate bind adapters
```

Podporiť:

```yaml
adapt: zero_extend
adapt: truncate
adapt: replicate
```

Príklad:

```yaml
ONB_LEDS:
  target: board:external.pmod.j10_led8
  adapt: zero_extend
```

RTL:

```systemverilog
wire [5:0] blink_02_ONB_LEDS;
assign PMOD_J10_LED = {2'b00, blink_02_ONB_LEDS};
```

---

## Commit 96 — input adaptation emitter

```text
rtl: emit input-side truncate and zero_extend adapters
```

Pre buttons:

```yaml
BUTTONS:
  target: board:external.pmod.j11_buttons8
  adapt: truncate
```

RTL:

```systemverilog
.BUTTONS(PMOD_J11_BTN[3:0])
```

---

## Commit 97 — board resource mux policy

```text
validate: add explicit mutually exclusive board resource groups
```

Board:

```yaml
mux_groups:
  sdram_or_j11:
    resources:
      - external.sdram
      - external.pmod.j11_gpio8
    policy: mutually_exclusive
```

Ak project použije obe:

```text
MUX001 resources external.sdram and external.pmod.j11_gpio8 are mutually exclusive
```

---

## Commit 98 — AC608 profile pack polish

```text
board: add AC608 profiles aliases and mux groups
```

Doplniť AC608:

```yaml
aliases:
  leds: onboard.leds
  buttons: onboard.buttons
  hdmi: onboard.hdmi
  sdram: external.sdram

profiles:
  minimal:
    use: [onboard.leds]
  hdmi:
    use: [onboard.hdmi]
  sdram:
    use: [external.sdram]

mux_groups:
  sdram_or_headers:
    resources:
      - external.sdram
      - external.headers.P8.gpio
```

---

## Commit 99 — board examples CI lane

```text
ci: add board example validation lane
```

CI:

```bash
socfw validate examples/ac608_blink/project.yaml
socfw validate examples/ac608_hdmi_out/project.yaml
socfw validate examples/ac608_sdram/project.yaml
```

---

## Commit 100 — board import/migration milestone

```text
release: document board import milestone and AC608 support
```

Docs:

```text
docs/releases/v1.1-board-import.md
```

Obsah:

* AC608 board support
* PMOD/header modeling
* feature-aware validation
* pin conflict checking
* board resource docs

---

## Odporúčané najbližšie poradie

Teraz by som išiel takto:

```text
86 board selector syntax docs
87 connector-to-resource derivation
89 feature resolver
91 feature-aware pin conflict validation
95 output adaptation emitter
98 AC608 aliases/profiles/mux groups
```

Najväčšia hodnota pre teba teraz: **Commit 87**, lebo rieši priamo problém, ako z fyzického header/PMOD popisu odvodiť bindovateľné resources.
