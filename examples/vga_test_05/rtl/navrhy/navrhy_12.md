Ďalej by som išiel v tomto poradí, bez skákania rovno na audio.

## 1. Stabilizovať aktuálny HDMI video + AVI stav

Najbližší krok je odstrániť posledné riziko okolo posunu obrazu pri `ENABLE_DATA_ISLAND=1`.

Konkrétne:

```text
packet_pending z VSYNC edge
    ↓ zmeniť na
packet_pending v bezpečnom vertical blanking okne
```

Teda nepúšťať AVI packet hneď na hrane `vsync`, ale až napríklad po niekoľkých riadkoch vo `vblank`.

Prakticky:

```text
frame_start_i → vynuluj vblank_line_counter
line_start_i && vblank_i → počítaj blanking riadky
vblank_line_counter == 4 → povol AVI packet
packet_start → zruš pending
```

Cieľ:

```text
ENABLE_DATA_ISLAND=1
farby správne
obraz neposunutý
monitor drží lock
AVI InfoFrame sa stále posiela
```

---

## 2. Simulačne overiť data-island timing

Pred ďalším rozširovaním by som spravil malý testbench pre `hdmi_tx_core`.

Overiť presne:

```text
DATA_PREAMBLE = 8 cyklov
DATA_GB_LEAD = 2 cykly
DATA_PAYLOAD = 32 cyklov
DATA_GB_TRAIL = 2 cykly
VIDEO_PREAMBLE = 8 cyklov
VIDEO_GB = 2 cykly
DATA_PAYLOAD nikdy nezasiahne do DE
packet_pop má presne 32 pulzov
```

Toto je dôležité, lebo keď pridáš viac packetov a audio, debug bude oveľa ťažší.

---

## 3. Doladiť PHY constraints

Keďže používaš `tmds_phy_ddr_aligned`, musíš mať korektne ošetrený vzťah:

```text
pix_clk → clk_x_i = 5× pix_clk
```

Nech to nie je len „funguje na stole“. V Quartuse treba skontrolovať SDC:

```tcl
set_multicycle_path -setup -from [get_clocks clk_pixel] -to [get_clocks clk_pixel5x] 5
set_multicycle_path -hold  -from [get_clocks clk_pixel] -to [get_clocks clk_pixel5x] 4
```

Názvy clockov treba upraviť podľa projektu. Cieľ je, aby Timing Analyzer naozaj kontroloval cestu z pixel-clock registrov do 5× PHY domény.

---

## 4. Pridať packet arbiter

Teraz máš v podstate jeden packet: AVI InfoFrame.

Pre plné HDMI potrebuješ blok:

```text
hdmi_packet_arbiter
```

Ten bude vyberať medzi:

```text
GCP
AVI InfoFrame
Audio InfoFrame
ACR
Audio Sample Packet
SPD/Vendor InfoFrame voliteľne
```

Prvá verzia nech je jednoduchá:

```text
každý frame:
  slot 1: GCP
  slot 2: AVI
```

Ešte bez audio.

---

## 5. Pridať GCP

Ďalší reálny HDMI packet by som pridal **GCP — General Control Packet**.

Pre základný RGB 8-bit režim môže byť payload jednoduchý, väčšinou nulový. Zmysel je hlavne overiť, že tvoj packet systém už zvláda viac než jeden packet za frame.

Cieľ:

```text
GCP + AVI cez rovnaký data_island_formatter
```

Nie dve špeciálne cesty.

---

## 6. Až potom audio infraštruktúra

Audio by som rozdelil na tri kroky:

### 6.1 ACR packet

Najprv Audio Clock Regeneration:

```text
N / CTS
```

Pre prvý režim:

```text
2ch LPCM
48 kHz
N = 6144
CTS podľa pixel clocku
```

Najprv môžeš použiť tabuľkové hodnoty pre konkrétny video mód.

### 6.2 Audio InfoFrame

Potom zapojiť Audio InfoFrame z `infoframe_builder`.

Napríklad:

```text
2 channels
LPCM
48 kHz
16/24 bit
```

### 6.3 Audio Sample Packetizer

Až potom reálne audio vzorky.

Na prvý test nepoužívaj I2S. Použi interný generátor:

```text
1 kHz tón
48 kHz sample rate
2ch
16 alebo 24 bit
```

Keď bude hrať interný tón, až potom pridaj:

```text
I2S receiver
audio FIFO
audio clock domain crossing
```

---

## Krátke poradie úloh

```text
1. AVI packet plánovať v bezpečnom vblank okne, nie na VSYNC hrane
2. Otestovať ENABLE_DATA_ISLAND=1 bez posunu obrazu
3. Simulácia scheduler + formatter + mux timing
4. SDC multicycle constraints pre TMDS PHY
5. Packet arbiter
6. GCP + AVI za frame
7. ACR N/CTS
8. Audio InfoFrame
9. Audio Sample Packetizer s interným tónom
10. I2S/audio FIFO
11. EDID/DDC parser
```

Najbližšia praktická úloha je teda: **upraviť plánovanie AVI packetu z `vsync edge` na bezpečné `vblank line` okno a overiť, či zmizne 2-riadkový posun.**
