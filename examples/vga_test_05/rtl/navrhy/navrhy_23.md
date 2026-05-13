Áno — podľa popisu je koreň veľmi pravdepodobne správne identifikovaný. Teraz by som to riešil takto:

## Záver k aktuálnemu zlyhaniu

Assertion:

```text
VIDEO outside de_r na poslednom cykle VIDEO periódy
```

znamená, že interný `period_o` je o 1 cyklus dlhší než `de_r`.

To môže byť buď:

1. **reálna chyba schedulera**, ak `period_o` má presne zodpovedať aktuálnemu `de_r`, alebo
2. **očakávaný pipeline efekt**, ak `period_o` má byť zarovnaný až s oneskorenými TMDS dátami.

Podľa tvojho popisu však scheduler používa `state_next` na registrovanie `period_o`, pričom `de_r` padne v tom istom edge. To je podozrivé. Takýto návrh často vyrobí presne tento 1-cyklový overhang.

---

# Čo by som spravil ako ďalší krok

Najprv by som **neopravoval assertion**, ale pridal tri paralelné kontroly:

```text
1. period_o vs de_r
2. period_d1 vs de_d1
3. finálny mux výber vs encoder-aligned de
```

Pretože problém nemusí byť viditeľný na výstupe, ak je neskôr kompenzovaný. Ale ak sa prejaví v `hdmi_channel_mux`, môže vysvetľovať horizontálny posun alebo čierne riadky.

---

## 1. Pridaj explicitné pipeline signály do testbenchu

Ak máš v core napríklad:

```systemverilog
period_o
period_d1
de_r
```

v testbenchi si vytvor oneskorenia:

```systemverilog
logic de_d1;
logic de_d2;

always_ff @(posedge pix_clk) begin
  if (!rst_n) begin
    de_d1 <= 1'b0;
    de_d2 <= 1'b0;
  end else begin
    de_d1 <= de_r;
    de_d2 <= de_d1;
  end
end
```

Potom testuj:

```systemverilog
// surový scheduler
if (period_o == HDMI_PERIOD_VIDEO && !de_r)
  $error("period_o VIDEO outside de_r at cy=%0d", cy);

// mux po 1-cycle period delay
if (period_d1 == HDMI_PERIOD_VIDEO && !de_d1)
  $error("period_d1 VIDEO outside de_d1 at cy=%0d", cy);

// encoder output po 2-cycle video latency
if (period_d2 == HDMI_PERIOD_VIDEO && !de_d2)
  $error("period_d2 VIDEO outside de_d2 at cy=%0d", cy);
```

Ak zlyháva iba prvý assertion, ale nie druhý/tretí, možno je problém len v tom, že assertion sleduje zlý pipeline stage.

Ak zlyhávajú aj oneskorené kontroly, je to reálna chyba.

---

# Pravdepodobná oprava schedulera

Ak `period_o` má vyjadrovať aktuálny stav registrovaného schedulera, nemal by sa registrovať zo `state_next`, ale zo stabilného aktuálneho stavu alebo z explicitného výstupného next výpočtu.

Typický problém býva niečo takéto:

```systemverilog
always_ff @(posedge clk_i) begin
  state_r  <= state_next;
  period_o <= period_from_state(state_next);
end
```

Toto často spôsobuje off-by-one správanie na hranách, lebo `state_next` je vypočítaný zo starých hodnôt `de_r`, counterov a state.

Bezpečnejší vzor je:

```systemverilog
always_ff @(posedge clk_i) begin
  if (!rst_ni) begin
    state_r  <= ST_CONTROL;
    period_o <= HDMI_PERIOD_CONTROL;
  end else begin
    state_r  <= state_next;
    period_o <= period_from_state(state_r);
  end
end
```

Tým `period_o` reprezentuje aktuálny registrovaný stav, nie dopredu odhadovaný stav.

Ale pozor: tým sa môže celý `period_o` posunúť o 1 cyklus. Preto treba skontrolovať preamble/GB dĺžky znovu.

---

## Lepší variant: explicitný registrovaný `period_next`

Odporúčam radšej oddeliť FSM stav a výstup:

```systemverilog
hdmi_period_e period_next;

always_comb begin
  state_next  = state_r;
  period_next = period_r;

  unique case (state_r)
    ST_CONTROL: begin
      period_next = HDMI_PERIOD_CONTROL;

      if (start_data_preamble) begin
        state_next  = ST_DATA_PREAMBLE;
        period_next = HDMI_PERIOD_DATA_PREAMBLE;
      end else if (start_video_preamble) begin
        state_next  = ST_VIDEO_PREAMBLE;
        period_next = HDMI_PERIOD_VIDEO_PREAMBLE;
      end
    end

    ST_VIDEO: begin
      if (de_i) begin
        period_next = HDMI_PERIOD_VIDEO;
      end else begin
        state_next  = ST_CONTROL;
        period_next = HDMI_PERIOD_CONTROL;
      end
    end

    default: begin
      period_next = period_from_state(state_r);
    end
  endcase
end

always_ff @(posedge clk_i) begin
  if (!rst_ni) begin
    state_r  <= ST_CONTROL;
    period_r <= HDMI_PERIOD_CONTROL;
  end else begin
    state_r  <= state_next;
    period_r <= period_next;
  end
end

assign period_o = period_r;
```

Toto je najčistejšie, pretože vieš presne povedať:

```text
period_r je registrovaný výstup FSM pre aktuálny cyklus.
```

---

# Konkrétna oprava pre stav `ST_VIDEO`

Ak chceš minimálny patch, zameraj sa na stav `ST_VIDEO`.

Namiesto logiky typu:

```systemverilog
ST_VIDEO: begin
  if (!de_i)
    state_next = ST_CONTROL;

  period_next = HDMI_PERIOD_VIDEO;
end
```

použi:

```systemverilog
ST_VIDEO: begin
  if (de_i) begin
    state_next  = ST_VIDEO;
    period_next = HDMI_PERIOD_VIDEO;
  end else begin
    state_next  = ST_CONTROL;
    period_next = HDMI_PERIOD_CONTROL;
  end
end
```

Teda v cykle, kde `de_i/de_r` už padlo na 0, nesmie byť `period_next = VIDEO`.

To je presne chyba, ktorú opisuješ.

---

# Či opraviť assertion alebo scheduler?

Moje odporúčanie:

## Assertion neopravovať ako prvý krok

Tento assertion je správny, ak platí:

```text
period_o má byť zarovnaný s de_r.
```

Ale ak `period_o` je zámerne „scheduler stage“ a nie „mux stage“, potom assertion musí používať zodpovedajúci oneskorený DE.

Preto by som najprv pomenoval signály podľa pipeline stage:

```systemverilog
period_sched_o      // výstup schedulera
period_mux_sel      // výber v channel muxe
de_sched
de_enc_aligned
```

Teraz máš pravdepodobne miešanie týchto významov.

---

# Najdôležitejší test: sleduj reálne TMDS vetvy

Pre scenár S2:

```text
ENABLE_DATA_ISLAND = 1
ENABLE_AUDIO       = 0
```

potrebuješ logovať nielen `period_o`, ale aj to, čo ide do `hdmi_channel_mux`.

Najdôležitejšie otázky:

```text
1. Vyberie mux ešte VIDEO encoder v cykle, kde už de_aligned=0?
2. Vyberie mux CONTROL encoder počas prvého aktívneho pixelu?
3. Sú prvé 1–2 pixely riadku nahradené guard bandom/control symbolom?
4. Je posledný pixel riadku nahradený control/data symbolom?
```

Presne toto môže spôsobovať horizontálny posun alebo rozbitie prvých riadkov.

---

## Assertion pre channel mux

Ak máš v muxe niečo ako:

```systemverilog
case (period_i)
  HDMI_PERIOD_VIDEO: ch = video_tmds;
  ...
endcase
```

tak si v testbenchi vytvor kontrolu:

```systemverilog
always_ff @(posedge pix_clk) begin
  if (rst_n) begin
    if (period_mux == HDMI_PERIOD_VIDEO && !de_mux_aligned) begin
      $error("MUX selects VIDEO outside aligned DE at cy=%0d", cy);
    end

    if (de_mux_aligned && period_mux != HDMI_PERIOD_VIDEO) begin
      $error("MUX does not select VIDEO during aligned DE at cy=%0d", cy);
    end
  end
end
```

Druhá kontrola je rovnako dôležitá. Prvá chytá „video presahuje za DE“, druhá chytá „začiatok aktívneho videa je zjedený preamble/controlom“.

---

# Kľúčové: video encoder má 2-cyklovú latenciu

Ak `tmds_video_encoder` má 2 cykly latenciu, potom musí mux vyberať video vetvu podľa `de` oneskoreného o 2 cykly, nie podľa aktuálneho `de`.

Teda konceptuálne:

```text
rgb_i/de_i
  ↓ 2 cykly
video_tmds_o
  ↓
mux musí použiť period/de oneskorené rovnako
```

Ak mux používa iba `period_d1`, ale video encoder má 2 cykly, tak môžeš mať stále 1-cyklový posun.

Toto je extrémne dôležité.

Ak je realita:

```text
video encoder latency   = 2
control encoder latency = 2
TERC4 encoder latency   = po oprave 2
period_d1               = 1
```

potom `period_d1` nestačí. Potrebuješ `period_d2`.

Čiže v `hdmi_tx_core.sv` by malo byť niečo ako:

```systemverilog
hdmi_period_e period_d1;
hdmi_period_e period_d2;

always_ff @(posedge pix_clk_i) begin
  if (!rst_ni) begin
    period_d1 <= HDMI_PERIOD_CONTROL;
    period_d2 <= HDMI_PERIOD_CONTROL;
  end else begin
    period_d1 <= period_sched;
    period_d2 <= period_d1;
  end
end
```

a do `hdmi_channel_mux` ísť:

```systemverilog
.period_i(period_d2)
```

Nie `period_d1`.

---

# Toto môže priamo súvisieť s tvojím reálnym bugom

Písal si, že pri určitých režimoch vznikal problém s horizontálnym posunom prvých riadkov. Ak mux vyberá nesprávnu vetvu o 1 cyklus pri prechode:

```text
CONTROL/DATA → VIDEO
```

alebo:

```text
VIDEO → CONTROL
```

tak presne vzniknú efekty typu:

```text
- prvý pixel riadku je zlý,
- posledný pixel riadku je ešte video mimo DE,
- riadok sa javí posunutý,
- monitor dostane neplatné symboly pri hranách,
- pri audio/data island záťaži sa link zhorší.
```

Takže ďalší krok by mal byť hlavne pipeline audit.

---

# Odporúčaný audit pipeline

Sprav tabuľku pre každý signál:

```text
signál                  latency
--------------------------------
rgb_i                   0
de_i                    0
hsync_i/vsync_i          0
scheduler period_o       ?
video_tmds_o             2
control_tmds_o           2
terc4_tmds_o             2
period do muxu           musí byť 2
hsync/vsync do formatter  musí sedieť s formatter stage
```

Cieľ:

```text
všetko, čo vstupuje do channel muxu, musí byť v rovnakom časovom stage.
```

Ak encodery dávajú výstup po 2 cykloch, tak aj `period`, `de`, `hsync`, `vsync`, `data island nibble select` musia byť konzistentne oneskorené alebo už vnútri formatteru registrované tak, aby sa stretli v rovnakom cykle.

---

# Moja odporúčaná oprava v poradí

## 1. Nechaj assertion `VIDEO outside de_r`

Zatiaľ ho nepovoľuj ako výnimku.

## 2. Pridaj `period_d2`

Ak teraz používaš `period_d1` do muxu, zmeň to na `period_d2`.

```systemverilog
always_ff @(posedge pix_clk_i) begin
  if (!rst_ni) begin
    period_d1 <= HDMI_PERIOD_CONTROL;
    period_d2 <= HDMI_PERIOD_CONTROL;
  end else begin
    period_d1 <= period_o;
    period_d2 <= period_d1;
  end
end
```

a:

```systemverilog
hdmi_channel_mux u_mux (
  .period_i(period_d2),
  ...
);
```

## 3. Pridaj `de_d2` do simulácie

```systemverilog
always_ff @(posedge pix_clk) begin
  if (!rst_n) begin
    de_d1 <= 1'b0;
    de_d2 <= 1'b0;
  end else begin
    de_d1 <= de_r;
    de_d2 <= de_d1;
  end
end
```

a kontroluj:

```systemverilog
if (period_d2 == HDMI_PERIOD_VIDEO && !de_d2)
  $error("MUX VIDEO outside de_d2");
```

## 4. Ak stále zlyháva, oprav `ST_VIDEO`

V scheduleri zabezpeč:

```systemverilog
ST_VIDEO: begin
  if (de_i) begin
    period_next = HDMI_PERIOD_VIDEO;
    state_next  = ST_VIDEO;
  end else begin
    period_next = HDMI_PERIOD_CONTROL;
    state_next  = ST_CONTROL;
  end
end
```

## 5. Zopakuj všetky S1/S2 testy

Najmä:

```text
S1: DATA_ISLAND=0, AUDIO=0
S2: DATA_ISLAND=1, AUDIO=0
```

S2 je teraz najdôležitejší, pretože je známe, že na HW ide, ale môže spôsobovať posun alebo skryté chyby.

---

# Čo očakávam po oprave

Po správnom pipeline zarovnaní by si mal vidieť:

```text
DATA_PAYLOAD = 32 ✓
DATA_PREAMBLE = 8 ✓
GB = 2 ✓
VIDEO_GB = 2 ✓
VIDEO_PREAMBLE = 8 ✓
VIDEO only during aligned DE ✓
aligned DE only during VIDEO ✓
```

A hlavne:

```text
žiadny posledný VIDEO cyklus po de_fall
žiadny prvý DE cyklus mimo VIDEO
```

---

## Krátky verdikt

Toto nevyzerá ako chyba testbenchu. Vyzerá to ako skutočný **1-cyklový pipeline mismatch** medzi schedulerom, DE a mux výberom.

Najsilnejší kandidát na opravu:

```text
period do hdmi_channel_mux má byť oneskorený o rovnakú latenciu ako encodery, pravdepodobne period_d2, nie period_d1.
```

A zároveň treba upratať `ST_VIDEO`, aby pri `de=0` už negeneroval `VIDEO`.

Najbližší praktický krok: **zanalyzuj S2 na úrovni mux výberu s `period_d1`, `period_d2`, `de_d1`, `de_d2`**. To ti jednoznačne povie, či problém len vyzerá ako chyba v `period_o`, alebo sa reálne dostáva na `ch0/ch1/ch2`.
