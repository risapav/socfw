Áno — toto nastavenie je veľmi zaujímavé, lebo máš **žiadne pakety**, ale obraz je posunutý / zelená čiara naľavo:

```yaml
ENABLE_DATA_ISLAND: 1
ENABLE_AUDIO: 0
ENABLE_ACR_PACKET: 0
ENABLE_AUDIO_INFOFRAME: 0
ENABLE_AUDIO_SAMPLE: 0
ENABLE_GCP_PACKET: 0
ENABLE_AVI_PACKET: 0
GCP_FRAME_PERIOD: 0
VBLANK_ONLY: 1
DEBUG_ISLAND_PHASES: 0
```

To zodpovedá režimu:

```text
2A: DATA island infra zapnutá, ale žiadny packet sa nemá vložiť.
```

Ak je pri tomto režime obraz síce viditeľný, ale posunutý doprava a s ľavou zelenou čiarou, tak to znamená:

```text
packet obsah nie je vinník,
ale samotné ENABLE_DATA_ISLAND=1 mení video period/pipeline alignment.
```

## Najdôležitejší podozrivý bod

V aktuálnom `hdmi_tx_core.sv` je explicitný komentár:

```systemverilog
// vga_de_i goes through vga_output_adapter (3 stages to de_r). Without
// alignment the VIDEO period switch leads valid TMDS by 5 symbols per line.
```

a scheduler používa:

```systemverilog
.de_i              (de_r),
.hblank_i          (hblank_rr),
.vblank_i          (vblank_r),
.blank_remaining_i (blank_remaining_rr),
```

Čiže časovanie scheduleru je odvodené od registrovaného `de_r`, ale zároveň od `blank_remaining_rr` a `hblank_rr`.

Tvoj symptom:

```text
zelená čiara na ľavom kraji
obraz akoby posunutý doprava
```

veľmi sedí na to, že `period_d1 == VIDEO` sa zapne o pár cyklov skôr alebo neskôr než reálne platné RGB dáta. Inými slovami:

```text
mux začne púšťať VIDEO ešte pred prvým správnym pixelom,
alebo prvé pixely aktívneho riadku nahradí guard/control symbolmi.
```

Pri `ENABLE_DATA_ISLAND=0` sa možno používa jednoduchšia cesta alebo iné period rozhodovanie, takže sa to neprejaví.

---

## GCP_FRAME_PERIOD: 0 radšej nepoužívaj

Aj keď máš `ENABLE_GCP_PACKET=0`, hodnota:

```yaml
GCP_FRAME_PERIOD: 0
```

je nebezpečná.

Ak niekde v arbitri existuje logika typu:

```systemverilog
frame_count % GCP_FRAME_PERIOD
```

alebo porovnanie s `GCP_FRAME_PERIOD-1`, môže to vytvárať nečakané syntézne správanie.

Pre 2A nastav radšej:

```yaml
GCP_FRAME_PERIOD: 1
```

Aj keď GCP vypínaš. `0` používaj iba vtedy, ak je výslovne zdokumentované ako „disabled“ a ošetrené v RTL.

---

# Čo testovať hneď

## Test 2A-clean

Nastav:

```yaml
ENABLE_DATA_ISLAND: 1
ENABLE_AUDIO: 0
ENABLE_GCP_PACKET: 0
ENABLE_AVI_PACKET: 0
ENABLE_ACR_PACKET: 0
ENABLE_AUDIO_INFOFRAME: 0
ENABLE_AUDIO_SAMPLE: 0
GCP_FRAME_PERIOD: 1
VBLANK_ONLY: 1
DEBUG_ISLAND_PHASES: 0
```

Ak zelená čiara zmizne, problém bol `GCP_FRAME_PERIOD=0`.

Ak ostane, problém je pipeline alignment pri `ENABLE_DATA_ISLAND=1`.

---

## Test 2A-no-vblank-only

Nastav:

```yaml
VBLANK_ONLY: 0
```

pri stále vypnutých GCP/AVI.

Ak sa obraz zmení, znamená to, že `VBLANK_ONLY` ovplyvňuje scheduler aj bez packetu, čo by nemal, alebo že niekde nie je správne gated `packet_pending`.

---

## Test DATA_ISLAND=0 baseline s rovnakým buildom

Pre porovnanie:

```yaml
ENABLE_DATA_ISLAND: 0
ENABLE_AUDIO: 0
```

Ak je obraz bez zeleného okraja, rozdiel je jednoznačne v HDMI period scheduler/mux vetve.

---

# Najpravdepodobnejšia oprava

Potrebujeme zabezpečiť invariant:

```text
Ak ENABLE_DATA_ISLAND=1, ale packet_pending_i=0,
výstupný period/mux pre VIDEO musí byť bitovo/cyklovo rovnaký ako v režime bez data islandov.
```

V testbenchi by som pridal porovnávací test:

```text
DVI mode:
  ENABLE_DATA_ISLAND=0

2A mode:
  ENABLE_DATA_ISLAND=1
  ENABLE_GCP_PACKET=0
  ENABLE_AVI_PACKET=0
  AUDIO=0

Očakávanie:
  ch0/ch1/ch2 musia byť identické počas celého frame,
  okrem prípadných explicitne očakávaných HDMI video preamble/guard rozdielov.
```

Ale ak video preamble/guard existujú iba pri `ENABLE_DATA_ISLAND=1`, tak nemajú byť viditeľné v aktívnom obraze. Preto stačí overiť aktívnu časť:

```text
počas active video musia byť pixelové TMDS symboly rovnaké a na rovnakých x pozíciách.
```

---

## Kde hľadať konkrétne

### 1. `blank_remaining_rr` alignment

Komentár tvrdí, že extra stage rieši 3-stage alignment. Ale symptom hovorí, že to môže byť stále zle o 1–5 cyklov.

Skús dočasne experimentálne:

```systemverilog
.blank_remaining_i(blank_remaining_r)
```

namiesto:

```systemverilog
.blank_remaining_i(blank_remaining_rr)
```

alebo opačne pridať ešte jeden stage:

```systemverilog
blank_remaining_rrr
hblank_rrr
```

Toto nie je finálne riešenie, ale ak zelená čiara zmizne alebo sa posunie, potvrdí to alignment problém.

### 2. `period_d1`

Mux používa period oneskorený o 1 cyklus. Ak obraz je posunutý, treba overiť či má byť:

```systemverilog
.period_i(period_d1)
```

alebo:

```systemverilog
.period_i(period)
```

alebo:

```systemverilog
.period_i(period_d2)
```

Toto presne vie ukázať sim test porovnania `de_aligned` vs `period_mux`.

### 3. `de_r` vs `hblank_rr`

Scheduler rozhoduje podľa:

```systemverilog
de_r
hblank_rr
blank_remaining_rr
```

Tieto tri signály musia byť v rovnakej pipeline fáze. Ak `de_r` pochádza z `vga_output_adapter`, ale `hblank/blank_remaining` z `video_timing_generator`, môžu byť posunuté.

---

# Čo zapísať do debug matice

Tento stav by som zapísal ako:

```text
2A PASS/PARTIAL — image visible, but shifted right with green line at left.
No packets inserted. Indicates video/period alignment issue when ENABLE_DATA_ISLAND=1.
```

Nie ako čistý PASS.

## Krátky záver

Aktuálne nastavenie bez GCP/AVI nemá vkladať žiadny packet. Ak aj tak mení obraz, problém je:

```text
video period alignment / scheduler-mux pipeline,
nie GCP, AVI, BCH, ani audio.
```

Najbližší praktický test:

```text
GCP_FRAME_PERIOD: 1
ENABLE_DATA_ISLAND: 1
GCP=0
AVI=0
VBLANK_ONLY=1
```

Ak zelená čiara ostane, rieš `period_d1`, `blank_remaining_rr` a synchronizáciu `de_r/hblank_rr/blank_remaining_rr`.
