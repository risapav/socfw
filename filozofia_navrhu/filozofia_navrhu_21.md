Dobre. Tu je môj návrh na **prvý minimálny end-to-end branch**, aby sa z architektúry stal živý framework.

## Cieľ branchu `bootstrap/minimal-e2e`

Branch má vedieť:

* načítať `board + project + timing + ip`
* validovať config
* vyrobiť:

  * `rtl/soc_top.sv`
  * `timing/soc_top.sdc`
  * `hal/board.tcl`
  * `files.tcl`
  * `reports/build_report.json`
  * `reports/build_report.md`
  * `reports/soc_graph.dot`
* prejsť aspoň na:

  * `blink_test_01`
  * `blink_test_02`
* bez plného SoC CPU/RAM flow v prvej iterácii

To je najlepší prvý rez, lebo je malý, ale už overí celý nový lifecycle. Súčasný framework už má pre tieto artefakty dobré referencie v RTL, SDC, TCL a graph/doc výstupoch.    

## Scope prvej iterácie

Do prvej iterácie by som **nedával**:

* CPU model
* RAM slave
* boot image
* IRQ combiner
* register block generovanie
* bridge pluginy

To všetko už máme navrhnuté, ale na oživenie branchu je lepšie ísť po vrstvách.

## Scope, ktorý by som dal hneď

### 1. Konfig a model

* `board_loader`
* `project_loader`
* `timing_loader`
* `ip_loader`
* `system_loader`

### 2. Validácia

* unknown board refs
* unknown IP type
* unknown generated clock source
* vendor artifact exists
* duplicate module names

### 3. Elaboration

* board bindings
* generated clocks
* dependency assets
* simple bus planner len ak bude treba pre `blink_test_02`

### 4. IR

* `BoardIR`
* `TimingIR`
* `RtlModuleIR`

### 5. Emit

* `soc_top.sv`
* `soc_top.sdc`
* `board.tcl`
* `files.tcl`

### 6. Report

* JSON
* Markdown
* Graphviz

## Odporúčaná implementačná postupnosť

### Commit 1

`repo skeleton + pyproject + CLI build/validate`

### Commit 2

`config schemas + loaders + domain models`

### Commit 3

`validation engine + core rules`

### Commit 4

`elaboration for board bindings and clocks`

### Commit 5

`board/timing/rtl IR + emitters`

### Commit 6

`reporting layer`

### Commit 7

`golden fixtures for blink_test_01`

### Commit 8

`PLL/generated clock support + blink_test_02 golden`

Takto bude každý commit spustiteľný a reviewovateľný.

## Fixtures, ktoré by som pripravil ako prvé

### `tests/golden/fixtures/blink_test_01/`

* `project.yaml`
* `board.yaml`
* `ip/blink_test.ip.yaml`

### `tests/golden/fixtures/blink_test_02/`

* `project.yaml`
* `board.yaml`
* `timing.yaml`
* `ip/blink_test.ip.yaml`
* `ip/clkpll.ip.yaml`

Toto sú ideálne fixtures, lebo:

* `blink_test_01` overí minimum
* `blink_test_02` overí generated clocks, vendor IP assets a width adaptation na PMOD

Presne tieto patterny sú aj v tvojich aktuálnych projektoch.   

## Definition of done pre prvý branch

Branch je hotový, keď:

* `socfw validate tests/golden/fixtures/blink_test_01/project.yaml` prejde
* `socfw build ...` vytvorí všetky očakávané artefakty
* golden testy pre `blink_test_01` a `blink_test_02` prejdú
* v kóde už nebude žiadna potreba legacy SoC contextu
* board pin map nebude nikde hardcoded v emitri

Ten posledný bod je dôležitý, lebo presne to je jeden z hlavných refaktorov oproti starému `tcl.py`. 

## Čo by som vedome odložil na branch 2

Branch `soc/simple-bus-core`:

* CPU model
* RAM model
* address map builder
* software IR
* docs IR
* IRQ planner
* simple_bus fabric module

Branch `soc/vendor-ip-sdram`:

* SDRAM project
* FIFO dependency IP
* boot image flow
* bin2hex wrapper
* fuller timing overrides

## Môj praktický odporúčaný plán

Spravil by som to v troch vetvách:

* `bootstrap/minimal-e2e`
* `soc/simple-bus-core`
* `soc/sdram-vendor-ip`

To ti dá:

* rýchly prvý úspech
* malý review scope
* čistú históriu bez big-bang commitu

## Čo by som urobil úplne prvé zajtra ráno

1. založiť repo skeleton a `pyproject.toml`
2. pridať `board/project/timing/ip` loadery
3. rozbehnúť `socfw validate`
4. dostať `blink_test_01` do green stavu
5. až potom pridať emitre

To je najrýchlejšia cesta k niečomu, čo sa dá reálne spustiť.

Ak chceš, ďalší krok spravím už úplne prakticky: dám ti **presný zoznam súborov pre branch `bootstrap/minimal-e2e` s poradím implementácie a obsahom prvých fixture YAML**.
