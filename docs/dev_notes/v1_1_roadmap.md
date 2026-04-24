# v1.1 Roadmap (post-cutover)

## Context

After `v1.0.0-cutover` the framework has:
- stable new flow (`socfw`)
- vendor IP support (PLL, SDRAM)
- bridge model + scaffold
- golden anchors
- CI enforcement

v1.1 is not about new features but about:
- removing temporary hacks
- hardening the architecture
- preparing for real SoC projects

---

## Priority 1 — Remove scaffolding (most important)

### 1.1 Real bridge RTL (replace scaffold patch)

Today: `simple_bus_to_wishbone_bridge` is inserted as a string hack into `soc_top.sv`

v1.1: bridge is generated as a normal IP block through IR / elaboration, not string patching.

Result: no `compat_top_patch.py`, bridge is deterministic, testable, extensible.

### 1.2 Bridge planner (not just registry)

Today: registry = "pair supported"

v1.1: planner decides where a bridge is needed, creates IR node, assigns address space.

Result: multi-IP bridging, ready for AXI-lite, APB, etc.

---

## Priority 2 — Build pipeline architecture

### 2.1 Remove legacy backend from pipeline center

Today: `socfw → legacy_build → patch`

v1.1: `socfw` has native RTL/files.tcl/SDC emitters.

### 2.2 Explicit IR

Introduce explicit IR model: modules, buses, bridges, clocks.

---

## Priority 3 — Timing & clocks

- Clock domains
- CDC hints
- Derived clock chaining
- Stable SDC sections with grouping

---

## Priority 4 — Developer UX

- More `socfw init` templates (soc, pll, sdram)
- Actionable error hints (e.g. `BRG001: Hint: add bridge support`)
- `socfw lint project.yaml`

---

## Priority 5 — Vendor & packs

- Multi-vendor pack support (Xilinx, Lattice)
- Pack index with versioning

---

## Priority 6 — Reporting v2

- Build summary with relative paths and module→artifact mapping
- JSON export: `reports/build_summary.json`

---

## Priority 7 — Legacy removal (not yet)

Not in v1.1. Possible v1.2+:
- Remove `legacy_build.py`
- Remove compat layer
- Remove fallback CLI

---

## Recommended commit sequence (v1.1)

### Phase A — critical
```
31: bridge: implement real simple_bus_to_wishbone RTL
32: elaborate: emit planned bridge instances into top-level output
33: elaborate: add bridge planner to elaboration pipeline
```

### Phase B — architecture
```
34: build: introduce IR model
35: build: replace legacy backend with native emitter
```

### Phase C — stability
```
36: timing: improve SDC emission
37: diagnostics: improve validation errors
```

### Phase D — UX
```
38: scaffold: add more init templates
39: cli: add lint command
```

### Phase E — ecosystem
```
40: packs: introduce pack index
```

---

## Success criteria for v1.1

- No patching of `soc_top.sv`
- No `.compat` layer
- Bridge is a first-class object
- Build works without legacy backend
- New projects are simple (`socfw init`)
- Vendor flow still works
