Nižšie je odporúčaný model.

## 1. Princíp

`connectors.pmod.J10.pins` je len fyzická mapa konektora:

```yaml
connectors:
  pmod:
    J10:
      pins:
        1: H1
        2: F1
```

Ale toto samo osebe nie je dobrý bind target pre modul, lebo chýba:

```yaml
kind
top_name
direction
width
pins
```

Preto do boardu pridaj **odvodené resources**.

---

# Odporúčaný board.yaml tvar

Nechaj fyzický connector map:

```yaml
resources:
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

      J11:
        pins:
          1: R1
          2: P1
          3: N1
          4: M1
          7: R2
          8: P2
          9: N2
          10: M2
```

A pridaj logické PMOD resources napríklad pod:

```yaml
resources:
  external:
    pmod:
```

## PMOD J10 ako 8 LED výstup

```yaml
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

## PMOD J11 ako 8 tlačidiel / vstupov

```yaml
      j11_buttons8:
        kind: vector
        top_name: PMOD_J11_BTN
        direction: input
        width: 8
        io_standard: "3.3-V LVTTL"
        connector: connectors.pmod.J11
        pins: [R1, P1, N1, M1, R2, P2, N2, M2]
```

Potom v `project.yaml` binduješ:

```yaml
target: board:external.pmod.j10_led8
target: board:external.pmod.j11_buttons8
```

---

# 2. LED príklad v project.yaml

Ak máš `blink_test` s portom `ONB_LEDS` width 6, ale PMOD LED resource má width 8, máš dve možnosti.

## Možnosť A — definovať PMOD LED ako 6-bit resource

Najjednoduchšie:

```yaml
j10_led6:
  kind: vector
  top_name: PMOD_J10_LED
  direction: output
  width: 6
  io_standard: "3.3-V LVTTL"
  pins: [H1, F1, E1, C1, H2, F2]
```

Potom:

```yaml
modules:
  - instance: blink_02
    type: blink_test
    clocks:
      SYS_CLK: clk_100mhz
    params:
      CLK_FREQ: 100000000
    bind:
      ports:
        ONB_LEDS:
          target: board:external.pmod.j10_led6
```

## Možnosť B — ponechať 8-bit resource a použiť adaptér šírky

```yaml
bind:
  ports:
    ONB_LEDS:
      target: board:external.pmod.j10_led8
      adapt: zero_extend
```

Ale toto vyžaduje, aby framework implementoval `adapt`.

Odporúčané canonical hodnoty:

```yaml
adapt: zero_extend
adapt: truncate
adapt: replicate
```

Nie len:

```yaml
adapt: zero
```

---

# 3. Buttons príklad

Predpokladaj IP:

```yaml
ports:
  - name: BUTTONS
    direction: input
    width: 8
```

V `project.yaml`:

```yaml
modules:
  - instance: button_demo
    type: button_demo
    clocks:
      SYS_CLK: sys_clk
    bind:
      ports:
        BUTTONS:
          target: board:external.pmod.j11_buttons8
```

Ak má IP iba 4-bit vstup:

```yaml
BUTTONS:
  target: board:external.pmod.j11_buttons8
  adapt: truncate
```

---

# 4. HDMI cez PMOD — odporúčaná štruktúra

HDMI cez PMOD závisí od konkrétneho PMOD modulu. Zvyčajne potrebuješ viac signálov, nie jeden vector. Preto by som ho modeloval ako **bundle**:

```yaml
resources:
  external:
    pmod:
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
          de:
            kind: scalar
            top_name: HDMI_DE
            direction: output
            pin: F1
          hsync:
            kind: scalar
            top_name: HDMI_HSYNC
            direction: output
            pin: E1
          vsync:
            kind: scalar
            top_name: HDMI_VSYNC
            direction: output
            pin: C1
          d:
            kind: vector
            top_name: HDMI_D
            direction: output
            width: 4
            pins: [H2, F2, D2, C2]
```

A v `project.yaml`:

```yaml
modules:
  - instance: hdmi_out0
    type: hdmi_out
    clocks:
      PIXEL_CLK: sys_clk
    bind:
      ports:
        HDMI_CLK:
          target: board:external.pmod.j10_hdmi_out.signals.clk
        HDMI_DE:
          target: board:external.pmod.j10_hdmi_out.signals.de
        HDMI_HSYNC:
          target: board:external.pmod.j10_hdmi_out.signals.hsync
        HDMI_VSYNC:
          target: board:external.pmod.j10_hdmi_out.signals.vsync
        HDMI_D:
          target: board:external.pmod.j10_hdmi_out.signals.d
```

Pre HDMI input podobne, ale direction `input`:

```yaml
j11_hdmi_in:
  kind: bundle
  connector: connectors.pmod.J11
  io_standard: "3.3-V LVTTL"
  signals:
    clk:
      kind: scalar
      top_name: HDMI_IN_CLK
      direction: input
      pin: R1
    de:
      kind: scalar
      top_name: HDMI_IN_DE
      direction: input
      pin: P1
    hsync:
      kind: scalar
      top_name: HDMI_IN_HSYNC
      direction: input
      pin: N1
    vsync:
      kind: scalar
      top_name: HDMI_IN_VSYNC
      direction: input
      pin: M1
    d:
      kind: vector
      top_name: HDMI_IN_D
      direction: input
      width: 4
      pins: [R2, P2, N2, M2]
```

---

# 5. Dôležitý problém: PMOD J11 vs SDRAM

Tvoj J11 používa piny:

```yaml
R1
R2
```

A SDRAM používa tiež:

```yaml
R1
R2
```

Takže by som zaviedol pravidlo:

```yaml
features:
  use:
    - board:external.pmod.j11_buttons8
```

a neskôr validátor pin konfliktov:

```text
PIN001: pin R1 used by external.pmod.j11_buttons8 and external.sdram.dq
```

Pre blink test je to OK, ak nepoužívaš SDRAM. Pre SDRAM projekt nie.

---

# 6. Odporúčaný project.yaml pre tvoje tri blink moduly

```yaml
features:
  use:
    - board:onboard.leds
    - board:external.pmod.j10_led6
    - board:external.pmod.j11_led6
```

```yaml
modules:
  - instance: blink_01
    type: blink_test
    clocks:
      SYS_CLK: clk_100mhz
    params:
      CLK_FREQ: 100000000
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds

  - instance: blink_02
    type: blink_test
    clocks:
      SYS_CLK: clk_100mhz
    params:
      CLK_FREQ: 100000000
    bind:
      ports:
        ONB_LEDS:
          target: board:external.pmod.j10_led6

  - instance: blink_03
    type: blink_test
    clocks:
      SYS_CLK: sys_clk
    params:
      CLK_FREQ: 50000000
    bind:
      ports:
        ONB_LEDS:
          target: board:external.pmod.j11_led6
```

Ak chceš 8-bit PMOD resource, potom:

```yaml
target: board:external.pmod.j10_led8
adapt: zero_extend
```

---

# Commit 56 — board resource schema docs + `BRDxxx` diagnostiky

```text
docs: add board resource schema guide and improve BRD diagnostics
```

Pridať:

```text
docs/schema/board_v2.md
docs/errors/board_diagnostics.md
socfw/config/normalizers/board.py
tests/unit/test_board_resource_normalizer.py
```

Cieľ:

* vysvetliť `scalar`, `vector`, `inout`, `bundle`
* vysvetliť `pins` list vs map
* vysvetliť `connectors` vs bindovateľné resources
* zlepšiť `BRD001`, `BRD002`

Canonical pravidlo:

```yaml
kind: vector
top_name: NAME
direction: output
width: 8
pins: [PIN0, PIN1, ...]
```

Legacy alias:

```yaml
pins:
  7: A4
  6: B1
```

normalizovať na:

```yaml
pins: [C4, B2, A3, C3, A5, B4, B1, A4]
```

---

# Commit 57 — bindovateľné PMOD resources

```text
board: add derived PMOD resources for J10 and J11
```

Upraviť board pack:

```yaml
resources:
  external:
    pmod:
      j10_led6:
      j10_led8:
      j11_led6:
      j11_led8:
      j10_buttons8:
      j11_buttons8:
```

Pridať test:

```text
tests/integration/test_validate_pmod_bindings.py
```

Overiť:

```yaml
target: board:external.pmod.j10_led6
target: board:external.pmod.j11_led6
```

---

# Commit 58 — width adaptation v bind syntaxe

```text
validate: add explicit bind width adaptation policy
```

Podporované:

```yaml
adapt: zero_extend
adapt: truncate
adapt: replicate
```

Pravidlá:

* bez `adapt` musí sedieť width presne
* `zero_extend`: IP width < board width
* `truncate`: IP width > board width
* `replicate`: menší signál sa opakuje do širšieho targetu

Chyby:

```text
BIND003 width mismatch
BIND006 invalid adapt mode
BIND007 adapt mode not allowed for direction
```

---

# Commit 59 — HDMI bundle resources

```text
board: add PMOD HDMI bundle resource examples and validation
```

Pridať do docs:

```yaml
kind: bundle
signals:
  clk:
  de:
  hsync:
  vsync:
  d:
```

Validátor:

* bundle target s `.signals.<name>` je validný
* bind na celý bundle povolený iba ak IP deklaruje matching interface
* zatiaľ odporúčané bindovať jednotlivé signály

---

# Commit 60 — pin conflict validator

```text
validate: add board pin conflict detection across selected features
```

Použiť:

```yaml
features:
  use:
    - board:external.pmod.j11_led8
    - board:external.sdram
```

Ak oba používajú `R1`, `R2`, chyba:

```text
PIN001 pin R1 is used by board:external.pmod.j11_led8 and board:external.sdram.dq
```

Toto je dôležité presne pre tvoju dosku, lebo J11 a SDRAM sa bijú.

---

# Commit 61 — PMOD examples

```text
examples: add pmod led button and hdmi project examples
```

Pridať:

```text
examples/pmod_led_j10/project.yaml
examples/pmod_buttons_j11/project.yaml
examples/pmod_hdmi_out_j10/project.yaml
examples/pmod_hdmi_in_j11/project.yaml
```

Každý má mať:

```bash
socfw validate project.yaml
```

green.

---

Najbližšie by som implementoval **Commit 56**, lebo bez canonical board resource dokumentácie a normalizácie budeš stále narážať na rozdiel medzi:

```yaml
connectors.pmod.J10.pins
```

a skutočným bind targetom:

```yaml
external.pmod.j10_led8
```
