# Build Report: blink_test_01

- Board: `qmtech_ep4ce55`
- CPU: `none`
- RAM: `0` B @ `0x00000000`
- Reset vector: `0x00000000`

## Diagnostics

No diagnostics.

## Artifacts

| Family | Generator | Path |
|--------|-----------|------|
| board | QuartusBoardEmitter | `tests/golden/expected/blink_test_01/hal/board.tcl` |
| rtl | RtlEmitter | `tests/golden/expected/blink_test_01/rtl/soc_top.sv` |
| timing | TimingEmitter | `tests/golden/expected/blink_test_01/timing/soc_top.sdc` |
| files | QuartusFilesEmitter | `tests/golden/expected/blink_test_01/files.tcl` |
| tests/golden/expected/blink_test_01/sim/files.f | SimFilelistEmitter | `sim` |

## Clock Domains

| Name | Freq (Hz) | Source | Reset |
|------|-----------|--------|-------|
| sys_clk | 50000000 | `board:SYS_CLK` | synced |

## Address Map

No address regions.

## IRQ Sources

No IRQ sources.

## Bus Endpoints

No bus endpoints.

## Planning Decisions

- **clock**: Resolved clock domain 'sys_clk' from board — Clock domain source resolved from 'SYS_CLK'

## Stage Timings

No stage data.

## Artifact Provenance

No artifact provenance.
