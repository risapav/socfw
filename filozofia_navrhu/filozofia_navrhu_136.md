Krátka odpoveď:
👉 **Lebo `comment` v YAML nie je automaticky “semantický” field – je to len obyčajný key, ktorý emitter momentálne ignoruje.**

---

# 🧠 Dôležité pochopiť

V YAML existujú **2 úplne odlišné veci**:

### 1. Skutočný YAML comment (❌ nedostane sa do parsera)

```yaml
# toto je comment
domain: clk_100mhz
```

➡️ Tento **sa vôbec nedostane do Pythonu / Pydanticu**
➡️ parser ho zahodí

---

### 2. `comment:` ako field (✔ dostane sa do modelu)

```yaml
comment: "Generated 100 MHz clock from PLL"
```

➡️ toto JE normálny key
➡️ ale musíš ho **explicitne spracovať v kóde**

---

# 🔥 Prečo sa ti negeneruje do výstupu

Lebo v tvojej pipeline:

```text
YAML → Pydantic schema → IR → emitter (SDC / RTL / report)
```

👉 nikde nemáš:

```python
if clock.comment:
    lines.append(f"# {clock.comment}")
```

---

# 📍 Konkrétne miesto kde to chýba

Typicky v:

```text
timing SDC emitter
clock domain resolver
reports (clock_domains.md)
```

Emitter generuje napr.:

```tcl
create_clock -name SYS_CLK -period 20.0 [get_ports {SYS_CLK}]
```

ale ignoruje:

```yaml
comment: ...
```

---

# ✅ Ako to má správne fungovať

## Commit 271 — propagate `comment` field do IR

```text
config: propagate optional comment fields into IR models
```

Do modelu:

```python
class ClockConfig(BaseModel):
    domain: str
    comment: str | None = None
```

A v IR:

```python
@dataclass
class ClockDomain:
    name: str
    comment: str | None = None
```

---

## Commit 272 — emit comments do SDC

```text
emit: include YAML comment fields as SDC comments
```

Výsledok:

```tcl
# Generated 100 MHz clock from PLL
create_generated_clock -name clk_100mhz \
  -source [get_ports {SYS_CLK}] \
  [get_pins {clkpll|c0}]
```

Implementácia:

```python
if clk.comment:
    lines.append(f"# {clk.comment}")
```

---

## Commit 273 — emit comments do reportov

```text
reports: include clock comments in clock_domains.md
```

Výstup:

```text
clk_100mhz:
  source: clkpll.c0
  frequency: 100 MHz
  comment: Generated 100 MHz clock from PLL
```

---

## Commit 274 — comment support pre ďalšie sekcie

```text
config: add comment support to clocks resets io_delays and false_paths
```

Podporiť:

```yaml
false_paths:
  - from_port: RESET_N
    comment: Async reset

io_delays:
  overrides:
    - port: ONB_LEDS[*]
      comment: LED output timing
```

SDC:

```tcl
# Async reset
set_false_path -from [get_ports {RESET_N}]
```

---

## Commit 275 — optional global comment preservation

```text
docs: explain difference between YAML comments and comment fields
```

Dokument:

```text
docs/schema/comments.md
```

Obsah:

* `# comment` → parser zahodí
* `comment:` → musí spracovať framework
* odporúčanie používať `comment:` pre generovaný output

---

# ⚠️ Dôležité UX rozhodnutie

👉 Framework musí explicitne rozhodnúť:

> ktoré `comment:` fieldy sa prenášajú do výstupu

Nie všetky sa hodia.

---

## Odporúčanie

Prenášať:

* clocks → SDC
* false_paths → SDC
* IO delays → SDC
* modules → RTL comment
* board resources → board.tcl

---

# 💡 Bonus: comment v RTL

## Commit 276 — RTL comment emission

```text
rtl: emit comments for module instances and bindings
```

Z:

```yaml
modules:
  - instance: blink_01
    comment: LED blinker instance
```

RTL:

```systemverilog
// LED blinker instance
blink_test blink_01 (...);
```

---

# ✔️ Zhrnutie

* YAML `comment:` **funguje len ak ho ty spracuješ**
* YAML `# comment` sa **nikdy nedostane do kódu**
* aktuálne ho ignoruješ → preto nič nevidíš

---

# 👉 Najbližší krok

Implementuj tieto 3 veci:

```text
271 propagate comment do IR
272 emit comment do SDC
273 emit comment do reports
```

To ti okamžite spraví YAML → SDC → report konzistentné a výrazne zlepší debugovanie.
