Skontroloval som `xfcp_test_09_targets.zip`.

```text
xfcp_test_09_targets.zip
SHA-256: d3c5609d6817df9c6bcba030ddd5b5cdaddab5c385d8bbf09ceb20f1055d96f5
```

## Verdikt

Funkčný RTL/simulačný smer je **správny**: `GET_TARGET_INFO` je implementovaný, simulačný test `T01–T30` prešiel a protokolovo to sedí na náš plán.

Ale projekt ako celok ešte **nie je konzistentne preklopný cez socfw/Quartus**, lebo build konfigurácia je stále z `xfcp_test_08_caps`.

Najväčší problém:

```text
project.yaml stále instancuje:
  xfcp_test_08_caps_top

ip/xfcp_test_08_caps_top.ip.yaml stále deklaruje:
  module: xfcp_test_08_caps_top

build/hal/files.tcl stále obsahuje:
  rtl/xfcp_test_08_caps_top.sv

ale v archíve existuje iba:
  rtl/xfcp_test_09_targets_top.sv
```

To znamená: **simulácia testuje nový `xfcp_test_09_targets_top`, ale socfw build/Quartus cesta je stale alebo nesprávna**.

---

# Čo je hotové dobre

## 1. `GET_TARGET_INFO` protokol je doplnený

V `xfcp_pkg.sv` sú nové opcodes:

```systemverilog
XFCP_OP_GET_TARGET_INFO       = 8'h03;
XFCP_OP_RESP_GET_TARGET_INFO  = 8'h04;
```

A helpery:

```systemverilog
xfcp_op_is_targets()
xfcp_resp_has_payload()
xfcp_resp_for_op()
```

To je presne podľa plánu.

---

## 2. `xfcp_target_info_adapter.sv` je dobrý prvý návrh

Adapter vracia 16-bajtový target descriptor:

```text
byte 0      target_type
byte 1      target_id
byte 2      flags
byte 3      reserved
byte 4..7   base_addr
byte 8..9   max_transfer
byte 10     align
byte 11     reserved
byte 12..15 4-char name
```

Pre neplatný index vracia:

```text
STATUS = BAD_ADDRESS
payload = zeros
```

To je správne správanie.

---

## 3. Simulácia prešla až po T30

Log ukazuje:

```text
ALL PASSED (0 failures)
```

Dôležité nové testy:

```text
T26 GET_TARGET_INFO index=0 -> SYSC
T27 GET_TARGET_INFO index=6 -> DIAG
T28 GET_TARGET_INFO index=7 -> STR0
T29 GET_TARGET_INFO index=8 -> BAD_ADDRESS
T30 GET_CAPS + GET_TARGET_INFO + AXIL READ interleaved
```

Toto je veľmi dobrá simulačná sada. Overuje aj routing/in-order správanie, nielen samotný payload.

---

# Čo nie je v poriadku

## 1. `project.yaml` je stále z testu 08

Aktuálne:

```yaml
project:
  name: xfcp_test_09_targets

modules:
  - instance: xfcp_test_08_caps_top
    type: xfcp_test_08_caps_top
```

Má byť:

```yaml
modules:
  - instance: xfcp_test_09_targets_top
    type: xfcp_test_09_targets_top
```

Inak `socfw build` negeneruje správny `soc_top.sv`.

---

## 2. IP YAML je stále `xfcp_test_08_caps_top.ip.yaml`

Adresár `ip/` obsahuje:

```text
ip/xfcp_test_08_caps_top.ip.yaml
```

a v ňom:

```yaml
ip:
  name: xfcp_test_08_caps_top
  module: xfcp_test_08_caps_top
```

Pre `xfcp_test_09_targets` má byť nový IP popis:

```text
ip/xfcp_test_09_targets_top.ip.yaml
```

s obsahom:

```yaml
ip:
  name: xfcp_test_09_targets_top
  module: xfcp_test_09_targets_top
```

A v artifacts synthesis musí pribudnúť:

```text
../rtl/xfcp/xfcp_target_info_adapter.sv
../rtl/xfcp_test_09_targets_top.sv
```

Nesmie tam zostať:

```text
../rtl/xfcp_test_08_caps_top.sv
```

---

## 3. `build/hal/files.tcl` je stale

Teraz obsahuje:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE "rtl/xfcp_test_08_caps_top.sv"
```

a nevidím tam:

```tcl
rtl/xfcp/xfcp_target_info_adapter.sv
rtl/xfcp_test_09_targets_top.sv
```

To znamená, že `build/` adresár je v archíve ešte z predchádzajúceho projektu. Treba ho pregenerovať po oprave `project.yaml` a IP YAML.

---

## 4. `Makefile hw-regression` netestuje targets

V `tools/test_hw.py` už existuje:

```text
--targets
```

a `run_target_info_test()` vie testovať celú 8-target tabuľku.

Ale `Makefile` má:

```makefile
test-uart:
	cd tools && python3 test_hw.py \
	  --uart $(UART_PORT) --baud $(UART_BAUD) \
	  --caps --rw --stream --diag --repeat $(TEST_REPEAT)

test-udp:
	cd tools && python3 test_hw.py \
	  --udp $(FPGA_IP):$(XFCP_UDP_PORT) \
	  --caps --rw --stream --diag --repeat $(TEST_REPEAT)
```

Chýba:

```text
--targets
```

Čiže aj keby HW regresia prešla, zatiaľ by **neoverila GET_TARGET_INFO**.

Má byť:

```makefile
test-uart:
	cd tools && python3 test_hw.py \
	  --uart $(UART_PORT) --baud $(UART_BAUD) \
	  --caps --targets --rw --stream --diag --repeat $(TEST_REPEAT)

test-udp:
	cd tools && python3 test_hw.py \
	  --udp $(FPGA_IP):$(XFCP_UDP_PORT) \
	  --caps --targets --rw --stream --diag --repeat $(TEST_REPEAT)
```

---

## 5. Status dokument je skopírovaný z `xfcp_test_08_caps`

Súbor sa volá:

```text
XFCP_TEST_09_TARGETS_STATUS.md
```

ale obsah začína:

```text
# XFCP_TEST_08_CAPS — Status
```

a stále hovorí o:

```text
xfcp_lib_v1_2_caps_pass
T01–T25
GET_CAPS
```

Lenže aktuálny projekt je už:

```text
xfcp_test_09_targets
GET_TARGET_INFO
T01–T30
proto_minor=2
caps_flags=0x0F
```

Tento status treba prepísať, inak bude zavádzať.

---

# Aktuálny stav projektu podľa mňa

```text
RTL návrh GET_TARGET_INFO:       dobrý
Simulácia T01–T30:               PASS
Python podpora --targets:        pripravená
Makefile HW regression:          neúplná, netestuje --targets
socfw/project/IP konfigurácia:   nesprávna, stále test_08
Quartus build report pre test_09: chýba
HW overenie test_09:             ešte nedoložené
```

Čiže tento snapshot je:

```text
xfcp_test_09_targets_sim_pass
```

ale ešte nie:

```text
xfcp_lib_v1_3_targets_pass
```

---

# Čo opraviť teraz

## Krok 1 — opraviť IP YAML

Premenuj:

```text
ip/xfcp_test_08_caps_top.ip.yaml
```

na:

```text
ip/xfcp_test_09_targets_top.ip.yaml
```

a zmeň minimálne:

```yaml
ip:
  name: xfcp_test_09_targets_top
  module: xfcp_test_09_targets_top
```

V artifacts doplniť:

```text
../rtl/xfcp/xfcp_target_info_adapter.sv
../rtl/xfcp_test_09_targets_top.sv
```

a odstrániť starý top:

```text
../rtl/xfcp_test_08_caps_top.sv
```

---

## Krok 2 — opraviť `project.yaml`

Zmeniť:

```yaml
- instance: xfcp_test_08_caps_top
  type: xfcp_test_08_caps_top
```

na:

```yaml
- instance: xfcp_test_09_targets_top
  type: xfcp_test_09_targets_top
```

---

## Krok 3 — pregenerovať build

Potom spustiť:

```bash
socfw build project.yaml
```

A skontrolovať:

```bash
grep -R "xfcp_test_09_targets_top" build/rtl/soc_top.sv build/hal/files.tcl
grep -R "xfcp_target_info_adapter" build/hal/files.tcl
```

Očakávanie:

```text
build/rtl/soc_top.sv instancuje xfcp_test_09_targets_top
build/hal/files.tcl obsahuje xfcp_target_info_adapter.sv
build/hal/files.tcl obsahuje xfcp_test_09_targets_top.sv
```

---

## Krok 4 — opraviť Makefile HW regresiu

Doplniť `--targets` do `test-uart` a `test-udp`.

Potom očakávaný test bude mať okrem `GET_CAPS` aj:

```text
GET_TARGET_INFO:
  [0] SYSC AXIL
  [1] UART AXIL
  [2] OUT_ AXIL
  [3] OUT_ AXIL
  [4] OUT_ AXIL
  [5] SEG7 AXIL
  [6] DIAG AXIL
  [7] STR0 STREAM
  [8] BAD_ADDRESS
```

---

## Krok 5 — Quartus compile

Po pregenerovaní buildu:

```bash
make compile
```

alebo tvoj štandardný flow.

Bez tohto nemáme reálny STA pre `xfcp_test_09_targets`.

Cieľ:

```text
CLK125 WNS >= 0
TNS = 0
ETH_RXC PASS
```

---

## Krok 6 — HW regresia

Po timing PASS:

```bash
make program
make hw-regression
```

Očakávaný výsledok bude vyšší než 41/41, lebo pribudne target table test.

Hrubý odhad počtu:

```text
Slot scan:        21
GET_CAPS:          3
GET_TARGET_INFO:  8*3 + 1 = 25
R/W:               5
STREAM:           12
Ping:              1
--------------------------------
spolu okolo:      67 test bodov / transport
```

Teda približne:

```text
UART ~67/67
UDP  ~67/67
```

---

# Čo je ešte architektonicky dobré doplniť

## 1. `GET_CAPS` teraz správne signalizuje TARGETS

V sim logu vidno:

```text
proto_minor = 2
caps_flags  = 0x0F
```

To znamená:

```text
HAS_AXIL
HAS_STREAM
HAS_CAPS
HAS_TARGETS
```

To je správne pre `xfcp_test_09_targets`.

## 2. Target table formát je dobrý ako v1

Pre aktuálny rozsah úplne stačí:

```text
type, id, flags, base, max_transfer, align, name
```

Neskôr pri AXI-Full pridáme typ:

```text
0x03 = MEM / AXI_FULL
```

a target table sa iba rozšíri o ďalší riadok.

---

# Odporúčané označenie po oprave

Teraz by som to označil:

```text
xfcp_test_09_targets_sim_pass
```

Po oprave project/IP/Makefile, timing PASS a HW PASS:

```text
xfcp_lib_v1_3_targets_pass
```

---

## Záver

Projekt je funkčne na dobrej ceste: `GET_TARGET_INFO` je navrhnutý správne a simulácia `T01–T30` prešla.

Ale aktuálny ZIP má vážny integračný nesúlad:

```text
simulácia = testuje xfcp_test_09_targets_top
socfw/Quartus build = stále smeruje na xfcp_test_08_caps_top
Makefile HW regression = netestuje --targets
STATUS = stále obsahovo xfcp_test_08_caps
```

Najbližšie neriešiť AXI-Full. Najprv uzavrieť `xfcp_test_09_targets` poriadne:

```text
1. opraviť project.yaml
2. opraviť IP YAML
3. pregenerovať build/
4. doplniť --targets do hw-regression
5. prekompilovať Quartus
6. spustiť HW UART+UDP regresiu
7. až potom tagovať xfcp_lib_v1_3_targets_pass
```

Potom bude target discovery míľnik čistý a môžeme bezpečne pokračovať na AXI-Full.
