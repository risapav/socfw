# New-flow Anchors

These fixtures are the reference points for the converged `socfw` flow.

## `blink_converged`

Purpose:
- standalone project
- pack-aware board resolution
- local IP registry
- basic RTL/board/timing output

Must stay green:
- validate
- build
- golden snapshot

## `pll_converged`

Purpose:
- typed timing coverage
- generated clock model
- non-vendor PLL integration

Must stay green:
- validate
- build

## `vendor_pll_soc`

Purpose:
- vendor IP metadata
- Intel/Quartus pack resolution
- QIP/SDC export
- vendor golden snapshot

Must stay green:
- validate
- build
- golden snapshot
- build summary snapshot

## `vendor_sdram_soc`

Purpose:
- external SDRAM board resources
- vendor memory IP
- simple_bus to wishbone bridge compatibility
- bridge-visible top scaffold
- vendor SDRAM golden snapshot

Must stay green:
- validate
- build
- golden snapshot
- build summary snapshot
