Áno, tento `soc_top.sv` už konečne zodpovedá testu **2A** a výsledok `FPGA real PASS` je veľmi dôležitý.

V inštancii `vga_hdmi_tx` máš:

```systemverilog
.ENABLE_ACR_PACKET(0),
.ENABLE_AUDIO(0),
.ENABLE_AUDIO_INFOFRAME(0),
.ENABLE_AUDIO_SAMPLE(0),
.ENABLE_AVI_PACKET(0),
.ENABLE_DATA_ISLAND(1),
.ENABLE_GCP_PACKET(0)
```

To znamená:

```text
DATA=1
AUDIO=0
GCP=0
AVI=0
ACR=0
AudioIF=0
Sample=0
```

Čiže presne:

```text
2A: DATA=1, AUDIO=0, GCP=0, AVI=0
```

## Záver z 2A PASS

Týmto je prakticky potvrdené:

```text
ENABLE_DATA_ISLAND=1 sám osebe nerozbíja video.
Scheduler/mux/video cesta je na HW v poriadku, pokiaľ sa nevkladá reálny packet.
Data-island FSM bez pending packetu negeneruje neplatný TMDS tok.
Parametre ENABLE_GCP_PACKET / ENABLE_AVI_PACKET už správne prechádzajú do soc_top.
```

Toto je veľký posun oproti pôvodnému #2 fail.

## Čo to vylučuje

2A PASS vylučuje ako hlavnú príčinu:

```text
samotné ENABLE_DATA_ISLAND=1
základné napojenie hblank/blank_remaining
mux rozbitý iba prítomnosťou data-island podpory
generátor topu ignorujúci nové parametre
```

## Čo testovať ďalej

Teraz pokračuj presne:

```text
2B: DATA=1, AUDIO=0, GCP=1, AVI=0
2C: DATA=1, AUDIO=0, GCP=0, AVI=1
2D: DATA=1, AUDIO=0, GCP=1, AVI=1
```

### 2B konfigurácia

```systemverilog
.ENABLE_DATA_ISLAND(1),
.ENABLE_AUDIO(0),
.ENABLE_GCP_PACKET(1),
.ENABLE_AVI_PACKET(0),
.ENABLE_ACR_PACKET(0),
.ENABLE_AUDIO_INFOFRAME(0),
.ENABLE_AUDIO_SAMPLE(0)
```

Ak 2B zlyhá, problém je GCP path.

### 2C konfigurácia

```systemverilog
.ENABLE_DATA_ISLAND(1),
.ENABLE_AUDIO(0),
.ENABLE_GCP_PACKET(0),
.ENABLE_AVI_PACKET(1),
.ENABLE_ACR_PACKET(0),
.ENABLE_AUDIO_INFOFRAME(0),
.ENABLE_AUDIO_SAMPLE(0)
```

Ak 2C zlyhá, problém je AVI InfoFrame path.

### 2D konfigurácia

```systemverilog
.ENABLE_DATA_ISLAND(1),
.ENABLE_AUDIO(0),
.ENABLE_GCP_PACKET(1),
.ENABLE_AVI_PACKET(1),
.ENABLE_ACR_PACKET(0),
.ENABLE_AUDIO_INFOFRAME(0),
.ENABLE_AUDIO_SAMPLE(0)
```

Ak 2B aj 2C prejdú, ale 2D zlyhá, problém je sekvencovanie GCP+AVI alebo rozloženie viacerých packetov vo frame.

## Zapíš do TEST_MATRIX.md

Do 2A:

```text
PASS — stable image; no packets inserted; confirms DATA_ISLAND enable path does not corrupt video by itself.
```

Aktuálny stav rozhodovacieho stromu:

```text
#1  PASS  DVI baseline
#2  FAIL  GCP+AVI no signal
#2A PASS  DATA island enabled, no packets
```

Takže chyba už je zúžená na:

```text
GCP packet
AVI packet
alebo kombinácia GCP+AVI
```

Pokračuj 2B.
