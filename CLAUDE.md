# Projekt Overview

Tento repository obsahuje:
- **socfw**: Python framework pre HW vývoj
- **examples/**: SystemVerilog aplikácie
- Interné build/simulačné nástroje

**Aktuálny cieľ:** Vývoj full HDMI (projekt `vga_test_05`).
- **RTL:** `examples/vga_test_05/rtl`
- **Simulácie:** `examples/vga_test_05/sim`
- **Kontext:** Vždy referuj `HDMI_STATUS.md` pre aktuálny stav a `rtl/navrhy/` pre komentáre dizajnéra.

---

# Vývojové pravidlá

## 1. SystemVerilog (Prísne pravidlá pre RTL a SVA)
Všetok generovaný kód musí byť syntetizovateľný v **Intel Quartus Prime 25.1 Lite** a kompatibilný so **svlint** a **verilator**.

### Formátovanie a Štruktúra
- **Odsadzovanie:** 2 medzery, max 100 znakov na riadok, žiadne medzery na konci riadkov (trailing spaces).
- **Koniec súboru:** Súbor musí končiť práve jedným prázdnym riadkom (newline).
- **Hlavička súboru:** Povinný Doxygen header (`@file`, `@brief`, `@param`, `@details`).
- **Nettype & Guards:**
  1. Doxygen hlavička
  2. `` `default_nettype none ``
  3. Include guards (`` `ifndef MOD_NAME_SV``, `` `define MOD_NAME_SV``, `` `endif ``)

### RTL Kódovací štandard
- **Porty a inštancie:** Používaj výhradne ANSI-style deklarácie portov. Pri inštanciách modulov vždy používaj pomenované porty a parametre (`.port(signal)`).
- **Šírka a priradenia:** Vždy používaj explicitnú šírku (napr. `1'b0`). Pre unsized nulu použi `'0`.
- **Logika:**
  - `always_comb` -> používaj blocking priradenia (`=`).
  - `always_ff` -> používaj non-blocking priradenia (`<=`).
- **Reset:** Asynchrónny, aktívny v nule, pomenovaný `rst_ni`.
- **Case statements:** Vždy musia obsahovať `default` vetvu a byť syntetizovateľné.
- **Komentáre:** Iba ASCII znaky.

### Zakázané konštrukcie (Strictly Forbidden)
- `defparam`, `#delay`, `wait`, `fork/join`
- `class`, `queue`, `mailbox`
- System tasks v RTL (`$psprintf`, `$random`, atď.)

### Naming Conventions
- **Moduly:** `snake_case`, názov súboru sa musí zhodovať s názvom modulu (`<module>.sv`).
- **Porty/Signály:** `i_*` (inputs), `o_*` (outputs), `r_*` (registers), `w_*` (wires).
- **Parametre:** `CamelCase` alebo `ALL_CAPS`.
- **Localparams:** `ALL_CAPS`.
- **Typedefs (enum/struct/union):** Prípona `_t` alebo `_e`.
- **Makrá:** `UPPER_SNAKE_CASE`.
- **Generate bloky:** Predpona `g_` alebo `gen_`.

---

## 2. Python Framework (`socfw`)
- Framework kód sa nachádza v `./socfw`.
- **DRY (Don't Repeat Yourself):** Pri implementácii vždy najprv hľadaj existujúcu abstraction layer a reutilizuj framework utility. Nevytváraj duplicity.
- Analyzuj "Python architectural smell" a nevyužité abstrakčné vrstvy.

---

## 3. Git Workflow
- Pred zmenami **vždy** analyzuj `git diff`.
- Vytváraj malé, logické commity.
- Generuj výstižné commit správy.
- **NIKDY** nerob rebase bez explicitného povolenia od používateľa.

---

## 4. Dokumentácia
Každý nový SystemVerilog modul musí obsahovať:
- Markdown dokumentáciu.
- Interface popis (tabuľka portov/parametrov).
- Timing assumptions.
- Block diagram description.
- Aktualizuj hlavnú dokumentáciu pri akejkoľvek zmene API.

---

## 5. Testovanie a Validácia
- **Po každej zmene aktívne spusti:**
  1. Simulácie (hľadaj mismatches a race conditions).
  2. Linter (svlint).
  3. Pytest pre framework.
- Vždy vyrieš failing testy a linting problémy pred pokračovaním (analyzuj dead code, invalid assumptions).

---

## 6. Základný AI Workflow
Pri akejkoľvek požiadavke dodržuj tento postup:
1. **Analyzuj problém** a prečítaj si kontextové súbory.
2. **Navrhni plán** úprav/implementácie.
3. **Počkaj na potvrdenie** plánu.
4. **Implementuj** zmeny podľa pravidiel vyššie.
5. **Validuj** (Lint, Sim, Tests).
6. **Vytvor/Uprav dokumentáciu**.
