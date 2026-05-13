# Projekt Overview

Tento repository obsahuje:
- Python framework pre HW vývoj, nazýva sa socfw
- SystemVerilog aplikácie v examples/
- interné build/sim tooling

# Vývojové pravidlá

## Framework
- Framework kód je v ./socfw
- Pri implementácii vždy reutilizuj existujúce framework utility
- Nevytváraj duplicity
- Najprv hľadaj existujúce abstraction layer

## SystemVerilog
- aktuálne pracujeme na vývoji vga_test_05
- cieľom je vyvinúť full hdmi
- RTL je v examples/vga_test_05/rtl
- Testbench je v examples/vga_test_05/sim
- Používaj SystemVerilog 2005 syntax
- Preferuj synthesizable code Quartus 25.1
- Používaj always_ff / always_comb
- Nepoužívaj blocking assignment v sequential logic
- Dodržuj naming:
  - i_* inputs
  - o_* outputs
  - r_* registers
  - w_* wires
- v examples/vga_test_05/HDMI_STATUS.md je aktuálny stav rozpracovania úlohy
- v examples/vga_test_05/rtl/navrhy/ je komenár nezávislého dizajnéra na vývoj hdmi

## Git workflow
- Pred zmenami analyzuj git diff
- Rob malé logické commity
- Generuj commit messages
- Nikdy nerebase bez explicitného povolenia

## Dokumentácia
- Každý nový modul musí mať:
  - markdown dokumentáciu
  - interface popis
  - timing assumptions
  - block diagram description
- Aktualizuj docs pri zmene API

## Bug hunting
- Aktívne analyzuj framework na:
  - dead code
  - race conditions
  - invalid assumptions
  - simulation mismatches
  - SV lint problémy
  - nevyužité abstraction layer
  - Python architectural smell

## Testovanie
- Po zmenách:
  - spusti simulácie
  - spusti lint
  - spusti pytest
- Fixni failing testy

## Workflow
Vždy:
1. analyzuj problém
2. navrhni plán
3. počkaj na potvrdenie
4. implementuj
5. validuj
6. vytvor dokumentáciu
