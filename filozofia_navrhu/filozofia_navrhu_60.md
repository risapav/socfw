Áno. Na základe aktuálneho repa v `/mnt/data` by som **Phase 1 — Core Convergence** rozbil takto: nie všeobecne, ale **priamo na tvoje existujúce súbory, s cieľovým diff smerom**.

Najprv stručný verdikt k tomu, čo v repo teraz reálne je:

* máš **monolitický generator štýl**: `base.py`, `rtl_builder.py`, `rtl.py`, `tcl.py`, `sdc.py`, `sw.py`
* configy sú ešte v **starom formáte**:

  * `project_config.yaml`
  * `board_qmtech_ep4ce55.yaml`
  * `timing_config.yaml`
  * `*.ip.yaml`
* silná hodnota repa je v:

  * fungujúcich templates
  * board definícii
  * PLL/SDRAM generated IP assets
* hlavný dlh je v tom, že:

  * loading/model/elaboration/emit nie sú oddelené
  * `rtl_builder.py` robí priveľa naraz
  * config kontrakty nie sú centrálne a typed
  * repo ešte nie je pack-aware

Teda Phase 1 tu v praxi znamená:

> **nevymieňať hneď všetko**, ale najprv vyseknúť nové jadro popri starom a dostať existujúci obsah do nového modelu.

---

# Phase 1 — Core Convergence

## konkrétne súbory a diff ciele

Rozdelím to na 8 pracovných blokov.

---

## 1. Zaviesť nový package core vedľa starého generator štýlu

### nové adresáre/súbory

V repo by som najprv založil:

```text
socfw/
  __init__.py
  cli/
    main.py
  core/
    diagnostics.py
    result.py
  config/
    common.py
    board_schema.py
    project_schema.py
    ip_schema.py
    timing_schema.py
    board_loader.py
    project_loader.py
    ip_loader.py
    timing_loader.py
    system_loader.py
  model/
    board.py
    project.py
    ip.py
    system.py
  validate/
    rules/
      base.py
  elaborate/
    design.py
    planner.py
  build/
    context.py
    pipeline.py
    full_pipeline.py
  emit/
    renderer.py
```

### prečo

Toto je prvý tvrdý rez:

* staré súbory nechaj zatiaľ žiť
* ale nový flow už nebuduj v `rtl_builder.py`

### čo zatiaľ **nemeníš**

* `rtl_builder.py`
* `rtl.py`
* `tcl.py`
* `sdc.py`
* `sw.py`

Tie zatiaľ ostanú ako legacy reference.

---

## 2. Z `base.py` vytiahnuť len renderer a prestať z neho robiť “core”

### aktuálny stav

`base.py` je v zásade použiteľný ako malý renderer wrapper.

### čo by som spravil

Nechal by som jeho logiku, ale presunul ju do nového súboru:

### nový súbor

`socfw/emit/renderer.py`

### diff cieľ

Zo `base.py` zober:

* `_make_env`
* `render`
* `write`

a uprav do tvaru triedy alebo malého utility modulu.

### výsledok

`base.py` ostane dočasne legacy, ale nový flow už bude používať:

```python
from socfw.emit.renderer import Renderer
```

### čo môže vyzerať ako výsledok

* `Renderer.render(template_name, **ctx)`
* `Renderer.write_text(path, content)`

Toto je prvý čistý kus, ktorý sa dá vziať skoro bez rizika.

---

## 3. Zaviesť typed config schemy z existujúcich YAML

Tu je najväčšia hodnota v tom, že už máš reálne vstupy, podľa ktorých sa to dá namapovať.

### vstupné súbory v starom stave

* `project_config.yaml`
* `board_qmtech_ep4ce55.yaml`
* `clkpll.ip.yaml`
* `sdram_fifo.ip.yaml`
* `timing_config.yaml`

### nové súbory

* `socfw/config/project_schema.py`
* `socfw/config/board_schema.py`
* `socfw/config/ip_schema.py`
* `socfw/config/timing_schema.py`

### dôležité

Tu ešte nemusíš hneď preklopiť všetko na finálny v2 model, ale sprav minimálne:

* nový schema model vie parse-núť cieľový nový formát
* popri tom môžeš mať krátkodobý compatibility adapter pre starý formát

### konkrétne odporúčanie podľa tvojho repa

#### `board_qmtech_ep4ce55.yaml`

Toto je veľmi cenný asset.
Je bohaté a dobre štruktúrované.
Toto by som **nezahadzoval**, ale transformoval do nového board modelu.

#### Diff cieľ

Z tejto existujúcej definície spraviť nový loader/model, ktorý vie:

* `system.clock`
* `system.reset`
* `onboard.*`
* `external.sdram`
* `inout/vector/scalar`

To je presne základ nového `BoardModel`.

---

## 4. Zaviesť nový loader layer a oddeliť ho od emit logiky

### nové súbory

* `socfw/config/common.py`
* `socfw/config/board_loader.py`
* `socfw/config/project_loader.py`
* `socfw/config/ip_loader.py`
* `socfw/config/timing_loader.py`
* `socfw/config/system_loader.py`

### čo má byť výsledok

Niečo ako:

```python
system = SystemLoader().load(project_file)
```

a výsledkom už nie je hneď generator context, ale normalizovaný model.

### čo mapovať z existujúcich súborov

#### `project_config.yaml`

Dnes má starý shape:

* `design`
* `plugins.ip`
* `board.type`
* `board.file`
* `modules`

To by som v Phase 1 urobil takto:

### krátkodobý compatibility diff

`project_loader.py` nech vie:

* načítať **legacy project_config.yaml**
* premapovať ho na nový `ProjectModel`

Teda v Phase 1 nemusíš hneď prepísať všetky fixture YAML.
Najprv sprav loader adapter.

To je veľmi dôležité pre bezpečný convergence.

---

## 5. Vytvoriť nový model layer namiesto implicitných modelov v builderoch

### nové súbory

* `socfw/model/board.py`
* `socfw/model/project.py`
* `socfw/model/ip.py`
* `socfw/model/timing.py`
* `socfw/model/system.py`

### prečo

Teraz máš implicitný model schovaný v:

* `models`
* builderoch
* generátoroch

Ale podľa toho, čo vidno v `rtl_builder.py`, väzba je príliš silná:

* builder predpokladá konkrétne typy a konvencie
* IR validácia je užitočná, ale je neskoro v pipeline

### čo by som zachoval z `rtl_builder.py`

Nie architektúru, ale:

* niektoré naming conventions
* validáciu typu:

  * duplicate wires
  * duplicate instances
  * unknown signal references

### čo by som spravil

Túto časť by som **nevykopol**, ale postupne presunul:

* časť do `validate/`
* časť do nového `RtlIRBuilder`

---

## 6. Zaviesť nový build context a result

### nové súbory

* `socfw/build/context.py`
* `socfw/core/result.py`
* `socfw/core/diagnostics.py`
* `socfw/build/pipeline.py`
* `socfw/build/full_pipeline.py`

### prečo

Momentálne staré generátory zjavne:

* zapisujú rovno na disk
* printujú počas generácie
* nemajú jednotný orchestration contract

Je to vidno aj v `sw.py`, kde napr.:

* generuje a rovno zapisuje
* pritom vypisuje `print(" -> soc_map.h")`

To je presne vec, ktorú treba v Phase 1 zmeniť.

### diff cieľ pre `sw.py`, `tcl.py`, `rtl.py`, `sdc.py`

Nie prepis hneď.
Najprv ich prestaň volať priamo z legacy flow a postupne ich obal do nového orchestration layer.

---

## 7. Zaviesť prvý nový CLI bez rozbitia starého sveta

### nové súbory

* `socfw/cli/main.py`
* `pyproject.toml` entrypoint

### Phase 1 cieľ

Mať aspoň:

```bash
socfw validate <project>
socfw build <project> --out build/gen
```

### dôležité

V Phase 1 ešte nemusí build robiť všetko nové.
Stačí, že nový CLI:

* zavolá nový loader
* nový validate
* a dočasne môže použiť legacy emitter wrappers

To je úplne v poriadku.

---

## 8. Zachytiť legacy ako fallback, nie ako jadro

### čo spraviť hneď v repo

Založ si:

```text
legacy/
  README.md
```

a zatiaľ tam nemusíš nič presúvať.

Ale do `README.md` daj pravidlo:

* nový vývoj ide do `socfw/`
* staré súbory sú compatibility layer

Toto je veľmi dôležitý mentálny rez.

---

# Konkrétne diffy podľa existujúcich súborov

Teraz úplne priamo: čo spraviť s konkrétnymi súbormi, ktoré v repo už máš.

---

## `base.py`

### ponechať:

* Jinja env setup
* `sv_param` filter idea

### zmeniť:

* presunúť do `socfw/emit/renderer.py`
* `write()` nech už nie je “ASCII transliteration magical sink”, ale explicitný utility krok

### odporúčanie

V novom flow by som už nepoužíval tiché zahadzovanie non-ASCII cez:

```python
content.encode("ascii", errors="ignore")
```

To je skôr legacy kompatibilita než dobrý default.

---

## `rtl_builder.py`

### ponechať:

* IR validation nápady
* naming conventions
* adapter wire dedup idea

### neponechať ako architektúru:

* to, že builder skladá top, wires, instances, reset syncs, port adaption naraz
* priamu väzbu na staré `models.*`

### Phase 1 diff cieľ

Neprepisovať ho celý hneď.
Spraviť nový:

* `socfw/ir/rtl.py`
* `socfw/builders/rtl_ir_builder.py`

a `rtl_builder.py` nechať zatiaľ ako referenciu.

---

## `rtl.py`

### ponechať:

* ak obsahuje renderer/emitter logiku, môže poslúžiť ako referencia pre nový `RtlEmitter`

### Phase 1 diff cieľ

Neviazať nový flow priamo naň.

---

## `tcl.py`

### ponechať:

* logiku okolo board/file exports ako referenciu

### Phase 1 diff cieľ

Rozdeliť na:

* board emitter
* files emitter

Lebo do budúcna:

* `board.tcl`
* `files.tcl`
  nemajú byť jeden mixed generator blob.

---

## `sdc.py`

### ponechať:

* know-how okolo generated clocks
* reset false path patterns
* IO delay policy

### Phase 1 diff cieľ

Neviazať timing model priamo na generator internals.
Najprv zaviesť nový `TimingModel`, až potom timing emitter.

---

## `sw.py`

### ponechať:

* štruktúru výstupov:

  * `soc_map.h`
  * `soc_irq.h`
  * `sections.lds`
  * `soc_map.md`

### zmeniť:

* oddeliť build od write
* žiadne `print()`
* dáta majú prísť z `SoftwareIR`, nie priamo zo starého `SoCModel`

### toto je veľmi dobrý kandidát na skorý refaktor

Zo všetkých starých generatorov je `sw.py` podľa mňa jeden z ľahších na preklopenie do nového IR-based flow.

---

## `project_config.yaml`

### ponechať:

* ako legacy fixture
* ako zdroj mapovania na nový model

### neprenášať 1:1

Tento shape by som nepovažoval za cieľový.

### Phase 1 stratégia

Sprav:

* nový `project_schema.py` pre cieľový formát
* plus compatibility loader pre starý `project_config.yaml`

To ti umožní convergence bez hromadného editovania všetkých existujúcich projektov hneď na začiatku.

---

## `board_qmtech_ep4ce55.yaml`

### ponechať:

* takmer celý obsah
* je to silný asset

### zmeniť:

* presunúť ho do built-in packu
* nový loader/model nech z neho robí nový `BoardModel`

### veľmi dôležité

Toto je jeden z prvých súborov, ktoré by som naozaj preklopil do pack-aware flow ako “source of truth”.

---

## `clkpll.ip.yaml`

### ponechať:

* ako referenciu, ako vyzerá starý generated IP contract

### nepreniesť 1:1

Tento formát je ešte príliš starý/implicitný:

* `type: standalone`
* `files: [...]`
* `interfaces: ...`

### nový cieľ

Z neho sprav nový vendor-aware descriptor v packu:

* `origin.kind: generated`
* `vendor.qip`
* `clocking.outputs`

---

## `sdram_fifo.ip.yaml`

### ponechať:

* ako referenciu pre vendor/generator use-case

### problém

Je tam dokonca zrejme duplicita header/content a mix starého štýlu.

### Phase 1 cieľ

Neriešiť ho ešte ako plne converged asset.
Len ho evidovať ako:

* vendor migration candidate

---

## `timing_config.yaml`

### ponechať:

* ako veľmi užitočný input asset

### zmeniť:

* nový typed `TimingDocumentSchema`
* nový loader
* nový `TimingModel`

Toto je podľa mňa ďalší veľmi vhodný Phase 1 kandidát, lebo je pomerne samostatný a cenný.

---

# Odporúčaný commit plán pre Phase 1 v tomto konkrétnom repo

Tu je môj praktický návrh.

---

## Commit 1

`core: add socfw package skeleton and renderer`

### súbory

* `socfw/...` package skeleton
* `socfw/emit/renderer.py`
* `pyproject.toml`

---

## Commit 2

`config: add typed schemas and common yaml loading`

### súbory

* `socfw/config/common.py`
* `board_schema.py`
* `project_schema.py`
* `ip_schema.py`
* `timing_schema.py`

---

## Commit 3

`model: add normalized board project ip timing and system models`

### súbory

* `socfw/model/*.py`

---

## Commit 4

`loader: add board/project/ip/timing/system loaders with legacy compatibility`

### súbory

* `socfw/config/*loader.py`

### poznámka

Tu je kľúčové:

* nový loader vie načítať **aj staré** `project_config.yaml` / `board_qmtech_ep4ce55.yaml`

---

## Commit 5

`validate: add diagnostics/result and first validation pipeline`

### súbory

* `socfw/core/result.py`
* `socfw/core/diagnostics.py`
* `socfw/validate/rules/base.py`
* prvé validation rules

---

## Commit 6

`build: add build context pipeline and minimal cli`

### súbory

* `socfw/build/context.py`
* `socfw/build/pipeline.py`
* `socfw/build/full_pipeline.py`
* `socfw/cli/main.py`

---

## Commit 7

`catalog: add builtin board pack and board resolution`

### súbory

* `packs/builtin/...`
* `catalog/indexer.py`
* `board_resolver.py`

---

## Commit 8

`test: migrate blink project to new loading path and add integration coverage`

### cieľ

Prvý green Phase 1 checkpoint.

---

# Čo je Definition of Done pre Phase 1 v tvojom reálnom repo

Podľa toho, čo teraz v repo máš, povedal by som:

Phase 1 je hotová, keď:

* existuje nový `socfw/` package
* nový loader vie načítať:

  * `project_config.yaml`
  * `board_qmtech_ep4ce55.yaml`
  * `clkpll.ip.yaml`
  * `timing_config.yaml`
* nový CLI vie:

  * validate
  * build aspoň stable blink flow
* board ide z built-in packu
* starý generator flow ešte nepadol, ale už nie je source of truth pre nový vývoj

To je realistické a správne.

---

# Môj praktický záver

Ak to poviem úplne priamo pre tento konkrétny repo stav:

## ako prvé by som reálne prekopol

1. `base.py` → nový renderer
2. `board_qmtech_ep4ce55.yaml` → built-in pack
3. `project_config.yaml` loader compatibility
4. `timing_config.yaml` typed loader
5. nový `socfw build` pre blink fixture

Až potom by som riešil:

* plné nahradenie `rtl_builder.py`
* vendor PLL pack
* SDRAM convergence

To je najnižšie riziko a najlepší pomer progresu.

Ak chceš, ďalší krok spravím ešte konkrétnejšie: dám ti **Phase 1 ako patch plan po presných nových súboroch a minimálnych editáciách existujúcich súborov**, teda už skoro ako implementačný TODO list.
