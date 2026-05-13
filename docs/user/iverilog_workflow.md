# Simulation s iverilog — pracovný postup

Tento návod popisuje ako simulovať projekty budované pomocou `socfw` frameworku:
od inštalácie nástrojov cez filozofiu testovania až po konkrétnu ukážku s projektom `seven_seg_static`.

---

## Nástroje

### Povinné

| Nástroj | Účel | Inštalácia |
|---|---|---|
| **iverilog** | kompilátor SystemVerilog/Verilog | `dnf install iverilog` / `apt install iverilog` |
| **vvp** | simulačný runtime (súčasť iverilog) | (inštaluje sa spolu) |

### Voliteľné

| Nástroj | Účel | Inštalácia |
|---|---|---|
| **GTKWave** | prezeranie VCD vĺn | `dnf install gtkwave` / `apt install gtkwave` |
| **Verilator** | rýchla kompilácia pre dlhé simulácie | `dnf install verilator` |

```sh
# Fedora / RHEL
sudo dnf install iverilog gtkwave

# Ubuntu / Debian
sudo apt install iverilog gtkwave

# macOS
brew install icarus-verilog gtkwave
```

---

## Filozofia simulácie v hardvéri

Simulácia HDL sa líši od unit testov v softvéri v jednej zásadnej veci:
**čas je prvotriedy**. Každé tvrdenie musí brať do úvahy, kedy nastane.

### Tri úrovne testovania

```
┌─────────────────────────────────────────────────────────────┐
│  Systémová simulácia (tb_soc_top.sv)                        │
│  ─ testuje celý soc_top (generovaný rámcom)                 │
│  ─ smoke test: reset, bez X/Z, základné výstupy             │
│  ─ pomalé (reálny takt = 20 ns → 300 000 cyklov = 6 ms sim) │
├─────────────────────────────────────────────────────────────┤
│  Integračná simulácia                                        │
│  ─ testuje kombináciu 2–3 modulov                            │
│  ─ medzimodulová komunikácia, protokoly                      │
├─────────────────────────────────────────────────────────────┤
│  Unit simulácia (tb_<modul>_unit.sv)                         │
│  ─ testuje jeden modul priamo                                │
│  ─ malé parametre → rýchly beh                               │
│  ─ overuje dekódery, FSM, timing                             │
└─────────────────────────────────────────────────────────────┘
```

### Základné princípy

**Čas je explicitný.** Stimulus sa aplikuje pred hranou hodín, samotné overenie po hraně:
```systemverilog
input_a = 5;
@(posedge clk); #1;    // +1ns po hrane, FF output je ustálený
assert(output_b == 10);
```

**Malé parametre pre rýchle unit testy.** Modul s `CLOCK_FREQ_HZ=50_000_000` a
`DIGIT_REFRESH_HZ=500` má `TicksPerDigit=100 000` — príliš veľa na unit test.
S `CLOCK_FREQ_HZ=30, DIGIT_REFRESH_HZ=1` → `TicksPerDigit=30` pokryje celý cyklus
za 90 taktov.

**`$error` namiesto `$display`.** iverilog rozlišuje `$error` (počíta sa ako chyba,
vvp exituje s nenulou) od `$display` (iba informácia). Pre asertácie vždy `$error`.

**VCD len keď treba.** Pre 10M-cyklové simulácie vypnite VCD (`--no-vcd`) — súbor
môže byť gigabajtov. Zapnite ho len pri ladení konkrétneho okna.

---

## Frameworkový pracovný postup

### Automaticky generovaný testbench

`socfw build` vždy generuje `build/sim/tb_soc_top.sv` — základný smoke test:

- hodinový signál z `timing_config.yaml`
- reset z board deskriptora (polarita, názov portu)
- 1 000 taktov, `$dumpvars`, `$display("SIM OK")`

Spustenie:
```sh
socfw simulate project.yaml --out build
```

### Vlastný testbench (odporúčané)

Umiestnite vlastný testbench do `tb/` v adresári projektu:

```
my_project/
  tb/
    tb_soc_top.sv        ← systémový test, nahrádza auto-generovaný
    tb_my_module_unit.sv ← unit test pre konkrétny modul
```

`TestbenchStager` skopíruje všetky `.sv` súbory z `tb/` do `build/sim/` pred simuláciou.
`tb_soc_top.sv` prepíše auto-generovaný.

```sh
socfw simulate project.yaml --out build     # spustí tb_soc_top.sv
```

Unit testbench musíte spustiť manuálne (nie je integrovaný do `socfw simulate`):
```sh
# kompilácia unit testu priamo
iverilog -g2012 -s tb_seven_seg_unit \
  -o build/sim/unit.vvp \
  examples/seven_seg_static/rtl/segment/seven_seg_mux.sv \
  examples/seven_seg_static/tb/tb_seven_seg_unit.sv

vvp build/sim/unit.vvp
```

---

## Ukážka: `seven_seg_static`

Projekt zobrazuje statické „000" na trojcifernom 7-segmentovom displeji so spoločnou anódou (CA).

**Parametre:**
- `CLOCK_FREQ_HZ = 50 000 000`, `DIGIT_REFRESH_HZ = 500` → `TicksPerDigit = 100 000`
- Jeden plný mux cyklus (3 číslice) = 300 000 taktov ≈ 6 ms simulačného času

### Krok 1: Build

```sh
cd examples/seven_seg_static
socfw build project.yaml --out build
```

Vygeneruje:
```
build/rtl/soc_top.sv
build/sim/tb_soc_top.sv    ← auto-generovaný smoke test
build/sim/files.f
```

### Krok 2: Overenie auto-generovaného testbenchu

```sh
socfw simulate project.yaml --out build
```

Očakávaný výstup:
```
[sim] build/sim/tb_soc_top.sv
[sim] build/sim/files.f
SIM OK
[vcd] build/sim/wave.vcd
```

### Krok 3: Vlastný systémový testbench

Súbor `tb/tb_soc_top.sv` obsahuje:
- overenie, že `ONB_DIG` a `ONB_SEG` nie sú `X/Z` po resete
- kontrolu, že CA displej nikdy neaktivuje viac ako jeden digit súčasne
- sledovanie, že všetky 3 číslice boli aktivované počas 310 000 taktov

```sh
# Framework skopíruje tb/tb_soc_top.sv → build/sim/tb_soc_top.sv
socfw simulate project.yaml --out build
```

### Krok 4: Unit test priamo na `seven_seg_mux`

```sh
iverilog -g2012 -s tb_seven_seg_unit \
  -o build/sim/unit.vvp \
  rtl/segment/seven_seg_mux.sv \
  tb/tb_seven_seg_unit.sv

vvp build/sim/unit.vvp
```

Očakávaný výstup:
```
T1 reset: digit_sel=111 segment_sel=FF
T2 digit=0 OK seg=C0
T2 digit=1 OK seg=F9
T2 digit=2 OK seg=A4
...
T2 digit=F OK seg=8E
T3 dot: segment_sel=40 OK (DP=0)
T4 digit 0 window OK: digit_sel=110 seg=C0
T4 digit 1 active: digit_sel=101 seg=F9 OK
T4 digit 2 active: digit_sel=011 seg=A4 OK
T4 wrap to digit 0 OK: digit_sel=110
SIM OK — unit tests passed
```

### Krok 5: Analýza vĺn

```sh
gtkwave build/sim/wave.vcd
```

Čo hľadať:
- `ONB_DIG` — CA dispej: bit = 0 znamená aktívna číslica, vzor sa cykluje `110 → 101 → 011 → 110`
- `ONB_SEG` — segmenty: `C0` = cifra 0, `F9` = cifra 1, `A4` = cifra 2, `FF` = všetko zhasnuté

---

## Kódovanie segmentov (CA, bez bodky)

| Cifra | Hex | Binárne (DP,G,F,E,D,C,B,A) |
|-------|-----|---------------------------|
| 0     | C0  | 1100_0000                 |
| 1     | F9  | 1111_1001                 |
| 2     | A4  | 1010_0100                 |
| 3     | B0  | 1011_0000                 |
| 4     | 99  | 1001_1001                 |
| 5     | 92  | 1001_0010                 |
| 6     | 82  | 1000_0010                 |
| 7     | F8  | 1111_1000                 |
| 8     | 80  | 1000_0000                 |
| 9     | 90  | 1001_0000                 |

DP (desatinná bodka) = bit 7: `0` = rozsvietená, `1` = zhasnutá (CA).

---

## Bežné problémy

### `ERROR: Unknown module type: soc_top`

Súbor `soc_top.sv` nie je v `files.f` alebo ste spustili iverilog bez neho:
```sh
iverilog -g2012 -s tb_soc_top -o sim.vvp -f build/sim/files.f
```
Uistite sa, že ste najskôr spustili `socfw build`.

### `X/Z` na výstupoch po resete

Príčiny:
1. Reset je synchronný, ale testbench neuplatnil reset na dostatočný počet cyklov.
   Riešenie: `repeat(10) @(posedge clk);` pred deassertom.
2. Port nie je zapojený v `soc_top.sv` (floating input).
   Riešenie: skontrolujte `build/rtl/soc_top.sv`, framework by mal tie-off-ovať nezapojené vstupy.

### `vvp: simulation failed` (SIM003)

vvp exitoval s chybou — hľadajte `$error` výstupy v konzole alebo zásobník z `$dumpvars`.

### Príliš veľký VCD súbor

Vypnite VCD pre dlhé simulácie:
```sh
socfw simulate project.yaml --out build --no-vcd
```

---

## Rýchla referencia

```sh
# Build + systémová simulácia
socfw simulate project.yaml --out build

# Bez VCD (rýchlejší pre dlhé simulácie)
socfw simulate project.yaml --out build --no-vcd

# Unit test manuálne (nie cez framework)
iverilog -g2012 -s <top_tb> -o build/sim/unit.vvp <dut.sv> <tb.sv>
vvp build/sim/unit.vvp

# Prezeranie vĺn
gtkwave build/sim/wave.vcd
```
