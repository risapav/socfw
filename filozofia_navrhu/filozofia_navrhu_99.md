Pokračoval by som teraz už nie ďalšími scaffold commitmi, ale **upevnením kontraktov**, lebo podľa chýb s `timing.file` a `timing:` je vidno, že najväčší problém bude drift medzi návrhom, schémou a príkladmi.

## Najbližšie vylepšenia socfw

### 1. Zafixovať verejný YAML kontrakt

Najprv by som určil jeden oficiálny formát a ten držal všade.

Odporúčam:

```yaml
timing:
  file: timing_config.yaml
```

v `project.yaml`.

A v `timing_config.yaml`:

```yaml
version: 2
kind: timing

timing:
  clocks: []
  generated_clocks: []
  io_delays: {}
  false_paths: []
```

Potom by som pridal spätnú kompatibilitu, aby loader akceptoval aj starší tvar:

```yaml
clocks: []
io_delays: {}
false_paths: []
```

ale s warningom:

```text
TIM001: timing file uses legacy top-level timing keys; wrap them under timing:
```

---

### 2. Pridať `socfw explain-schema`

Veľmi by pomohlo CLI:

```bash
socfw explain-schema project
socfw explain-schema timing
socfw explain-schema ip
socfw explain-schema board
```

Výstup:

```text
project.yaml:
  timing.file: path to timing YAML, relative to project.yaml
  registries.packs: list of pack roots
  registries.ip: list of IP descriptor search paths
```

Toto by okamžite odstránilo nejasnosti typu `config` vs `file`.

---

### 3. Pridať `socfw doctor`

Príkaz:

```bash
socfw doctor project.yaml
```

by spravil viac než validate:

* ukázal resolved paths
* ukázal board file
* ukázal timing file
* ukázal nájdené IP descriptors
* ukázal chýbajúce alebo ignorované súbory
* odporučil opravy

Príklad:

```text
Project: blink_test_01
Board: qmtech_ep4ce55
Board file: ../../../config/board_qmtech_ep4ce55.yaml
Timing file: timing_config.yaml
IP search paths:
  - ../../../src/ip

Warnings:
  - timing.file exists and loaded
  - 1 module uses type blink_test
```

---

### 4. Zaviesť normalizačnú vrstvu

Namiesto toho, aby každý loader rovno vyrábal model, by som zaviedol:

```text
raw YAML
  ↓
schema parse
  ↓
compat normalization
  ↓
canonical document
  ↓
model
```

Teda súbory:

```text
socfw/config/normalizers/project.py
socfw/config/normalizers/timing.py
socfw/config/normalizers/ip.py
socfw/config/normalizers/board.py
```

Výhoda:

* všetky legacy aliasy sú na jednom mieste
* schema zostáva čistá
* chyby sú lepšie

---

### 5. Zaviesť aliasy s jasnou politikou

Napríklad pre `project.yaml`:

```yaml
timing:
  file: timing_config.yaml
```

je canonical.

Ale loader môže akceptovať:

```yaml
timing:
  config: timing_config.yaml
```

ako alias.

S warningom:

```text
PRJ_ALIAS001: timing.config is deprecated; use timing.file
```

To je praktické, lebo počas vývoja sa ľahko stane, že návrh a implementácia sa rozídu.

---

### 6. Pridať `socfw fmt`

Príkaz:

```bash
socfw fmt project.yaml
```

by prepísal config do canonical tvaru:

* `timing.config` → `timing.file`
* top-level `clocks` v timing configu → `timing.clocks`
* dict-style modules → list-style modules
* zoradené sekcie

Toto by bolo veľmi užitočné pri migrácii projektov.

---

### 7. Zlepšiť chyby z Pydanticu

Teraz chyba vyzerá ako:

```text
Field required [type=missing...]
```

To je technicky správne, ale používateľsky slabé.

Nad tým by som spravil human layer:

```text
ERROR TIM100
timing_config.yaml is not in the expected v2 timing format.

Expected:
  version: 2
  kind: timing
  timing:
    clocks: []
    io_delays: {}
    false_paths: []

Found top-level keys:
  clocks, io_delays, false_paths

Fix:
  Move these keys under `timing:`.
```

Toto je extrémne hodnotné.

---

### 8. Rozšíriť `socfw init` o validné templates

Pridať:

```bash
socfw init blink_test_01 --template blink
socfw init pll_test --template pll
socfw init sdram_test --template sdram
```

A všetky templaty musia byť testované cez:

```bash
socfw init ...
socfw validate ...
socfw build ...
```

Tým bude dokumentácia vždy sedieť s implementáciou.

---

### 9. Zjednotiť názvoslovie

Navrhujem tieto canonical názvy:

```yaml
project:
  board: qmtech_ep4ce55
  board_file: optional/path.yaml

timing:
  file: timing_config.yaml

registries:
  packs: []
  ip: []
  cpu: []

modules:
  - instance: name
    type: ip_type
```

Nepoužíval by som už:

* `paths.ip_plugins`
* `board.type`
* `timing.config`
* dict-style `modules: blink_test:`

Tie môžu byť len compatibility aliasy.

---

### 10. Pridať `schema_version` do reportu

Do `build_summary.md` by som doplnil:

```text
Project schema: v2 canonical
Timing schema: v2 canonical
Compatibility aliases used: none
```

Ak sa použil starý alias:

```text
Compatibility aliases used:
- project.timing.config → project.timing.file
- timing top-level clocks → timing.timing.clocks
```

To veľmi pomôže pri čistení projektov.

---

## Roadmap najbližších commitov

### Commit 36

```text
config: add canonical schema docs and compatibility aliases
```

### Commit 37

```text
diagnostics: improve project and timing schema error messages
```

### Commit 38

```text
cli: add socfw doctor for resolved config inspection
```

### Commit 39

```text
cli: add socfw explain-schema command
```

### Commit 40

```text
config: add normalization layer and alias reporting
```

### Commit 41

```text
scaffold: add tested blink/pll/sdram templates
```

Najbližšie by som začal **Commitom 36**, lebo opraví presne ten problém, na ktorý si teraz narazil: nejasný YAML kontrakt.
