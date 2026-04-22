Super. Poďme na to prakticky:

# implementation convergence: čo ponechať, čo zahodiť, cieľový layout, a migračný/refaktor plán na reálny repozitár

Toto je podľa mňa správny moment prejsť z:

* „navrhli sme moderný framework“

na:

* „teraz ho naozaj bezpečne preklopíme do reálneho repa bez chaosu“.

Tu už nejde o ďalšie feature nápady, ale o:

* **čo z dnešného stavu zachovať**
* **čo prestať ďalej rozvíjať**
* **čo presunúť**
* **aké vrstvy zaviesť ako finálne**
* **v akom poradí to urobiť, aby sa repo nerozbilo**

---

# 1. Môj celkový verdikt

Ak to mám povedať priamo:

## ponechal by som

* základnú myšlienku config-driven generovania
* niektoré existujúce templaty / emit logiku, ak už fungujú
* existujúce know-how okolo board/PLL/SDRAM integrácie
* užitočné generated artifact patterns (`board.tcl`, `files.tcl`, `sdc`, headery)
* overené vendor IP artefakty a fixture data

## zásadne by som prerobil

* centrálny model konfigurácie
* loading/validation flow
* integráciu IP/CPU/board descriptorov
* hardcoded väzby medzi YAML a emitrom
* implicitnú clock/bus logiku
* ad hoc prácu s Quartus IP artefaktmi
* miešanie „project-level wiring“ a „IP-level definície“

Teda:

* **nie rewrite pre rewrite**
* ale **rewrite architektonického jadra**
* so zachovaním cenných artefaktov a know-how

---

# 2. Čo by som ponechal zo starého repa

Toto je dôležité. Nevyhadzoval by som všetko.

## A. ponechať ako assets

Sem patria veci, ktoré majú hodnotu bez ohľadu na architektúru:

* existujúce `.sv/.v` IP bloky
* generated Quartus IP súbory:

  * `.qip`
  * `.sdc`
  * `.v/.sv`
* fungujúce Tcl kúsky
* linker / header patterns
* existujúce board pin mapy
* fixture projekty, ktoré reprezentujú reálne use-cases

Toto sú **doménové aktíva**, nie architektonický dlh.

---

## B. ponechať ako referenčné fixtures

Staré projekty by som nepoužíval ako cieľovú architektúru, ale ako:

* regression fixtures
* golden fixtures
* porovnávacie referencie

To znamená:

* `blink_test_01`
* `blink_test_02`
* PLL projekt
* SDRAM projekt

sú veľmi cenné, ale:

* **nie ako základ nového dizajnu**
* **ale ako testy correctness**

To je veľmi dôležitý rozdiel.

---

## C. ponechať užitočné templaty, ak sú čisté

Ak niektoré templaty:

* sú malé,
* sú čitateľné,
* nie sú prepchaté business logikou,

tak ich môžeš zachovať a len ich napojiť na nové IR.

Typicky:

* jednoduché `.tcl.j2`
* niektoré `.h.j2`
* možno časť `soc_top.sv.j2`, ak sa dá očistiť

Ale len ak:

* template renderuje,
* nie rozhoduje architektúru.

---

# 3. Čo by som zahodil alebo zmrazil

Toto je podľa mňa rovnako dôležité.

## A. zahodiť ako aktívnu architektúru

Všetko, čo mieša naraz:

* parsing configu
* rozhodovanie topológie
* generovanie namingov
* emit do RTL/TCL

To je presne typ kódu, ktorý sa v starom frameworku zvykne zle rozširovať.

Ak nejaký modul:

* číta YAML
* zároveň skladá bus
* zároveň píše Tcl

tak ten by som **neprenášal**.

---

## B. zmraziť legacy buildery

Ak máš dnes buildery, ktoré:

* fungujú len pre konkrétny projekt
* používajú implicitné predpoklady
* majú hardcoded PLL/SDRAM/board názvy

tak ich:

* nevyhadzuj hneď
* ale presuň do:

  * `legacy/`
  * alebo označ ako deprecated

A ďalej na nich nestavaj nič nové.

---

## C. zahodiť implicitné conventions, ktoré sa nedajú vysvetliť

Napríklad:

* „tento port sa volá takto, lebo vždy sa volal“
* „toto IP sa správa špeciálne, lebo Quartus“
* „ak je názov obsahuje pll, urob toto“

Takéto pravidlá musia ísť preč a nahradiť ich:

* descriptor metadata
* validation
* planner rules

---

# 4. Cieľový layout repa

Toto by som považoval za cieľový layout, ku ktorému má refaktor konvergovať.

```text
socfw/
  build/
  builders/
  catalog/
  cli/
  config/
  core/
  elaborate/
  emit/
  ir/
  model/
  plugins/
  reports/
  scaffold/
  tools/
  validate/
  templates/

packs/
  builtin/
  vendor-intel/

src/
  ip/
    bus/
    irq/

docs/
  architecture/
  user/
  generated/
  dev_notes/

tests/
  unit/
  integration/
  golden/
    fixtures/
    expected/

examples/

legacy/
  old_builders/
  old_templates/
  old_scripts/
```

Kľúčové rozhodnutie:

* **legacy oddeliť fyzicky**
* nech neprekáža v mentálnom modeli nového jadra

---

# 5. Finálny architektonický rez

Ja by som finálnu architektúru repa vnímal takto:

## vrstva 1 — config contracts

* `board_schema`
* `project_schema`
* `ip_schema`
* `cpu_schema`
* `timing_schema`

## vrstva 2 — load + normalize

* YAML → model
* path normalization
* pack resolution

## vrstva 3 — validate

* consistency rules
* catalog/bridge/vendor checks

## vrstva 4 — elaborate

* board bindings
* clocks
* buses
* bridges
* address map
* IRQ plan

## vrstva 5 — IR build

* RTL IR
* Timing IR
* Files IR
* Software IR
* Docs IR

## vrstva 6 — emit

* Tcl
* RTL
* headers
* docs
* reports

## vrstva 7 — workflow

* full build
* two-pass firmware build
* cache
* provenance

To je správny moderný shape.

---

# 6. Čo by som mapoval zo starého repa do nového

Tu je praktická mapa.

## staré board definície

→ nové:

* `packs/builtin/boards/.../board.yaml`

## staré IP YAML / heuristiky

→ nové:

* `packs/.../ip/.../ip.yaml`

## staré CPU knowledge

→ nové:

* `packs/.../cpu/.../*.cpu.yaml`

## staré vendor generated IP directories

→ nové:

* `packs/vendor-intel/vendor/intel/...`

## staré project examples

→ nové:

* `tests/golden/fixtures/...`
* prípadne `examples/...`

## staré ad hoc scripts

→ nové:

* `scripts/`
* alebo CLI subcommands

---

# 7. Migračná stratégia

Tu je najdôležitejšia vec:
**nerobiť big-bang prepis celého repa naraz.**

Odporúčam 4-fázovú konvergenciu.

---

## Fáza 1 — parallel core

Cieľ:

* nový framework žije vedľa starého
* starý sa ešte dá použiť
* nový už vie spraviť stable fixtures

Prakticky:

* nechaj starý kód bežať
* nový jadro je v `socfw/`
* fixtures testujú nový flow

Túto fázu už v zásade máme navrhnutú.

---

## Fáza 2 — example parity

Cieľ:

* všetky dôležité reálne use-cases musia ísť novým frameworkom

Minimum parity:

* blink
* pll
* soc_led
* sdram
* vendor pll
* vendor sdram

Až keď toto funguje, má zmysel vypínať staré cesty.

---

## Fáza 3 — legacy freeze

Cieľ:

* starý framework už nedostáva nové feature
* len bugfixy, ak nutné
* nový framework je default

Prakticky:

* staré entrypoints označ deprecated
* docs presmeruj na nový flow
* nové fixture a nové projekty iba cez nový framework

---

## Fáza 4 — legacy removal / archival

Cieľ:

* starý kód buď:

  * presunúť do `legacy/`
  * alebo odseknúť po tagu

Toto by som robil až po niekoľkých green sprintoch, nie hneď.

---

# 8. Praktický refaktor plán po vetvách

Takto by som to rozdelil do branchov.

## branch 1

`converge/core-layout`

* zaviesť finálny package layout
* presunúť nové jadro na stabilné miesto

## branch 2

`converge/packs-and-catalogs`

* board/ip/cpu packy
* built-in pack
* vendor pack skeleton

## branch 3

`converge/vendor-fixtures`

* PLL + SDRAM fixtures
* golden tests
* files/tcl stabilization

## branch 4

`converge/default-cli`

* `socfw` ako hlavný entrypoint
* `init`
* `build`
* `build-fw`
* `sim-smoke`
* `schema/docs export`

## branch 5

`converge/legacy-freeze`

* staré entrypointy deprecated
* docs switch
* cleanup warnings

To je realistické a reviewovateľné.

---

# 9. Čo migrovať ako prvé

Ak by som to robil v reálnom repozitári, poradie by bolo:

## 1. board + packs

Pretože board shared model je centrálny pre všetky projekty.

## 2. stable fixtures

* blink
* pll
* soc_led

## 3. vendor IP fixtures

* vendor pll
* sdram

## 4. CPU + firmware path

* picorv32

## 5. bridges

* axi / wishbone

Toto poradie znižuje riziko.

---

# 10. Čo nerobiť počas konvergencie

Niekoľko vecí by som počas refaktoru vedome nerobil:

## A. nepridávať ďalšie veľké features

Keď beží convergence, neotváraj ďalšie veľké smery naraz.

## B. nemenit naming conventions každý týždeň

Stabilita je teraz cennejšia než perfektný názov.

## C. nerobiť hneď 100% generic abstraction všade

Ak niečo funguje dobre pre 2-3 protokoly, stačí.
Nepreabstrahuj.

## D. nepresúvať fixtures bez testov

Najprv test, potom move.

---

# 11. Definition of done pre convergence

Povedal by som, že konvergencia je hotová, keď:

* nový `socfw` flow pokryje všetky dôležité use-cases
* packy sú primary source pre board/IP/CPU
* vendor generated IP ide cez pack model
* stable + vendor golden testy sú green
* starý framework už nie je potrebný pre nové projekty
* `socfw init` založí nový projekt bez ručného kopírovania
* docs ukazujú už len nový flow

To je podľa mňa reálny cieľový stav.

---

# 12. Čo by som ponechal ako “legacy island”

Niečo by som nechal ako ostrov kompatibility, niekedy aj dlhodobo:

* staré skripty na jednorazové importy
* utility pre conversion / vendor helpery
* prípadne starý build wrapper, ak ho používa CI inde

Ale iba ak:

* sú jasne označené
* nie sú súčasťou nového jadra

To je zdravý kompromis.

---

# 13. Môj odporúčaný praktický checkpoint

Keď sa dostaneš do stavu:

* stable fixtures green
* vendor pll green
* sdram green
* packs fungujú
* new CLI funguje

spravil by som checkpoint:

```text
milestone/m2-converged-new-core
```

alebo tag:

```text
v0.2.0-converged
```

To by bol veľmi dobrý interný míľnik.

---

# 14. Môj úprimný záver: čo ponechať a čo vylepšiť

Ak to zhrniem úplne priamo:

## ponechať

* existujúce doménové aktíva
* fungujúce RTL/vendor IP artefakty
* reálne fixture projekty ako referencie
* to, čo už preukázateľne funguje ako assets

## vylepšiť / prerobiť

* celý orchestration core
* config contracts
* validation
* elaboration
* IR
* packs/catalogs
* diagnostics
* build flow
* bridge selection
* vendor normalization

Teda:
**ponechať obsah, prerobiť architektúru.**

A podľa mňa je to presne správne rozhodnutie pre tvoj prípad.

---

# 15. Čo by som spravil úplne ako ďalší reálny krok

Keby sme už neostali pri návrhu, ale išli robiť real repo refaktor, ja by som začal touto jednou vetou:

👉 **najprv preklopiť shared board + blink + pll do pack-aware stable green flow**

To je najlepší prvý praktický refaktor checkpoint.

Ak chceš, ďalšia správa môže byť už úplne exekučná:

**konkrétny “first real convergence sprint” po dňoch a commitoch pre existujúci repozitár**.
