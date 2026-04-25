Áno. Tu je **Commit 32 ako file-by-file scaffold**:

# Commit 32 — bridge instance cez top-level IR, nie iba copied artifact

Cieľ commitu:

* bridge už nie je len skopírovaný `.sv` súbor
* `soc_top.sv` má explicitnú bridge inštanciu
* stále ešte minimalisticky, bez plného native emitter rewrite
* posun od “artifact exists” k “bridge is part of design topology”

---

# Názov commitu

```text
elaborate: emit planned bridge instances into top-level output
```

---

# Súbory pridať

```text
socfw/build/top_injection.py
tests/unit/test_top_injection.py
```

---

# Súbory upraviť

```text
legacy_build.py
tests/integration/test_build_vendor_sdram_soc.py
tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv
tests/golden/test_vendor_sdram_soc_golden.py
```

---

# `socfw/build/top_injection.py`

```python
from __future__ import annotations

from pathlib import Path


def bridge_instance_block(bridge) -> str:
    return f"""
  // socfw planned bridge instance
  {bridge.kind}_bridge {bridge.instance} (
    .clk(1'b0),
    .reset_n(1'b1),
    .sb_addr(32'h0),
    .sb_wdata(32'h0),
    .sb_be(4'h0),
    .sb_we(1'b0),
    .sb_valid(1'b0),
    .sb_rdata(),
    .sb_ready(),
    .wb_adr(),
    .wb_dat_w(),
    .wb_dat_r(32'h0),
    .wb_sel(),
    .wb_we(),
    .wb_cyc(),
    .wb_stb(),
    .wb_ack(1'b0)
  );
"""


def inject_bridge_instances(out_dir: str, planned_bridges: list) -> str | None:
    if not planned_bridges:
        return None

    soc_top = Path(out_dir) / "rtl" / "soc_top.sv"
    if not soc_top.exists():
        return None

    text = soc_top.read_text(encoding="utf-8")
    marker = "// socfw planned bridge instance"

    if marker in text:
        return str(soc_top)

    blocks = "".join(bridge_instance_block(b) for b in planned_bridges)

    idx = text.rfind("endmodule")
    if idx == -1:
        return None

    patched = text[:idx].rstrip() + "\n" + blocks + "\nendmodule\n"
    soc_top.write_text(patched, encoding="utf-8")
    return str(soc_top)
```

---

# Úprava `legacy_build.py`

Pridaj import:

```python
from socfw.build.top_injection import inject_bridge_instances
```

V `build_legacy(...)` po skopírovaní bridge artifacts:

```python
patched_soc_top = inject_bridge_instances(out_dir, planned_bridges or [])
```

Do generated files:

```python
for extra in [patched_files_tcl, bridge_summary, patched_soc_top, *bridge_files]:
    if extra is not None and extra not in generated:
        generated.append(extra)
```

---

# Úprava `tests/integration/test_build_vendor_sdram_soc.py`

Pridaj späť tvrdú kontrolu top-level inštancie:

```python
rtl_text = rtl.read_text(encoding="utf-8")

assert "simple_bus_to_wishbone_bridge" in rtl_text
assert "u_bridge_sdram0" in rtl_text
assert "socfw planned bridge instance" in rtl_text
```

A nechaj aj kontrolu first-class artifactu:

```python
bridge_rtl = out_dir / "rtl" / "simple_bus_to_wishbone_bridge.sv"
assert bridge_rtl.exists()
```

---

# `tests/unit/test_top_injection.py`

```python
from dataclasses import dataclass
from pathlib import Path

from socfw.build.top_injection import inject_bridge_instances


@dataclass(frozen=True)
class DummyBridge:
    instance: str = "u_bridge_sdram0"
    kind: str = "simple_bus_to_wishbone"


def test_inject_bridge_instances(tmp_path):
    rtl_dir = tmp_path / "rtl"
    rtl_dir.mkdir()
    soc_top = rtl_dir / "soc_top.sv"
    soc_top.write_text("module soc_top;\nendmodule\n", encoding="utf-8")

    patched = inject_bridge_instances(str(tmp_path), [DummyBridge()])

    assert patched is not None
    text = soc_top.read_text(encoding="utf-8")
    assert "socfw planned bridge instance" in text
    assert "simple_bus_to_wishbone_bridge" in text
    assert "u_bridge_sdram0" in text
```

---

# Golden update

Po stabilnom builde:

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc
cp build/vendor_sdram_soc/rtl/soc_top.sv tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv
```

Potom:

```bash
pytest tests/integration/test_build_vendor_sdram_soc.py
pytest tests/unit/test_top_injection.py
pytest tests/golden/test_vendor_sdram_soc_golden.py
```

---

# Čo ešte nerobiť

Ešte nerob:

* plné wire-level zapojenie bridge
* odstránenie legacy backendu
* nový native RTL emitter
* SDRAM functional test

Tento commit má len zabezpečiť, že planned bridge sa objaví v topológii.

---

# Definition of Done

Commit 32 je hotový, keď:

* bridge RTL artifact existuje
* bridge inštancia je v `soc_top.sv`
* `vendor_sdram_soc` integration test overuje artifact aj inštanciu
* golden snapshot je aktualizovaný

Ďalší commit:

```text
rtl: replace top-level injection with native RTL IR emitter
```
