Áno. Tu je **Commit 19 ako file-by-file scaffold**:

# Commit 19 — prvý bridge-aware `vendor_sdram_soc` build path cez compatibility shim

Cieľ tohto commitu:

* dostať `vendor_sdram_soc` z:

  * validate-green
    na
  * prvý build-level flow
* ešte bez plného nového bridge RTL stacku
* ale s **compatibility shimom**, ktorý vie:

  * rozpoznať potrebu `simple_bus -> wishbone`
  * vložiť do legacy sveta potrebné scaffold informácie
  * dostať build aspoň na úroveň:

    * top-level generated
    * externé SDRAM porty prenesené
    * vendor artifacts exportované

Toto je správny commit, lebo teraz už nechceš len modelovo vedieť, že bridge existuje, ale chceš prvý reálny build path pre SDRAM fixture.

---

# Názov commitu

```text
build: add first bridge-aware vendor_sdram_soc compatibility build path
```

---

# 1. Čo má byť výsledok po Commite 19

Po tomto commite má fungovať:

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
```

A očakávaš:

* build prejde
* vzniknú aspoň základné artefakty:

  * `rtl/soc_top.sv`
  * `hal/board.tcl`
  * `hal/files.tcl`
  * `timing/soc_top.sdc`
* `files.tcl` obsahuje:

  * `QIP_FILE`
  * `sdram_ctrl.qip`
  * `SDC_FILE`
  * `sdram_ctrl.sdc`
* build path už rozumie tomu, že medzi fabric a SDRAM IP je bridge-supported pair

Na tomto commite ešte nemusíš mať:

* plne správny bridge RTL implementation detail
* finálny SDRAM functional design
* golden snapshot

Cieľ je:

* build-level vertical slice
* bridge-aware compatibility flow

---

# 2. Súbory, ktoré pridať

```text
tests/integration/test_build_vendor_sdram_soc.py
```

Voliteľne, ak chceš helper oddeliť čistejšie:

```text
socfw/build/compat_bridge.py
```

Ale dá sa to spraviť aj len v `legacy_build.py`.

---

# 3. Súbory, ktoré upraviť

```text
legacy_build.py
socfw/build/vendor_artifacts.py
tests/golden/fixtures/vendor_sdram_soc/project.yaml
```

Voliteľne:

```text
tests/integration/test_validate_vendor_sdram_soc_with_bridge_support.py
```

ak chceš pridať ešte pár assertionov navyše.

---

# 4. Kľúčové rozhodnutie pre Commit 19

Správny scope je:

## ešte nerobiť plný bridge generator

Na tomto commite sprav len:

* compatibility shim vie rozpoznať supported bridge pair
* pri generovaní temporary legacy configu vie zachovať bus informácie
* legacy build path dostane dosť údajov na to, aby build prešiel

Teda:

* bridge je zatiaľ **modelovo a kompatibilitne podporovaný**
* nie ešte plne “novým IR builderom vložený”

To je správny medzikrok.

---

# 5. úprava `tests/golden/fixtures/vendor_sdram_soc/project.yaml`

Ak si v Commite 17/18 ešte nemal timing file alebo si chcel fixture nechať úzky, teraz by som ho mierne doplnil.

## odporúčaná verzia

```yaml
version: 2
kind: project

project:
  name: vendor_sdram_soc
  mode: soc
  board: qmtech_ep4ce55
  output_dir: build/gen
  debug: true

registries:
  packs:
    - packs/builtin
    - packs/vendor-intel
  ip: []
  cpu:
    - tests/golden/fixtures/vendor_sdram_soc/ip

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

buses:
  - name: main
    protocol: simple_bus
    addr_width: 32
    data_width: 32

cpu:
  instance: cpu0
  type: dummy_cpu
  fabric: main
  reset_vector: 0

modules:
  - instance: sdram0
    type: sdram_ctrl
    bus:
      fabric: main
      base: 2147483648
      size: 16777216
    clocks:
      clk: sys_clk
    bind:
      ports:
        zs_addr:
          target: board:external.sdram.addr
        zs_ba:
          target: board:external.sdram.ba
        zs_dq:
          target: board:external.sdram.dq
        zs_dqm:
          target: board:external.sdram.dqm
        zs_cs_n:
          target: board:external.sdram.cs_n
        zs_we_n:
          target: board:external.sdram.we_n
        zs_ras_n:
          target: board:external.sdram.ras_n
        zs_cas_n:
          target: board:external.sdram.cas_n
        zs_cke:
          target: board:external.sdram.cke
        zs_clk:
          target: board:external.sdram.clk
```

Ak už túto verziu máš, netreba meniť.

---

# 6. Hlavná úprava `legacy_build.py`

Toto je jadro commitu.

Musíš rozšíriť compatibility bridge tak, aby:

1. nový `project.yaml` premapoval na legacy dočasný config
2. zachoval:

   * `buses`
   * `cpu.fabric`
   * `module.bus`
3. vedel vyrobiť scaffold bridge-aware shape, ktorý starý build zje

---

## 6.1 uprav `_convert_new_project_to_legacy_shape()`

Doplň tam `buses` a `module.bus`.

## odporúčaná verzia relevantnej časti

```python
def _convert_new_project_to_legacy_shape(project_file: str, out_dir: str) -> str:
    project_path = Path(project_file).resolve()
    data = yaml.safe_load(project_path.read_text(encoding="utf-8")) or {}

    if data.get("kind") != "project" or "project" not in data:
        return str(project_path)

    compat_dir = Path(out_dir) / ".compat"
    compat_dir.mkdir(parents=True, exist_ok=True)

    registries = data.get("registries", {})
    project = data.get("project", {})
    modules = data.get("modules", [])
    buses = data.get("buses", [])
    cpu = data.get("cpu")

    legacy = {
        "design": {
            "name": project.get("name", "project"),
            "type": project.get("mode", "standalone"),
            "output_dir": out_dir,
            "debug": bool(project.get("debug", False)),
        },
        "board": {
            "type": project.get("board"),
            "file": project.get("board_file"),
        },
        "plugins": {
            "ip": list(registries.get("ip", [])),
            "cpu": list(registries.get("cpu", [])),
        },
        "buses": [
            {
                "name": b.get("name"),
                "protocol": b.get("protocol"),
                "addr_width": b.get("addr_width", 32),
                "data_width": b.get("data_width", 32),
            }
            for b in buses
        ],
        "modules": [
            {
                "name": m.get("instance"),
                "type": m.get("type"),
                "params": m.get("params", {}),
                "clocks": m.get("clocks", {}),
                "bind": m.get("bind", {}),
                "bus": m.get("bus"),
            }
            for m in modules
        ],
    }

    if cpu:
        legacy["cpu"] = {
            "instance": cpu.get("instance"),
            "type": cpu.get("type"),
            "fabric": cpu.get("fabric"),
            "reset_vector": cpu.get("reset_vector"),
            "params": cpu.get("params", {}),
        }

    if not legacy["board"]["file"] and project.get("board") == "qmtech_ep4ce55":
        legacy["board"]["file"] = str(Path("packs/builtin/boards/qmtech_ep4ce55/board.yaml").resolve())

    compat_file = compat_dir / "legacy_project_config.yaml"
    compat_file.write_text(yaml.safe_dump(legacy, sort_keys=False), encoding="utf-8")
    return str(compat_file)
```

### prečo

Týmto už bridge-aware a bus-aware informácie nestratíš v compatibility kroku.

---

## 6.2 pridaj helper pre build-level bridge awareness

Nechceme ešte plný bridge RTL planner, ale chceme vedieť, že fixture ide build pathom so supported pair.

Pridaj helper:

```python
def _collect_bridge_pairs(system):
    pairs = []
    if system is None:
        return pairs

    for mod in system.project.modules:
        if mod.bus is None:
            continue

        fabric = system.project.fabric_by_name(mod.bus.fabric)
        if fabric is None:
            continue

        ip = system.ip_catalog.get(mod.type_name)
        if ip is None:
            continue

        iface = ip.slave_bus_interface()
        if iface is None:
            continue

        if fabric.protocol != iface.protocol:
            pairs.append((fabric.protocol, iface.protocol, mod.instance))

    return pairs
```

A potom v `build_legacy()` môžeš zapísať marker metadata alebo debug helper:

```python
def _write_bridge_summary(out_dir: str, system) -> str | None:
    if system is None:
        return None

    pairs = _collect_bridge_pairs(system)
    if not pairs:
        return None

    reports_dir = Path(out_dir) / "reports"
    reports_dir.mkdir(parents=True, exist_ok=True)
    fp = reports_dir / "bridge_summary.txt"

    lines = []
    for src, dst, inst in pairs:
        lines.append(f"{inst}: {src} -> {dst}")

    fp.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return str(fp)
```

### prečo

Toto je veľmi užitočné:

* máš build-level stopu
* bez veľkého zásahu do starého RTL stacku
* neskôr to ľahko nahradíš novým reportom

---

## 6.3 uprav `build_legacy()` takto

```python
def build_legacy(project_file: str, out_dir: str, system=None) -> list[str]:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    effective_project_file = _convert_new_project_to_legacy_shape(project_file, out_dir)

    # TODO: Replace this block with the real current repo build entrypoint.
    # Example:
    # from <legacy module> import build_project
    # build_project(effective_project_file, str(out))

    marker = out / "LEGACY_BACKEND_NOT_FULLY_WIRED.txt"
    if not any(out.iterdir()):
        marker.write_text(
            f"project_file={project_file}\n"
            f"effective_project_file={effective_project_file}\n"
            f"out_dir={out_dir}\n",
            encoding="utf-8",
        )

    patched_files_tcl = _write_or_patch_files_tcl(out_dir, system)
    bridge_summary = _write_bridge_summary(out_dir, system)

    generated = _collect_generated(out_dir)
    for extra in [patched_files_tcl, bridge_summary]:
        if extra is not None and extra not in generated:
            generated.append(extra)

    generated = sorted(dict.fromkeys(generated))
    return generated
```

---

# 7. úprava `socfw/build/vendor_artifacts.py`

CPU descriptor v tomto fixture nie je vendor IP, takže tam netreba veľkú zmenu.
Ale ak chceš byť robustný, nech collector ide len po IP moduloch a nie po CPU type-name, ak CPU descriptor nebude v `ip_catalog`.

## odporúčaná bezpečnejšia verzia

```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class VendorArtifactBundle:
    qip_files: list[str] = field(default_factory=list)
    sdc_files: list[str] = field(default_factory=list)


def collect_vendor_artifacts(system) -> VendorArtifactBundle:
    bundle = VendorArtifactBundle()
    seen_qip = set()
    seen_sdc = set()

    used_types = {m.type_name for m in system.project.modules}

    for type_name in sorted(used_types):
        ip = system.ip_catalog.get(type_name)
        if ip is not None and ip.vendor_info is not None:
            if ip.vendor_info.qip and ip.vendor_info.qip not in seen_qip:
                bundle.qip_files.append(ip.vendor_info.qip)
                seen_qip.add(ip.vendor_info.qip)

            for sdc in ip.vendor_info.sdc:
                if sdc not in seen_sdc:
                    bundle.sdc_files.append(sdc)
                    seen_sdc.add(sdc)

    bundle.qip_files = sorted(bundle.qip_files)
    bundle.sdc_files = sorted(bundle.sdc_files)
    return bundle
```

### prečo

Je to čistejšie a bezpečnejšie.

---

# 8. `tests/integration/test_build_vendor_sdram_soc.py`

Toto je hlavný test commitu.

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_vendor_sdram_soc(tmp_path):
    out_dir = tmp_path / "out"

    result = FullBuildPipeline().build(
        BuildRequest(
            project_file="tests/golden/fixtures/vendor_sdram_soc/project.yaml",
            out_dir=str(out_dir),
        )
    )

    assert result.ok, [f"{d.code}: {d.message}" for d in result.diagnostics]

    files_tcl = out_dir / "hal" / "files.tcl"
    bridge_summary = out_dir / "reports" / "bridge_summary.txt"

    assert files_tcl.exists()
    assert bridge_summary.exists()

    files_tcl_text = files_tcl.read_text(encoding="utf-8")
    bridge_summary_text = bridge_summary.read_text(encoding="utf-8")

    assert "QIP_FILE" in files_tcl_text
    assert "sdram_ctrl.qip" in files_tcl_text
    assert "SDC_FILE" in files_tcl_text
    assert "sdram_ctrl.sdc" in files_tcl_text

    assert "sdram0: simple_bus -> wishbone" in bridge_summary_text
```

### prečo takto

Na tomto commite ešte cielene netlačíme:

* `rtl/soc_top.sv`
* bridge module string v RTL

Lebo bridge insertion ešte nerobíme.
Ale build-level flow už potvrdzuje:

* vendor artifacts export
* bridge-aware compatibility path

To je správny scope.

---

# 9. Voliteľne: doplň aj timing file do fixture

Ak chceš byť bližšie budúcemu buildu, pridaj:

## `tests/golden/fixtures/vendor_sdram_soc/timing_config.yaml`

```yaml
version: 2
kind: timing

generated_clocks: []
false_paths:
  - from_path: "*reset*"
    to_path: "*"
```

Nie je to nutné, ale je to čisté.

---

# 10. Čo robiť, ak reálny legacy entrypoint už vie buildiť viac

Ak po napojení reálneho legacy build entrypointu už dostávaš:

* `rtl/soc_top.sv`
* `board.tcl`
* `soc_top.sdc`

tak ich pokojne v teste doplň ako soft assertions.

Napríklad:

```python
rtl = out_dir / "rtl" / "soc_top.sv"
if rtl.exists():
    rtl_text = rtl.read_text(encoding="utf-8")
    assert "sdram_ctrl" in rtl_text
```

Ale na Commit 19 by som to ešte nedával natvrdo, kým bridge insertion nie je hotová.

---

# 11. Čo v tomto commite ešte **nerobiť**

Vedome by som nechal bokom:

* bridge RTL emitter
* real `simple_bus_to_wishbone_bridge.sv`
* full top-level bridge wiring
* golden snapshot pre `vendor_sdram_soc`
* SDRAM functional simulation
* CPU firmware path

Commit 19 má vyriešiť len:

* prvý build-level compatibility path
* vendor artifacts
* bridge-aware reporting/helper stopu

To je správny scope.

---

# 12. Čo po Commite 19 overiť

Spusti:

```bash
pip install -e .
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
pytest tests/integration/test_build_vendor_sdram_soc.py
```

### očakávanie

* build green
* `files.tcl` obsahuje SDRAM vendor artifacts
* `bridge_summary.txt` existuje a zachytí protocol pair

To je veľmi dobrý build-level checkpoint.

---

# 13. Definition of Done pre Commit 19

Commit 19 je hotový, keď:

* `vendor_sdram_soc` sa buildí novým CLI
* build generuje aspoň vendor files export
* bridge-aware compatibility summary vznikne
* integration test je green

To je prvý skutočný SDRAM build vertical slice.

---

# 14. Čo má byť Commit 20

Po tomto by som išiel na:

## Commit 20

```text
rtl: add first explicit bridge insertion scaffold and assert bridge presence in vendor_sdram_soc top
```

Ten prinesie:

* prvý explicitný bridge artifact/model
* aspoň scaffold-level bridge prítomnosť v top-level generácii
* posun z “bridge-aware build path” na “bridge-visible top output”

To je ďalší prirodzený krok.

---

# 15. Môj praktický odporúčaný rytmus

Po Commite 19:

1. potvrď build stabilitu
2. nechoď ešte do golden snapshotov
3. až potom pridaj explicitnú bridge prítomnosť v top-level outpute
4. až potom snapshotuj SDRAM fixture

To je správny convergence rytmus.

Ak chceš, ďalšia správa môže byť presne:
👉 **Commit 20 ako file-by-file scaffold: explicitný bridge insertion scaffold + assertion bridge prítomnosti v `vendor_sdram_soc` top outpute**
