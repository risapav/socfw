# Getting Started

## Installation

```sh
git clone <repo>
cd socfw
pip install -e .
```

## Validate a project

```sh
socfw validate tests/golden/fixtures/soc_led_test/project.yaml
```

## Build RTL

```sh
socfw build tests/golden/fixtures/soc_led_test/project.yaml --out build/gen
```

Outputs:
- `build/gen/rtl/soc_top.sv` — top-level SystemVerilog
- `build/gen/timing/soc_top.sdc` — timing constraints
- `build/gen/hal/board.tcl` — Quartus board TCL
- `build/gen/sw/soc_map.h` — peripheral address map header
- `build/gen/docs/soc_top.md` — block diagram docs

## Build with firmware (PicoRV32)

```sh
socfw build-fw tests/golden/fixtures/picorv32_soc/project.yaml --out build/gen
```

Requires `riscv32-unknown-elf-gcc` in PATH.

## Run simulation smoke test

```sh
socfw sim-smoke tests/golden/fixtures/picorv32_soc/project.yaml --out build/gen
```

Requires `iverilog` + `vvp` in PATH.

## CLI reference

```
socfw validate <project.yaml>           — validate project config
socfw build <project.yaml> [--out DIR]  — full RTL/docs/software build
socfw build-fw <project.yaml> [--out DIR] — firmware-aware two-pass build
socfw sim-smoke <project.yaml> [--out DIR] — build + run simulation smoke test
socfw explain <topic>                   — show explanation for a topic
```
