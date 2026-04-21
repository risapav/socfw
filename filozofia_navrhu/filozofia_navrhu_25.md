Dobrá otázka — tu je **praktický spôsob, ako si to uložiť tak, aby si zajtra nestratil ani minútu**.

---

# 🔒 Najlepšia stratégia (odporúčaná)

## 1. Ulož si checkpoint ako súbor do repa

Vytvor súbor napr.:

```
docs/dev_notes/2026-04-20-bootstrap.md
```

A vlož tam toto (upravené pre teba):

# SoC Framework – checkpoint (2026-04-20)

## Stav

* hotový návrh architektúry frameworku
* implementovaný branch: `bootstrap/minimal-e2e`
* pipeline:

  * YAML → model → validation → elaboration → IR → emit → report
* podporované projekty:

  * blink_test_01
  * blink_test_02 (PLL + generated clock)

## Funkčné časti

* config loaders (board/project/ip/timing)
* validation rules
* elaboration:

  * board bindings
  * clock domains
* IR:

  * board_ir
  * timing_ir
  * rtl_ir
* emit:

  * soc_top.sv
  * soc_top.sdc
  * board.tcl
  * files.tcl
* report:

  * JSON
  * Markdown
  * Graphviz

## CLI

* socfw validate
* socfw build
* socfw explain clocks
* socfw graph

## Ďalší krok

branch: `soc/simple-bus-core`

cieľ:

* pridať:

  * buses:
  * address map builder
  * CPU model
  * RAM model
  * peripheral mapping
* rozšíriť IR:

  * bus_ir
  * addr_map_ir
* doplniť:

  * software IR
  * register blocks

## Poznámky

* architektúra je plugin-based (emitters + validators)
* board abstraction funguje cez `board:` reference
* timing je oddelený a mergeovaný v IR
* žiadne hardcoded piny v emitroch

👉 Toto je **najdôležitejší krok**. Toto je tvoj “mozog projektu”.

---

# 📦 2. Ako spraviť ZIP

## Varianta A – celý projekt (najlepšie)

```bash
zip -r socfw_checkpoint.zip .
```

alebo

```bash
tar -czf socfw_checkpoint.tar.gz .
```

---

## Varianta B – len minimum

Zbaľ:

```text
socfw/
tests/golden/
pyproject.toml
docs/dev_notes/
```

---

# 💬 3. Uloženie tejto konverzácie

### Možnosti:

### ✅ Najjednoduchšie

* **Ctrl + S → uložiť ako HTML**
* alebo **Print → Save as PDF**

---

### ✅ Lepšie (prehľadné)

* skopíruj relevantné časti do:

```
docs/dev_notes/chat_2026-04-20.md
```

---

### ❌ Na čo sa nespoliehať

* že chat tu bude zajtra automaticky dostupný
* že si budem pamätať detailný stav bez inputu

---

# 🚀 4. Ako zajtra pokračovať (presne)

Zajtra mi pošli:

* ZIP alebo repo
* alebo aspoň:

  * `docs/dev_notes/2026-04-20-bootstrap.md`

A napíš:

> pokračuj – soc/simple-bus-core

A ja:

* nadviažem presne na túto architektúru
* navrhnem bus model
* dám ti ďalší “copy-paste ready” balík

---

# 🧠 Extra tip (najlepší workflow)

Pridaj do repa:

```
docs/
  dev_notes/
  architecture/
```

A každý väčší krok:

* 1 markdown súbor
* stručný checkpoint

To je lepšie než akýkoľvek nástroj.

---

Ak chceš, ako posledný krok dnes ti viem dať **presný návrh `soc/simple-bus-core` (buses + address map + CPU/RAM) v rovnakom štýle ako bootstrap** – zajtra by si len kopíroval a implementoval.

https://chatgpt.com/share/69e69db1-d33c-8392-9885-e5f42ec85aec