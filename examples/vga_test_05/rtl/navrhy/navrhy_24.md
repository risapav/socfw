Áno, refaktor ide správnym smerom, ale v aktuálnych súboroch sú ešte minimálne **tri kritické problémy**, ktoré môžu priamo vysvetľovať stav:

```text
ENABLE_AUDIO=0, ENABLE_DATA_ISLAND=1 → ide
ENABLE_AUDIO=1, ENABLE_DATA_ISLAND=1 → spí alebo čierna obrazovka
```

Najdôležitejší verdikt:

**Refaktor zlepšil architektúru, ale ešte nie je konzistentne zarovnaná data-island pipeline. `terc4_encoder` je stále 1-cyklový, debug parametre sa nepoužívajú a scheduler stále generuje `period_o` zo `state_next`.**

---

## 1. Kritická chyba: `terc4_encoder` je stále 1-cyklový

V `hdmi_tx_core.sv` je komentár:

```systemverilog
// TERC4 encoders — 2-cycle latency matches video encoder latency
```

ale aktuálny `terc4_encoder.sv` má iba jeden register:

```systemverilog
always_ff @(posedge clk_i) begin
  if (!rst_ni) tmds_o <= 10'b1010011100;
  else         tmds_o <= lut;
end
```

To znamená:

```text
video encoder latency   = 2
control encoder latency = 2
TERC4 encoder latency   = 1
```

Toto je stále vážny problém. Pri `DATA_PAYLOAD` mux vyberá `data_ch*`, ale TERC4 výstupy sú o 1 takt v inom pipeline stage než video/control symboly.

### Oprava

Uprav `terc4_encoder.sv` na 2-cyklový:

```systemverilog
module terc4_encoder (
  input  logic       clk_i,
  input  logic       rst_ni,

  input  logic [3:0] nibble_i,
  output tmds_word_t tmds_o
);

  logic [3:0]   nibble_r;
  tmds_word_t   lut;

  always_ff @(posedge clk_i) begin
    if (!rst_ni)
      nibble_r <= 4'h0;
    else
      nibble_r <= nibble_i;
  end

  always_comb begin
    unique case (nibble_r)
      4'h0: lut = 10'b1010011100;
      4'h1: lut = 10'b1001100011;
      4'h2: lut = 10'b1011100100;
      4'h3: lut = 10'b1011100010;
      4'h4: lut = 10'b0101110001;
      4'h5: lut = 10'b0100011110;
      4'h6: lut = 10'b0110001110;
      4'h7: lut = 10'b0100111100;
      4'h8: lut = 10'b1011001100;
      4'h9: lut = 10'b0100111001;
      4'ha: lut = 10'b0110011100;
      4'hb: lut = 10'b1011000110;
      4'hc: lut = 10'b1010001110;
      4'hd: lut = 10'b1001110001;
      4'he: lut = 10'b0101100011;
      4'hf: lut = 10'b1011000011;
      default: lut = 10'b1010011100;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni)
      tmds_o <= 10'b1010011100;
    else
      tmds_o <= lut;
  end

endmodule
```

Toto je podľa mňa **najdôležitejšia oprava pred ďalším HW testom**.

---

## 2. Kritická chyba: debug parametre sú deklarované, ale nepoužité

V `hdmi_tx_core.sv` pribudli parametre:

```systemverilog
parameter bit ENABLE_ACR_PACKET      = 1,
parameter bit ENABLE_AUDIO_INFOFRAME = 1,
parameter bit ENABLE_AUDIO_SAMPLE    = 1,
```

ale pri pripojení `hdmi_packet_arbiter` sa nepoužívajú.

Aktuálne máš:

```systemverilog
.valid_acr_i     (valid_acr),
.valid_audio_if_i(enable_audio_i),
.valid_sample_i  (w_valid_sample && enable_audio_i),
```

Tým pádom keď si myslíš, že testuješ napríklad „ACR only“ alebo „sample only“, v skutočnosti tieto nové parametre nemusia vôbec nič vypínať.

### Oprava

Zmeň pripojenie arbiteru na:

```systemverilog
.valid_acr_i(
  ENABLE_ACR_PACKET ? valid_acr : 1'b0
),

.valid_audio_if_i(
  ENABLE_AUDIO_INFOFRAME ? enable_audio_i : 1'b0
),

.valid_sample_i(
  ENABLE_AUDIO_SAMPLE ? (w_valid_sample && enable_audio_i) : 1'b0
),
```

Ešte lepšie zapojiť aj starší parameter `ENABLE_AUDIO_IF`:

```systemverilog
.valid_audio_if_i(
  (ENABLE_AUDIO_IF && ENABLE_AUDIO_INFOFRAME) ? enable_audio_i : 1'b0
),
```

Teraz je `ENABLE_AUDIO_IF` tiež prakticky mŕtvy parameter.

---

## 3. `ENABLE_AVI`, `ENABLE_SPD`, `info_cfg_i` sú stále nepoužité

V `hdmi_tx_core.sv` máš parametre a vstupy:

```systemverilog
parameter bit ENABLE_AVI = 1,
parameter bit ENABLE_SPD = 0,
parameter bit ENABLE_AUDIO_IF = 0,

input hdmi_info_cfg_t info_cfg_i,
```

ale arbiter vždy posiela GCP → AVI → ACR → Audio IF podľa svojho FSM. `ENABLE_AVI`, `ENABLE_SPD`, `info_cfg_i.send_avi`, `info_cfg_i.send_audio`, `info_cfg_i.send_spd` sa zatiaľ reálne nepoužívajú.

Pre debug to nie je fatálne, ale pre full HDMI jadro áno.

Minimálne by som spravil:

```systemverilog
logic valid_avi;
logic valid_audio_if;

assign valid_avi      = ENABLE_AVI && info_cfg_i.send_avi;
assign valid_audio_if = ENABLE_AUDIO_IF &&
                        ENABLE_AUDIO_INFOFRAME &&
                        info_cfg_i.send_audio &&
                        enable_audio_i;
```

A arbiter rozšíril tak, aby `ARB_AVI` vedel preskočiť AVI, ak `valid_avi=0`.

Teraz `info_cfg_i` vo `vga_hdmi_tx.sv` ide ako:

```systemverilog
.info_cfg_i('0)
```

Čiže aj keby sa neskôr začal používať, všetko bude vypnuté. Pre súčasný kód to nemá efekt, lebo sa ignoruje.

---

## 4. Scheduler stále používa `state_next` na `period_o`

V `hdmi_period_scheduler.sv` zostalo:

```systemverilog
always_ff @(posedge clk_i) begin
  if (!rst_ni) begin
    period_o <= HDMI_PERIOD_CONTROL;
  end else begin
    unique case (state_next)
      ST_CONTROL:         period_o <= HDMI_PERIOD_CONTROL;
      ST_VIDEO_PREAMBLE:  period_o <= HDMI_PERIOD_VIDEO_PREAMBLE;
      ST_VIDEO_GB:        period_o <= HDMI_PERIOD_VIDEO_GB;
      ST_VIDEO:           period_o <= HDMI_PERIOD_VIDEO;
      ...
    endcase
  end
end
```

Toto je presne mechanizmus, ktorý ti predtým vytvoril 1-cyklový „VIDEO outside de_r“ na konci video periódy.

Nie je to automaticky zlé, ak je celý pipeline výpočet úmyselne založený na tomto posune. Ale potom musí byť v testbenchi jasne povedané:

```text
period_o nie je zarovnaný s de_r,
period_d1 alebo mux output je zarovnaný s encoder výstupom.
```

Momentálne kód obsahuje veľmi detailný komentár, ktorý tvrdí, že `period_d1` je správne zarovnanie. To treba overiť assertionmi priamo na mux stage, nie len na `period_o`.

### Odporúčanie

Zatiaľ by som scheduler ešte nemenil, ale pridal by som do testbenchu kontroly:

```text
period_o  vs de_r
period_d1 vs de_d1/de_d2
ch*_o     vs očakávaný mux stage
```

Ak zlyháva iba `period_o`, ale `ch*_o` je správne, assertion bol príliš skorý.
Ak zlyháva aj `ch*_o`, treba opraviť scheduler alebo `period_d1`.

---

## 5. `period_d1` môže byť správny pre video/control, ale nie pre 1-cyklový TERC4

V core máš:

```systemverilog
hdmi_period_t period_d1;

always_ff @(posedge pix_clk_i) begin
  if (!rst_ni) period_d1 <= HDMI_PERIOD_CONTROL;
  else         period_d1 <= period;
end
```

a do muxu ide:

```systemverilog
.period_i(period_d1)
```

Ak majú všetky encoder vetvy latenciu 2, `period_d1` môže byť správny podľa tvojej pipeline analýzy.

Ale kým `terc4_encoder` ostáva 1-cyklový, `period_d1` nie je konzistentný pre data island payload.

Preto teraz platí:

```text
VIDEO/CONTROL cesta: pravdepodobne zarovnaná
DATA PAYLOAD cesta: pravdepodobne o 1 cyklus posunutá
```

Toto veľmi dobre sedí na problém:

```text
DATA_ISLAND bez audio ešte ide,
ale pri audio packetoch receiver zlyhá.
```

---

## 6. `data_island_formatter` má stále chybný komentár k HSYNC/VSYNC

Implementácia:

```systemverilog
assign ch0_o = {parity, hdr_bit, vsync_i, hsync_i};
```

To znamená:

```text
ch0_o[1] = vsync_i
ch0_o[0] = hsync_i
```

Komentár však hovorí:

```systemverilog
input logic hsync_i, // current HSYNC value (passed to ch0[1])
input logic vsync_i, // current VSYNC value (passed to ch0[0])
```

Komentár je opačne.

Kód by som zatiaľ nemenil, ale komentár opraviť:

```systemverilog
input logic hsync_i, // current HSYNC value (passed to ch0[0])
input logic vsync_i, // current VSYNC value (passed to ch0[1])
```

---

## 7. `hdmi_packet_arbiter` stále používa `vsync_i`, nie `frame_start_i`

V arbitri:

```systemverilog
wire w_vsync_rise = vsync_i && !r_vsync_prev;
```

Toto je funkčné iba vtedy, ak má daný mód pozitívnu VSYNC polaritu a chceš frame packet sekvenciu spúšťať na rising edge VSYNC.

Pre robustný návrh je lepšie použiť:

```systemverilog
input logic frame_start_i;
```

a sekvenciu spúšťať cez:

```systemverilog
if (frame_start_i)
  r_state <= ARB_GCP;
```

Pre 800×600 s pozitívnou VSYNC to nemusí byť aktuálny dôvod sleep režimu, ale do full HDMI jadra by som `vsync_rise` nenechal.

---

## 8. `vblank_i` je v scheduleri stále nepoužitý

Scheduler má vstup:

```systemverilog
input logic vblank_i
```

ale v FSM sa nepoužíva.

Vkladanie data islandov je viazané na:

```systemverilog
hblank_i && packet_pending_i
```

Ak `hblank_i` znamená iba horizontálny blank v aktívnych riadkoch, potom sa pakety nebudú vkladať počas vertical blank riadkov. Ak `hblank_i` pulzuje aj vo vertical blank oblasti, potom je to menej vážne.

Pre HDMI by som to neskôr zmenil na explicitný signál:

```systemverilog
blank_i = !de_i;
```

alebo:

```systemverilog
data_island_allowed_i = blank_i && enough_budget;
```

Nie je to prvá oprava, ale je to nedokončené.

---

## 9. `vga_hdmi_tx` nepropaguje nové debug parametre

V `hdmi_tx_core` sú debug parametre, ale vo `vga_hdmi_tx.sv` sa neprepájajú.

Aktuálne:

```systemverilog
hdmi_tx_core #(
  .ENABLE_DATA_ISLAND(ENABLE_DATA_ISLAND),
  .PIXEL_CLK_HZ      (40_000_000),
  .AUDIO_SAMPLE_RATE (48_000)
) u_core (
```

Ak chceš robiť HW maticu testov, potrebuješ pridať parametre aj do `vga_hdmi_tx`:

```systemverilog
parameter bit ENABLE_ACR_PACKET      = 1,
parameter bit ENABLE_AUDIO_INFOFRAME = 1,
parameter bit ENABLE_AUDIO_SAMPLE    = 1
```

a poslať ich do core:

```systemverilog
hdmi_tx_core #(
  .ENABLE_DATA_ISLAND    (ENABLE_DATA_ISLAND),
  .ENABLE_ACR_PACKET     (ENABLE_ACR_PACKET),
  .ENABLE_AUDIO_INFOFRAME(ENABLE_AUDIO_INFOFRAME),
  .ENABLE_AUDIO_SAMPLE   (ENABLE_AUDIO_SAMPLE),
  .PIXEL_CLK_HZ          (40_000_000),
  .AUDIO_SAMPLE_RATE     (48_000)
) u_core (
```

Potom v `soc_top.sv` vieš robiť testy:

```systemverilog
vga_hdmi_tx #(
  .ENABLE_AUDIO(1),
  .ENABLE_DATA_ISLAND(1),
  .ENABLE_ACR_PACKET(1),
  .ENABLE_AUDIO_INFOFRAME(0),
  .ENABLE_AUDIO_SAMPLE(0)
) hdmi_tx0 (
```

Bez toho sa izolované HW testy nedajú spoľahlivo interpretovať.

---

## 10. PHY je stále bez explicitného pixel/5× word alignmentu

`tmds_phy_ddr_aligned.sv` má lepší komentár a zámer:

```text
pair_cnt==4 latch new word
pair_cnt==0 serialization begins
```

Ale stále nemá explicitný `pix_clk_i` ani `word_start_x_i`. Keďže si už otestoval, že video ide v režime `00`, PHY zjavne funguje dostatočne pre základný režim. Pre robustný full HDMI modul by som to však neskôr ešte spevnil.

Teraz to nie je hlavný bug.

---

# Čo je na refaktore dobré

Pozitívne zmeny:

1. `hdmi_tx_core` už prijíma explicitné:

   ```systemverilog
   hblank_i,
   vblank_i,
   frame_start_i,
   line_start_i,
   blank_remaining_i
   ```

2. Scheduler používa `blank_remaining_i` a stráži, či data island neprebehne do aktívneho videa:

   ```systemverilog
   blank_remaining_i >= ISLAND_TOTAL + VIDEO_TRIG
   ```

3. Pribudlo explicitné pipeline uvažovanie okolo `blank_remaining_rr`.

4. `tmds_control_encoder` je už naozaj 2-cyklový.

5. `sync` signály pre guard band sú oneskorené cez:

   ```systemverilog
   vsync_enc1, vsync_enc
   hsync_enc1, hsync_enc
   ```

6. `data_island_formatter` má lepší shift-register model a explicitný `advance_i`.

Toto sú dobré kroky. Problém je, že refaktor nie je dotiahnutý konzistentne cez všetky vetvy.

---

# Najbližší odporúčaný patch

## Patch 1 — opraviť `terc4_encoder` na 2 cykly

Toto urob ako prvé.

---

## Patch 2 — zapojiť debug parametre

V `hdmi_tx_core.sv` zmeň arbiter pripojenie:

```systemverilog
.valid_acr_i(
  ENABLE_ACR_PACKET ? valid_acr : 1'b0
),

.valid_audio_if_i(
  ENABLE_AUDIO_INFOFRAME ? enable_audio_i : 1'b0
),

.valid_sample_i(
  ENABLE_AUDIO_SAMPLE ? (w_valid_sample && enable_audio_i) : 1'b0
),
```

---

## Patch 3 — propagovať debug parametre do `vga_hdmi_tx`

Do `vga_hdmi_tx.sv` pridaj:

```systemverilog
parameter bit ENABLE_ACR_PACKET      = 1,
parameter bit ENABLE_AUDIO_INFOFRAME = 1,
parameter bit ENABLE_AUDIO_SAMPLE    = 1,
```

a do `hdmi_tx_core` parametrov:

```systemverilog
.ENABLE_ACR_PACKET      (ENABLE_ACR_PACKET),
.ENABLE_AUDIO_INFOFRAME (ENABLE_AUDIO_INFOFRAME),
.ENABLE_AUDIO_SAMPLE    (ENABLE_AUDIO_SAMPLE),
```

---

## Patch 4 — opraviť komentár v `data_island_formatter`

Nie funkčné, ale zabráni ďalším omylom.

---

# Potom zopakovať testovaciu maticu

Po týchto patchoch zopakuj presne:

```text
DATA_ISLAND AUDIO ACR AUDIO_IF SAMPLE  očakávanie
0           0     x   x        x       video ide
1           0     0   0        0       video ide
1           1     1   0        0       ACR only
1           1     0   1        0       Audio IF only
1           1     0   0        1       Sample only
1           1     1   1        0       ACR + Audio IF
1           1     1   1        1       full audio
```

Až po tejto oprave budú výsledky dôveryhodné.

---

# Čo očakávam

Ak je moja hypotéza správna, po 2-cyklovom TERC4 a reálnom zapojení debug parametrov sa zmení správanie minimálne v jednom z týchto smerov:

```text
- ACR only prestane uspávať monitor,
- Audio IF only prestane uspávať monitor,
- Sample only sa zmení zo sleep na čiernu obrazovku alebo obraz,
- full audio bude stále problém, ale už izolovateľný.
```

Ak bude po týchto patchoch stále padať každý jeden audio/data packet, potom ďalší kandidát bude:

```text
data_island_formatter bit mapping,
BCH/ECC,
alebo časovanie advance_i voči TERC4/mux výberu.
```

Ale momentálne by som tam ešte nešiel, lebo najprv treba odstrániť zjavné pipeline a debug-gating chyby.

---

## Krátky verdikt

Refaktor je dobrý smerom k správnej architektúre, ale aktuálny stav má tieto hlavné blokujúce chyby:

```text
1. TERC4 encoder je stále 1-cycle, hoci core počíta s 2-cycle.
2. ENABLE_ACR_PACKET / ENABLE_AUDIO_INFOFRAME / ENABLE_AUDIO_SAMPLE sú nepoužité.
3. ENABLE_AUDIO_IF / ENABLE_AVI / info_cfg_i sú stále prakticky mŕtve.
4. Arbiter stále používa vsync edge namiesto frame_start.
5. period_o zo state_next treba ďalej overovať na mux-output stage.
```

Najbližší praktický krok: **oprav TERC4 + zapoj debug parametre + zopakuj simulačnú aj HW testovaciu maticu.**
