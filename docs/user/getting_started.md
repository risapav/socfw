# Getting Started

The default flow is the `socfw` CLI.

## Installation

```sh
git clone <repo>
cd socfw
pip install -e .
```

## Validate

```bash
socfw validate <project.yaml>
```

## Build

```bash
socfw build <project.yaml> --out build/gen
```

## Example

```bash
socfw validate tests/golden/fixtures/blink_converged/project.yaml
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
```

Outputs:
- `build/blink_converged/rtl/soc_top.sv` — top-level SystemVerilog
- `build/blink_converged/timing/soc_top.sdc` — timing constraints
- `build/blink_converged/hal/board.tcl` — Quartus board TCL
- `build/blink_converged/sw/soc_map.h` — peripheral address map header
- `build/blink_converged/reports/build_summary.md` — build provenance report

## Project shape

```yaml
version: 2
kind: project

project:
  name: my_project
  mode: standalone
  board: qmtech_ep4ce55

registries:
  packs:
    - packs/builtin
  ip:
    - ip

modules:
  - instance: blink_test
    type: blink_test
```

## Notes

- Boards are resolved through packs.
- IP descriptors are loaded from registered IP paths or packs.
- Vendor IP should use descriptor metadata rather than ad-hoc project scripts.

## Create a new project

```bash
socfw init my_blink --template blink --name my_blink --board qmtech_ep4ce55
socfw validate my_blink/project.yaml
socfw build my_blink/project.yaml --out my_blink/build/gen
```

The generated project uses the new pack-aware `project.yaml` format.

## Additional CLI commands

```
socfw validate <project.yaml>             — validate project config
socfw build <project.yaml> [--out DIR]    — full RTL/docs/software build
socfw build-fw <project.yaml> [--out DIR] — firmware-aware two-pass build
socfw sim-smoke <project.yaml> [--out DIR] — build + run simulation smoke test
socfw explain <topic>                     — show explanation for a topic
```
