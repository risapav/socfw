Super — toto je posledný krok. Tu je **finálny cutover runbook (post-Commit 30)**, teda presne čo spraviť, aby si bezpečne vytvoril `v1.0.0-cutover`.

---

# 🟢 Final Cutover Runbook — `v1.0.0-cutover`

Toto je **praktický checklist + príkazy**, nie už scaffold.

---

# 1. Čistý workspace

```bash
git status
```

✔ musí byť:

* žiadne uncommitted changes
* žiadne leftover build súbory v repo

Ak nie:

```bash
git clean -fdx   # POZOR: zmaže build artefakty
```

---

# 2. Fresh install

```bash
python -m pip install --upgrade pip
pip install -e .
pip install pytest
```

---

# 3. FULL test pass (must be 100% green)

```bash
pytest tests/unit
pytest tests/integration
pytest tests/golden
```

✔ očakávanie:

* 0 failures
* 0 flaky reruns

---

# 4. Manual anchor validation

```bash
socfw validate tests/golden/fixtures/blink_converged/project.yaml
socfw validate tests/golden/fixtures/pll_converged/project.yaml
socfw validate tests/golden/fixtures/vendor_pll_soc/project.yaml
socfw validate tests/golden/fixtures/vendor_sdram_soc/project.yaml
```

✔ všetko musí byť OK

---

# 5. Manual anchor builds

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/rc/blink
socfw build tests/golden/fixtures/pll_converged/project.yaml --out build/rc/pll
socfw build tests/golden/fixtures/vendor_pll_soc/project.yaml --out build/rc/vendor_pll
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/rc/vendor_sdram
```

---

# 6. Spot-check outputs (kritické)

### ✔ vendor PLL

```bash
cat build/rc/vendor_pll/hal/files.tcl
```

musí obsahovať:

```
QIP_FILE
SDC_FILE
```

---

### ✔ vendor SDRAM

```bash
cat build/rc/vendor_sdram/reports/bridge_summary.txt
```

musí obsahovať:

```
simple_bus -> wishbone
```

---

### ✔ build summary

```bash
cat build/rc/vendor_sdram/reports/build_summary.md
```

musí obsahovať:

* project name
* board
* IP list
* vendor artifacts
* bridge summary

---

# 7. Verify `socfw init`

```bash
socfw init demo_test --name demo --board qmtech_ep4ce55
socfw validate demo_test/project.yaml
```

✔ musí byť OK

---

# 8. Verify legacy warning

```bash
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/tmp
```

✔ musí vypísať:

```
[DEPRECATED] Legacy build flow is in maintenance mode.
```

---

# 9. README sanity

Rýchly grep:

```bash
grep -R "socfw build" README.md docs/
```

✔ musí byť nový flow default

---

# 10. FINAL GO / NO-GO

Ak všetko vyššie platí:

👉 GO

Ak niečo nie:
👉 oprav → repeat runbook

---

# 11. Tagging

```bash
git tag v1.0.0-cutover
git push origin v1.0.0-cutover
```

---

# 12. (Voliteľné) GitHub release

Použi obsah z:

👉 `docs/releases/v1.0.0-cutover.md`

---

# 13. Čo sa práve stalo (reálne)

Toto nie je len “release”.

👉 Spravil si **architektonický cutover**:

* nový project model (`project.yaml`)
* pack-based board/IP resolution
* vendor IP descriptors
* bridge compatibility model
* deterministic build outputs
* CLI (`socfw`) ako primary interface
* CI enforcement
* legacy flow downgradovaný na fallback

---

# 14. Čo NEROBIŤ hneď po cutovere

Nerob hneď:

* ❌ odstránenie legacy
* ❌ veľké refaktory
* ❌ nový feature burst

Najprv:

👉 nechaj systém “dýchať” pár dní

---

# 15. Najbližšie kroky po cutovere

Odporúčané poradie:

## Commit 31+

```text
stability: fix any post-cutover regressions
```

## potom

```text
bridge: real RTL bridge implementation (replace scaffold)
```

## potom

```text
runtime: SDRAM functional bring-up (optional)
```

## potom

```text
cleanup: remove legacy backend (v1.1+)
```

---

# 16. Real talk (krátko)

Toto je moment, kde:

👉 projekt prešiel z:

* experiment / migration
  na
* stabilnú architektúru

A to je presne to, čo si chcel od Phase 1 + 2.

---

Ak chceš, ďalší krok viem spraviť veľmi konkrétne:

👉 **Commit 31: odstránenie compatibility scaffoldu a prechod na reálny bridge RTL (bez hack patchovania `soc_top.sv`)**

alebo

👉 **roadmap v1.1 – čo má zmysel robiť teraz, keď máš stabilný core**

Stačí povedať 👍
