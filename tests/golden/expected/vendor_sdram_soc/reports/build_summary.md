# Build Summary

## Project

- Name: `vendor_sdram_soc`
- Mode: `soc`
- Board: `qmtech_ep4ce55`

## CPU

- CPU type: `dummy_cpu`
- CPU module: `dummy_cpu`

## Modules and IP

- Module instance: `sdram0`

- IP type: `sdram_ctrl`

## Timing

- Generated clocks: `0`
- False paths: `0`

## Vendor Artifacts

- QIP: `$REPO/packs/vendor-intel/ip/sdram_ctrl/files/sdram_ctrl.qip`
- SDC: `$REPO/packs/vendor-intel/ip/sdram_ctrl/files/sdram_ctrl.sdc`

## Bridges

- `sdram0: simple_bus -> wishbone`

## Compatibility Aliases

- none

## Artifact Inventory

- report: `4`
- rtl: `2`
- sim: `2`
- tcl: `2`
- timing: `1`

## Generated Files

- `$OUT/hal/board.tcl`
- `$OUT/hal/files.tcl`
- `$OUT/reports/board_bindings.json`
- `$OUT/reports/board_bindings.md`
- `$OUT/reports/board_pinout.md`
- `$OUT/reports/board_selectors.json`
- `$OUT/reports/bridge_summary.txt`
- `$OUT/rtl/simple_bus_to_wishbone_bridge.sv`
- `$OUT/rtl/soc_top.sv`
- `$OUT/sim/files.f`
- `$OUT/sim/tb_soc_top.sv`
- `$OUT/timing/soc_top.sdc`

## Artifacts

- report: `$OUT/reports/board_bindings.json` (BoardBindingsReport)
- report: `$OUT/reports/board_bindings.md` (BoardBindingsReport)
- report: `$OUT/reports/board_pinout.md` (BoardPinoutReport)
- report: `$OUT/reports/board_selectors.json` (BoardSelectorIndex)
- rtl: `$OUT/rtl/simple_bus_to_wishbone_bridge.sv` (BridgePlanner)
- rtl: `$OUT/rtl/soc_top.sv` (RtlEmitter)
- sim: `$OUT/sim/files.f` (SimFilelistEmitter)
- sim: `$OUT/sim/tb_soc_top.sv` (SimTbEmitter)
- tcl: `$OUT/hal/board.tcl` (BoardTclEmitter)
- tcl: `$OUT/hal/files.tcl` (FilesTclEmitter)
- timing: `$OUT/timing/soc_top.sdc` (SdcEmitter)
