Hotovo — máš kompletný **master checklist pre cestu až po v1.0.0 cutover**.

Toto je presne ten typ artefaktu, ktorý:

* drží celý refaktor pod kontrolou
* umožňuje robiť checkpointy
* a zabraňuje tomu, aby sa projekt “rozliezol” bez uzavretia

---

## Ako ho prakticky používať (dôležité)

Odporúčam ti veľmi konkrétny workflow:

### 1. Používaj ho ako jediný source of truth

Každý commit / sprint by mal:

* odškrtnúť konkrétne položky
* alebo pridať krátku poznámku (ak niečo blokuje)

---

### 2. Pridaj si k nemu 2 veci

#### A. status stĺpec (voliteľné)

Ak chceš viac granularitu:

```md
- [ ] (in progress) Vendor SDRAM pack created
```

alebo:

```md
- [x] Vendor PLL pack created (commit abc123)
```

---

#### B. prepojenie na branch/commit

Pri väčších krokoch si zapisuj:

```md
- [x] Vendor PLL pack created — branch converge/vendor-pll
```

To ti brutálne pomôže pri návrate späť.

---

### 3. Sprint rytmus

Používaj to takto:

* každý sprint = 1–2 fázy z checklistu
* nikdy neskáč medzi fázami
* dokonči fázu → checkpoint → až potom ďalej

---

## Najbližší praktický krok (tvoj konkrétny stav)

Podľa toho, kde si teraz, odporúčam:

👉 začať od:

**Phase 1 + Phase 2 + Phase 3 (blink + board + packs)**

a ísť presne v tomto poradí:

1. Packs + board resolution
2. Blink fixtures green
3. Golden stabilizácia

A až potom:
4. Vendor PLL
5. Vendor SDRAM

---

## Najväčšia chyba, ktorej sa vyhni

Nesnaž sa:

* robiť všetky fázy paralelne
* alebo „len trochu“ zo všetkého

Tento checklist je navrhnutý tak, že:
👉 každá fáza odstraňuje neistotu pre ďalšiu

---

## Keď sa dostaneš sem…

Keď budeš mať odškrtnuté:

* Phase 1–5
* Phase 8 (readiness)

tak si v bode, kde:

👉 nový framework je prakticky hotový
👉 a cutover je už len organizačný krok

---

## Ak chceš ísť ešte hlbšie

Môžeme spraviť ďalší krok úplne prakticky:

👉 rozbiť **Phase 1 (Core Convergence)** na konkrétne súbory a diffy v tvojom existujúcom repo

alebo

👉 spraviť **review checklist pre PR (code review guide)** pre tento refaktor

Stačí povedať 👍
