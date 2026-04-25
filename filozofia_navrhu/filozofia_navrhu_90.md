Áno. Tu je **Commit 29 ako file-by-file scaffold**:

# Commit 29 — legacy freeze + v1.0 readiness checklist

Cieľ commitu:

* formálne zmraziť legacy feature path
* zdokumentovať, že nové features idú iba do `socfw/`
* pripraviť v1.0 cutover checklist
* uzavrieť convergence fázu pred tagom

---

# Názov commitu

```text
cutover: freeze legacy feature path and document v1.0 readiness checklist
```

---

# Súbory, ktoré pridať

```text
docs/dev_notes/v1_0_readiness.md
docs/dev_notes/legacy_freeze_policy.md
```

---

# Súbory, ktoré upraviť

```text
legacy/README.md
docs/dev_notes/cutover_status.md
docs/dev_notes/checkpoints.md
README.md
```

---

# `docs/dev_notes/legacy_freeze_policy.md`

```md
# Legacy Freeze Policy

The legacy flow is now frozen.

## Rules

- No new features in legacy build flow.
- No new board/IP/CPU models should be added only to legacy paths.
- Critical bug fixes are allowed only when they unblock migration.
- Compatibility shims may call legacy code temporarily.
- All new architecture work must live under `socfw/`.

## Allowed changes

- Critical fixes
- Deprecation warnings
- Compatibility adapters
- Test-only migration support

## Not allowed

- New feature development
- New project skeletons
- New vendor-specific hacks
- New implicit config conventions
```

---

# `docs/dev_notes/v1_0_readiness.md`

```md
# v1.0 Cutover Readiness

## Required anchors

- [ ] `blink_converged` validates
- [ ] `blink_converged` builds
- [ ] `vendor_pll_soc` validates
- [ ] `vendor_pll_soc` builds
- [ ] `vendor_pll_soc` golden passes
- [ ] `vendor_sdram_soc` validates
- [ ] `vendor_sdram_soc` builds
- [ ] `vendor_sdram_soc` golden passes

## Tooling

- [ ] `socfw validate` is documented
- [ ] `socfw build` is documented
- [ ] `socfw init` is documented
- [ ] new-flow CI lane is required
- [ ] legacy lane is compatibility-only

## Legacy freeze

- [ ] legacy warning is emitted
- [ ] freeze policy is documented
- [ ] new projects use `socfw init`
- [ ] legacy fallback is retained only temporarily

## Release candidate

- [ ] run full unit tests
- [ ] run integration tests
- [ ] run golden tests
- [ ] create release candidate tag
```

---

# `legacy/README.md`

Doplň hore:

```md
> Status: frozen. No new features should be added here.
```

---

# `docs/dev_notes/cutover_status.md`

Doplň:

```md
## Legacy freeze

Status: active

Legacy is now frozen for feature development.  
All new project work should use `socfw init` or an existing new-flow fixture.
```

---

# `docs/dev_notes/checkpoints.md`

Doplň:

```md
## m8-legacy-freeze

Status:
- legacy feature path frozen
- v1.0 readiness checklist added
- new work targets `socfw/`
- legacy retained only as compatibility fallback

Next:
- release candidate tag
- final cutover review
```

---

# README doplnok

````md
## Legacy status

The legacy build flow is frozen and kept only as a migration fallback.

New projects should use:

```bash
socfw init <project_dir>
````

````

---

# Definition of Done

Commit 29 je hotový, keď:

- legacy freeze policy existuje
- v1.0 readiness checklist existuje
- README hovorí, že legacy je frozen
- cutover status je aktualizovaný

Ďalší commit:

```text
release: add v1.0 cutover release candidate checklist and tag notes
````
