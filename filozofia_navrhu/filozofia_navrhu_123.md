## Commit 72 — board resource `kind` inference

```text
config: infer board resource kind from direction width and pins
```

Cieľ:

* ak legacy board resource nemá `kind`, framework ho vie odvodiť
* znížiť ručné úpravy pri importe BSP
* podporiť tvoje existujúce tvary ako:

```yaml
seg:
  top_name: ONB_SEG
  direction: output
  width: 8
  pins:
    7: A4
    0: C4
```

Inferencia:

```text
direction: inout            -> kind: inout
width > 1 + pins            -> kind: vector
width == 1 + pin            -> kind: scalar
signals/groups existujú     -> container, nie leaf
```

Pridať:

```text
socfw/config/normalizers/board_kind.py
tests/unit/test_board_kind_inference.py
```

---

## Commit 73 — board resource validator

```text
validate: add board resource shape validation
```

Cieľ:

* zachytiť zlé resource definície priamo pri board load
* napríklad:

  * `width: 8`, ale iba 7 pinov
  * `kind: scalar`, ale má `pins`
  * `kind: vector`, ale nemá `pins`
  * `direction: nonsense`

Chyby:

```text
BRD201 invalid resource kind
BRD202 scalar requires pin
BRD203 vector/inout requires pins
BRD204 width does not match number of pins
BRD205 invalid direction
```

---

## Commit 74 — `socfw board-info`

```text
cli: add socfw board-info command
```

Použitie:

```bash
socfw board-info packs/builtin/boards/ac608_ep4ce15/board.yaml
socfw board-info --board ac608_ep4ce15
```

Výstup:

```text
Board: ac608_ep4ce15
FPGA: EP4CE15E22C8
Clock: clk @ 50 MHz

Resources:
- onboard.leds output [5] pins L3,J13,G16,B16,F8
- external.sdram.dq inout [16] pins ...
- onboard.hdmi.tmds_p output [4] pins ...
```

Pridať:

```text
socfw/diagnostics/board_info.py
tests/integration/test_board_info_ac608.py
```

---

## Commit 75 — board resource aliases in project binds

```text
board: add optional board resource aliases for convenient binds
```

Cieľ:

umožniť v boarde:

```yaml
aliases:
  leds: onboard.leds
  sdram: external.sdram
  hdmi_out: onboard.hdmi
```

Potom v projekte:

```yaml
target: board:@leds
```

alebo:

```yaml
features:
  use:
    - board:@sdram
```

Pravidlá:

* alias musí začínať `@`
* alias expanduje na reálny resource path
* doctor zobrazí expanded path

---

## Commit 76 — board pin conflict exceptions

```text
validate: support explicit board pin conflict exceptions
```

Niektoré dosky majú muxované alebo alternatívne funkcie. Board môže definovať:

```yaml
pin_conflicts:
  allowed:
    - pins: [R1, R2]
      resources:
        - external.sdram.dq
        - connectors.pmod.J11
      reason: "J11 shares pins with SDRAM; mutually exclusive by project features"
```

Validator potom:

* nehlási konflikt, ak nie sú obe features aktívne
* hlási konflikt, ak projekt explicitne použije obe naraz

---

## Commit 77 — feature profiles

```text
board: add feature profiles for common board configurations
```

Board:

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

  demo:
    use:
      - onboard.leds
      - onboard.uart
```

Project:

```yaml
features:
  profile: demo
```

Výhoda:

* príklady sú kratšie
* pin conflict checker vie, čo je aktívne
* board author vie odporučiť validné kombinácie

---

## Commit 78 — AC608 profile examples

```text
examples: add AC608 board profile examples
```

Pridať:

```text
examples/ac608_profile_minimal/project.yaml
examples/ac608_profile_hdmi/project.yaml
examples/ac608_profile_sdram/project.yaml
```

Každý:

```bash
socfw validate project.yaml
```

musí prejsť.

---

## Commit 79 — board pack index

```text
packs: add board pack index and board discovery
```

Cieľ:

```bash
socfw boards list
```

Výstup:

```text
qmtech_ep4ce55
ac608_ep4ce15
```

Board pack:

```yaml
boards:
  - id: qmtech_ep4ce55
    file: boards/qmtech_ep4ce55/board.yaml
  - id: ac608_ep4ce15
    file: boards/ac608_ep4ce15/board.yaml
```

---

## Commit 80 — board migration tool

```text
tools: add legacy board YAML migration helper
```

Použitie:

```bash
socfw migrate-board old_ac608.yaml --out packs/builtin/boards/ac608_ep4ce15/board.yaml
```

Robí:

```text
device -> fpga
system.clock.port -> system.clock.top_name
standard -> io_standard
soc_top_name -> top_name
dir -> direction
indexed pins -> list pins
groups/signals -> canonical nested resources
```

---

## Commit 81 — better HDMI modeling

```text
board: add differential pair resource model for HDMI TMDS
```

Dnes máme:

```yaml
tmds_p:
tmds_n:
```

Lepší model:

```yaml
hdmi:
  tmds:
    kind: differential_vector
    top_name_p: TMDS_P
    top_name_n: TMDS_N
    direction: output
    width: 4
    pins_p: [L2, N2, P2, K2]
    pins_n: [L1, N1, P1, K1]
    io_standard: LVDS_E_3R
```

Emitter potom vie vytvoriť obidve assignment skupiny.

---

## Commit 82 — differential resource validation

```text
validate: add differential resource width and pin checks
```

Chyby:

```text
BRD301 differential resource requires pins_p and pins_n
BRD302 pins_p and pins_n width mismatch
BRD303 invalid differential direction
```

---

## Commit 83 — HDMI IP descriptor convention

```text
docs: add HDMI IP descriptor convention and example
```

Príklad:

```yaml
ip:
  name: hdmi_out
  module: hdmi_out

ports:
  - name: TMDS_P
    direction: output
    width: 4
  - name: TMDS_N
    direction: output
    width: 4
  - name: PIXEL_CLK
    direction: input
    width: 1
```

Bind:

```yaml
TMDS_P:
  target: board:onboard.hdmi.tmds_p
TMDS_N:
  target: board:onboard.hdmi.tmds_n
```

---

## Commit 84 — canonical board snapshot tests

```text
golden: add board descriptor normalization snapshots
```

Cieľ:

* AC608 legacy import sa normalizuje na canonical YAML
* QMTech board canonical zostáva stabilný

Pridať:

```text
tests/golden/board_expected/ac608_ep4ce15.normalized.yaml
tests/golden/test_board_normalization_golden.py
```

---

## Commit 85 — board lint command

```text
cli: add socfw board-lint command
```

Použitie:

```bash
socfw board-lint packs/builtin/boards/ac608_ep4ce15/board.yaml
```

Kontroly:

* resource shape
* duplicate pins inside board
* missing io standards
* suspicious pins like `R0`
* missing `kind`
* indexed pins not normalized

---

## Odporúčané poradie teraz

Najbližšie by som spravil:

```text
72 config: infer board resource kind from direction width and pins
73 validate: add board resource shape validation
74 cli: add socfw board-info command
75 board: add optional board resource aliases
```

Až potom by som išiel na HDMI differential model, lebo najprv potrebuješ pevný board resource základ.
