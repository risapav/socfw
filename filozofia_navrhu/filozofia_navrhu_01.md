Ak by cieľ bol **spraviť z toho rozšíriteľný, dlhodobo udržateľný generator framework**, ktorý zvládne nové bus-y, nové boardy, nové IP typy, centrálny config loading, validáciu a auditovateľný reporting, tak by som neodhadzoval všetko. Ponechal by som to, čo už dnes ukazuje správny smer, a kompletne by som prerobil hlavne **hranice medzi vrstvami**.

Za najcennejšie, čo by som ponechal, považujem tieto princípy:

Prvý je **transformačný pipeline štýl**: model → intermediate representation → render. V RTL vetve to už dnes existuje cez `SoCModel -> RtlBuilder -> RtlContext -> Jinja2`, a to je podľa mňa správne jadro celej budúcej architektúry. Logika nemá byť v templatoch, ale v builderoch a IR vrstvách. To by som určite zachoval a rozšíril aj na bus fabric, timing, software mapy a board flow.

Druhý dobrý základ je **snaha o validáciu ešte pred renderom**. `RtlBuilder.validate()` je síce len parciálna, ale filozofia je správna: nekontrolovať až v Quartuse alebo po syntéze, ale chytiť nekonzistencie už v internom modeli. Tento princíp by som povýšil na centrálnu vlastnosť frameworku.

Tretí prvok, ktorý by som ponechal, je **deterministické generovanie artefaktov**. V `tcl.py` je dobre vidno odklon od dynamického chainu k statickému, čitateľnému a grepovateľnému `board.tcl`. To je presne ten smer, ktorý chceš pri serióznom build systéme: build má byť reprodukovateľný a z výstupov musí byť jasné, z čoho vznikli.

Štvrtý dobrý základ je **jednotný renderer shared across generators**. `base.py` má správnu ambíciu: jeden Jinja environment, spoločné helpery, centrálne renderovanie. Túto myšlienku by som ponechal, ale rozšíril o silnejší output management, manifesty a provenance.

Čo by som naopak zásadne prerobil:

Najväčší problém dnešného stavu je, že architektúra je ešte **napoly moderná a napoly legacy**. RTL má IR, ale SoC mode ešte stále používa „legacy context“ pre bus fabric. To znamená, že framework nemá jeden konzistentný execution model. Pri kompletnom redizajne by som zaviedol pravidlo: **žiadny generator nesmie renderovať priamo z doménového modelu**, iba z explicitného IR. Žiadne dočasné mosty.

Druhý veľký problém je, že konfigurácia a model vyzerajú byť **roztrúsené a implicitné**. Generátory očakávajú `SoCModel`, `TimingConfig`, pomocné moduly a viacero fallbackov cez `getattr`, `.get`, optional polia. To škáluje zle. Pri greenfield návrhu by som YAML loading, normalizáciu, defaulty, merge logiku a validáciu dal do jednej centrálnej vrstvy, nie rozliatej naprieč generátormi.

Tretí problém je, že framework dnes generuje viacero typov výstupov, ale **nemá zjavne jeden centrálny reportovací model**. Generujú sa súbory, printujú sa stručné hlášky, ale chýba jednotný build report: čo sa načítalo, čo sa validovalo, čo sa vygenerovalo, aké warningy vznikli, aké defaulty sa doplnili, aké konflikty boli vyriešené. To by som považoval za kľúčový prvok nového návrhu.

Štvrtý problém je **slabá explicitnosť kontraktov**. Napríklad chyba typu mismatch názvu šablóny pre register block ukazuje, že rozhrania medzi vrstvami nie sú dostatočne chránené. Ak by boli templaty, generators a artifact registry explicitne registrované v type-safe katalógu, takáto chyba by sa dala chytiť pri štarte alebo testom nad registráciou.

Keby som to navrhol od základu, cieľová architektúra by podľa mňa mala vyzerať takto:

**1. Input layer – konfigurácia a zdroje pravdy**
Sem patrí načítanie všetkých YAML súborov: project config, board config, IP registry, timing config, bus registry, plugin config. Táto vrstva by robila iba:

* loading,
* include/import mechanizmy,
* merge profilov a overrideov,
* schema validation,
* provenance tracking, teda odkiaľ prišla každá hodnota.

Výstupom tejto vrstvy nemá byť ešte runtime model SoC, ale **RawConfig tree** plus zoznam diagnostics.

**2. Domain normalization layer**
Tu by sa z raw YAML skladal jeden **canonical domain model**. Nie „čo bolo v YAML“, ale „čo systém reálne znamená“.
Príklad:

* názvy clock domains sa znormalizujú,
* reset policy sa doplní defaultmi,
* peripheral instances dostanú rozbalené adresy,
* board porty sa prevedú na jednotný typ,
* bus attachment sa zvedie na kanonický opis master/slave/bridge endpointov.

Tu by som použil striktne typované dataclass/Pydantic modely. Toto je miesto, kde má vzniknúť jeden `SystemModel`, ktorý je kompletne validný alebo má presne definované diagnostiky.

**3. Semantic validation layer**
Samostatná vrstva validatorov, nie roztrúsené `if`-y po builderoch.
Typy validácií:

* schema validation,
* referential integrity,
* address space overlaps,
* reset/clock domain consistency,
* board pin conflicts,
* bus protocol compatibility,
* unsupported feature combinations,
* style/lint rules.

Každá validácia by vracala bohatý diagnostic objekt: severity, code, message, location v configu, suggestion, related objects.

**4. Planning / elaboration layer**
Toto je najdôležitejšia vrstva pre rozšíriteľnosť. Tu by sa z doménového modelu vytváral **elaborated system plan**:

* ktoré IP sa majú instantiate-nuť,
* ktoré adaptéry treba vložiť,
* aké bridge moduly treba medzi busmi,
* aké clocks a resets vzniknú,
* ktoré statické IP sú potrebné,
* ktoré artefakty sa majú generovať.

Toto je miesto, kde by sa veľmi dobre dali zapojiť pluginy pre nové bus-y.

**5. IR layer per artifact family**
Nie jeden univerzálny IR, ale viacero čistých IR:

* `RtlIR`
* `TimingIR`
* `SoftwareIR`
* `BoardIR`
* `DocsIR`

Tento princíp už naznačuje `RtlContext`; ja by som ho iba zovšeobecnil na celú platformu.

**6. Artifact generation layer**
Templaty alebo programatické emitre, ale vždy len z IR.
Sem patria:

* SystemVerilog,
* SDC,
* TCL,
* C headers,
* linker script,
* markdown/html reporty,
* graphviz diagramy.

**7. Reporting layer**
Na konci by build vždy produkoval:

* machine-readable `build_report.json`,
* human-readable `build_report.md` alebo HTML,
* zoznam warningov a errorov,
* manifest vygenerovaných súborov,
* checksumy alebo provenance metadata.

Toto by zásadne pomohlo pri CI aj pri debugovaní.

Ak je hlavný cieľ **rozšíriteľnosť pre bus-y**, navrhol by som špeciálne plugin architektúru práve pre interconnect:

Namiesto toho, aby bol bus typ len string ako dnes, zaviedol by som abstrakcie typu:

* `BusProtocol`
* `BusEndpoint`
* `BusAdapter`
* `BusBridge`
* `BusFabricPlanner`

Tým pádom by pridanie nového busu neznamenalo editovanie polovice frameworku, ale registráciu:

* protokolu,
* pravidiel kompatibility,
* planneru,
* adapterov,
* šablón alebo emitterov.

Dnes `RtlBuilder._get_bus_type()` v podstate len číta prvý bus fabric z modelu, čo je príliš ploché na budúce rozširovanie. Na modernú architektúru treba, aby interconnect bol plnohodnotná doména, nie len atribút.

Pri YAML vstupoch by som odporučil toto:

Ponechať YAML ako authoring format, ale zaviesť:

* centrálne schema definície,
* versioning config formátu,
* migrácie medzi verziami,
* explicitné include/override mechanizmy,
* jednotné source locations.

Inými slovami: nie „hocijaký dict z YAML“, ale **konfiguračný jazyk s formalizovaným významom**.

Veľmi by som odporúčal použiť niečo ako:

* Pydantic v2 alebo podobný silný validačný model,
* JSON Schema export,
* interné `Diagnostic` objekty namiesto `print + sys.exit`.

Dnešný štýl s `print(...)` a občasným `sys.exit(1)` by som úplne odstránil z core vrstvy. Core má vracať diagnostics a exceptions len pre fatálne interné chyby, nie pre user-facing config chyby. `bin2hex.py` ako standalone utilita môže byť jednoduchšia, ale framework core nie.

Čo by som ešte ponechal konceptuálne:

Ponechal by som **separáciu podľa artifact typov**. To, že existuje zvlášť `rtl.py`, `sdc.py`, `tcl.py`, `sw.py`, je dobrý instinct. V novom návrhu by som to neurobil ako voľné moduly, ale ako plugin-capable balíky nad spoločným jadrom.

Čo by som neponechal v dnešnej forme:

Neponechal by som:

* priame `getattr`/`.get` fallbacky v generatoroch,
* miešanie doménovej logiky a render logiky,
* ad-hoc defaulting,
* implicitné naming conventions ako náhradu za explicitný model,
* ASCII dropping v shared writeri ako univerzálne správanie pre všetky artefakty,
* dočasné legacy bridges.

Pri reportingu by som išiel dosť ďaleko. Framework by mal vedieť vyprodukovať napríklad:

* „použité clock domains“,
* „vytvorené reset synchronizers“,
* „vložené bus adapters“,
* „obsadenie adresového priestoru“,
* „mapovanie top-level portov na board piny“,
* „zoznam implicitne doplnených defaultov“,
* „zoznam deprecated config keys“.

Toto dnes framework robí len fragmentovane, napríklad cez `soc_map.md` alebo Graphviz template, ale nie ako jeden integrovaný reportovací produkt.

Moje praktické odporúčanie by bolo:

**Ponechať:**

* myšlienku IR medzi modelom a templatom,
* separáciu artifact generatorov,
* deterministické generovanie,
* doménu reset/clock/bus už v Pythone, nie v Jinja,
* generovanie SW a docs z rovnakého zdroja pravdy.

**Kompletne prerobiť:**

* config loading a merge,
* validačný systém,
* execution pipeline,
* plugin model pre bus-y a IP,
* jednotný diagnostics/reporting subsystem,
* odstránenie legacy codepathov,
* explicitný artifact registry.

Ak by som to mal zhrnúť jednou vetou:
**nechal by som filozofiu “builder + IR + deterministic emit”, ale prerobil by som celý frontend frameworku na striktne typované, validačné, pluginové jadro s jednotným reportingom.**

Ak chceš, v ďalšom kroku ti viem navrhnúť aj **konkrétnu cieľovú adresárovú štruktúru a API rozhrania tried** pre takýto nový framework.
