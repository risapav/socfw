Dobre — tu je **realistická roadmapa pre v1.1**. Nie marketingová, ale technicky prioritizovaná podľa toho, čo ti teraz najviac vráti hodnotu po cutovere.

---

# 🧭 v1.1 Roadmap (post-cutover)

## Kontext

Po `v1.0.0-cutover` máš:

* stabilný nový flow (`socfw`)
* vendor IP support (PLL, SDRAM)
* bridge *model* + scaffold
* golden anchors
* CI enforcement

👉 v1.1 nie je o “ďalších features”, ale o:

* odstránení dočasných hackov
* spevnení architektúry
* pripravení systému na reálne SoC projekty

---

# 🔴 PRIORITA 1 — odstrániť scaffolding (najdôležitejšie)

## 1.1 Real bridge RTL (nahradiť scaffold patch)

Dnes:

* `simple_bus_to_wishbone_bridge` je len vložený hack do `soc_top.sv`

v1.1:

* bridge sa generuje ako **normálny IP blok**
* zapojený cez:

  * IR / elaboration
  * nie string patchovanie

### výsledok

* žiadny `compat_top_patch.py`
* bridge je:

  * deterministický
  * testovateľný
  * rozšíriteľný

👉 Toto je **najvyššia priorita**

---

## 1.2 Bridge planner (nie len registry)

Dnes:

* registry = “pair supported”

v1.1:

* planner:

  * rozhodne, kde treba bridge
  * vytvorí IR node
  * priradí adresný priestor

### výsledok

* viac IP → automatické bridging
* pripravené na:

  * AXI-lite
  * APB
  * atď.

---

# 🟠 PRIORITA 2 — build pipeline architektúra

## 2.1 odstrániť legacy backend zo stredu pipeline

Dnes:

* `socfw → legacy_build → patch`

v1.1:

* `socfw` má vlastný:

  * RTL emitter
  * files.tcl emitter
  * SDC emitter

### výsledok

* žiadny `.compat/`
* žiadne YAML premapovania
* čistejší debug

---

## 2.2 IR (intermediate representation)

Zaviesť jednoduchý IR:

* modules
* buses
* bridges
* clocks

### výsledok

* jasný debug:

  * “čo sa vygeneruje”
* ľahšie testovanie

---

# 🟡 PRIORITA 3 — timing & clocks

## 3.1 silnejší timing model

Dnes:

* základný model funguje

v1.1:

* clock domains
* CDC hinty
* derived clocks chaining

---

## 3.2 lepší SDC emitter

* stabilné sekcie
* grouping
* naming

---

# 🟢 PRIORITA 4 — developer UX

## 4.1 `socfw init` rozšírenie

Pridať templaty:

```bash
socfw init --template soc
socfw init --template pll
socfw init --template sdram
```

---

## 4.2 lepšie chyby

Dnes:

* errors existujú

v1.1:

* actionable hints:

napr:

```text
BRG001: Missing bridge simple_bus -> wishbone
Hint: add bridge support or change fabric protocol
```

---

## 4.3 config lint

```bash
socfw lint project.yaml
```

---

# 🔵 PRIORITA 5 — vendor & packs

## 5.1 lepší vendor pack systém

* viac než Intel:

  * Xilinx
  * Lattice

---

## 5.2 pack index

* central registry
* versioning

---

# 🟣 PRIORITA 6 — reporting v2

## 6.1 build_summary upgrade

Pridať:

* relative paths
* module → artifact mapping
* bridge mapping detail

---

## 6.2 JSON export

```bash
reports/build_summary.json
```

---

# ⚫ PRIORITA 7 — legacy removal (nie hneď)

👉 nie v 1.1. možno 1.2+

* odstrániť `legacy_build.py`
* odstrániť compat layer
* odstrániť fallback CLI

---

# 📊 odporúčané poradie commitov (v1.1)

## Fáza A — critical

```text
31: bridge: implement real simple_bus_to_wishbone RTL
32: elaborate: add bridge planner
33: remove compat_top_patch scaffold
```

## Fáza B — architektúra

```text
34: build: introduce IR model
35: build: replace legacy backend with native emitter
```

## Fáza C — stabilita

```text
36: timing: improve SDC emission
37: diagnostics: improve validation errors
```

## Fáza D — UX

```text
38: scaffold: add more init templates
39: cli: add lint command
```

## Fáza E — ecosystem

```text
40: packs: introduce pack index
```

---

# 🎯 čo je “success” pre v1.1

v1.1 je úspešné, keď:

* ❌ žiadne patchovanie `soc_top.sv`
* ❌ žiadny `.compat` layer
* ✔ bridge je normálny first-class objekt
* ✔ build ide bez legacy backendu
* ✔ nové projekty sú jednoduché (`socfw init`)
* ✔ vendor flow stále funguje

---

# 🧠 najdôležitejšia veta

👉 v1.0 bol **cutover**

👉 v1.1 je **odstránenie dočasných hackov**

---

# 🚀 odporúčanie

Ak chceš pokračovať správne:

👉 začni týmto:

**Commit 31: real bridge RTL + odstránenie compat_top_patch**

To je najväčší architektonický dlh, ktorý máš.

---

Ak chceš, viem ti to rozbiť presne ako predtým:

👉 **Commit 31 — file-by-file implementácia reálneho bridge (bez hackov)**
