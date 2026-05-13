Potom, keď bude fungovať:

```text
ENABLE_DATA_ISLAND=1
obraz bez posunu
AVI InfoFrame stabilný
TMDS PHY časovo uzavretý
```

tak ďalší cieľ je prejsť z „jeden AVI packet“ na **plnohodnotný HDMI packet engine**.

## 1. Packet arbiter ako centrálna vrstva

Namiesto toho, aby `hdmi_tx_core` priamo posielal iba AVI, vytvor blok:

```text
hdmi_packet_arbiter
```

Ten bude vyberať, ktorý packet sa pošle do `data_island_formatter`.

Cieľová štruktúra:

```text
gcp_packet_builder
avi_infoframe_builder
audio_infoframe_builder
acr_packet_builder
audio_sample_packetizer
        ↓
hdmi_packet_arbiter
        ↓
data_island_formatter
        ↓
TERC4
        ↓
hdmi_channel_mux
```

Prvá verzia arbitra môže byť veľmi jednoduchá:

```text
každý frame:
  1. GCP
  2. AVI InfoFrame
```

Ešte bez audio.

---

## 2. GCP — General Control Packet

Toto by bol ďalší packet po AVI.

Pre základný režim:

```text
RGB 8-bit
no deep color
no AVMUTE
```

bude GCP veľmi jednoduchý, ale overí, že packet systém vie poslať viac packetov za frame.

Cieľ:

```text
v jednom frame sa pošle GCP aj AVI
```

Ak toto funguje, máš pripravenú infraštruktúru pre audio pakety.

---

## 3. ACR — Audio Clock Regeneration

Potom pridaj ACR packet.

Bez ACR nebude HDMI sink vedieť správne rekonštruovať audio clock.

Prvý cieľ:

```text
48 kHz audio
2 channels
N = 6144
CTS podľa pixel clocku
```

Na začiatku môžeš použiť tabuľkové hodnoty pre tvoje režimy, napríklad:

```text
640×480
800×600
720p
```

Neskôr môžeš doplniť výpočet alebo meranie CTS.

---

## 4. Audio InfoFrame

Potom zapoj Audio InfoFrame z `infoframe_builder`.

Prvá konfigurácia:

```text
LPCM
2 channels
48 kHz
16 alebo 24 bit
speaker allocation default
```

Audio InfoFrame by sa mal posielať periodicky alebo pri zmene audio konfigurácie.

---

## 5. Audio sample packetizer

Až keď máš:

```text
GCP
AVI
ACR
Audio InfoFrame
```

potom pridaj reálne audio vzorky.

Najprv bez I2S. Použi interný generátor:

```text
1 kHz test tone
48 kHz sample rate
2 channels
16-bit PCM
```

Bloky:

```text
audio_tone_generator
    ↓
audio_sample_packetizer
    ↓
hdmi_packet_arbiter
```

Až keď toto hrá na monitore/TV, pridaj I2S:

```text
i2s_rx
    ↓
audio_async_fifo
    ↓
audio_sample_packetizer
```

---

## 6. EDID/DDC

Keď máš základné video + audio, až potom rieš univerzálnosť:

```text
DDC I2C master
EDID read
CEA/CTA extension parser
supported video modes
supported audio formats
speaker allocation
preferred timing
```

Bez EDID vieš najprv fungovať s fixným módom. EDID je dôležitý, ale nie je prvý blocker pre vlastný HDMI TX.

---

## 7. Potom rozšírenia

Až po základnom HDMI:

```text
YCbCr 4:4:4 / 4:2:2
limited/full range switching
SPD InfoFrame
Vendor Specific InfoFrame
deep color
multi-channel audio
44.1 kHz / 96 kHz audio
CEC
```

HDCP a FRL by som do tohto projektu vôbec nedával, kým nie je úplne stabilný základný TMDS HDMI.

---

## Praktická roadmapa

```text
A. Stabilný HDMI video + AVI
B. Packet arbiter
C. GCP + AVI v jednom frame
D. ACR packet
E. Audio InfoFrame
F. Audio sample packetizer s interným tónom
G. I2S vstup + audio FIFO
H. EDID/DDC
I. ďalšie formáty a rozšírenia
```

Najbližší „potom“ po oprave AVI timing-u je teda: **packet arbiter + GCP**.
