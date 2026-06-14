Skontroloval som aktuálny `xfcp_test_09_targets(1).zip`.

```text
xfcp_test_09_targets(1).zip
SHA-256: d8a1bc52a3ba01a6245a892f18359df924e1ebc60a72dad1fbdf56e46364507f
```

## Verdikt

Progres je veľmi dobrý: predchádzajúce integračné chyby sú opravené a `GET_TARGET_INFO` je už reálne overené cez UART aj UDP.

Ale je tam jedna dôležitá poznámka: **funkčne je projekt PASS, ale timing formálne ešte nie**.

```text
Sim:        PASS, T01–T30, 142 checks, 0 failures
HW UART:    PASS 66/66
HW UDP:     PASS 66/66
DIAG:       bez chýb
Build cfg:  opravený na xfcp_test_09_targets_top
Timing:     FAIL, CLK125 WNS -0.150 ns
```

Takže by som stav označil ako:

```text
xfcp_test_09_targets = HW PASS, timing-open
```

Nie ešte ako úplne čistý release míľnik, ak chceme byť dôslední.

---

# Čo sa zlepšilo oproti minulému ZIP-u

Minule bol problém, že projekt bol len napoly preklopený z `xfcp_test_08_caps`. Teraz je to opravené.

## 1. `project.yaml` je už správny

Teraz instancuje:

```yaml
- instance: xfcp_test_09_targets_top
  type: xfcp_test_09_targets_top
```

To je správne.

## 2. IP YAML je už správny

Existuje:

```text
ip/xfcp_test_09_targets_top.ip.yaml
```

a obsahuje:

```yaml
ip:
  name: xfcp_test_09_targets_top
  module: xfcp_test_09_targets_top
```

Tiež správne.

## 3. Build už obsahuje nové súbory

`build/hal/files.tcl` už obsahuje:

```text
rtl/xfcp/xfcp_target_info_adapter.sv
rtl/xfcp_test_09_targets_top.sv
```

a `build/rtl/soc_top.sv` už instancuje:

```text
xfcp_test_09_targets_top
```

Čiže socfw/Quartus integračná cesta je už konzistentná.

## 4. Makefile už testuje target discovery

Do HW regresie už pribudlo:

```text
--targets
```

Teda HW test už nerobí iba caps/rw/stream, ale aj `GET_TARGET_INFO`.

To bol presne chýbajúci kus.

---

# Stav `GET_TARGET_INFO`

Toto je splnené veľmi dobre.

Protokol:

```text
GET_TARGET_INFO      opcode 0x03
RESP_GET_TARGET_INFO opcode 0x04
```

Response payload má 16 bajtov:

```text
target_type
target_id
flags
reserved
base_addr
max_transfer
align
reserved
name[4]
```

Tabuľka je:

```text
0: AXIL   SYSC  0xFF000000  128B  align 4
1: AXIL   UART  0xFF010000  128B  align 4
2: AXIL   OUT_  0xFF020000  128B  align 4
3: AXIL   OUT_  0xFF030000  128B  align 4
4: AXIL   OUT_  0xFF040000  128B  align 4
5: AXIL   SEG7  0xFF050000  128B  align 4
6: AXIL   DIAG  0xFF060000  128B  align 4
7: STREAM STR0  0x00000000  256B  align 4
8+: BAD_ADDRESS
```

`GET_CAPS` je tiež aktualizované:

```text
proto = 1.2
caps_flags = 0x0F
HAS_AXIL | HAS_STREAM | HAS_CAPS | HAS_TARGETS
```

To je presne v súlade s naším plánom: najprv `GET_CAPS`, potom konkrétna target tabuľka.

---

# Simulácia

Simulačný stav je veľmi dobrý:

```text
T01–T30 ALL PASSED
142 checks
0 failures
```

Nové testy sú správne zvolené:

```text
T26 GET_TARGET_INFO index 0 -> SYSC
T27 GET_TARGET_INFO index 6 -> DIAG
T28 GET_TARGET_INFO index 7 -> STR0
T29 GET_TARGET_INFO index 8 -> BAD_ADDRESS
T30 GET_CAPS + GET_TARGET_INFO + AXIL READ interleaved
```

T30 je obzvlášť dôležitý, lebo overuje, že nový TI backend nerozbil routing a order FIFO.

---

# HW progres

Status hovorí:

```text
UART: 66/66 PASS
UDP:  66/66 PASS
spolu: 132/132 PASS
```

Overené:

```text
Ping
Slot scan 7 slotov
GET_CAPS
GET_TARGET_INFO 0–7 + bad index
AXI-Lite LED R/W
AXI-Stream loopback 4/16/64/256B
DIAG clean
```

Toto je funkčne veľmi silný míľnik.

DIAG:

```text
rx_lost      0
rx_frame     0
rx_overrun   0
rx_bad_hdr   0
rx_drop      0
```

Čiže parser, recovery, transporty a backend routing sú čisté.

---

# Jediný vážny otvorený bod: timing

STA report:

```text
Slow 85C CLK125 setup:
  WNS = -0.150 ns
  TNS = -1.826 ns

ETH_RXC:
  WNS = +0.590 ns

Hold:
  CLK125 = +0.428 ns
  ETH_RXC = +0.449 ns
```

Toto je malé prekročenie, ale je to stále formálny timing FAIL.

Status to poctivo uvádza:

```text
HW pracuje správne, ale formalny timing closure nie je splneny.
```

S tým súhlasím.

## Kritická oblasť

Podľa STA nie je najhoršia cesta primárne v `xfcp_target_info_adapter`, ale v parser/input ceste:

```text
xfcp_arbiter_2to1 / arb_s0_valid_r alebo p0_remain_q
  -> xfcp_rx_parser.bytes_left_q[*]
```

To naznačuje, že pridanie TI backendu trochu zvýšilo tlak na routing/fabric, ale aktuálny najhorší timing je späť v prijímacej/payload parser ceste.

---

# Čo by som spravil teraz

## 1. Nepokračoval by som ešte na AXI-Full

Funkčne áno, projekt je super. Ale pred AXI-Full by som nechcel ťahať otvorený timing fail.

AXI-Full pridá ďalší backend, ďalšie muxy, ďalšie buffre a ďalšie status cesty. Ak teraz máme `-0.150 ns`, AXI-Full to pravdepodobne zhorší.

Takže ďalší míľnik by podľa mňa nemal byť ešte:

```text
xfcp_test_10_axifull
```

ale krátky fix míľnik:

```text
xfcp_test_09_targets_timing_fix
```

alebo commit v tejto vetve pred tagom release.

---

# Odporúčaný postup na timing fix

## Krok A — seed sweep

Keďže fail je iba:

```text
WNS -0.150 ns
TNS -1.826 ns
```

najprv by som spravil seed sweep.

```bash
for s in 1 2 3 4 5 6 7 8 9 10; do
  sed -i "s/set_global_assignment -name SEED .*/set_global_assignment -name SEED $s/" soc_top.qsf
  make compile
  echo "SEED $s"
  grep -A3 "Slow 1200mV 85C Model Setup 'CLK125'" output_files/soc_top.sta.summary
done
```

Ak niektorý seed dá aspoň:

```text
WNS >= +0.1 ns
```

tak by som ho použil a projekt uzavrel.

## Krok B — ak seed nepomôže, register slice medzi arbiter a parser

Najhoršia cesta ide z `xfcp_arbiter_2to1` do `xfcp_rx_parser.bytes_left_q`.

Preto by som zvážil 1-beat stream register slice medzi:

```text
xfcp_arbiter_2to1 output
  -> xfcp_fabric_endpoint/parser input
```

Čiže:

```text
u_arbiter.m_axis
  -> xfcp request stream register slice
  -> u_endpoint.xfcp_in
```

Musí zachovať:

```text
TDATA
TVALID
TREADY
TLAST
```

Toto by malo odrezať cestu:

```text
arb_s0_valid_r / p0_remain_q
  -> parser bytes_left_q
```

Cena: +1 cyklus latency na každý XFCP request. To je úplne v poriadku.

## Krok C — prípadne zjednodušiť parser `bytes_left_q` update

Ak nechceš pridávať slice pred endpoint, druhý smer je pozrieť `xfcp_rx_parser.sv` a staging `bytes_left_q`.

Ale register slice medzi arbiterom a parserom je čistejší a menej riskantný zásah.

---

# Ako by som označil aktuálny stav

Teraz by som ešte nedával finálny tag:

```text
xfcp_lib_v1_3_targets_pass
```

ak tým myslíme aj timing-clean.

Presnejšie označenie aktuálneho stavu:

```text
xfcp_lib_v1_3_targets_hw_pass_timing_open
```

Po timing fixe:

```text
xfcp_lib_v1_3_targets_pass
```

Ak však chceš tagovať podľa funkčného HW a timing riešiť až v ďalšom projekte, je to možné, ale ja by som to v názve tagu rozlíšil. Pri FPGA knižnici je timing PASS súčasť kvality.

---

# Stav voči roadmap

Roadmap progres:

```text
v0.9 STATUS:        hotové
v1.1 AXIS:          hotové
v1.2 CAPS:          hotové
v1.3 TARGETS:       funkčne hotové, timing ešte otvorený
v1.4 / v2 AXI-Full: nezačínať pred timing closure
```

Teda:

```text
funkčný progres: výborný
release progres: brzdený iba timingom
```

---

# Konkrétne najbližšie kroky

```text
1. Spustiť seed sweep.
2. Ak niektorý seed prejde, aktualizovať QSF/STATUS a tagovať.
3. Ak seed nepomôže, pridať stream register slice medzi arbiter a endpoint/parser.
4. Rerun sim T01–T30.
5. Rerun compile.
6. Rerun hw-regression UART+UDP.
7. Až potom tagovať xfcp_lib_v1_3_targets_pass.
```

---

## Záver

Projekt sa posunul správnym smerom. `GET_TARGET_INFO` je implementovaný a reálne overený:

```text
UART + UDP HW: 132/132 PASS
DIAG clean
Sim: 142 checks PASS
```

To je výborný výsledok.

Ale pred ďalším backendom by som uzavrel posledný formálny problém:

```text
CLK125 WNS -0.150 ns
```

Najbližšie teda nerobíme AXI-Full. Najbližšie robíme **timing closure pre `xfcp_test_09_targets`**, najprv seed sweep, potom prípadne register slice medzi arbiterom a parserom.
