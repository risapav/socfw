Super. Nižšie je návrh **cieľovej architektúry od nuly**, ale tak, aby sa dali rozumne preniesť dobré nápady zo súčasného frameworku.

## 1. Cieľ návrhu

Framework by som staval ako **kompilátor konfigurácie SoC projektu**:

**YAML/registry inputs → canonical model → validation → elaboration/planning → IR per artifact → emitters → report**

To je mentálny model, ktorý škáluje najlepšie.
Nie „skript, čo generuje pár súborov“, ale **build system s doménovým jadrom**.

---

## 2. Navrhovaná adresárová štruktúra

```text
socfw/
  api/
    __init__.py
    types.py
    diagnostics.py
    plugin.py

  cli/
    __init__.py
    main.py
    commands/
      build.py
      validate.py
      explain.py
      graph.py
      doctor.py

  config/
    __init__.py
    loader.py
    merger.py
    resolver.py
    provenance.py
    schema/
      project.py
      board.py
      ip.py
      timing.py
      bus.py

  domain/
    __init__.py
    model.py
    enums.py
    references.py
    identities.py

  normalize/
    __init__.py
    project.py
    board.py
    ip.py
    timing.py
    buses.py

  validate/
    __init__.py
    runner.py
    rules/
      schema_rules.py
      naming_rules.py
      address_rules.py
      clock_reset_rules.py
      board_rules.py
      bus_rules.py
      ip_rules.py

  elaborate/
    __init__.py
    planner.py
    clocks.py
    resets.py
    address_map.py
    interconnect.py
    adapters.py
    board_ports.py
    dependencies.py

  ir/
    __init__.py
    rtl.py
    timing.py
    software.py
    board.py
    docs.py

  build/
    __init__.py
    pipeline.py
    context.py
    manifest.py
    cache.py

  emit/
    __init__.py
    registry.py
    renderer.py
    artifacts.py
    rtl/
      emitter.py
      templates/
    timing/
      emitter.py
      templates/
    software/
      emitter.py
      templates/
    board/
      emitter.py
      templates/
    docs/
      emitter.py
      templates/

  plugins/
    builtin/
      buses/
        simple_bus/
        axi_lite/
        wishbone/
      boards/
        qmtech_ep4ce55/
      ips/
        uart/
        gpio/
        timer/
        pll/
        sdram/
      toolchains/
        quartus/

  reports/
    __init__.py
    json_report.py
    markdown_report.py
    html_report.py
    graphviz.py

  tests/
    unit/
    integration/
    golden/
    fixtures/
```

Toto rozdelenie je dôležité hlavne preto, aby sa ti:

* config loading nemiešal s generator logikou,
* validation nemiešala s elaboration,
* IR nemiešalo s templatingom,
* plugin systém držal oddelene od jadra.

---

## 3. Hlavné vrstvy a ich zodpovednosti

### A. `config/` — centrálne načítanie YAML vstupov

Táto vrstva robí iba:

* načítanie YAML,
* include/import,
* merge overrideov,
* environment/profile overlays,
* zachytenie source location,
* schema validation raw configu.

Výstup tejto vrstvy by som nechcel ako voľný `dict`, ale ako:

```python
@dataclass
class RawConfigBundle:
    project: RawProjectConfig
    board: RawBoardConfig | None
    ip_registry: list[RawIpDefinition]
    timing: RawTimingConfig | None
    buses: list[RawBusDefinition]
    sources: list[ConfigSource]
```

A každá hodnota by mala provenance:

* z ktorého súboru prišla,
* z akého riadku,
* či bola defaultnutá,
* či prepísala inú hodnotu.

To je zásadné pre reporting.

---

### B. `domain/` + `normalize/` — kanonický doménový model

Zo surového YAML vznikne **jeden canonical model**.

Nie:

* `dict`,
* čiastočný `SoCModel`,
* kopu optional fallbackov,

ale niečo v tomto duchu:

```python
@dataclass
class SystemModel:
    project: Project
    board: Board
    cpu: CpuInstance | None
    clocks: list[ClockDomain]
    resets: list[ResetDomain]
    buses: list[BusInstance]
    peripherals: list[PeripheralInstance]
    memory_regions: list[MemoryRegion]
    board_ports: list[BoardPort]
    constraints: ConstraintSet
    docs: DocumentationMetadata
```

Dôležité je, že toto už je:

* **typované**,
* **normalizované**,
* **bez YAML špecifík**,
* **bez templating assumptions**.

Takýto model je základ, na ktorom môžeš stavať všetko ostatné.

---

### C. `validate/` — jednotný validačný systém

Toto musí byť samostatný subsystém.

Každé pravidlo nech vracia jednotný diagnostický objekt:

```python
@dataclass
class Diagnostic:
    severity: Literal["info", "warning", "error"]
    code: str
    message: str
    subject: str
    locations: list[SourceLocation]
    hints: list[str] = field(default_factory=list)
    related: list[str] = field(default_factory=list)
```

Príklady kódov:

* `CFG001` unknown config key
* `BUS014` incompatible bus widths
* `ADR007` overlapping address ranges
* `CLK011` missing reset synchronization
* `BRD003` pin assigned twice
* `IP022` missing required parameter
* `GEN005` emitter template missing

To je dôležité, lebo bez kódov sa z validácie zle robí CI aj dokumentácia.

Validator runner:

```python
class ValidationRunner:
    def run(self, model: SystemModel) -> list[Diagnostic]:
        ...
```

Pravidlá by mali byť malé, izolované, testovateľné.

---

### D. `elaborate/` — plánovanie a odvodenie systému

Toto je srdce rozšíriteľnosti.

Tu sa zo `SystemModel` vytvorí **elaborated plan**:

* ktorý interconnect sa má vložiť,
* aké bridge moduly vzniknú,
* ktoré width adaptery sú nutné,
* aké reset synchronizéry treba,
* ktoré top-level porty vzniknú,
* aké dependency IP sa majú pritiahnuť,
* ktoré artefakty sa budú emitovať.

Napríklad:

```python
@dataclass
class ElaboratedSystem:
    model: SystemModel
    address_map: AddressMap
    clock_plan: ClockPlan
    reset_plan: ResetPlan
    interconnect_plan: InterconnectPlan
    board_port_plan: BoardPortPlan
    dependency_plan: DependencyPlan
    artifact_plan: ArtifactPlan
```

Toto dnes v tvojom frameworku existuje len fragmentovane v `RtlBuilder`, `SDCGenerator` a podobne. Ja by som to centralizoval.

---

### E. `ir/` — samostatné IR pre každý typ artefaktu

To je veľmi dôležitý bod.

Nesnažil by som sa mať jeden univerzálny IR. Lepšie je mať:

* `RtlIR`
* `TimingIR`
* `SoftwareIR`
* `BoardIR`
* `DocsIR`

Príklad:

```python
@dataclass
class RtlIR:
    top: RtlModule
    packages: list[RtlPackage]
    interfaces: list[RtlInterface]
    modules: list[RtlModuleDef]
    static_sources: list[StaticSourceRef]

@dataclass
class TimingIR:
    clocks: list[TimingClock]
    generated_clocks: list[GeneratedClock]
    false_paths: list[FalsePathConstraint]
    io_delays: list[IoDelayConstraint]
    multicycles: list[MulticycleConstraint]

@dataclass
class SoftwareIR:
    memory_map: MemoryMap
    irq_map: IrqMap
    linker_regions: list[LinkerRegion]
    csr_descriptors: list[CsrBlock]
```

To je čisté, testovateľné a dobre sa na to píšu emittery.

---

### F. `emit/` — emitre a templaty

Emitter má mať zodpovednosť iba:

* prevziať IR,
* vygenerovať artefakty,
* zaregistrovať ich do manifestu,
* vrátiť diagnostics ak niečo chýba.

Napríklad:

```python
class ArtifactEmitter(Protocol):
    artifact_family: str

    def emit(self, ctx: BuildContext, ir: object) -> list[GeneratedArtifact]:
        ...
```

Pre RTL:

```python
class RtlEmitter:
    artifact_family = "rtl"

    def emit(self, ctx: BuildContext, ir: RtlIR) -> list[GeneratedArtifact]:
        ...
```

Tým sa zbavíš toho, že generátory priamo riešia loading, planning aj rendering naraz.

---

## 4. Plugin architektúra

Keď chceš rozšíriteľnosť pre bus-y a IP, plugin model je kľúčový.

### Základné plugin typy

```python
class BusPlugin(Protocol):
    name: str
    def register(self, reg: PluginRegistry) -> None: ...

class IpPlugin(Protocol):
    name: str
    def register(self, reg: PluginRegistry) -> None: ...

class BoardPlugin(Protocol):
    name: str
    def register(self, reg: PluginRegistry) -> None: ...

class ToolchainPlugin(Protocol):
    name: str
    def register(self, reg: PluginRegistry) -> None: ...
```

### Registry

```python
@dataclass
class PluginRegistry:
    bus_protocols: dict[str, BusProtocol]
    bus_planners: dict[str, BusPlanner]
    bus_adapters: list[BusAdapterFactory]
    ip_factories: dict[str, IpFactory]
    board_descriptors: dict[str, BoardDescriptor]
    emitters: dict[str, ArtifactEmitter]
    validators: list[ValidationRule]
```

### Pre bus-y konkrétne

Navrhol by som tieto entity:

```python
@dataclass
class BusProtocol:
    name: str
    addr_width: int
    data_width: int
    features: set[str]

class BusPlanner(Protocol):
    def plan(self, sys: SystemModel, registry: PluginRegistry) -> InterconnectPlan:
        ...

class BusAdapterFactory(Protocol):
    def supports(self, src: BusEndpoint, dst: BusEndpoint) -> bool: ...
    def create(self, src: BusEndpoint, dst: BusEndpoint) -> AdapterInstance: ...
```

Takto pridanie nového busu nebude znamenať editovať core logiku, ale:

* pridať `BusProtocol`,
* pridať `BusPlanner`,
* pridať adaptery/bridges,
* pridať validačné pravidlá,
* pridať RTL/Timing emit support, ak treba.

---

## 5. Konkrétny execution flow

Takto by som si predstavoval build pipeline:

```python
class BuildPipeline:
    def run(self, req: BuildRequest) -> BuildResult:
        raw = self.config_loader.load(req)
        raw_diags = self.raw_validator.validate(raw)

        model = self.normalizer.normalize(raw)
        sem_diags = self.semantic_validator.validate(model)

        if has_errors(raw_diags + sem_diags):
            return BuildResult.failed(...)

        elaborated = self.elaborator.elaborate(model)

        rtl_ir = self.rtl_ir_builder.build(elaborated)
        timing_ir = self.timing_ir_builder.build(elaborated)
        sw_ir = self.software_ir_builder.build(elaborated)
        board_ir = self.board_ir_builder.build(elaborated)
        docs_ir = self.docs_ir_builder.build(elaborated)

        artifacts = []
        artifacts += self.emitters["rtl"].emit(ctx, rtl_ir)
        artifacts += self.emitters["timing"].emit(ctx, timing_ir)
        artifacts += self.emitters["software"].emit(ctx, sw_ir)
        artifacts += self.emitters["board"].emit(ctx, board_ir)
        artifacts += self.emitters["docs"].emit(ctx, docs_ir)

        report = self.reporter.build(...)
        return BuildResult.success(...)
```

To je čisté a dobre sa to testuje krok po kroku.

---

## 6. CLI návrh

Framework by mal mať pár jasných príkazov:

```bash
socfw build project.yaml
socfw validate project.yaml
socfw explain clocks project.yaml
socfw explain address-map project.yaml
socfw graph interconnect project.yaml
socfw doctor environment
socfw list plugins
socfw schema export
```

### Význam

* `build` generuje všetko
* `validate` iba load + normalize + validate
* `explain` ukáže odvodzovanie konkrétnej oblasti
* `graph` spraví diagram
* `doctor` skontroluje toolchain, templates, plugins
* `list plugins` ukáže nainštalované bus/IP/board pluginy
* `schema export` vygeneruje schema pre editor/CI

`explain` je veľmi cenný. Pri zložitejších clock/reset/bus návrhoch vie ušetriť hodiny.

---

## 7. Reporting a audit trail

Toto by som postavil ako first-class feature.

### Build manifest

```python
@dataclass
class GeneratedArtifact:
    path: str
    kind: str
    generator: str
    inputs: list[str]
    checksum: str
    metadata: dict[str, Any]
```

### Build report

```python
@dataclass
class BuildReport:
    started_at: datetime
    finished_at: datetime
    inputs: list[InputSummary]
    diagnostics: list[Diagnostic]
    artifacts: list[GeneratedArtifact]
    stats: BuildStats
    decisions: list[PlanningDecision]
```

### PlanningDecision

```python
@dataclass
class PlanningDecision:
    category: str
    message: str
    rationale: str
    related_objects: list[str]
```

Príklady:

* "Inserted AXI-Lite to simple_bus bridge between CPU and uart0"
* "Added 2-stage reset synchronizer for clk_100m domain"
* "Assigned base address 0x40000000 to gpio0 from auto-allocation region"
* "Expanded board port ETH_RX_CLK from board descriptor"

To je presne ten detailný reporting, ktorý dnes chýba.

---

## 8. Typový model: čo by som spravil explicitne

Zo skúsenosti sú najväčšie problémy tam, kde sú implicitné konvencie. Preto by som spravil explicitné:

### Board port

```python
@dataclass(frozen=True)
class BoardPort:
    name: str
    direction: PortDir
    width: int
    electrical: str | None
    pin_binding: list[PhysicalPinRef]
    attributes: dict[str, Any]
```

### Peripheral instance

```python
@dataclass
class PeripheralInstance:
    inst_name: str
    kind: str
    params: dict[str, Any]
    bus_attachment: BusAttachment | None
    interrupts: list[InterruptSource]
    external_ports: list[ExternalPortRequirement]
    clocks: list[ClockRequirement]
    resets: list[ResetRequirement]
```

### Bus attachment

```python
@dataclass
class BusAttachment:
    protocol: str
    role: Literal["master", "slave"]
    addr_width: int
    data_width: int
    region: AddressRegion | None
```

Keď to máš takto explicitné, zrazu vieš robiť rozšíriteľnosť bez hackov.

---

## 9. Čo zo súčasného frameworku preniesť priamo

Nie všetko treba vyhodiť.

### Preniesol by som takmer priamo

* myšlienku `RtlContext` a `RtlBuilder` ako základ `RtlIR` builderu, ale s čistejším API,
* separáciu `rtl.py`, `sdc.py`, `tcl.py`, `sw.py` ako budúce artifact families,
* deterministický pin database prístup z `tcl.py`, ale nie priamo v generátore; skôr ako `BoardPlugin` descriptor,
* generovanie SW mapy a docs z rovnakého source of truth,
* Graphviz export ako report/debug artifact.

### Ponechal by som len ako inšpiráciu, nie priamo

* `base.py` renderer, lebo shared environment je správny nápad, ale write policy by som rozdelil podľa artifact type.
* `SDCGenerator` logiku odvodenia clock/reset constraints, ale presunul by som ju do `TimingIRBuilder`.

### Zahodil by som

* legacy bridge context v RTL generátore,
* ad-hoc fallbacky cez `getattr` a dict `.get`,
* `print + sys.exit` štýl error handlingu v core,
* implicitné väzby medzi názvami template súborov a generator kódom,
* shared ASCII-dropping write policy pre všetky výstupy.

---

## 10. Ako by vyzeralo API jadra

Toto je zhruba API, ktoré by som chcel mať:

```python
engine = FrameworkEngine.with_builtin_plugins()

result = engine.build(
    BuildRequest(
        project_file="project.yaml",
        profile="debug",
        out_dir="build/gen",
        artifact_families=["rtl", "timing", "software", "board", "docs"],
    )
)

if result.ok:
    print(result.report.summary())
else:
    for d in result.diagnostics:
        print(d.pretty())
```

A vnútorné služby:

```python
class FrameworkEngine:
    def load(self, req: BuildRequest) -> RawConfigBundle: ...
    def normalize(self, raw: RawConfigBundle) -> SystemModel: ...
    def validate(self, model: SystemModel) -> list[Diagnostic]: ...
    def elaborate(self, model: SystemModel) -> ElaboratedSystem: ...
    def build_ir(self, elaborated: ElaboratedSystem) -> IrBundle: ...
    def emit(self, ir: IrBundle, ctx: BuildContext) -> list[GeneratedArtifact]: ...
    def report(self, ...) -> BuildReport: ...
```

To je pekne skladateľné aj pre CLI, aj pre testy, aj pre embedding do iných toolov.

---

## 11. Migračná stratégia

Aby sa to nemuselo robiť „big bang“ bez kontroly, išiel by som takto:

### Fáza 1 — stabilizácia modelu a validácie

* zaviesť `Diagnostic`
* zaviesť centrálny `BuildResult`
* odstrániť `print/sys.exit` z core
* spraviť central `config loader`
* pridať strict typed `SystemModel`

### Fáza 2 — odseknutie generatorov od raw modelu

* pre RTL dokončiť čistý IR
* pre Timing spraviť `TimingIR`
* pre SW spraviť `SoftwareIR`
* pre Board spraviť `BoardIR`

### Fáza 3 — plugin system

* board pluginy
* IP pluginy
* bus pluginy
* emitter registry

### Fáza 4 — reporting a explain tooling

* JSON/MD/HTML report
* explain adresový priestor
* explain reset tree
* graph interconnect
* graph clocks

### Fáza 5 — breaking config version 2

* formalizovať YAML schema
* version field
* migrator zo starej config syntaxe
* deprecated keys report

To je realistický a bezpečný postup.

---

## 12. Testovacia stratégia

Pri takomto frameworku je testovanie zásadné.

Mal by som štyri úrovne:

### Unit tests

na:

* validator rules
* address allocator
* bus adapters
* clock/reset planners
* renderer helpers

### Integration tests

* celé buildy malých projektov

### Golden tests

* fixné YAML vstupy
* porovnanie vygenerovaných artefaktov s referenčnými výstupmi

### Explain/report tests

* kontrola diagnostics
* kontrola manifestu
* kontrola graph/report výstupov

Bez golden testov sa generátorové frameworky veľmi rýchlo rozpadnú.

---

## 13. Najdôležitejšie design pravidlá

Keby som mal celý návrh zredukovať na pár tvrdých pravidiel, boli by tieto:

1. **Žiadny emitter nesmie pracovať priamo s raw YAML ani s voľným dictom.**
2. **Každý artifact family má vlastné IR.**
3. **Každé validačné pravidlo vracia diagnostics s kódom a source location.**
4. **Rozšíriteľnosť ide cez registry/pluginy, nie cez `if bus_type == ...`.**
5. **Každé build rozhodnutie má byť reportovateľné.**
6. **Templaty sú hlúpe; logika je v planneroch a IR builderoch.**
7. **Konfigurácia má verziu a migrácie.**
8. **Core nevypisuje a nekončí proces; vracia štruktúrované výsledky.**

---

## 14. Môj odporúčaný „minimum viable redesign“

Ak nechceš hneď prerábať úplne všetko, toto je najlepší prvý rez:

* spraviť `BuildPipeline`
* zaviesť `Diagnostic`
* spraviť centrálny `config loader`
* zaviesť jeden kanonický `SystemModel`
* dokončiť IR pre RTL, Timing, SW
* z generátorov spraviť emittery
* pridať manifest + JSON report

Toto samo o sebe už dramaticky zlepší architektúru aj bez plného plugin systému.

---

## 15. Môj stručný verdikt

**Ponechal by som filozofiu:**

* builder,
* IR,
* deterministické emitovanie,
* jednotný source of truth pre HW/SW/docs.

**Kompletne by som prerobil:**

* config frontend,
* validačné jadro,
* reporting,
* lifecycle buildu,
* plugin model pre bus-y/IP/boardy.

Výsledok by bol framework, ktorý sa správa skôr ako **doménový kompilátor SoC konfigurácie**, nie ako zbierka generátor skriptov.

Ak chceš, v ďalšom kroku ti viem rovno pripraviť aj **konkrétny skeleton kódu**: Python balíky, dataclass/Pydantic modely a prázdne rozhrania tried pre `BuildPipeline`, `Diagnostic`, `PluginRegistry`, `SystemModel` a `RtlIR`.
