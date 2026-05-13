Áno. Tento refaktor je citeľne lepší než predchádzajúci stav. Najdôležitejšia oprava je hotová:

```text
TERC4 encoder je už 2-cyklový.
tmds_video_encoder = 2 cykly
tmds_control_encoder = 2 cykly
terc4_encoder = 2 cykly
```

To odstraňuje jednu z hlavných predošlých pipeline chýb.

Ale v aktuálnych súboroch vidím ešte **jeden nový kritický problém v data-island payload toku**, plus niekoľko integračných nedotiahnutí.

---

# Hlavný verdikt

Aktuálny stav je:

```text
Video/DVI cesta:             pravdepodobne OK
Data island period timing:   pravdepodobne OK
TERC4 latency:               opravená
Packet gating v core:        čiastočne opravený
Packet gating cez top:       nedotiahnutý
Formatter → TERC4 advance:   pravdepodobne zle zarovnaný
```

Najvážnejší aktuálny kandidát na bug je teraz:

```text
data_island_formatter posúva symboly až počas DATA_PAYLOAD,
ale TERC4 + channel_mux majú spolu ďalšiu latenciu.
```

To môže spôsobiť, že v reálnom výstupe sa prvý payload symbol zopakuje a celý packet bude bitovo poškodený.

---

# 1. Opravené: `terc4_encoder.sv` je už správne 2-cyklový

Aktuálne má:

```systemverilog
logic [3:0] nibble_r;

always_ff @(posedge clk_i) begin
  if (!rst_ni) nibble_r <= 4'h0;
  else         nibble_r <= nibble_i;
end

always_ff @(posedge clk_i) begin
  if (!rst_ni) tmds_o <= 10'b1010011100;
  else         tmds_o <= lut;
end
```

To je správne. Teraz sedí s komentárom v `hdmi_tx_core.sv`:

```text
TERC4 latency = 2
video latency = 2
control latency = 2
```

Toto je dobrý krok.

---

# 2. Kritický problém: `data_island_formatter.advance_i` je pravdepodobne o 1 cyklus neskoro

V `hdmi_period_scheduler.sv` máš:

```systemverilog
ST_DATA_PAYLOAD: begin
  packet_pop_o = 1'b1;
  ...
end
```

Čiže `packet_pop_o`, ktorý ide do:

```systemverilog
data_island_formatter.advance_i(packet_pop)
```

je aktívny až vtedy, keď je aktuálny FSM stav `ST_DATA_PAYLOAD`.

Lenže cesta payload symbolu je:

```text
data_island_formatter nibble
  → terc4_encoder stage 1
  → terc4_encoder stage 2
  → hdmi_channel_mux register
  → ch*_o
```

To znamená, že ak formatter začne posúvať až počas `DATA_PAYLOAD`, TERC4 výstup sa zmení príliš neskoro.

Typický efekt:

```text
výstupný DATA_PAYLOAD symbol 0 = správny
výstupný DATA_PAYLOAD symbol 1 = znova symbol 0
výstupný DATA_PAYLOAD symbol 2 = symbol 1
...
posledný symbol sa stratí alebo posunie
```

Takýto packet bude mať správnu dĺžku 32 cyklov, ale **nesprávny obsah**.

To veľmi dobre vysvetľuje situáciu:

```text
DATA_ISLAND=1, AUDIO=0 ide
DATA_ISLAND=1, AUDIO=1 padá / čierna / sleep
```

Monitor môže tolerovať alebo ignorovať poškodené GCP/AVI, ale pri ACR/audio packetoch už môže link zhodiť.

---

## Odporúčaná oprava

`packet_pop_o` pre formatter nemá znamenať „sme v payload“, ale skôr:

```text
priprav ďalší data-island symbol dostatočne skoro pre TERC4 pipeline
```

Minimálne treba posunúť prvý `advance_i` už pri prechode:

```text
ST_DATA_GUARD_LEAD → ST_DATA_PAYLOAD
```

Teda v scheduleri doplniť lookahead advance.

Približne:

```systemverilog
ST_DATA_GUARD_LEAD: begin
  if (sym_cnt == 0) begin
    state_next   = ST_DATA_PAYLOAD;
    sym_cnt_next = ($bits(sym_cnt_next))'(PAYLOAD_LEN - 1);

    // Lookahead: formatter má počas guard bandu symbol 0 už pripravený.
    // Tu ho posunieme na symbol 1, aby po TERC4+MUX pipeline vyšiel včas.
    packet_pop_o = 1'b1;
  end else begin
    sym_cnt_next = ($bits(sym_cnt_next))'(sym_cnt - 1);
  end
end
```

A v samotnom `ST_DATA_PAYLOAD` neposúvať slepo počas všetkých 32 cyklov. Inak spravíš o jeden shift navyše.

Skôr niečo v štýle:

```systemverilog
ST_DATA_PAYLOAD: begin
  // Posúvaj iba dovtedy, kým treba pripraviť ďalší symbol.
  // Posledný payload symbol už nepotrebuje ďalší advance.
  packet_pop_o = (sym_cnt > 1);

  if (sym_cnt == 0) begin
    state_next   = ST_DATA_GUARD_TRAIL;
    sym_cnt_next = ($bits(sym_cnt_next))'(GUARD_LEN - 1);
  end else begin
    sym_cnt_next = ($bits(sym_cnt_next))'(sym_cnt - 1);
  end
end
```

Presnú podmienku odporúčam potvrdiť v simulácii logom symbol indexu, ale princíp je: **formatter musí byť o pipeline latenciu pred mux výstupom**.

---

# 3. Testbench zatiaľ pravdepodobne kontroluje len dĺžky periód, nie obsah data islandu

Tvoje predchádzajúce výsledky hovorili:

```text
DATA_PAYLOAD = 32 ✓
DATA_PREAMBLE = 8 ✓
GB = 2 ✓
VIDEO_GB = 2 ✓
```

To je dobré, ale nestačí.

Teraz treba doplniť kontrolu, či počas 32 payload cyklov vychádza symbolová sekvencia:

```text
symbol 0, symbol 1, symbol 2, ..., symbol 31
```

nie napríklad:

```text
symbol 0, symbol 0, symbol 1, ..., symbol 30
```

Odporúčam do testbenchu dočasne vyexportovať alebo sledovať:

```text
formatter.sym_cnt
formatter.ch0_o/ch1_o/ch2_o
terc4 input nibble
terc4 output
period_d1
mux ch*_o
```

Najmä treba overiť:

```text
prvý DATA_PAYLOAD cyklus na ch*_o obsahuje payload symbol 0
druhý DATA_PAYLOAD cyklus na ch*_o obsahuje payload symbol 1
...
32. DATA_PAYLOAD cyklus obsahuje payload symbol 31
```

Toto je teraz dôležitejšie než ďalšie testovanie monitora.

---

# 4. `data_island_formatter.sv` má stále opačný komentár pre HSYNC/VSYNC

Implementácia je:

```systemverilog
assign ch0_o = {parity, hdr_bit, vsync_i, hsync_i};
```

Čiže:

```text
ch0_o[1] = vsync_i
ch0_o[0] = hsync_i
```

Ale komentár stále hovorí:

```systemverilog
input logic hsync_i, // current HSYNC value (passed to ch0[1])
input logic vsync_i, // current VSYNC value (passed to ch0[0])
```

Toto je opačne.

Opraviť komentár na:

```systemverilog
input logic hsync_i, // current HSYNC value (passed to ch0[0])
input logic vsync_i, // current VSYNC value (passed to ch0[1])
```

Samotný kód by som zatiaľ nemenil.

---

# 5. Debug enable parametre sú zapojené v `hdmi_tx_core`, ale nie sú propagované vyššie

V `hdmi_tx_core.sv` už máš:

```systemverilog
parameter bit ENABLE_ACR_PACKET      = 1,
parameter bit ENABLE_AUDIO_INFOFRAME = 1,
parameter bit ENABLE_AUDIO_SAMPLE    = 1,
```

a v arbiteri sú už správne použité:

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

To je dobré.

Ale `vga_hdmi_tx.sv` tieto parametre nemá, takže zo `soc_top.sv` ich nevieš meniť. Momentálne môžeš prepínať iba:

```systemverilog
.ENABLE_AUDIO(1),
.ENABLE_DATA_ISLAND(1)
```

Pre ďalšie HW testy potrebuješ dostať debug parametre až do topu.

Do `vga_hdmi_tx.sv` pridaj:

```systemverilog
parameter bit ENABLE_ACR_PACKET       = 1,
parameter bit ENABLE_AUDIO_INFOFRAME  = 1,
parameter bit ENABLE_AUDIO_SAMPLE     = 1,
```

a do `hdmi_tx_core`:

```systemverilog
.ENABLE_ACR_PACKET      (ENABLE_ACR_PACKET),
.ENABLE_AUDIO_INFOFRAME (ENABLE_AUDIO_INFOFRAME),
.ENABLE_AUDIO_SAMPLE    (ENABLE_AUDIO_SAMPLE),
```

Potom v `soc_top.sv` vieš testovať napríklad:

```systemverilog
vga_hdmi_tx #(
  .ENABLE_AUDIO(1),
  .ENABLE_DATA_ISLAND(1),
  .ENABLE_ACR_PACKET(1),
  .ENABLE_AUDIO_INFOFRAME(0),
  .ENABLE_AUDIO_SAMPLE(0)
) hdmi_tx0 (
```

Bez toho sú izolované HW testy stále nepohodlné.

---

# 6. `ENABLE_AUDIO_IF` je deklarovaný, ale fakticky ignorovaný

V `hdmi_tx_core.sv` je:

```systemverilog
parameter bit ENABLE_AUDIO_IF = 0,
```

ale pri arbiteri používaš iba:

```systemverilog
.valid_audio_if_i(
  ENABLE_AUDIO_INFOFRAME ? enable_audio_i : 1'b0
),
```

Teda aj keď `ENABLE_AUDIO_IF = 0`, Audio InfoFrame sa stále pošle, ak:

```text
ENABLE_AUDIO_INFOFRAME = 1
enable_audio_i = 1
```

Odporúčam to zjednotiť:

```systemverilog
.valid_audio_if_i(
  (ENABLE_AUDIO_IF && ENABLE_AUDIO_INFOFRAME) ? enable_audio_i : 1'b0
),
```

Alebo `ENABLE_AUDIO_IF` úplne odstrániť a používať iba nový názov `ENABLE_AUDIO_INFOFRAME`.

Teraz sú tam dva prepínače pre tú istú vec, ale iba jeden funguje.

---

# 7. `ENABLE_AVI`, `ENABLE_SPD` a `info_cfg_i` sú stále mŕtve alebo nedokončené

V `hdmi_tx_core.sv` máš:

```systemverilog
parameter bit ENABLE_AVI = 1,
parameter bit ENABLE_SPD = 0,
input hdmi_info_cfg_t info_cfg_i,
```

ale:

```text
ENABLE_AVI sa nepoužíva
ENABLE_SPD sa nepoužíva
info_cfg_i sa nepoužíva
SPD packet sa vôbec neintegruje
```

`hdmi_packet_arbiter` vždy prejde:

```text
GCP → AVI → ACR → AUDIO_IF
```

a `AVI` je vždy povinný.

Pre debug to nie je kritické, ale pre finálny HDMI modul by som to upravil takto:

```systemverilog
logic valid_avi;
logic valid_audio_if;

assign valid_avi =
  ENABLE_AVI && info_cfg_i.send_avi;

assign valid_audio_if =
  ENABLE_AUDIO_IF &&
  ENABLE_AUDIO_INFOFRAME &&
  info_cfg_i.send_audio &&
  enable_audio_i;
```

Potom arbiter musí vedieť preskočiť `ARB_AVI`, ak `valid_avi=0`.

Momentálne vo `vga_hdmi_tx.sv` posielaš:

```systemverilog
.info_cfg_i('0)
```

Čiže ak sa `info_cfg_i` začne používať, AVI aj Audio InfoFrame sa vypnú, pokiaľ nenastavíš konfiguráciu.

---

# 8. `hdmi_packet_arbiter.sv` je lepší — používa `frame_start_i`

Toto je dobrá zmena. Predtým bol problém, že arbiter používal `vsync_rise`. Teraz má:

```systemverilog
input logic frame_start_i
```

a v core:

```systemverilog
.frame_start_i(frame_start_r)
```

To je správnejšie a robustnejšie.

---

# 9. `r_audio_ready` je dobrý nápad, ale pozor na corner case

V arbitri pribudlo:

```systemverilog
r_audio_ready
```

To bráni posielaniu audio sample packetov pred tým, než prebehne inicializačná sekvencia GCP/AVI/ACR/AudioIF.

To je rozumné.

Ale aktuálna logika hovorí:

```systemverilog
else if (r_state == ARB_AVI && packet_start_i && !valid_acr_i && !valid_audio_if_i)
  r_audio_ready <= 1'b1;
```

Čiže ak vypneš ACR aj AudioIF, sample packety sa povolia po AVI. To je vhodné pre debug.

Ak však budeš chcieť byť striktnejší pre reálny audio režim, tak audio samples by mali ísť až po ACR. Pre debug to nechaj tak.

---

# 10. `hdmi_period_scheduler.sv` stále generuje `period_o` podľa `state_next`

Stále tam je:

```systemverilog
unique case (state_next)
  ST_CONTROL:         period_o <= HDMI_PERIOD_CONTROL;
  ST_VIDEO_PREAMBLE:  period_o <= HDMI_PERIOD_VIDEO_PREAMBLE;
  ...
endcase
```

To je zdroj predchádzajúceho efektu:

```text
VIDEO outside de_r na poslednom cykle
```

Nemusí to byť chyba, ak je celý pipeline model nastavený tak, že `period_o` je skorší scheduler stage. Ale potom sa assertion nesmie robiť proti surovému `de_r`, ale proti zarovnanému mux/output stage.

Odporúčam ponechať scheduler zatiaľ takto, ale v testbenchi rozlíšiť:

```text
period_o       = scheduler stage
period_d1      = mux select input stage
ch*_o          = output stage
de_r/de_d1/... = zodpovedajúce DE stage
```

Nekontroluj iba:

```text
period_o == VIDEO ⇒ de_r
```

Kontroluj hlavne:

```text
mux output vyberá VIDEO presne vtedy, keď výstupný TMDS symbol patrí aktívnemu pixelu
```

---

# 11. `vblank_i` je stále nepoužitý v scheduleri

V `hdmi_period_scheduler.sv` je vstup:

```systemverilog
input logic vblank_i
```

ale v logike sa nepoužíva.

Data islandy sú podmienené:

```systemverilog
hblank_i && packet_pending_i
```

Ak tvoj `hblank_i` je aktívny aj počas vertical blank riadkov, je to OK. Ak `hblank_i` znamená iba horizontálny blank počas aktívnych riadkov, potom nevyužívaš vertical blank na data islandy.

Pre finálny návrh by bolo lepšie mať explicitné:

```systemverilog
blank_i = !de_i;
```

alebo:

```systemverilog
data_island_allowed_i = !de_i && enough_budget;
```

Zatiaľ to nie je hlavný bug.

---

# 12. `tmds_phy_ddr_aligned.sv` je stále bez samostatného resetu pre 5× clock

V `soc_top.sv` máš reset synchronizovaný iba do pixel clock domény:

```systemverilog
cdc_reset_synchronizer rst_sync0 (
  .clk_i(clkpll_c0),
  .rst_ni(w_clkpll_locked),
  .rst_no(w_rst_sync0_rst_no)
);
```

Ten istý reset potom ide aj do PHY, ktorý beží na `clkpll_c1`.

Keďže čisté video už funguje, toto nie je aktuálny hlavný problém. Ale pre robustný návrh by som stále pridal druhý reset synchronizátor:

```systemverilog
wire reset_pix_n;
wire reset_x_n;

cdc_reset_synchronizer rst_sync_pix (
  .clk_i(clkpll_c0),
  .rst_ni(w_clkpll_locked),
  .rst_no(reset_pix_n)
);

cdc_reset_synchronizer rst_sync_x (
  .clk_i(clkpll_c1),
  .rst_ni(w_clkpll_locked),
  .rst_no(reset_x_n)
);
```

a do PHY dať `reset_x_n`.

---

# Najbližšie odporúčané kroky

## Krok 1 — opraviť data-island formatter advance timing

Toto je teraz najdôležitejšie.

Cieľ:

```text
na výstupe ch*_o počas DATA_PAYLOAD musí ísť 32 symbolov:
0, 1, 2, ..., 31
bez duplikácie a bez straty posledného symbolu
```

---

## Krok 2 — doplniť testbench na obsah payloadu

Nestačí kontrolovať dĺžky periód. Pridaj kontrolu postupnosti symbolov.

Vhodný debug log:

```text
cy
period
packet_pop
formatter_sym_cnt
di_ch0/di_ch1/di_ch2
terc4_ch0/ch1/ch2
mux_ch0/ch1/ch2
```

Hľadaj hlavne pattern:

```text
symbol0, symbol0, symbol1...
```

Ak ho uvidíš, potvrdzuje to vyššie uvedený problém.

---

## Krok 3 — propagovať debug parametre do `vga_hdmi_tx.sv`

Až potom má zmysel opakovať HW maticu:

```text
ACR only
Audio IF only
Sample only
ACR + Audio IF
full audio
```

---

## Krok 4 — zjednotiť `ENABLE_AUDIO_IF` a `ENABLE_AUDIO_INFOFRAME`

Buď jeden odstrániť, alebo používať oba konzistentne.

---

# Priorita chýb

Podľa aktuálneho refaktoru by som priority zoradil takto:

```text
1. data_island_formatter advance_i je neskoro voči TERC4+MUX pipeline
2. debug parametre nie sú propagované do vga_hdmi_tx/soc_top
3. ENABLE_AUDIO_IF je ignorovaný
4. ENABLE_AVI / ENABLE_SPD / info_cfg_i sú stále nedokončené
5. komentár HSYNC/VSYNC vo formatteri je opačne
6. vblank_i je nepoužitý
7. PHY reset pre clk_x_i doménu ešte nie je oddelený
```

---

## Krátky záver

Refaktor odstránil predchádzajúcu veľkú chybu s 1-cyklovým TERC4. To je dobré.

Teraz sa hlavná pozornosť presúva na **časovanie posuvu data-island payload symbolov**. Period lengths môžu byť úplne správne, ale ak formatter posúva payload až počas `DATA_PAYLOAD`, po 2-cyklovom TERC4 a registrovanom muxe bude packet obsahovo posunutý.

Toto by som opravil a overil skôr, než pôjdeš znova na monitor.
