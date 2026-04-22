Áno. Tu je **hard cutover plan**:

# ako prepnúť repozitár na nový flow, zmraziť legacy, a migrovať reálne projekty bez výpadku

Toto je už posledný veľký organizačno-technický krok.
Nie je to o ďalšej architektúre, ale o bezpečnom prechode:

* z legacy flow
* na nový `socfw` flow
* bez toho, aby si rozbil existujúce projekty alebo tímový workflow.

Najdôležitejší princíp:

## **cutover nesmie byť big-bang**

Má byť:

* merateľný,
* reverzibilný,
* po etapách,
* s jasným “default path” a “fallback path”.

---

# 1. Cieľ cutoveru

Na konci má platiť:

* nový `socfw` flow je **default**
* legacy flow je **freeze-only**
* všetky aktívne projekty majú:

  * migračný status
  * ownera
  * plán prechodu
* stable CI ide cez nový flow
* nové projekty sa zakladajú iba cez:

  * `socfw init`
  * alebo nový pack-aware layout

To je reálny cieľ.

---

# 2. Čo znamená “hard cutover”

Pre mňa to znamená 5 konkrétnych vecí:

## A. nový entrypoint je oficiálny

Používateľ má používať:

* `socfw validate`
* `socfw build`
* `socfw build-fw`
* `socfw sim-smoke`

nie staré skripty.

## B. legacy flow nedostáva nové feature

Už len:

* kritické bugfixy
* alebo compatibility shim

## C. dokumentácia smeruje len na nový flow

Staré veci sú:

* označené legacy
* nie sú v quickstart
* nie sú v onboarding docs

## D. CI hodnotí nový flow ako source of truth

Legacy môže mať len prechodný smoke lane.

## E. projekty dostanú migračné fázy

Nie všetko naraz.

---

# 3. Projektová klasifikácia pred cutoverom

Pred samotným cutoverom by som všetky existujúce projekty rozdelil do 3 skupín.

## skupina 1 — už migrovateľné teraz

Typicky:

* blink
* pll
* jednoduché standalone
* jednoduchý SoC bez exotických vendor závislostí

Tieto sa majú prepnúť ako prvé.

---

## skupina 2 — migrovateľné s kontrolovaným sprintom

Typicky:

* vendor PLL
* SDRAM projekty
* jednoduché bridged periférie

Tieto prepnúť hneď po overených fixtures.

---

## skupina 3 — dočasne legacy-only

Typicky:

* zložité workspace väzby
* veľmi project-specific hacky
* custom tool invocation
* nezdokumentované vendor exotiky

Tieto:

* nezastavovať
* ale označiť ako “legacy island”
* s termínom refaktoru

Toto je veľmi dôležité, aby si si nespravil z cutoveru nekonečnú bitku.

---

# 4. Cutover governance tabuľka

Odporúčam si spraviť reálnu tabuľku, napr. `docs/dev_notes/cutover_status.md`.

# Cutover status

| Project          | Current flow | Target flow | Status      | Owner | Notes                      |
| ---------------- | ------------ | ----------- | ----------- | ----- | -------------------------- |
| blink_test_01    | legacy       | socfw       | done        | ...   | stable                     |
| blink_test_02    | legacy       | socfw       | done        | ...   | pll stable                 |
| vendor_pll_soc   | legacy       | socfw       | done        | ...   | qip export verified        |
| vendor_sdram_soc | legacy       | socfw       | in progress | ...   | top wiring + qip/sdc green |
| real_app_X       | legacy       | socfw       | not started | ...   | needs vendor cleanup       |

Toto znie banálne, ale je to extrémne dôležité.

---

# 5. Cutover strategy po fázach

Odporúčam 4 fázy.

---

## Fáza 1 — dual-run

### cieľ

Nový aj starý flow existujú paralelne.

### pravidlá

* nový flow buildí stable fixtures
* legacy flow ešte zostáva pre staré projekty
* CI má:

  * nový stable lane
  * starý compatibility lane

### exit criteria

* stable fixtures green v novom flow
* vendor PLL green
* vendor SDRAM green

Toto je v zásade stav, ku ktorému sa blížime.

---

## Fáza 2 — default switch

### cieľ

Nový flow sa stane oficiálnym.

### pravidlá

* README, docs, onboarding ukazujú len nový flow
* `socfw init` je odporúčaný štart
* nové projekty sa už nesmú zakladať legacy spôsobom
* starý flow je explicitne legacy

### exit criteria

* aspoň 80 % aktívnych use-caseov má nový ekvivalent
* tím vie používať nový CLI bez workaroundov

---

## Fáza 3 — legacy freeze

### cieľ

Legacy už nevyvíjaš.

### pravidlá

* žiadne nové feature v legacy
* len critical fixes
* staré entrypointy emitujú warning:

  * “deprecated, use socfw ...”

### exit criteria

* všetky aktívne projekty sú:

  * migrované,
  * alebo v schválenom legacy exception zozname

---

## Fáza 4 — archival / removal

### cieľ

Legacy už nie je živé jadro.

### možnosti

* presun do `legacy/`
* alebo tag + odstránenie z main branch
* alebo samostatná archival branch

Môj praktický názor:

* najprv **presun do `legacy/`**
* úplné zmazanie až neskôr

---

# 6. Čo presne spraviť v repozitári

Tu je konkrétny technický plán.

---

## Krok 1 — nový CLI ako default

### spraviť

* `socfw` je hlavný entrypoint
* všetky docs, scripts, CI používajú `socfw ...`

### nezrušiť hneď

* staré skripty nech ešte ostanú, ale mimo quickstart

---

## Krok 2 — legacy entrypoint warnings

Ak existujú staré skripty/CLI, doplň warning:

```python
print("WARNING: legacy build flow is deprecated; use `socfw build ...`")
```

To je jednoduché a účinné.

---

## Krok 3 — docs switch

V `README.md`, `getting_started.md`, `cli.md`:

* nový flow ako jediný odporúčaný
* legacy len v sekcii:

  * “legacy compatibility”

---

## Krok 4 — examples switch

`examples/` nech sú už len:

* pack-aware
* nové fixtures/scaffolds

Staré project directories:

* buď presun do `tests/golden/fixtures`
* alebo `legacy/examples`

---

## Krok 5 — CI switch

CI required jobs majú overovať:

* nový flow
* stable fixtures
* golden tests

Legacy môže zostať iba v:

* nightly
* manual compatibility workflow

---

# 7. Ako zmraziť legacy bezpečne

Neodporúčam legacy hneď zmazať. Lepší model:

## `legacy/`

Presuň tam:

* staré build orchestration skripty
* staré buildery, ktoré už nechceš rozvíjať
* staré templaty, ak sa nepoužívajú

A pridaj `legacy/README.md`:

# legacy/

This directory contains deprecated build flow components kept temporarily for compatibility and migration fallback.

Rules:

* no new features
* critical fixes only
* all new work must target `socfw/`

To je veľmi zdravý krok.

---

# 8. Migration policy pre reálne projekty

Toto je veľmi dôležité. Každý projekt by mal mať jeden z týchto statusov:

## `migrated`

Projekt ide iba novým flow.

## `dual`

Projekt vie buildnúť starý aj nový flow.

## `legacy-exception`

Projekt zostáva dočasne na legacy, lebo:

* chýba feature
* chýba vendor pack
* chýba refaktor owner

To ti zabráni mať nejasný medzistav.

---

# 9. Odporúčaný migračný order pre reálne projekty

Prakticky by som šiel takto:

## vlna 1

* shared board
* blink projekty
* pll-only projekty

## vlna 2

* vendor pll projekty
* jednoduché SoC demo projekty
* projekty bez veľmi špeciálnych externých IP

## vlna 3

* SDRAM projekty
* firmware-heavy projekty
* bridge-dependent projekty

## vlna 4

* exotické/custom interné projekty
* tie, čo majú veľa historických workaroundov

To je veľmi rozumné poradie.

---

# 10. Hard gate pre nové projekty

Od momentu default switchu by som zaviedol jednoduché pravidlo:

## nové projekty

* musia vzniknúť cez:

  * `socfw init`
  * alebo podľa nového pack-aware example

## nesmie sa

* kopírovať starý projekt skeleton
* pridávať nové board definície len projekt-lokálne bez pack stratégie
* pridávať nové vendor IP bez descriptoru

Toto je dôležité, inak sa legacy mindset vráti hneď späť.

---

# 11. Compatibility shimy, ktoré sa oplatí mať

Počas cutoveru by som si nechal 2-3 malé shim vrstvy.

## A. board_file fallback

Ak projekt ešte používa explicitný `board_file`, nový flow ho stále vezme.

## B. explicit registries.ip fallback

Aj keď nový model preferuje `packs`, explicitné `registries.ip` nech ešte funguje.

## C. legacy script wrapper

Napr. starý script môže interne zavolať nový build a len vytlačiť warning.

To výrazne znižuje riziko výpadku.

---

# 12. Čo musí byť hotové pred default switch

Predtým než povieš “nový flow je default”, mali by byť hotové tieto veci:

* stable board pack
* stable blink fixtures
* stable PLL vendor fixture
* stable SDRAM vendor fixture aspoň na build-level
* docs quickstart
* CI stable lane
* `socfw init`
* diagnostics a explain rozumne čitateľné

Ak toto nie je hotové, default switch je predčasný.

---

# 13. Čo by som dal do CI počas cutoveru

Odporúčam 3 lane model.

## lane 1 — required

* unit
* stable integration
* stable golden
* len nový flow

## lane 2 — compatibility

* legacy smoke
* len manual/nightly

## lane 3 — extended

* firmware
* sim
* vendor-heavy testy
* manual/nightly

Takto sa nový flow stane source of truth bez toho, aby si stratil fallback.

---

# 14. Hard cutover milestone checklist

Toto by som dal ako oficiálny checklist.

# Hard cutover checklist

## New flow readiness

* [ ] `socfw` CLI is the documented default
* [ ] `socfw init` scaffolds new projects
* [ ] pack-aware board resolution is stable
* [ ] vendor PLL fixture is green
* [ ] vendor SDRAM fixture is green
* [ ] stable golden tests are green
* [ ] CI required lane uses new flow

## Legacy freeze readiness

* [ ] legacy scripts emit deprecation warnings
* [ ] no new features are added to legacy path
* [ ] active projects have migration status assigned
* [ ] exceptions are documented

## Default switch

* [ ] README updated
* [ ] onboarding docs updated
* [ ] examples updated
* [ ] project owners notified

---

# 15. Reálny commit plán pre cutover

Odporúčam 8 commitov.

## Commit 1

`cutover: make socfw cli the default documented entrypoint`

## Commit 2

`cutover: add deprecation warnings to legacy build scripts`

## Commit 3

`cutover: move legacy-only assets into legacy/ and document freeze policy`

## Commit 4

`cutover: switch examples and quickstart to pack-aware socfw flow`

## Commit 5

`ci: make new flow the required lane and move legacy to compatibility lane`

## Commit 6

`migration: add project cutover status tracking and owner mapping`

## Commit 7

`cutover: enable new-flow-only policy for freshly scaffolded projects`

## Commit 8

`checkpoint: mark hard cutover default-switch milestone`

---

# 16. Odporúčaný checkpoint/tag

Keď bude hotové:

* nový flow default
* legacy freeze
* stable CI green

spravil by som tag:

```text
v1.0.0-cutover
```

alebo branch:

```text
milestone/m4-hard-cutover
```

To je podľa mňa veľmi legitímny moment.

---

# 17. Čo by som po cutovere už nerobil

Po cutovere by som:

* už nerozširoval legacy
* nerobil nové “temporary” shortcuts
* nedovolil nové projekty na starom skeleton-e

Toto je kritické.
Inak sa repozitár znova rozdelí na dva svety.

---

# 18. Môj úprimný odporúčaný praktický postup

Ak by som to robil ja, tak po všetkom, čo sme navrhli, by som išiel takto:

## najbližšie 3 reálne kroky

1. **shared board + blink + pll converged green**
2. **vendor sdram converged green**
3. **default switch + legacy freeze**

To je najkratšia cesta k reálnemu úspešnému cutoveru.

---

# 19. Úplne stručný záver

Ak to zhrniem do jednej vety:

## správny cutover je:

**obsah zachovať, jadro vymeniť, legacy zmraziť, nový flow spraviť defaultom až po parity na kľúčových use-cases**

A podľa mňa to je presne správna stratégia pre tvoj repozitár.

---

Ak chceš, ďalšia správa môže byť už úplne finálna a exekučná:

**master checklist “od dnešného stavu po v1.0.0-cutover” v jednom súbore na odškrtávanie**.
