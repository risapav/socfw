Spravil by som **obe veci naraz**: najprv navrhnúť **YAML v2**, lebo ten určí hranice systému, a hneď na to **migračný plán**, aby sa dalo prejsť zo starého frameworku bez chaosu.

## 1. YAML v2 – princípy

Cieľ YAML v2 by nemal byť „kopírovať interné Python objekty“, ale opísať systém tak, aby bol:

* čitateľný pre človeka,
* validovateľný schémou,
* stabilný medzi verziami,
* rozšíriteľný cez pluginy.

Najdôležitejšie pravidlo: **YAML má opisovať intent, nie implementačné detaily rendererov**.
Čiže nie „aké wires vygenerovať“, ale „aký peripheral, na aký bus, s akými clock/reset požiadavkami“.

Súčasný framework už implicitne pracuje s entitami ako board, peripherals, timing, bus fabric, ext ports a SW mapy, takže YAML v2 by ich mal zjednotiť do jednej explicitnej štruktúry.

---

## 2. Navrhovaná top-level štruktúra `project.v2.yaml`

```yaml
version: 2

project:
  name: demo_soc
  profile: default
  board: qmtech_ep4ce55
  output_dir: build/gen

cpu:
  type: picorv32
  params:
    ENABLE_IRQ: true

memory:
  ram:
    base: 0x00000000
    size: 65536
    latency: registered
    reset_vector: 0x00000000
    stack_percent: 25

clocks:
  - name: sys
    source: board:SYS_CLK
    frequency_hz: 50000000
    reset:
      signal: board:RESET_N
      active_low: true
      sync_stages: 2

buses:
  - name: main
    protocol: simple_bus
    data_width: 32
    addr_width: 32
    masters:
      - cpu
    slaves:
      - uart0
      - gpio0
      - timer0

peripherals:
  - instance: uart0
    kind: uart
    bus:
      attach: main
      base: 0x40000000
      size: 0x1000
    clocks: [sys]
    resets: [sys]
    params:
      baud_default: 115200
    external_ports:
      - top_name: UART_TX
        port: tx
      - top_name: UART_RX
        port: rx

  - instance: gpio0
    kind: gpio
    bus:
      attach: main
      base: 0x40001000
      size: 0x1000
    clocks: [sys]
    resets: [sys]
    params:
      width: 8
    external_ports:
      - top_name: ONB_LEDS
        port: gpio_o

  - instance: timer0
    kind: timer
    bus:
      attach: main
      base: 0x40002000
      size: 0x1000
    clocks: [sys]
    resets: [sys]

board_overrides:
  enable_onboard:
    uart: true
    leds: true
    buttons: false
  pmod:
    J10: NONE
    J11: SEG

timing:
  derive_clock_uncertainty: true
  false_paths: []
  io:
    auto: true
    default_input_max_ns: 2.5
    default_output_max_ns: 2.5

artifacts:
  emit:
    - rtl
    - timing
    - board
    - software
    - docs
```

Týmto sa získa:

* jedna vstupná pravda,
* explicitná verzia formátu,
* jasné miesto pre CPU, memory, clocks, buses, peripherals, board a timing,
* priestor pre pluginové rozšírenia.

---

## 3. Rozdelenie schém

Odporúčal by som mať **jednu hlavnú project schému**, ale interne ju rozdeliť na subschémy:

* `ProjectSchema`
* `CpuSchema`
* `MemorySchema`
* `ClockSchema`
* `BusSchema`
* `PeripheralSchema`
* `BoardOverridesSchema`
* `TimingSchema`
* `ArtifactsSchema`

Takto sa dá robiť validácia po vrstvách a zároveň exportovať JSON Schema pre editor/CI.

---

## 4. Pydantic modely pre YAML v2

Takto by mohol vyzerať základ.

```python
from __future__ import annotations
from typing import Any, Literal
from pydantic import BaseModel, Field, model_validator


class CpuConfig(BaseModel):
    type: str
    params: dict[str, Any] = Field(default_factory=dict)


class RamConfig(BaseModel):
    base: int
    size: int
    latency: Literal["combinational", "registered"] = "registered"
    reset_vector: int
    stack_percent: int = 25


class MemoryConfig(BaseModel):
    ram: RamConfig


class ResetConfig(BaseModel):
    signal: str
    active_low: bool = True
    sync_stages: int = 2
    sync_from: str | None = None


class ClockConfig(BaseModel):
    name: str
    source: str
    frequency_hz: int
    reset: ResetConfig | None = None


class BusConfig(BaseModel):
    name: str
    protocol: str
    data_width: int = 32
    addr_width: int = 32
    masters: list[str] = Field(default_factory=list)
    slaves: list[str] = Field(default_factory=list)


class PeripheralBusAttach(BaseModel):
    attach: str
    base: int
    size: int


class ExternalPortBinding(BaseModel):
    top_name: str
    port: str


class PeripheralConfig(BaseModel):
    instance: str
    kind: str
    bus: PeripheralBusAttach | None = None
    clocks: list[str] = Field(default_factory=list)
    resets: list[str] = Field(default_factory=list)
    params: dict[str, Any] = Field(default_factory=dict)
    external_ports: list[ExternalPortBinding] = Field(default_factory=list)


class BoardOverridesConfig(BaseModel):
    enable_onboard: dict[str, bool] = Field(default_factory=dict)
    pmod: dict[str, str] = Field(default_factory=dict)


class TimingIoConfig(BaseModel):
    auto: bool = True
    default_input_max_ns: float = 2.5
    default_output_max_ns: float = 2.5


class TimingConfig(BaseModel):
    derive_clock_uncertainty: bool = True
    false_paths: list[dict[str, Any]] = Field(default_factory=list)
    io: TimingIoConfig = Field(default_factory=TimingIoConfig)


class ArtifactsConfig(BaseModel):
    emit: list[str] = Field(default_factory=lambda: ["rtl", "timing", "board", "software", "docs"])


class ProjectMeta(BaseModel):
    name: str
    profile: str = "default"
    board: str
    output_dir: str = "build/gen"


class ProjectV2(BaseModel):
    version: Literal[2]
    project: ProjectMeta
    cpu: CpuConfig | None = None
    memory: MemoryConfig
    clocks: list[ClockConfig]
    buses: list[BusConfig] = Field(default_factory=list)
    peripherals: list[PeripheralConfig] = Field(default_factory=list)
    board_overrides: BoardOverridesConfig = Field(default_factory=BoardOverridesConfig)
    timing: TimingConfig = Field(default_factory=TimingConfig)
    artifacts: ArtifactsConfig = Field(default_factory=ArtifactsConfig)

    @model_validator(mode="after")
    def validate_unique_names(self):
        bus_names = [b.name for b in self.buses]
        if len(bus_names) != len(set(bus_names)):
            raise ValueError("Duplicate bus names")
        per_names = [p.instance for p in self.peripherals]
        if len(per_names) != len(set(per_names)):
            raise ValueError("Duplicate peripheral instance names")
        clk_names = [c.name for c in self.clocks]
        if len(clk_names) != len(set(clk_names)):
            raise ValueError("Duplicate clock names")
        return self
```

Toto je len schema-level validácia. Semantická validácia ostáva vo validator vrstve.

---

## 5. Čo má byť v YAML a čo už nie

Do YAML by som dal:

* project intent,
* výber boardu,
* CPU a memory config,
* clocks/resets,
* buses,
* peripheral instances,
* board enable/override voľby,
* timing politiky,
* zoznam artifact family.

Do YAML by som **nedával**:

* priamo generované wires,
* low-level RTL assigny,
* template-specific flags,
* konkrétne názvy interných modulov typu `u_ram`,
* detaily o tom, ako emitter skladá súbor.

To patrí do elaboration a IR vrstvy.

---

## 6. Pluginové rozšírenie YAML

Pre rozšíriteľnosť by som dovolil plugin sekcie, ale kontrolovane. Napríklad:

```yaml
plugins:
  axi_lite:
    default_ready_policy: registered

  quartus:
    family: "Cyclone IV E"
```

Každý plugin by si registroval vlastnú schému a vlastné validačné pravidlá.
Nie voľný chaos v YAML.

---

## 7. Migračný plán zo súčasného frameworku

Teraz to podstatné: ako prejsť zo starého na nový.

Súčasný framework už má oddelené generátorové oblasti:

* RTL,
* TCL/board,
* SDC/timing,
* software outputs.

To je dobrý základ na migráciu po častiach.

### Fáza 0 — freeze legacy vstupov

Najprv by som:

* zdokumentoval dnešné YAML vstupy,
* pridal golden testy pre 3–5 reprezentatívnych projektov,
* zamrazil správanie starého buildu.

Bez toho sa migrácia zle verifikuje.

### Fáza 1 — nový frontend, staré backendy

Postavil by som:

* nový `ConfigLoader`,
* nový `ProjectV2` schema model,
* nový `SystemModel`,
* nový `ValidationRunner`.

Ale generovanie by ešte stále mohlo chvíľu volať staré generátory cez adapter vrstvu.

Čiže:
`YAML v2 -> SystemModel -> LegacyAdapter -> old RTLGenerator/SDCGenerator/SWGenerator/TCLGenerator`

To zníži riziko.

### Fáza 2 — IR buildery po family

Potom po jednom:

* `SoftwareIRBuilder` + nový software emitter,
* `TimingIRBuilder` + nový timing emitter,
* `BoardIRBuilder` + nový board emitter,
* `RtlIRBuilder` + nový RTL emitter.

Začal by som software vetvou, lebo je najjednoduchšia a dobre sa porovnáva s existujúcim `soc_map.h` a `sections.lds`.

### Fáza 3 — board pluginy

Dnešnú pin databázu z `tcl.py` by som presunul do board pluginov.
To je čisté oddelenie hardware faktov od generátora.

### Fáza 4 — bus pluginy

Potom by som vytiahol:

* `simple_bus`
* neskôr `axi_lite`
* prípadne bridge/adapters

Dnešný stav, kde bus type funguje skôr ako atribút než doména, by sa tu konečne zlomil na poriadnu plugin vrstvu.

### Fáza 5 — odstránenie legacy bridge

Až keď budú nové IR buildre stabilné, odstránil by som staré prechodové miesta, napríklad legacy SoC context v RTL generátore.

---

## 8. Adaptéry pre prechodné obdobie

Na migráciu by som spravil dočasné adapter triedy.

### Príklad: `SystemModel -> old SoCModel adapter`

```python
class LegacySocModelAdapter:
    def to_legacy(self, model: SystemModel):
        # mapne nový kanonický model do štruktúry, ktorú čakajú staré generátory
        ...
```

Toto ti dovolí:

* zaviesť nový frontend skoro,
* ale nemať hneď hotový celý nový backend.

Je to dobrá prechodová technika, ak chceš prerábku od základu, ale stále potrebuješ priebežne fungujúci build.

---

## 9. Kompatibilita a verzovanie configu

Do YAML by som zaviedol povinné:

```yaml
version: 2
```

A v loadri:

* `version: 1` → legacy parser alebo migrator,
* `version: 2` → nový parser,
* iné → error.

K tomu by som pridal migrator:

```python
class ConfigMigrator:
    def migrate_v1_to_v2(self, legacy: dict) -> dict:
        ...
```

A samostatný CLI príkaz:

```bash
socfw migrate old_project.yaml > new_project.v2.yaml
```

To je veľmi praktické pri veľkej zmene.

---

## 10. Reporting počas migrácie

Počas prechodu by som build report rozšíril o:

* ktoré hodnoty boli migrované automaticky,
* ktoré boli defaultnuté,
* ktoré legacy key boli deprecated,
* ktoré sekcie sa ešte renderujú legacy backendom.

Príklad diagnostiky:

* `MIG001 legacy key "peripherals[].base_addr" mapped to "peripherals[].bus.base"`
* `MIG014 timing.false_paths carried over without semantic normalization`
* `DEP003 old RTL backend still active for family=rtl`

To veľmi pomáha pri postupnej adopcii.

---

## 11. Konkrétny migračný backlog

Keby som ti mal dať úplne praktický backlog, vyzeral by takto:

### Sprint 1

* `Diagnostic`, `Result`, `BuildPipeline`
* `ProjectV2` schema
* `ConfigLoader`
* `SystemModel`
* golden test fixtures

### Sprint 2

* `ValidationRunner`
* pravidlá: duplicates, address overlap, unknown refs, board port conflicts
* JSON report

### Sprint 3

* `SoftwareIR`
* `SoftwareIRBuilder`
* nový `software` emitter
* porovnanie so starým `soc_map.h` / `sections.lds`

### Sprint 4

* `BoardIR`
* `BoardPlugin`
* nový board emitter
* migrácia pin DB z `tcl.py`

### Sprint 5

* `TimingIR`
* nový timing emitter
* migrácia logiky zo `sdc.py`

### Sprint 6+

* `RtlIR`
* nový RTL emitter
* bus planners
* adapters/bridges
* odstránenie legacy RTL contextu

---

## 12. Čo by som z dnešného YAML určite zlomil

Ak ideš na čistý redesign, tieto veci by som vedome už neopakoval:

* roztrúsené config vstupy bez jednotného root modelu,
* implicitné defaulty rozosiate po generátoroch,
* voľné dict-y bez verzie schémy,
* naming conventions ako náhradu za explicitné väzby,
* závislosť generátorov na tom, že nejaký field „asi existuje“ cez `getattr`/`.get`.
  To je presne typ technického dlhu, ktorý brzdí rozšíriteľnosť.

---

## 13. Čo by som ponechal ako filozofiu

Určite by som ponechal:

* shared source of truth pre HW/SW/docs,
* builder/IR prístup,
* deterministické výstupy,
* oddelené artifact families,
* generovanie dokumentačných výstupov ako súčasť buildu, nie bokom.

---

## 14. Môj odporúčaný ďalší krok

Najlepší ďalší krok je podľa mňa tento:

**najprv spísať finálny `project.v2.yaml` kontrakt a 3 referenčné príklady**:

1. minimálny standalone projekt,
2. SoC s `simple_bus`,
3. projekt s board override + timing override.

Keď bude toto hotové, zvyšok architektúry sa bude navrhovať omnoho ľahšie.

Ak chceš, v ďalšej správe ti môžem rovno pripraviť **kompletný návrh `project.v2.yaml` so všetkými sekciami a 3 ukážkovými konfiguráciami**.
