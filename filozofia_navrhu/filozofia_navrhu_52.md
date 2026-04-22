Super. Ideme na:

# board/package catalogs: reusable board packs, IP/CPU packs, external search paths, and dependency resolution policy

Toto je veľmi prirodzený ďalší krok po `socfw init`, lebo samotný scaffold je užitočný až vtedy, keď vieš rozumne zdieľať:

* board definície,
* CPU/IP deskriptory,
* vendor artefakty,
* common RTL bloky,
* a prípadne celé “packs” medzi projektami.

To je presne to, čo si chcel od začiatku:
**zdieľaný board pre viac projektov, centrálne definície, menej copy-paste.**

---

# 1. Cieľ

Chceš dosiahnuť model, kde projekt nemusí mať všetko lokálne v sebe, ale vie použiť:

* **board pack**
* **IP pack**
* **CPU pack**
* **vendor pack**
* **project-local overrides**

Teda napríklad:

```yaml
project:
  board: qmtech_ep4ce55

registries:
  packs:
    - ./packs
    - ~/socfw-packs
    - /opt/socfw/packs
```

A framework si vie nájsť:

* `boards/qmtech_ep4ce55/board.yaml`
* `ip/gpio.ip.yaml`
* `cpu/picorv32_min.cpu.yaml`
* `vendor/intel/pll/...`

bez toho, aby si to musel kopírovať do každého projektu.

---

# 2. Správny princíp

Odporúčam zaviesť pojem:

## **pack**

adresár so štandardnou štruktúrou, ktorý môže obsahovať:

* boards
* ip
* cpu
* rtl
* vendor artifacts
* docs
* examples

Príklad:

```text
pack_root/
  pack.yaml
  boards/
    qmtech_ep4ce55/
      board.yaml
      README.md
  ip/
    gpio/
      gpio.ip.yaml
      rtl/
        gpio_core.sv
  cpu/
    picorv32_min/
      picorv32_min.cpu.yaml
      rtl/
        picorv32_simple_bus_wrapper.sv
        picorv32.v
  vendor/
    intel/
      pll/
      sdram/
  examples/
    picorv32_soc/
```

To je veľmi dobrý model:

* je čitateľný,
* dá sa verzovať,
* dá sa zdieľať medzi projektami,
* a dá sa skladať z viacerých packov.

---

# 3. Pack manifest

Každý pack by mal mať malý manifest.

## nový `socfw/catalog/pack_schema.py`

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class PackManifestSchema(BaseModel):
    version: Literal[1]
    kind: Literal["pack"]
    name: str
    title: str | None = None
    description: str | None = None
    provides: list[str] = Field(default_factory=list)   # boards, ip, cpu, vendor, examples
```

---

## nový `socfw/catalog/pack_model.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class PackManifest:
    name: str
    title: str | None = None
    description: str | None = None
    provides: tuple[str, ...] = ()
```

---

## nový `socfw/catalog/pack_loader.py`

```python
from __future__ import annotations

from pydantic import ValidationError

from socfw.catalog.pack_model import PackManifest
from socfw.catalog.pack_schema import PackManifestSchema
from socfw.config.common import load_yaml_file
from socfw.core.result import Result
from socfw.core.diag_builders import err


class PackLoader:
    def load(self, path: str) -> Result[PackManifest]:
        raw = load_yaml_file(path)
        if not raw.ok:
            return Result(diagnostics=raw.diagnostics)

        try:
            doc = PackManifestSchema.model_validate(raw.value)
        except ValidationError as exc:
            return Result(diagnostics=[
                err(
                    "PACK100",
                    f"Invalid pack manifest: {exc}",
                    "pack",
                    file=path,
                    category="catalog",
                )
            ])

        return Result(value=PackManifest(
            name=doc.name,
            title=doc.title,
            description=doc.description,
            provides=tuple(doc.provides),
        ))
```

---

# 4. Catalog search path model

Teraz potrebuješ vedieť, kde packy hľadať.

Odporúčam 3 vrstvy:

## poradie precedence

1. **project-local packs**
2. **user/global packs**
3. **built-in packs**

Teda:

* lokálny projekt môže override-núť board/IP
* zdieľané packy sú reusable
* built-in packy slúžia ako fallback

To je správna politika.

---

## nový `socfw/catalog/search_path.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class CatalogSearchPath:
    roots: list[str] = field(default_factory=list)

    def normalized(self) -> list[str]:
        return [str(Path(r).expanduser().resolve()) for r in self.roots]
```

---

# 5. Project schema rozšírenie

Namiesto len `registries.ip` odporúčam zaviesť aj `registries.packs`.

## update `socfw/config/project_schema.py`

Rozšír `RegistriesSchema`:

```python
class RegistriesSchema(BaseModel):
    packs: list[str] = Field(default_factory=list)
    ip: list[str] = Field(default_factory=list)
    cpu: list[str] = Field(default_factory=list)
```

Tým pádom vieš:

* stále podporovať explicitné legacy cesty,
* ale nový preferovaný model bude `packs`.

---

## update `socfw/model/project.py`

Rozšír `ProjectModel`:

```python
    registries_packs: list[str] = field(default_factory=list)
    registries_cpu: list[str] = field(default_factory=list)
```

A v `ProjectLoader`:

```python
            registries_ip=doc.registries.ip,
            registries_packs=doc.registries.packs,
            registries_cpu=doc.registries.cpu,
```

---

# 6. Pack indexer

Teraz treba vedieť z pack roots spraviť index:

* boards
* ip descriptors
* cpu descriptors

## nový `socfw/catalog/index.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class CatalogIndex:
    pack_roots: list[str] = field(default_factory=list)
    board_dirs: list[str] = field(default_factory=list)
    ip_dirs: list[str] = field(default_factory=list)
    cpu_dirs: list[str] = field(default_factory=list)
    vendor_dirs: list[str] = field(default_factory=list)
    example_dirs: list[str] = field(default_factory=list)
```

---

## nový `socfw/catalog/indexer.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.catalog.index import CatalogIndex


class CatalogIndexer:
    def index_packs(self, roots: list[str]) -> CatalogIndex:
        idx = CatalogIndex()

        for root in roots:
            rp = Path(root).expanduser().resolve()
            if not rp.exists():
                continue

            idx.pack_roots.append(str(rp))

            boards = rp / "boards"
            ip = rp / "ip"
            cpu = rp / "cpu"
            vendor = rp / "vendor"
            examples = rp / "examples"

            if boards.exists():
                idx.board_dirs.append(str(boards))
            if ip.exists():
                idx.ip_dirs.append(str(ip))
            if cpu.exists():
                idx.cpu_dirs.append(str(cpu))
            if vendor.exists():
                idx.vendor_dirs.append(str(vendor))
            if examples.exists():
                idx.example_dirs.append(str(examples))

        return idx
```

---

# 7. Board resolver

Doteraz si mal `board_file` priamo v projekte. To je fajn, ale pre reusable packs potrebuješ vedieť nájsť board podľa `project.board`.

Odporúčam policy:

## resolution policy

* ak `project.board_file` existuje → použij ju
* inak hľadaj `boards/<board>/board.yaml` v indexovaných packoch
* prvý match vyhráva podľa precedence search path

To je čisté a očakávateľné.

---

## nový `socfw/catalog/board_resolver.py`

```python
from __future__ import annotations

from pathlib import Path


class BoardResolver:
    def resolve(self, *, board_key: str, explicit_board_file: str | None, board_dirs: list[str]) -> str | None:
        if explicit_board_file:
            p = Path(explicit_board_file)
            if p.exists():
                return str(p)

        for d in board_dirs:
            candidate = Path(d) / board_key / "board.yaml"
            if candidate.exists():
                return str(candidate)

        return None
```

---

# 8. CPU/IP catalog z packov

To isté platí pre CPU a IP.
Tvoje loadery už vedia prehľadávať priečinky, takže stačí im dať správne zoznamy.

## policy

`search_dirs =`

* explicit project registries (`registries.ip`, `registries.cpu`)
* plus dirs odvodené z pack indexu

A precedence:

* explicit project local dirs first
* pack dirs after
* built-in dirs last

---

# 9. System loader update

Toto je najdôležitejší integračný bod.

## update `socfw/config/system_loader.py`

Pridaj importy:

```python
from socfw.catalog.board_resolver import BoardResolver
from socfw.catalog.indexer import CatalogIndexer
```

V `__init__`:

```python
        self.catalog_indexer = CatalogIndexer()
        self.board_resolver = BoardResolver()
```

V `load()` po načítaní projektu:

```python
        pack_index = self.catalog_indexer.index_packs(project.registries_packs)

        resolved_board_file = self.board_resolver.resolve(
            board_key=project.board_ref,
            explicit_board_file=project.board_file,
            board_dirs=pack_index.board_dirs,
        )

        if resolved_board_file is None:
            return Result(diagnostics=diags + [
                err(
                    "SYS101",
                    f"Unable to resolve board '{project.board_ref}'",
                    "project.board",
                    file=project_file,
                    path="project.board",
                    category="catalog",
                    hints=[
                        "Set project.board_file explicitly.",
                        "Or add a pack containing boards/<board>/board.yaml.",
                    ],
                )
            ])
```

A potom:

```python
        board_res = self.board_loader.load(resolved_board_file)
```

IP dirs:

```python
        ip_search_dirs = list(project.registries_ip) + list(pack_index.ip_dirs)
        catalog_res = self.ip_loader.load_catalog(ip_search_dirs)
```

CPU dirs:

```python
        cpu_search_dirs = list(project.registries_cpu) + list(project.registries_ip) + list(pack_index.cpu_dirs)
        cpu_catalog_res = self.cpu_loader.load_catalog(cpu_search_dirs)
```

To je veľmi silný krok:

* projekt môže byť ľahký,
* packy držia zdieľané definície.

---

# 10. Built-in packs

Odporúčam mať aj built-in pack root, napr.:

```text
socfw_builtin_packs/
  boards/
  cpu/
  ip/
```

Najjednoduchšie:

* zabaliť ho do package data,
* alebo mať ho ako repo adresár `packs/builtin`.

Pre V1 stačí:

```text
packs/builtin
```

a `SystemLoader` ho doplní automaticky na koniec search path.

---

## update `socfw/config/system_loader.py`

Napríklad:

```python
from pathlib import Path
```

a v `load()`:

```python
        builtin_pack_root = str(Path(__file__).resolve().parents[2] / "packs" / "builtin")
        pack_roots = list(project.registries_packs) + [builtin_pack_root]
        pack_index = self.catalog_indexer.index_packs(pack_roots)
```

---

# 11. Pack-aware `socfw init`

Teraz `init` vie byť oveľa lepší:

* `list-boards` nech číta z pack catalogu,
* nie len z hardcoded listu.

To je podľa mňa veľmi dôležité.

---

## update `socfw/scaffold/board_catalog.py`

Namiesto hardcoded listu sprav resolver nad pack indexom.
Pre V1 môžeš nechať hardcoded fallback, ale lepší model je:

## nový `socfw/scaffold/board_catalog_runtime.py`

```python
from __future__ import annotations

from pathlib import Path


class RuntimeBoardCatalog:
    def list_boards(self, board_dirs: list[str]):
        found = []
        for d in board_dirs:
            root = Path(d)
            if not root.exists():
                continue
            for board_dir in sorted(root.iterdir()):
                if board_dir.is_dir() and (board_dir / "board.yaml").exists():
                    found.append((board_dir.name, str(board_dir / "board.yaml")))
        return found
```

Neskôr vieš doplniť čítanie title/vendor z board.yaml.

---

# 12. Dependency resolution policy

Toto treba explicitne zdokumentovať.

## odporúčaná politika

Pre board/IP/CPU resolution:

### precedence

1. explicit file path v projecte
2. explicit local registry dirs
3. project pack roots
4. built-in packs

### duplicate names

* prvý match vyhrá
* ale pri viacnásobnom matchi emitni warning

To je veľmi dôležité, aby bolo správanie predvídateľné.

---

## nový validator / warning

Napríklad:

* 2 packy obsahujú rovnaký `gpio`
* 2 board packy obsahujú rovnaký board id

Odporúčam zatiaľ warning, nie error.

---

## nový `socfw/validate/rules/catalog_rules.py`

```python
from __future__ import annotations

from socfw.core.diag_builders import warn
from socfw.validate.rules.base import ValidationRule


class DuplicateCatalogEntryWarningRule(ValidationRule):
    def validate(self, system) -> list:
        # V1 placeholder: duplicate detection is better implemented during indexing.
        return []
```

Lepšie to neskôr robiť už pri indexovaní.

---

# 13. Vendor pack policy

Toto je dôležité pre Quartus IP a zdieľané generated cores.

Odporúčam model:

```text
vendor/
  intel/
    pll/
      my_pll/
        files/
          my_pll.qip
          my_pll.v
          my_pll.sdc
        ip.yaml
    sdram/
      ...
```

A `ip.yaml` môže na tieto artefakty referencovať relatívne k pack rootu.

To je oveľa čistejšie než rozhádzané cesty po repozitári.

---

# 14. Relative path normalization

Keďže packy budú obsahovať IP/CPU descriptor s relatívnymi artifact paths, treba ich normalizovať proti descriptor file location.

Toto je veľmi dôležité.

Odporúčam:

* pri `IpLoader.load_file(path)` prepísať artifact paths na absolútne alebo canonical project-relative paths podľa policy.

---

## update `socfw/config/ip_loader.py`

Pri skladaní `IpDescriptor`:

```python
from pathlib import Path
```

Na začiatku `load_file()`:

```python
        base_dir = Path(path).parent
```

A pri artifacts:

```python
            artifacts=IpArtifactBundle(
                synthesis=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.synthesis),
                simulation=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.simulation),
                metadata=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.metadata),
            ),
```

To isté pre CPU loader:

```python
            artifacts=tuple(str((Path(path).parent / p).resolve()) for p in doc.artifacts),
```

Toto je veľká praktická výhra.

---

# 15. Pack layout docs

Toto určite treba zdokumentovať.

## `docs/architecture/06_packs_and_catalogs.md`

Sekcie:

* čo je pack
* odporúčaná štruktúra
* resolution precedence
* duplicate policy
* relative artifact normalization
* built-in vs project-local packs

To je veľmi dôležitý dokument.

---

# 16. Example pack layout

Odporúčaný referenčný príklad:

```text
packs/
  builtin/
    pack.yaml
    boards/
      qmtech_ep4ce55/
        board.yaml
    cpu/
      picorv32_min/
        picorv32_min.cpu.yaml
        rtl/
          picorv32_simple_bus_wrapper.sv
          picorv32.v
    ip/
      gpio/
        gpio.ip.yaml
        rtl/
          gpio_core.sv
```

A `pack.yaml`:

```yaml
version: 1
kind: pack
name: builtin
title: Built-in socfw pack
provides:
  - boards
  - ip
  - cpu
```

---

# 17. Integration tests

## `tests/integration/test_pack_board_resolution.py`

```python
from pathlib import Path

from socfw.config.system_loader import SystemLoader


def test_board_resolves_from_pack(tmp_path):
    pack = tmp_path / "packs" / "builtin" / "boards" / "demo_board"
    pack.mkdir(parents=True)

    (tmp_path / "packs" / "builtin" / "pack.yaml").write_text(
        "version: 1\nkind: pack\nname: builtin\nprovides: [boards]\n",
        encoding="utf-8",
    )

    (pack / "board.yaml").write_text(
        "version: 2\nkind: board\n"
        "board:\n  id: demo_board\n"
        "fpga:\n  family: testfam\n  part: testpart\n"
        "system:\n"
        "  clock:\n    id: clk\n    top_name: SYS_CLK\n    pin: A1\n    frequency_hz: 50000000\n"
        "  reset:\n    id: rst\n    top_name: RESET_N\n    pin: A2\n    active_low: true\n"
        "resources:\n  onboard: {}\n  connectors: {}\n",
        encoding="utf-8",
    )

    project = tmp_path / "project.yaml"
    project.write_text(
        "version: 2\nkind: project\n"
        "project:\n  name: demo\n  mode: standalone\n  board: demo_board\n"
        "registries:\n  packs:\n    - ./packs/builtin\n"
        "clocks:\n  primary:\n    domain: sys_clk\n    source: board:sys_clk\n  generated: []\n"
        "modules: []\n",
        encoding="utf-8",
    )

    loaded = SystemLoader().load(str(project))
    assert loaded.ok
    assert loaded.value is not None
    assert loaded.value.board.board_id == "demo_board"
```

---

## `tests/integration/test_pack_ip_resolution.py`

Podobne:

* vytvoriť pack s `ip/gpio/gpio.ip.yaml`
* project `registries.packs`
* loader nájde IP descriptor

---

# 18. Čo týmto získaš

Po tomto kroku framework získa veľmi dôležitú schopnosť:

* zdieľať boardy medzi projektami
* zdieľať CPU/IP medzi projektami
* mať reusable packs
* mať built-in aj external catalogs
* znížiť lokálny copy-paste
* zjednodušiť `socfw init`

Toto je presne tá časť, ktorú si chcel už pri boarde zdieľanom medzi projektami na rovnakom kite.

---

# 19. Môj odporúčaný ďalší krok

Po tomto bode sú podľa mňa najlepšie tri smery:

### A

**vendor IP import cleanup**

* Quartus generated IP pack normalization
* qip/sdc/v wrapper contracts

### B

**interactive init v2**

* wizard
* pack-aware board selection
* example starter bundles

### C

**workspace model**

* multi-project workspace
* shared packs + local overrides
* team-level configuration

Môj praktický odporúčaný ďalší krok je:

👉 **A — vendor IP import cleanup + Quartus generated IP pack normalization**

Lebo to prirodzene nadväzuje na packs a veľmi pomôže pri tvojom pôvodnom use-case s Quartus-generated IP, SDRAM a PLL blokmi.

Ak chceš, ďalšia správa môže byť presne:
**vendor IP cleanup: Quartus/QIP pack model, generated IP descriptors, artifact normalization, and integration policy**
