pri kombinácii .ENABLE_AUDIO(0) a .ENABLE_DATA_ISLAND(0) hdmi video ide,
pri 01 ide, pri 10 ide, pri 11 zaspáva monitor


Toto je výborný výsledok testu. Znamená to:

```text
ENABLE_AUDIO  ENABLE_DATA_ISLAND   výsledok
0             0                    ide
0             1                    ide
1             0                    ide
1             1                    monitor zaspí
```

Z toho vyplýva dôležitý záver:

**Video, PHY, PLL, pinout, TMDS serializer aj základné data islandy sú funkčné.**
Problém vzniká až vtedy, keď sa audio začne reálne prenášať cez data islandy.

---

# Čo z toho vyplýva

Kombinácia:

```systemverilog
.ENABLE_AUDIO(1),
.ENABLE_DATA_ISLAND(0)
```

v skutočnosti netestuje HDMI audio cestu, pretože v `hdmi_tx_core.sv` je audio logika vo vnútri:

```systemverilog
if (ENABLE_DATA_ISLAND) begin : gen_data_island
```

Čiže keď `ENABLE_DATA_ISLAND = 0`, audio packet builder, ACR, audio sample packet ani packet arbiter sa reálne nepoužijú.

Preto test `10 ide` znamená iba:

```text
audio parameter sám osebe nič nerozbije
```

ale nie:

```text
audio pakety sú správne
```

Skutočný problém je teda v ceste:

```text
audio_test_src
 → audio_sample_packet_builder
 → acr_packet_builder
 → audio infoframe
 → hdmi_packet_arbiter
 → data_island_formatter
 → TERC4
 → TMDS
```

---

# Najpravdepodobnejšie príčiny

## 1. Audio sample packety sú najväčší podozrivý

V `hdmi_packet_arbiter.sv` sa v `ARB_IDLE` posiela audio sample packet vždy, keď je pripravený:

```systemverilog
packet_valid_o = valid_sample_i;
```

a vo `hdmi_tx_core.sv`:

```systemverilog
.valid_sample_i(w_valid_sample && enable_audio_i)
```

To znamená, že po zapnutí audia začne jadro periodicky vkladať audio sample packety do horizontálneho blankingu.

Ak je audio sample packet nesprávne zložený, má zlý header, zlý payload layout, zlú paritu, zlý BCH/ECC alebo zlý TERC4 bit mapping, niektoré monitory môžu link zhodiť alebo prejsť do sleep.

---

## 2. ACR packet je druhý podozrivý

Pri `ENABLE_AUDIO=1` sa ACR stane validným:

```systemverilog
valid_o = enable_i && cts_valid_i;
```

a vo `vga_hdmi_tx.sv` máš:

```systemverilog
.acr_cts_valid_i(1'b1)
```

Čiže pri zapnutom audio režime arbiter pošle ACR packet.

Pre 40 MHz / 48 kHz máš:

```systemverilog
ACR_N   = 6144
ACR_CTS = 40000
```

To matematicky sedí:

```text
CTS = pixel_clock × N / (128 × sample_rate)
CTS = 40 000 000 × 6144 / (128 × 48 000)
CTS = 40000
```

Takže hodnota CTS/N vyzerá dobre. Problém môže byť skôr v layout-e ACR payloadu alebo v tom, ako ho formatter zakóduje.

---

## 3. Audio InfoFrame je menej pravdepodobný, ale tiež ho treba izolovať

Vo `hdmi_tx_core.sv` máš:

```systemverilog
.valid_audio_if_i(enable_audio_i)
```

Tým pádom sa Audio InfoFrame posiela vždy, keď je audio zapnuté.

Zatiaľ by som ho dočasne vypol. Najprv musíš zistiť, ktorý typ packetu spôsobuje sleep:

```text
ACR?
Audio InfoFrame?
Audio Sample Packet?
ich kombinácia?
```

---

# Najlepší ďalší debug postup

Teraz by som nesiahal na PHY ani video. Tie sú podľa tvojho testu v poriadku.

Sprav tieto štyri testy.

---

## Test A — data island zapnutý, audio sample packety vypnuté

Vo `hdmi_tx_core.sv` dočasne zmeň:

```systemverilog
.valid_sample_i(w_valid_sample && enable_audio_i)
```

na:

```systemverilog
.valid_sample_i(1'b0)
```

Nechaj:

```systemverilog
.valid_acr_i(valid_acr)
.valid_audio_if_i(enable_audio_i)
```

Výsledky:

```text
Ak monitor ide:
  problém je pravdepodobne audio_sample_packet_builder alebo sample packet tok.

Ak monitor stále zaspí:
  problém je ACR alebo Audio InfoFrame.
```

---

## Test B — vypnúť Audio InfoFrame

Zmeň:

```systemverilog
.valid_audio_if_i(enable_audio_i)
```

na:

```systemverilog
.valid_audio_if_i(1'b0)
```

a nechaj ACR zapnuté.

Výsledky:

```text
Ak monitor ide:
  problém je v Audio InfoFrame.

Ak monitor zaspí:
  problém je pravdepodobne ACR alebo sample packet.
```

---

## Test C — vypnúť ACR

Zmeň:

```systemverilog
.valid_acr_i(valid_acr)
```

na:

```systemverilog
.valid_acr_i(1'b0)
```

Výsledky:

```text
Ak monitor ide:
  problém je v ACR packete.

Ak monitor zaspí:
  problém je inde, najmä audio sample packet.
```

---

## Test D — iba AVI/GCP, bez všetkého audia

Toto by malo zodpovedať tvojmu funkčnému režimu `01`.

V arbiteri dočasne:

```systemverilog
.valid_acr_i      (1'b0),
.valid_audio_if_i (1'b0),
.valid_sample_i   (1'b0),
```

Ak toto ide, máš potvrdené, že `data_island_formatter` aspoň pre GCP/AVI funguje dostatočne dobre.

---

# Čo by som upravil hneď

## 1. Dočasne zaveď samostatné debug parametre

Do `hdmi_tx_core.sv` by som pridal:

```systemverilog
parameter bit ENABLE_ACR_PACKET      = 0,
parameter bit ENABLE_AUDIO_INFOFRAME = 0,
parameter bit ENABLE_AUDIO_SAMPLE    = 0
```

a potom:

```systemverilog
.valid_acr_i(
  ENABLE_ACR_PACKET ? valid_acr : 1'b0
),

.valid_audio_if_i(
  ENABLE_AUDIO_INFOFRAME ? enable_audio_i : 1'b0
),

.valid_sample_i(
  ENABLE_AUDIO_SAMPLE ? (w_valid_sample && enable_audio_i) : 1'b0
)
```

Potom vieš testovať presne:

```text
data island only
data island + ACR
data island + Audio InfoFrame
data island + audio samples
data island + ACR + samples
full audio
```

---

## 2. Neposielaj zatiaľ audio sample packety bez potvrdeného ACR

Pre prvý audio bring-up odporúčam túto postupnosť:

```text
1. ENABLE_DATA_ISLAND = 1, ENABLE_AUDIO = 0
   iba GCP/AVI

2. ACR only
   bez Audio InfoFrame, bez sample packetov

3. ACR + Audio InfoFrame
   stále bez sample packetov

4. ACR + Audio InfoFrame + veľmi riedke audio sample packety

5. až potom normálny sample rate
```

---

# Veľmi pravdepodobný praktický problém

Tvoj `hdmi_audio_test_src.sv` generuje 4-sample batch a keď je validný, drží `valid_o = 1`, kým ho scheduler nespotrebuje.

To je v princípe v poriadku, ale pri prvom bring-upe je lepšie audio sample packety posielať výrazne pomalšie, napríklad iba raz za frame alebo raz za niekoľko riadkov. Ak monitor začne fungovať s riedkymi packetmi, problém môže byť:

```text
- packet rate,
- príliš veľa data islandov,
- chýbajúce pravidlá plánovania,
- alebo zlá interakcia s video preamble pred active video.
```

Dočasný test:

```systemverilog
logic [15:0] dbg_audio_div;

always_ff @(posedge pix_clk_i) begin
  if (!rst_ni)
    dbg_audio_div <= '0;
  else
    dbg_audio_div <= dbg_audio_div + 1'b1;
end
```

a potom:

```systemverilog
.valid_sample_i(
  w_valid_sample && enable_audio_i && (dbg_audio_div == 16'd0)
)
```

Toto nie je finálne riešenie, ale pomôže zistiť, či monitor zhadzuje link kvôli hustote audio packetov alebo kvôli samotnému formátu packetu.

---

# Ešte jedna dôležitá vec: nepoužívaj `vsync_i` ako frame trigger

V `hdmi_packet_arbiter.sv` sa frame sekvencia spúšťa cez:

```systemverilog
wire w_vsync_rise = vsync_i && !r_vsync_prev;
```

Pri 800×600 máš pozitívne syncy, takže to môže fungovať. Ale robustnejšie je použiť `frame_start_i`.

Odporúčam neskôr zmeniť arbiter z:

```systemverilog
input logic vsync_i
```

na:

```systemverilog
input logic frame_start_i
```

a v `hdmi_tx_core.sv` pripojiť:

```systemverilog
.frame_start_i(frame_start_r)
```

Pre aktuálny sleep problém to nemusí byť hlavná príčina, ale je to správnejší návrh.

---

# Moja pracovná hypotéza

Podľa tvojich výsledkov by som teraz tipoval túto prioritu:

```text
1. Audio sample packet format alebo jeho BCH/TERC4 zakódovanie
2. ACR packet layout
3. Audio InfoFrame
4. Príliš agresívne vkladanie audio sample packetov do hblanku
5. Menej pravdepodobne všeobecná chyba data_island_formatteru
```

Preto by som ako prvý test spravil presne toto:

```systemverilog
.valid_acr_i      (1'b0),
.valid_audio_if_i (1'b0),
.valid_sample_i   (w_valid_sample && enable_audio_i)
```

Teda **iba audio sample packet**, bez ACR a bez Audio InfoFrame.

A potom opačne:

```systemverilog
.valid_acr_i      (valid_acr),
.valid_audio_if_i (1'b0),
.valid_sample_i   (1'b0)
```

Teda **iba ACR**.

Tak veľmi rýchlo zistíš, ktorý packet zhadzuje monitor.

---

# Najbližší odporúčaný krok

Urob si jednoduchú testovaciu maticu:

```text
DATA  AUDIO  ACR  AUDIO_IF  SAMPLE   výsledok
1     0      0    0         0        ide
1     1      1    0         0        ?
1     1      0    1         0        ?
1     1      0    0         1        ?
1     1      1    1         0        ?
1     1      1    1         1        zaspí
```

Keď budeš mať tieto výsledky, dá sa už veľmi presne povedať, či treba opraviť `acr_packet_builder`, `audio_sample_packet_builder`, `infoframe_builder`, alebo scheduler/formatter.
