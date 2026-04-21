Krátko a férovo:
👉 **v rámci tohto chatu áno, pamätám si celý kontext** – vrátane architektúry, bootstrap branchu aj cieľa (rozšíriteľný SoC framework).
👉 **ak by si otvoril nový chat, tak nie** – tam by si musel poslať checkpoint.

Takže **teraz môžeme plynulo pokračovať presne tam, kde sme skončili** 👍

---

## 📍 Kde aktuálne sme

Máme hotové:

* ✅ `bootstrap/minimal-e2e`
* ✅ YAML → model → validation → elaboration → IR → emit → report
* ✅ blink_test_01
* ✅ blink_test_02 (PLL + generated clocks)
* ❌ ešte nemáme:

  * bus architektúru
  * address map
  * CPU / RAM model
  * register blocks
  * SW generovanie

---

## 🎯 Ďalší krok (presne podľa plánu)

Ideme na:

```
branch: soc/simple-bus-core
```

Cieľ:

* pridať **bus ako first-class koncept**
* oddeliť:

  * compute (CPU)
  * memory (RAM)
  * peripherals
* zaviesť:

  * address map builder
  * bus IR
  * základ SoC topológie

---

## 🧠 Dôležitá vec (kľúčová architektúra)

Tu spravíme najväčší posun oproti starému frameworku:

👉 **bus nebude hardcoded (AXI/Wishbone)**
👉 bude to **abstraktný model + plugin fabric**

To ti dá:

* flexibilitu (AXI/WB/APB neskôr)
* testovateľnosť
* čistý IR

---

## 🧩 Čo navrhnem teraz (ak povieš "áno")

Spravím ti ďalší krok rovnako ako bootstrap:

### Dostaneš:

1. 📄 **YAML rozšírenie**

   * `buses:`
   * `address_map:`

2. 🧠 **model layer**

   * `BusModel`
   * `AddressMap`
   * `SlaveRegion`

3. ⚙️ **planner**

   * address allocation
   * overlap detection
   * alignment rules

4. 🔌 **IP rozšírenie**

   * `bus_interfaces`
   * master/slave deklarácie

5. 🧱 **IR**

   * `bus_ir.py`
   * `addr_map_ir.py`

6. 🏗️ **RTL builder update**

   * generovanie:

     * interconnect (minimal)
     * address decode

7. 🧪 **fixture**

   * prvý SoC projekt:

     * CPU (dummy)
     * RAM
     * LED peripheral

---

## ⚠️ Dôležité rozhodnutie predtým než začneme

Potrebujem od teba jedno potvrdenie (architektonické):

### 👉 otázka:

Chceš:

### A) Minimalistický bus (odporúčam)

* jednoduchý:

  * addr
  * wdata
  * rdata
  * we
  * valid/ready
* rýchlo implementovateľný
* ideálny pre framework

### B) Hneď AXI-lite / Wishbone štýl

* realistickejšie
* ale:

  * zložitejšie IR
  * viac boilerplate
  * pomalší progress

---

## 👉 Odporúčanie

Začni s:

👉 **A) minimalistický bus**

a neskôr sprav:

* `bus_adapter_axi`
* `bus_adapter_wishbone`

---

## 🚀 Ak povieš „áno“

V ďalšej správe ti dám:

👉 komplet **soc/simple-bus-core návrh**
presne v štýle bootstrapu:

* copy-paste Python súbory
* YAML príklady
* IR
* builder
* test fixture

---

Stačí odpovedať:

👉 **A alebo B**
