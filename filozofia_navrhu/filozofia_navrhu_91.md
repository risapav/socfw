Áno. Tu je **Commit 30 ako file-by-file scaffold**:

# Commit 30 — v1.0 cutover release candidate checklist + tag notes

Cieľ commitu:

* pripraviť posledný release-candidate checkpoint
* mať jasné tag notes pre `v1.0.0-cutover`
* uzavrieť technický aj procesný cutover stav

---

# Názov commitu

```text
release: add v1.0 cutover release candidate checklist and tag notes
```

---

# Súbory, ktoré pridať

```text
docs/releases/v1.0.0-cutover.md
docs/dev_notes/release_candidate_checklist.md
```

---

# Súbory, ktoré upraviť

```text
docs/dev_notes/v1_0_readiness.md
docs/dev_notes/checkpoints.md
README.md
```

---

# `docs/releases/v1.0.0-cutover.md`

````md
# v1.0.0-cutover

This release marks the default switch to the converged `socfw` flow.

## Highlights

- `socfw validate` is the default validation entrypoint
- `socfw build` is the default build entrypoint
- `socfw init` creates new-flow projects
- board resolution is pack-aware
- vendor Intel/Quartus IP packs are supported
- QIP/SDC export is covered
- SDRAM external board resources are modeled
- simple_bus to wishbone bridge compatibility is recognized
- vendor PLL and SDRAM fixtures are covered by golden tests
- legacy flow is frozen and kept only as migration fallback

## New-flow anchors

- `tests/golden/fixtures/blink_converged`
- `tests/golden/fixtures/pll_converged`
- `tests/golden/fixtures/vendor_pll_soc`
- `tests/golden/fixtures/vendor_sdram_soc`

## Legacy policy

Legacy build flow is frozen:
- no new features
- critical migration fixes only
- new projects should use `socfw init`

## Verification

Before tagging, run:

```bash
pytest tests/unit
pytest tests/integration
pytest tests/golden
````

and:

```bash
socfw validate tests/golden/fixtures/blink_converged/project.yaml
socfw validate tests/golden/fixtures/pll_converged/project.yaml
socfw validate tests/golden/fixtures/vendor_pll_soc/project.yaml
socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml
```

## Suggested tag

```bash
git tag v1.0.0-cutover
```

````

---

# `docs/dev_notes/release_candidate_checklist.md`

```md
# Release Candidate Checklist

## Required test commands

```bash
pytest tests/unit
pytest tests/integration
pytest tests/golden
````

## Required fixture builds

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/rc/blink_converged
socfw build tests/golden/fixtures/pll_converged/project.yaml --out build/rc/pll_converged
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/rc/vendor_pll_soc
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/rc/vendor_sdram_soc
```

## Required manual review

* [ ] README quickstart uses `socfw`
* [ ] `socfw init` creates a valid project
* [ ] vendor PLL files export contains `QIP_FILE`
* [ ] vendor SDRAM files export contains `QIP_FILE`
* [ ] legacy warning is emitted
* [ ] CI new-flow lane is required
* [ ] legacy lane is non-blocking
* [ ] release notes are accurate

## Tag

```bash
git tag v1.0.0-cutover
```

````

---

# `docs/dev_notes/v1_0_readiness.md`

Doplň sekciu:

```md
## Release candidate

- [ ] release notes added
- [ ] RC checklist added
- [ ] all required tests green
- [ ] tag candidate reviewed
````

---

# `docs/dev_notes/checkpoints.md`

Doplň:

```md
## m9-v1.0-rc

Status:
- release notes added
- RC checklist added
- cutover tag procedure documented

Next:
- run full CI
- create `v1.0.0-cutover` tag
```

---

# README doplnok

````md
## Release status

Current cutover target:

```text
v1.0.0-cutover
````

See:

* `docs/releases/v1.0.0-cutover.md`
* `docs/dev_notes/release_candidate_checklist.md`

````

---

# Definition of Done

Commit 30 je hotový, keď:

- release notes existujú
- RC checklist existuje
- readiness checklist odkazuje na release candidate
- README ukazuje cutover target

Po tomto je ďalší krok už len:

```bash
pytest tests/unit
pytest tests/integration
pytest tests/golden
git tag v1.0.0-cutover
````
