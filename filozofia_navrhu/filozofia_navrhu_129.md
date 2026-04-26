## Commit 131 — unified board selector index

```text
board: add unified board selector index for resources aliases profiles and connectors
```

Cieľ:

* z jedného miesta získať všetky platné board selektory
* použiť to v:

  * `doctor`
  * `board-info`
  * chybových hláškach
  * editor autocomplete
  * `BRD001/BRD002` hintoch

Pridať:

```text
socfw/board/selector_index.py
tests/unit/test_board_selector_index.py
```

Výstup API:

```python
index.resources      # board:onboard.leds
index.aliases        # board:@leds
index.profiles       # minimal, hdmi, sdram
index.connectors     # board:connectors.pmod.J10
```

Dôležité: `connectors` sú zobraziteľné, ale nie bindovateľné.

---

## Commit 132 — actionable selector suggestions

```text
diagnostics: suggest closest board selectors for invalid board targets
```

Cieľ:

Ak user napíše:

```yaml
target: board:connectors.pmod.J10
```

výstup má byť:

```text
ERROR BRD003
board:connectors.pmod.J10 is a physical connector, not a bindable resource.

Did you mean:
  board:external.pmod.j10_gpio8
  board:external.pmod.j10_led8
```

Použiť fuzzy match:

```text
connectors.pmod.J10 -> external.pmod.j10_*
```

Pridať:

```text
socfw/diagnostics/suggestions.py
tests/unit/test_board_selector_suggestions.py
```

---

## Commit 133 — project `features` schema hardening

```text
project: formalize features profile and use schema
```

Canonical:

```yaml
features:
  profile: minimal
  use:
    - board:onboard.leds
    - board:external.sdram
```

Pridať do schema:

```python
class ProjectFeaturesSchema(BaseModel):
    profile: str | None = None
    use: list[str] = Field(default_factory=list)
```

Do `ProjectModel`:

```python
features_profile: str | None
features_use: list[str]
```

---

## Commit 134 — feature expansion into selected resource set

```text
board: expand project features into selected board resource set
```

Cieľ:

Z:

```yaml
features:
  profile: sdram
  use:
    - board:@leds
```

vznikne:

```text
selected_resources:
- external.sdram.addr
- external.sdram.dq
- ...
- onboard.leds
```

Pridať:

```text
socfw/board/feature_expansion.py
tests/unit/test_feature_expansion.py
```

---

## Commit 135 — build summary selected board resources

```text
reports: include selected board resources in build provenance
```

Do `build_summary.md`:

```text
## Selected Board Resources
- onboard.leds
- external.sdram.addr
- external.sdram.dq
```

Do JSON:

```json
"selected_board_resources": [
  "onboard.leds",
  "external.sdram.dq"
]
```

---

## Commit 136 — board pin ownership model

```text
board: add pin ownership model for selected resources
```

Cieľ:

Každý selected resource vygeneruje:

```python
PinUse(
  pin="R1",
  resource_path="external.sdram.dq",
  bit=11,
  top_name="SDRAM_DQ[11]"
)
```

Pridať:

```text
socfw/board/pin_ownership.py
tests/unit/test_pin_ownership.py
```

---

## Commit 137 — feature-aware pin conflict rule v2

```text
validate: rewrite pin conflict rule using selected resource pin ownership
```

Chyba:

```text
PIN001 pin R1 selected by both external.sdram.dq[11] and external.headers.P8.gpio[0]
```

Toto už bude robustné pre AC608 aj QMTech.

---

## Commit 138 — board.tcl emits only selected/bound resources

```text
emit: restrict board.tcl pin assignments to selected and bound resources
```

Dnes board emitter môže emitovať veľa vecí.
Nový behavior:

* system clock/reset vždy
* bindované resources vždy
* `features.use` / profile selected resources
* nič iné

Tým sa vyhneš konfliktom z alternatívnych funkcií na doske.

---

## Commit 139 — RTL top emits only selected/bound top ports

```text
rtl: restrict top ports to selected and bound resources
```

Rovnaký princíp pre `soc_top.sv`.

Napríklad AC608 HDMI projekt nebude mať SDRAM porty.

---

## Commit 140 — strict feature mode

```text
validate: add strict feature selection mode
```

Project:

```yaml
features:
  strict: true
  profile: minimal
```

Pravidlo:

Ak binduješ resource mimo `features.use/profile`, chyba:

```text
FEAT002 module binds board:external.sdram.dq but resource is not selected by features
```

Default môže byť warning, strict je error.

---

## Commit 141 — board resource direction policy

```text
validate: add board resource direction policy for bind targets
```

Pravidlá:

* IP output → board output OK
* IP input → board input OK
* IP inout → board inout OK
* IP output → board input error
* IP input → board output môže byť OK iba pre internal feedback? default warning/error podľa policy

Chyby:

```text
BIND010 direction mismatch IP output to board input
BIND011 direction mismatch IP input to board output
```

---

## Commit 142 — IO standard propagation

```text
emit: include IO standard assignments in board.tcl`
```

Emitter:

```tcl
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ONB_LEDS[0]
```

Pre vector:

```tcl
-to ONB_LEDS[0]
...
```

Pre scalar:

```tcl
-to UART_TX
```

---

## Commit 143 — device/family assignments

```text
emit: improve Quartus device family assignments
```

`board.tcl`:

```tcl
set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE EP4CE15E22C8
set_global_assignment -name TOP_LEVEL_ENTITY soc_top
set_global_assignment -name VERILOG_INPUT_VERSION SYSTEMVERILOG_2005
```

---

## Commit 144 — generated_config.tcl native emitter

```text
emit: add native generated_config.tcl emitter
```

Výstup:

```text
hal/generated_config.tcl
```

Obsah:

```tcl
set_global_assignment -name TOP_LEVEL_ENTITY soc_top
set_global_assignment -name DEVICE EP4CE15E22C8
source board.tcl
source files.tcl
```

---

## Commit 145 — Quartus file set complete

```text
build: emit complete Quartus helper file set natively
```

Build výstup:

```text
hal/board.tcl
hal/files.tcl
hal/generated_config.tcl
timing/soc_top.sdc
rtl/soc_top.sv
reports/build_summary.md
reports/build_provenance.json
```

---

## Commit 146 — AC608 native build golden anchor

```text
golden: add AC608 blink native build golden anchor
```

Pridať:

```text
tests/golden/fixtures/ac608_blink/project.yaml
tests/golden/expected/ac608_blink/...
tests/golden/test_ac608_blink_golden.py
```

Overiť:

* `clk` top port
* `ONB_LEDS[4:0]`
* EP4CE15E22C8 device
* correct LED pins

---

## Commit 147 — AC608 HDMI validation anchor

```text
golden: add AC608 HDMI validation anchor
```

Nie nutne build golden, stačí validate:

```text
tests/integration/test_validate_ac608_hdmi.py
```

Overiť:

* TMDS width 4
* LVDS standard
* no SDRAM ports selected

---

## Commit 148 — AC608 SDRAM validation anchor

```text
golden: add AC608 SDRAM validation anchor
```

Overiť:

* SDRAM addr width 12
* dq width 16
* ba width 2
* selected resources expand correctly
* no header conflict unless selected

---

## Commit 149 — board import regression suite

```text
tests: add regression suite for imported board descriptors
```

Covers:

* QMTech board
* AC608 board
* connector-derived resources
* pin conflicts
* profiles
* aliases
* board.tcl native output

---

## Commit 150 — v1.1 board system release notes

```text
release: document v1.1 board system roadmap completion
```

Docs:

```text
docs/releases/v1.1-board-system.md
```

Obsah:

* canonical board syntax
* AC608 support
* connector-derived resources
* feature profiles
* selected-resource build
* native board.tcl improvements
* pin conflict detection

---

Najbližší praktický implementačný blok:

```text
131 selector index
134 feature expansion
136 pin ownership
137 pin conflict rule v2
138 board.tcl selected-only emission
146 AC608 blink golden anchor
```
