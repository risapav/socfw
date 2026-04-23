# Build Report: vendor_sdram_soc

- Board: `qmtech_ep4ce55`
- CPU: `dummy_cpu`
- RAM: `32768` B @ `0x00000000`
- Reset vector: `0x00000000`

## Diagnostics

No diagnostics.

## Artifacts

| Family | Generator | Path |
|--------|-----------|------|
| board | QuartusBoardEmitter | `tests/golden/expected/vendor_sdram_soc/hal/board.tcl` |
| rtl | RtlEmitter | `tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv` |
| timing | TimingEmitter | `tests/golden/expected/vendor_sdram_soc/timing/soc_top.sdc` |
| files | QuartusFilesEmitter | `tests/golden/expected/vendor_sdram_soc/files.tcl` |
| software | SoftwareEmitter | `tests/golden/expected/vendor_sdram_soc/sw/soc_map.h` |
| software | SoftwareEmitter | `tests/golden/expected/vendor_sdram_soc/sw/soc_irq.h` |
| software | SoftwareEmitter | `tests/golden/expected/vendor_sdram_soc/sw/sections.lds` |
| docs | DocsEmitter | `tests/golden/expected/vendor_sdram_soc/docs/soc_map.md` |
| tests/golden/expected/vendor_sdram_soc/sim/files.f | SimFilelistEmitter | `sim` |

## Clock Domains

| Name | Freq (Hz) | Source | Reset |
|------|-----------|--------|-------|
| sys_clk | 50000000 | `board:SYS_CLK` | synced |

## Address Map

| Name | Base | End | Size | Kind | Module |
|------|------|-----|------|------|--------|
| RAM | `0x00000000` | `0x00007FFF` | 32768 | memory | soc_ram |
| ram | `0x00000000` | `0x00007FFF` | 32768 | peripheral | soc_ram |

## IRQ Sources

No IRQ sources.

## Bus Endpoints

| Fabric | Instance | Module | Role | Protocol | Base | End |
|--------|----------|--------|------|----------|------|-----|
| main | cpu0 | dummy_cpu | master | simple_bus |  |  |
| main | ram | soc_ram | slave | simple_bus | `0x00000000` | `0x00007FFF` |
| main | bridge_sdram0 | simple_bus_to_wishbone_bridge | slave | simple_bus | `0x80000000` | `0x80FFFFFF` |

## Planning Decisions

- **bus**: Built fabric 'main' with protocol 'simple_bus' — Fabric protocol selected from project bus_fabrics configuration
- **clock**: Resolved clock domain 'sys_clk' from board — Clock domain source resolved from 'SYS_CLK'
- **memory**: Configured RAM region at 0x00000000 size 32768 — RAM model taken from project memory configuration

## Stage Timings

No stage data.

## Artifact Provenance

No artifact provenance.
