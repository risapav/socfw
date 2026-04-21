Áno — toto doplnenie je architektonicky dôležité.

Mení to návrh tak, že nový framework by mal rozlišovať **aspoň 3 typy IP zdrojov**:

1. **custom/source IP**
   ručne písané RTL alebo interné IP z `cores/` či `src/ip`

2. **vendor-generated IP**
   Quartus/MegaWizard/IP Catalog generované bloky, kde zdrojom pravdy je najmä `.qip` a prípadne wrapper `.v` / `_bb.v`

3. **internal helper/generated modules**
   veci, ktoré framework generuje sám, napr. top, register blocky, constraints, mapy

To je presne vidieť na tvojich Quartus IP descriptoroch:

* `clkpll.ip.yaml` sa opiera hlavne o `clkpll.qip`, nie o ručný core balík, a nesie semantiku clock outputs, reset bypass a active-high reset.
* `sdram_fifo.ip.yaml` rovnako ukazuje vendor-generated FIFO s `.qip`, bez potreby klasického „core“ lookupu, a dokonca s atypickou reset semantikou okolo `aclr`/absence klasického `rst_n`.

## Čo to znamená pre nový návrh

### 1. `plugins.ip` alebo `paths.ip_plugins` nestačí ako jediný mechanizmus

V SDRAM projekte dnes uvádzaš IP search paths, ale pri vendor IP to nie je ideálny model, pretože tieto IP nie sú len „ďalšie RTL moduly v core adresári“. Sú to skôr **balíky build assets** okolo jedného logického IP bloku. To sedí aj na tvoj aktuálny SDRAM projekt, kde `clkpll` je projektový modul, ale jeho realizácia je Quartus-generated asset set.

Preto by som v YAML v2 zaviedol oddelenie:

* `plugins` alebo `registries` pre **IP descriptor discovery**
* `assets` alebo `vendor_ip_roots` pre **vendor-generated build assets**

Nie všetko hádzať pod `cores`.

---

### 2. IP descriptor musí vedieť povedať aj **origin**

Navrhoval by som, aby mal každý IP descriptor explicitné pole typu:

```yaml
origin:
  kind: vendor_generated
  tool: quartus
```

alebo

```yaml
origin:
  kind: source
```

Pre `clkpll` by to bolo niečo ako:

```yaml
kind: ip
type: standalone
module: clkpll

origin:
  kind: vendor_generated
  tool: quartus
  packaging: qip

artifacts:
  synthesis:
    - clkpll.qip
  simulation:
    - clkpll.v
    - clkpll_bb.v
```

To je omnoho presnejšie než dnešné všeobecné `files:` pole. Dnes tam síce už správne preferuješ `.qip`, ale architektonicky by som to ešte pomenoval explicitnejšie.

---

### 3. Vendor IP treba modelovať ako **asset bundle**, nie len ako modul

Pri Quartus IP nie je dôležitý len názov modulu. Dôležité sú:

* `.qip`
* prípadný wrapper `.v`
* black-box súbor
* tool metadata
* niekedy generované submodules/transitívne závislosti

Preto by som zaviedol objekt napr.:

```python
@dataclass
class IpAssetBundle:
    logical_name: str
    origin_kind: str          # source / vendor_generated / generated
    synthesis_files: list[str]
    simulation_files: list[str]
    constraints_files: list[str]
    manifest_files: list[str] # qip, xci, tcl, ppf...
```

A `files.tcl` / Quartus emitter by už pracoval s týmto bundle modelom, nie len s plochým zoznamom súborov. Dnešný `files.tcl.j2` je plochý file list emitter, čo je použiteľné, ale na vendor IP trochu nízkoúrovňové.

---

### 4. Clock-output a vendor reset semantics musia byť first-class

Tvoje `clkpll.ip.yaml` je veľmi dôležité tým, že nepopisuje len „modul s portami“, ale aj:

* `bypass_rst_sync: true`
* `active_high_rst: true`
* `clock_output` rozhrania
* `locked` signal
* väzbu na timing model PLL outputov.

To znamená, že nový framework nesmie brať vendor IP iba ako statický file include. Musí vedieť, že:

* niektoré IP generujú clock domains,
* niektoré reset porty majú špeciálnu semantiku,
* niektoré signály majú planning význam, nielen wiring význam.

Teda `clkpll` nemá byť len `module + files`, ale **planner-visible IP kind**.

---

### 5. `sdram_fifo` ukazuje potrebu odlíšiť top-level IP a internal dependency IP

Podľa komentára je `sdram_fifo` interný submodul a `soc_top` ho neinštanciuje priamo.

To je dôležité. Nový framework by mal vedieť rozlišovať:

* **top-level instantiated IP**
* **dependency-only IP**
* **toolchain-provided implementation artifacts**

Navrhoval by som v IP descriptoroch niečo ako:

```yaml
visibility:
  instantiate_directly: false
  dependency_only: true
```

alebo na úrovni projektu:

```yaml
dependencies:
  vendor_ip:
    - sdram_fifo
```

Tým pádom sa `sdram_fifo.qip` dostane do Quartus build manifestu, ale nevznikne očakávanie, že musí mať samostatnú top-level konfiguráciu v `modules:`.

---

## Praktická úprava návrhu YAML v2

Po tomto doplnení by som projektový YAML rozšíril o sekciu napríklad:

```yaml
ip:
  search_paths:
    - ../../../src/ip
    - ../rtl

  vendor_assets:
    roots:
      - ../quartus_ip
```

Ale ešte lepšie je, ak sa IP discovery vôbec neopiera o dva oddelené search path mechanizmy, ale o registrované deskriptory:

```yaml
registries:
  ip:
    - ../../../src/ip
    - ../quartus_ip
```

pričom každý descriptor sám povie, či je:

* `origin.kind: source`
* `origin.kind: vendor_generated`

To je čistejší model.

---

## Konkrétny dopad na tvoje odporúčané vrstvy

### Board YAML

Bez zmeny. Board descriptor rieši fyzické zdroje dosky, nie vendor IP bundly.

### Project YAML

Mal by vedieť deklarovať použitie vendor IP logickým názvom, nie ručne všetky `.qip` súbory.

### IP registry / IP descriptors

Tu je najväčšia zmena:

* descriptors musia vedieť popísať asset bundle,
* origin,
* synthesis vs simulation files,
* planner semantics.

### Build manifest

Musí reportovať, ktoré vendor-generated assety boli pridané do build flow.

---

## Môj odporúčaný finálny model IP descriptoru

Pre vendor-generated Quartus IP by som odporučil niečo v tomto štýle:

```yaml
version: 2
kind: ip

name: clkpll
type: standalone
module: clkpll

origin:
  kind: vendor_generated
  tool: quartus
  packaging: qip

integration:
  bus: none
  generate_registers: false
  instantiate: true

reset:
  bypass_sync: true
  active_high: true
  port: areset

clocking:
  primary_input: inclk0
  outputs:
    - port: c0
      domain: clk_100mhz
      kind: generated_clock
    - port: c1
      domain: clk_100mhz_sh
      kind: generated_clock
    - port: locked
      signal: pll_locked
      kind: status

artifacts:
  synthesis:
    - clkpll.qip
  simulation:
    - clkpll.v
    - clkpll_bb.v
  metadata:
    - clkpll.ppf
```

A pre `sdram_fifo` podobne, ale s:

* `instantiate: false` alebo `dependency_only: true`
* dual-clock semantics
* atypical reset behavior.

---

## Najdôležitejší záver

Tvoje doplnenie znamená, že nový framework by **nemal vyžadovať `cores/` pre každý IP blok**.
Namiesto toho má mať:

* **jednotný IP descriptor discovery**
* s explicitným rozlíšením:

  * custom RTL IP
  * vendor-generated Quartus IP
  * generated/internal helper IP

To je presnejšie, škálovateľnejšie a lepšie to sedí na tvoje reálne prípady s `clkpll` a `sdram_fifo`.

Najpraktickejšia zmena oproti môjmu predošlému návrhu je táto:

**`plugins.ip` by som premenoval na všeobecnejšie `registries.ip` alebo `ip.search_paths`, a IP descriptors by som rozšíril o `origin` + `artifacts` + `integration semantics`.**

Ak chceš, v ďalšej správe ti môžem rovno pripraviť:
**finálny YAML v2 návrh pre**

* `board_qmtech_ep4ce55.board.yaml`
* `blink_test_01.project.yaml`
* `blink_test_02.project.yaml`
* `sdram_test.project.yaml`
* `sdram_test.timing.yaml`
* `clkpll.ip.yaml v2`
* `sdram_fifo.ip.yaml v2`
