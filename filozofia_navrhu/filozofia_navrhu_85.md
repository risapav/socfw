Áno. Tu je **Commit 24 ako file-by-file scaffold**:

# Commit 24 — migration status board + new-flow anchors

Cieľ commitu:

* formálne označiť, čo je už nový flow anchor
* začať riadený cutover proces
* mať jeden dokument, kde vidíš stav migrácie projektov
* jasne oddeliť:

  * migrated
  * dual
  * legacy-exception
  * not-started

---

# Názov commitu

```text
cutover: add migration status board and mark converged fixtures as new-flow anchors
```

---

# Súbory, ktoré pridať

```text
docs/dev_notes/cutover_status.md
docs/dev_notes/new_flow_anchors.md
legacy/README.md
```

---

# Súbory, ktoré upraviť

```text
README.md
docs/dev_notes/checkpoints.md
```

---

# `docs/dev_notes/cutover_status.md`

```md
# Cutover Status

This file tracks migration from the legacy flow to the new `socfw` flow.

## Status values

- `migrated`: project uses the new flow only
- `dual`: project can be built by both legacy and new flow
- `legacy-exception`: project temporarily remains on legacy flow
- `not-started`: migration has not started

## Projects

| Project | Current flow | Target flow | Status | Owner | Notes |
|---|---|---|---|---|---|
| blink_converged | socfw | socfw | migrated | TBD | New-flow standalone anchor |
| pll_converged | socfw | socfw | migrated | TBD | Typed timing / PLL anchor |
| vendor_pll_soc | socfw | socfw | migrated | TBD | Vendor QIP/SDC anchor |
| vendor_sdram_soc | socfw | socfw | migrated | TBD | Vendor SDRAM + bridge scaffold anchor |
| legacy project_config.yaml | legacy | socfw | dual | TBD | Supported through compatibility loader |
```

---

# `docs/dev_notes/new_flow_anchors.md`

```md
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
```

---

# `legacy/README.md`

```md
# Legacy Flow

This directory is reserved for deprecated build-flow components kept temporarily for migration fallback.

## Policy

- No new features should be added to the legacy flow.
- Critical fixes are allowed only when needed to keep migration unblocked.
- All new projects should use the `socfw` flow.
- Compatibility shims may call legacy code, but new architecture should live under `socfw/`.

## Current role

The legacy flow may still be used as a backend during convergence, but it is no longer the target architecture.
```

---

# README doplnok

Do `README.md` pridaj krátku sekciu:

````md
## New `socfw` flow

The converged flow uses:

```bash
socfw validate <project.yaml>
socfw build <project.yaml> --out build/gen
````

Reference fixtures:

* `tests/golden/fixtures/blink_converged`
* `tests/golden/fixtures/pll_converged`
* `tests/golden/fixtures/vendor_pll_soc`
* `tests/golden/fixtures/vendor_sdram_soc`

Legacy scripts are kept only for migration fallback.

````

---

# `docs/dev_notes/checkpoints.md`

Pridaj:

```md
# Checkpoints

## m4-new-flow-anchors

Status:
- `blink_converged` added
- `pll_converged` added
- `vendor_pll_soc` added
- `vendor_sdram_soc` added
- build summary reporting added
- vendor PLL and SDRAM golden anchors added

Next:
- default CLI documentation
- legacy warning messages
- CI lane split
````

---

# Definition of Done

Commit 24 je hotový, keď:

* existuje cutover status board
* new-flow anchors sú explicitne pomenované
* legacy policy je zdokumentovaná
* README ukazuje nový `socfw` flow
* starý flow je opísaný ako fallback, nie cieľová architektúra

Ďalší logický commit:

```text
cutover: add deprecation warnings to legacy entrypoints
```
