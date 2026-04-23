# Build Report: vendor_pll_soc

- Board: `qmtech_ep4ce55`
- CPU: `none`
- RAM: `0` B @ `0x00000000`
- Reset vector: `0x00000000`

## Diagnostics

No diagnostics.

## Artifacts

| Family | Generator | Path |
|--------|-----------|------|
| board | QuartusBoardEmitter | `tests/golden/expected/vendor_pll_soc/hal/board.tcl` |
| rtl | RtlEmitter | `tests/golden/expected/vendor_pll_soc/rtl/soc_top.sv` |
| timing | TimingEmitter | `tests/golden/expected/vendor_pll_soc/timing/soc_top.sdc` |
| files | QuartusFilesEmitter | `tests/golden/expected/vendor_pll_soc/files.tcl` |
| tests/golden/expected/vendor_pll_soc/sim/files.f | SimFilelistEmitter | `sim` |

## Clock Domains

| Name | Freq (Hz) | Source | Reset |
|------|-----------|--------|-------|
| ref_clk | 50000000 | `board:SYS_CLK` | synced |

## Address Map

No address regions.

## IRQ Sources

No IRQ sources.

## Bus Endpoints

No bus endpoints.

## Planning Decisions

- **clock**: Resolved clock domain 'ref_clk' from board — Clock domain source resolved from 'SYS_CLK'

## Stage Timings

No stage data.

## Artifact Provenance

No artifact provenance.
