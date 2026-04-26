## Commit 111 — project-level board profile support

```text
project: add board feature profile selection
```

Cieľ:

* umožniť v projekte krátky zápis:

```yaml
features:
  profile: minimal
```

namiesto:

```yaml
features:
  use:
    - board:onboard.leds
```

## Project syntax

```yaml
features:
  profile: hdmi
```

alebo kombinácia:

```yaml
features:
  profile: minimal
  use:
    - board:external.headers.P8.gpio
```

## Board syntax

```yaml
profiles:
  minimal:
    use:
      - onboard.leds

  hdmi:
    use:
      - onboard.hdmi

  sdram:
    use:
      - external.sdram
```

## Pridať

```text
socfw/board/profile_resolver.py
tests/unit/test_board_profile_resolver.py
```

---

## Commit 112 — board alias resolver

```text
board: resolve board resource aliases in features and binds
```

Board:

```yaml
aliases:
  leds: onboard.leds
  buttons: onboard.buttons
  hdmi: onboard.hdmi
  sdram: external.sdram
```

Project:

```yaml
features:
  use:
    - board:@leds
```

Bind:

```yaml
ONB_LEDS:
  target: board:@leds
```

Resolver:

```text
board:@leds -> board:onboard.leds
```

Chyby:

```text
BRD_ALIAS404 unknown board alias '@foo'
```

---

## Commit 113 — unified board target resolver

```text
board: add unified resolver for board targets aliases profiles and derived resources
```

Cieľ:

mať jedno API:

```python
resolver.resolve("board:@leds")
resolver.resolve("board:onboard.leds")
resolver.resolve_feature_profile("minimal")
```

Pridať:

```text
socfw/board/target_resolver.py
tests/unit/test_board_target_resolver.py
```

Použije sa v:

```text
binding_rules.py
pin_rules.py
rtl_ir_builder.py
doctor.py
board_info.py
```

---

## Commit 114 — board target diagnostics

```text
diagnostics: improve BRD001 BRD002 board target errors
```

Nový výstup:

```text
ERROR BRD001
Unsupported board target 'board:connectors.pmod.J10'

Reason:
  This path describes a physical connector, not a bindable resource.

Use one of:
  board:external.pmod.j10_gpio8
  board:external.pmod.j10_led8
```

Pridať hinty:

* unknown path
* connector-only path
* alias not found
* resource exists but not leaf
* resource width/direction missing

---

## Commit 115 — connector-only target detection

```text
validate: detect connector-only board targets and suggest derived resources
```

Ak user napíše:

```yaml
target: board:connectors.pmod.J10
```

chyba:

```text
BRD003 connector path is not bindable
```

Hint:

```text
Define a derived resource:
derived_resources:
  - name: external.pmod.j10_gpio8
    from: connectors.pmod.J10
    role: gpio8
    top_name: PMOD_J10_D
```

---

## Commit 116 — resource leaf detection

```text
board: add resource leaf detection and traversal helpers
```

Pridať:

```text
socfw/board/resource_tree.py
```

API:

```python
is_resource_leaf(node)
iter_resource_leaves(resources, root_path="")
collect_resource_pins(node)
resource_width(node)
resource_direction(node)
```

Použije sa v:

* board-info
* doctor
* pin conflict validation
* board target resolver
* board.tcl emitter

---

## Commit 117 — board.tcl emitter uses resource tree helpers

```text
emit: use board resource tree helpers in board.tcl emitter
```

Cieľ:

* prestať mať custom rekurziu v emitteri
* podporiť:

  * scalar
  * vector
  * inout
  * differential_vector
  * bundle leaves

---

## Commit 118 — bundle resource support

```text
board: add bundle resource model and binding validation
```

Canonical:

```yaml
hdmi:
  kind: bundle
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

Rules:

* `board:onboard.hdmi` is a bundle, not directly bindable unless IP interface matches
* `board:onboard.hdmi.signals.d` is bindable
* doctor displays bundle children

---

## Commit 119 — differential vector resource support

```text
board: add differential vector resource type for HDMI TMDS
```

Canonical:

```yaml
tmds:
  kind: differential_vector
  direction: output
  width: 4
  top_name_p: TMDS_P
  top_name_n: TMDS_N
  pins_p: [L2, N2, P2, K2]
  pins_n: [L1, N1, P1, K1]
  io_standard: LVDS_E_3R
```

Emitter:

```tcl
set_location_assignment L2 -to TMDS_P[0]
set_location_assignment L1 -to TMDS_N[0]
```

---

## Commit 120 — HDMI TMDS modeling cleanup

```text
board: convert AC608 HDMI to differential_vector resource
```

Replace:

```yaml
hdmi:
  tmds_p:
  tmds_n:
```

with:

```yaml
hdmi:
  tmds:
    kind: differential_vector
    top_name_p: TMDS_P
    top_name_n: TMDS_N
    ...
```

Project bind:

```yaml
TMDS_P:
  target: board:onboard.hdmi.tmds.p
TMDS_N:
  target: board:onboard.hdmi.tmds.n
```

or better:

```yaml
TMDS:
  target: board:onboard.hdmi.tmds
```

once IP interface bundles exist.

---

## Commit 121 — IP interface bundles

```text
ip: add interface bundles for grouped ports
```

IP descriptor:

```yaml
interfaces:
  - name: hdmi
    type: differential_video_out
    ports:
      tmds_p: TMDS_P
      tmds_n: TMDS_N
```

Then project:

```yaml
bind:
  interfaces:
    hdmi:
      target: board:onboard.hdmi.tmds
```

This avoids binding every TMDS signal manually.

---

## Commit 122 — interface binding validation

```text
validate: add IP interface to board bundle binding checks
```

Checks:

* IP interface type matches board resource kind/capability
* widths match
* directions match
* required signals exist

Error examples:

```text
IFACE001 interface hdmi expects differential_video_out but target is vector
IFACE002 TMDS width mismatch IP=4 board=3
```

---

## Commit 123 — interface binding RTL emission

```text
rtl: emit interface bundle bindings
```

For:

```yaml
bind:
  interfaces:
    hdmi:
      target: board:onboard.hdmi.tmds
```

emit:

```systemverilog
.TMDS_P(TMDS_P),
.TMDS_N(TMDS_N)
```

---

## Commit 124 — AC608 HDMI example with interface binding

```text
examples: add AC608 HDMI example using interface bind syntax
```

Project:

```yaml
modules:
  - instance: hdmi0
    type: hdmi_out
    clocks:
      PIXEL_CLK: sys_clk
    bind:
      interfaces:
        hdmi:
          target: board:onboard.hdmi.tmds
```

---

## Commit 125 — board selector autocompletion data

```text
doctor: emit board selector index for editor support
```

Generate:

```text
reports/board_selectors.json
```

Example:

```json
{
  "resources": [
    "board:onboard.leds",
    "board:external.sdram.dq",
    "board:onboard.hdmi.tmds"
  ],
  "aliases": [
    "board:@leds",
    "board:@sdram"
  ],
  "profiles": [
    "minimal",
    "hdmi",
    "sdram"
  ]
}
```

---

## Commit 126 — VS Code schema hints

```text
docs: add JSON schema and editor hints for project and board YAML
```

Pridať:

```text
schemas/project.schema.json
schemas/board.schema.json
schemas/ip.schema.json
docs/editor/vscode.md
```

---

## Commit 127 — JSON schema generation from Pydantic

```text
schema: export pydantic JSON schemas for editor integration
```

CLI:

```bash
socfw schema-export --out schemas/
```

Exports:

```text
project.schema.json
timing.schema.json
ip.schema.json
board.schema.json
```

---

## Commit 128 — board migration report

```text
tools: add migration report for imported board YAML
```

When migrating legacy AC608 YAML, output:

```text
reports/board_migration.md
```

Sections:

* converted fields
* aliases used
* inferred resource kinds
* pin map normalization
* warnings
* unresolved structures

---

## Commit 129 — board pack QA suite

```text
ci: add board pack QA validation for all builtin boards
```

CI:

```bash
socfw boards list
socfw board-lint packs/builtin/boards/qmtech_ep4ce55/board.yaml
socfw board-lint packs/builtin/boards/ac608_ep4ce15/board.yaml
```

---

## Commit 130 — v1.1 board subsystem milestone

```text
release: document v1.1 board subsystem milestone
```

Release notes:

* AC608 support
* derived connector resources
* aliases/profiles
* pin conflict checking
* board-info
* board-lint
* HDMI/differential modeling groundwork

---

Najbližší praktický blok by som robil takto:

```text
111 project profile support
112 board alias resolver
113 unified board target resolver
115 connector-only target diagnostics
116 resource tree helpers
```

Potom už budeš mať stabilný základ pre AC608, PMOD, HDMI aj mux/conflict validáciu.
