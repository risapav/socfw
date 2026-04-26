## Commit 151 — board selector index in diagnostics

```text
diagnostics: use board selector index in BRD and BIND errors
```

Cieľ:

* `BRD001`, `BRD002`, `BIND001` budú ukazovať platné možnosti
* pri preklepe v `target:` dostaneš návrhy
* pri connector-only ceste dostaneš vysvetlenie

Príklad:

```text
ERROR BRD003
board:connectors.pmod.J10 is a connector path, not a bindable resource.

Suggested bind targets:
- board:external.pmod.j10_gpio8
- board:external.pmod.j10_led8
```

---

## Commit 152 — board selector JSON report

```text
reports: emit board selector index JSON
```

Výstup:

```text
reports/board_selectors.json
```

Obsah:

```json
{
  "board": "ac608_ep4ce15",
  "resources": [
    "board:onboard.leds",
    "board:onboard.buttons",
    "board:onboard.hdmi.tmds",
    "board:external.sdram.dq"
  ],
  "aliases": [
    "board:@leds",
    "board:@sdram"
  ],
  "profiles": [
    "minimal",
    "hdmi",
    "sdram"
  ],
  "connectors": [
    "board:connectors.headers.P8"
  ]
}
```

---

## Commit 153 — selector-aware `socfw doctor`

```text
doctor: show valid board selectors and nearest suggestions
```

`socfw doctor project.yaml` doplní:

```text
## Board selectors
Resources:
- board:onboard.leds
- board:external.sdram
- board:onboard.hdmi.tmds

Aliases:
- board:@leds -> board:onboard.leds

Profiles:
- minimal
- hdmi
- sdram
```

---

## Commit 154 — `socfw board-info --selectors`

```text
cli: add board-info selectors view
```

Použitie:

```bash
socfw board-info ac608_ep4ce15 --selectors
```

Výstup:

```text
Bindable resources:
- board:onboard.leds
- board:onboard.buttons
- board:onboard.hdmi.tmds
- board:external.sdram.dq

Connector-only paths:
- board:connectors.headers.P8
```

---

## Commit 155 — project bind target linter

```text
lint: add project bind target lint checks
```

Nový príkaz:

```bash
socfw lint project.yaml
```

Kontroly:

* neznámy board target
* connector-only target
* target exists but is container
* width mismatch
* direction mismatch
* missing `features.use` pri strict mode

---

## Commit 156 — strict mode default warning

```text
validate: warn when project has binds but no selected board features
```

Ak projekt nemá:

```yaml
features:
```

ale používa board bindy, warning:

```text
FEAT010 project binds board resources but does not declare features.use
```

Nie error, len odporúčanie.

---

## Commit 157 — auto feature inference from binds

```text
project: infer selected features from board binds when features.use is absent
```

Cieľ:

Aj keď projekt nemá:

```yaml
features:
  use:
```

framework vie vytvoriť selected set z bindov.

Report:

```text
Selected board resources:
- onboard.leds  # inferred from bind blink0.ONB_LEDS
```

---

## Commit 158 — explicit feature inference report

```text
reports: show inferred versus explicit board resources
```

Do `build_summary.md`:

```text
## Board Resource Selection
Explicit:
- external.sdram

Inferred from binds:
- onboard.leds
```

---

## Commit 159 — board profile conflict docs

```text
docs: document feature profiles mux groups and conflict behavior
```

Vysvetliť:

```yaml
features:
  profile: sdram
```

vs

```yaml
features:
  use:
    - board:external.sdram
```

a mux conflict:

```yaml
mux_groups:
  sdram_vs_headers:
    resources:
      - external.sdram
      - external.headers.P8.gpio
```

---

## Commit 160 — native Quartus project script emitter

```text
emit: add native Quartus project script emitter
```

Generovať:

```text
hal/project.tcl
```

Obsah:

```tcl
project_new soc_top -overwrite
source board.tcl
source files.tcl
source generated_config.tcl
source ../timing/soc_top.sdc
project_close
```

---

## Commit 161 — `socfw quartus-script` command

```text
cli: add quartus-script command for generated build helpers
```

Použitie:

```bash
socfw quartus-script project.yaml --out build/q
```

Vygeneruje len:

```text
hal/project.tcl
hal/files.tcl
hal/board.tcl
timing/soc_top.sdc
```

bez RTL rebuild/debug reportov.

---

## Commit 162 — project output layout docs

```text
docs: document native output layout
```

Dokument:

```text
docs/user/output_layout.md
```

Obsah:

```text
rtl/
  soc_top.sv
  bridge RTL

hal/
  files.tcl
  board.tcl
  generated_config.tcl
  project.tcl

timing/
  soc_top.sdc

reports/
  build_summary.md
  build_provenance.json
  board_selectors.json
```

---

## Commit 163 — artifact inventory report detail

```text
reports: include artifact producer details in build provenance JSON
```

JSON:

```json
"artifacts": [
  {
    "path": "$OUT/rtl/soc_top.sv",
    "kind": "rtl",
    "producer": "rtl_emitter"
  }
]
```

Markdown:

```text
## Artifacts
- rtl: $OUT/rtl/soc_top.sv (rtl_emitter)
```

---

## Commit 164 — selected resource pin report

```text
reports: include selected board resource pins
```

JSON:

```json
"selected_resource_pins": [
  {
    "resource": "onboard.leds",
    "top_name": "ONB_LEDS",
    "pin": "L3",
    "bit": 0
  }
]
```

Toto je veľmi užitočné pri AC608/QMTech debugovaní.

---

## Commit 165 — board pinout report

```text
reports: emit board_pinout.md for selected resources
```

Výstup:

```text
reports/board_pinout.md
```

Príklad:

```text
# Board Pinout

## onboard.leds

| Signal | Bit | Pin | IO Standard |
|---|---:|---|---|
| ONB_LEDS | 0 | L3 | 3.3-V LVTTL |
| ONB_LEDS | 1 | J13 | 3.3-V LVTTL |
```

---

## Commit 166 — pinout report golden anchor

```text
golden: snapshot selected pinout report for AC608 blink
```

Pridať:

```text
tests/golden/expected/ac608_blink/reports/board_pinout.md
```

Overí:

* LED pins
* clock pin
* IO standard

---

## Commit 167 — project board capability requirements

```text
validate: support project-level board capability requirements
```

Project:

```yaml
requires:
  board_capabilities:
    - leds
    - hdmi
```

Board resources:

```yaml
capabilities: [leds, output]
```

Chyba:

```text
REQ001 board does not provide required capability hdmi
```

---

## Commit 168 — IP board capability requirements

```text
ip: support IP-required board capabilities
```

IP:

```yaml
requires:
  board_capabilities:
    - hdmi
```

Ak modul použije `hdmi_out`, ale board nemá hdmi capability:

```text
REQ002 IP hdmi_out requires board capability hdmi
```

---

## Commit 169 — board capability discovery

```text
cli: add board capability discovery
```

Použitie:

```bash
socfw boards capabilities ac608_ep4ce15
```

Výstup:

```text
leds
buttons
uart
i2c
hdmi
sdram
headers
```

---

## Commit 170 — init templates filtered by board capabilities

```text
scaffold: validate init templates against board capabilities
```

Ak user spraví:

```bash
socfw init demo --template hdmi --board board_without_hdmi
```

chyba:

```text
Template hdmi requires board capability hdmi.
```

---

## Commit 171 — board package metadata

```text
packs: add board package metadata and docs
```

Pack:

```yaml
pack:
  name: builtin-boards
  version: 1.1.0
  boards:
    - id: qmtech_ep4ce55
      capabilities: [leds, sdram, pmod]
    - id: ac608_ep4ce15
      capabilities: [leds, buttons, uart, hdmi, sdram, headers]
```

---

## Commit 172 — board pack compatibility matrix

```text
docs: add board compatibility matrix
```

Table:

| Board          | FPGA         | LEDs | Buttons | UART | SDRAM | HDMI     | Headers  |
| -------------- | ------------ | ---- | ------- | ---- | ----- | -------- | -------- |
| QMTech EP4CE55 | EP4CE55F23C8 | yes  | yes     | yes  | yes   | via PMOD | PMOD     |
| AC608 EP4CE15  | EP4CE15E22C8 | yes  | yes     | yes  | yes   | yes      | P5/P6/P8 |

---

## Commit 173 — board regression command

```text
cli: add board-regress command for builtin board examples
```

Použitie:

```bash
socfw board-regress ac608_ep4ce15
```

Spustí:

* validate board
* validate examples
* build blink anchor
* board-lint

---

## Commit 174 — CI board regression lane

```text
ci: add builtin board regression lane
```

CI:

```bash
socfw board-regress qmtech_ep4ce55
socfw board-regress ac608_ep4ce15
```

---

## Commit 175 — v1.1 release candidate checklist

```text
release: add v1.1 board and native pipeline RC checklist
```

Checklist:

* native pipeline default
* no legacy backend in default build
* AC608 blink golden
* selector index
* board pin conflict validation
* JSON provenance
* board pinout report
* board-info and doctor selectors

---

Najbližší vývojový blok by som zafixoval takto:

```text
151 selector diagnostics
157 inferred features from binds
163 artifact producer JSON
165 board_pinout.md report
166 AC608 blink pinout golden
175 v1.1 RC checklist
```
