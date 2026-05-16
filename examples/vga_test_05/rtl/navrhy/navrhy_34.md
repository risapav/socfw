Rozumiem. Táto konfigurácia:

```yaml
ENABLE_DATA_ISLAND: 1
ENABLE_AUDIO: 0
ENABLE_ACR_PACKET: 0
ENABLE_AUDIO_INFOFRAME: 0
ENABLE_AUDIO_SAMPLE: 0
```

nie je „no packet“ režim. Je to stále:

```text
DATA island zapnutý
audio vypnuté
ACR/AudioIF/Sample vypnuté
GCP + AVI stále zapnuté
```

Čiže ak je obraz nefunkčný, zlyháva základná HDMI data-island cesta:

```text
GCP / AVI
alebo data preamble / guard band
alebo packet arbiter / scheduler / formatter / mux timing
```

Audio teraz nerieš. Treba rozbiť túto konfiguráciu na menšie prípady.

---

## Najprv dôležitá kontrola

V aktuálne nahratej sim sade, ktorú tu vidím, `Makefile` ešte nemá targety pre 2A–2D a nahratá RTL sada v `/mnt/data` neobsahuje `ENABLE_GCP_PACKET` / `ENABLE_AVI_PACKET`.

Ty ale píšeš, že commit `63b06e8` ich už pridal. To znamená, že lokálne v repozitári ich zrejme máš, ale sem si teraz nahral hlavne sim súbory alebo staršiu RTL sadu.

Pre ďalší debug používaj lokálny repozitár na commite:

```bash
git rev-parse --short HEAD
```

očakávanie:

```text
63b06e8
```

A over:

```bash
grep -R "ENABLE_GCP_PACKET\|ENABLE_AVI_PACKET\|valid_gcp_i\|valid_avi_i" \
  examples/vga_test_05/rtl/hdmi
```

Ak grep nič nenájde, build netestuje to, čo si myslíme.

---

# Testovací cieľ

Potrebuješ zistiť, či zlyháva:

```text
A. samotné zapnutie data-island FSM
B. GCP packet
C. AVI packet
D. sekvencia GCP + AVI
```

Preto testuj tieto štyri konfigurácie:

```text
2A: DATA=1, AUDIO=0, GCP=0, AVI=0
2B: DATA=1, AUDIO=0, GCP=1, AVI=0
2C: DATA=1, AUDIO=0, GCP=0, AVI=1
2D: DATA=1, AUDIO=0, GCP=1, AVI=1
```

---

# Interpretácia výsledkov

## 2A FAIL

```text
DATA=1, GCP=0, AVI=0 → no signal
```

Potom nie je problém v GCP/AVI obsahu. Problém je v tom, že samotná data-island logika mení TMDS stream aj bez paketov.

Hľadaj v:

```text
hdmi_period_scheduler
packet_pending_i
period_o / period_d1
channel_mux
video preamble / video guard band návrat
```

Očakávanie pre 2A v simulácii:

```text
nesmie sa objaviť DATA_PREAMBLE
nesmie sa objaviť DATA_GB_LEAD
nesmie sa objaviť DATA_PAYLOAD
nesmie sa objaviť DATA_GB_TRAIL
má to vyzerať ako čistý DVI/video režim + VIDEO_PREAMBLE/VIDEO_GB podľa návrhu
```

Ak sa v 2A objaví data period, je chyba v gatingu.

---

## 2A PASS, 2B FAIL

```text
GCP only zhadzuje monitor
```

Potom je problém v:

```text
gcp_packet_builder
GCP BCH/ECC
GCP payload byte order
GCP scheduling
```

---

## 2A PASS, 2C FAIL

```text
AVI only zhadzuje monitor
```

Potom je problém v:

```text
infoframe_builder AVI
AVI checksum
AVI BCH/ECC
AVI payload layout
AVI VIC/aspect/quantization field
```

---

## 2B PASS, 2C PASS, 2D FAIL

```text
samostatne GCP aj AVI idú, spolu zlyhajú
```

Potom je problém v:

```text
arbiter sequencing
príliš skorý frame_start preemption
dva pakety v jednom frame / hblank rozpočet
scheduler pending/start handshake
```

---

# Čo doplniť do simulácie

## 1. Samostatný TB alebo generický TB pre 2A–2D

Najjednoduchšie: rozšír `tb_hdmi_tx_core_32x10.sv` o parametre:

```systemverilog
parameter bit ENABLE_GCP_PACKET = 1;
parameter bit ENABLE_AVI_PACKET = 1;
```

a v DUT:

```systemverilog
.ENABLE_GCP_PACKET(ENABLE_GCP_PACKET),
.ENABLE_AVI_PACKET(ENABLE_AVI_PACKET),
```

Potom spúšťaj cez Makefile:

```makefile
tx_core_32x10_2a:
	$(VLOG) ... tb_hdmi_tx_core_32x10.sv
	$(VSIM) "tb_hdmi_tx_core_32x10 \
	  -G ENABLE_GCP_PACKET=0 \
	  -G ENABLE_AVI_PACKET=0"

tx_core_32x10_2b:
	$(VLOG) ... tb_hdmi_tx_core_32x10.sv
	$(VSIM) "tb_hdmi_tx_core_32x10 \
	  -G ENABLE_GCP_PACKET=1 \
	  -G ENABLE_AVI_PACKET=0"

tx_core_32x10_2c:
	$(VLOG) ... tb_hdmi_tx_core_32x10.sv
	$(VSIM) "tb_hdmi_tx_core_32x10 \
	  -G ENABLE_GCP_PACKET=0 \
	  -G ENABLE_AVI_PACKET=1"

tx_core_32x10_2d:
	$(VLOG) ... tb_hdmi_tx_core_32x10.sv
	$(VSIM) "tb_hdmi_tx_core_32x10 \
	  -G ENABLE_GCP_PACKET=1 \
	  -G ENABLE_AVI_PACKET=1"
```

Presná syntax `-G` závisí od toho, ako voláš `vsim`. Dôležitý princíp je, aby sa jeden testbench dal spustiť s rôznymi generikami.

---

## 2. Assertion pre 2A

V 2A musí platiť:

```systemverilog
if (!ENABLE_GCP_PACKET && !ENABLE_AVI_PACKET) begin
  if (w_period == HDMI_PERIOD_DATA_PREAMBLE ||
      w_period == HDMI_PERIOD_DATA_GB_LEAD  ||
      w_period == HDMI_PERIOD_DATA_PAYLOAD   ||
      w_period == HDMI_PERIOD_DATA_GB_TRAIL) begin
    $error("2A FAIL: data period generated while GCP/AVI disabled");
  end
end
```

Toto je kritické. Ak 2A sim prejde, ale HW zlyhá, problém môže byť v compile-time param propagation do `soc_top`.

---

## 3. Assertion pre 2B / 2C packet identity

V testbenchi počítaj `HB0` paketov:

```text
GCP HB0 = 0x00
AVI HB0 = 0x82
```

Pre 2B:

```text
GCP count > 0
AVI count = 0
```

Pre 2C:

```text
GCP count = 0
AVI count > 0
```

Pre 2D:

```text
GCP count > 0
AVI count > 0
```

Ak sa napríklad v 2A objaví GCP alebo AVI, tak debug parametre nefungujú.

---

# Čo overiť v generovanom `soc_top.sv`

Keďže píšeš, že „kombinácia generuje nefunkčný kód“, osobitne skontroluj, či `project.yaml` parametre skutočne prešli až do inštancie `vga_hdmi_tx`.

Po builde:

```bash
grep -n "vga_hdmi_tx" -A30 build/gen/soc_top.sv
```

Hľadaj:

```systemverilog
.ENABLE_DATA_ISLAND(1),
.ENABLE_AUDIO(0),
.ENABLE_GCP_PACKET(0 alebo 1),
.ENABLE_AVI_PACKET(0 alebo 1),
.ENABLE_ACR_PACKET(0),
.ENABLE_AUDIO_INFOFRAME(0),
.ENABLE_AUDIO_SAMPLE(0)
```

Ak tam `ENABLE_GCP_PACKET` / `ENABLE_AVI_PACKET` vôbec nie sú, tak testuješ stále starý variant `GCP+AVI`.

---

# HW test poradie

Nerob audio testy. Teraz len:

```text
2A
2B
2C
2D
```

Pre každý bitstream zapíš:

```text
commit hash
project.yaml parametre
monitor stav
poznámka
```

Tabuľka:

```text
2A DATA=1 AUDIO=0 GCP=0 AVI=0
2B DATA=1 AUDIO=0 GCP=1 AVI=0
2C DATA=1 AUDIO=0 GCP=0 AVI=1
2D DATA=1 AUDIO=0 GCP=1 AVI=1
```

---

# Najpravdepodobnejší výsledok

Podľa toho, že #1 DVI ide a #2 `GCP+AVI` dáva `no signal`, očakávam jednu z týchto možností:

## Možnosť A — 2A PASS, 2C FAIL

Najpravdepodobnejší vinník by bol AVI InfoFrame:

```text
checksum
VIC=0
aspect / quantization
BCH/ECC
payload mapping
```

## Možnosť B — 2A FAIL

Potom je zásadnejší problém: `ENABLE_DATA_ISLAND=1` mení stream aj bez paketov. Vtedy treba ísť po scheduler/mux timing.

## Možnosť C — 2A/2B/2C PASS, 2D FAIL

Potom treba riešiť arbiter sekvenciu a či sa dva frame pakety nesnažia poslať príliš blízko aktívneho videa.

---

# Praktický najbližší task

Sprav teraz toto:

```bash
git rev-parse --short HEAD
grep -R "ENABLE_GCP_PACKET\|ENABLE_AVI_PACKET\|valid_gcp_i\|valid_avi_i" examples/vga_test_05/rtl/hdmi
```

Potom buildni a otestuj:

```text
2A: DATA=1 AUDIO=0 GCP=0 AVI=0
```

Výsledok 2A je teraz najdôležitejší. Ak 2A zlyhá, packet obsah neriešime. Ak 2A prejde, pokračuje sa 2B a 2C.
