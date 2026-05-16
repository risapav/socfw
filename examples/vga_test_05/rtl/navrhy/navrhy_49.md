Toto je dôležitý výsledok: pri **2A/no-packet** sa v aktívnom obraze stále prejaví posun. Tým sa chyba posúva mimo packet obsah a mimo GCP/AVI.

Aktuálna konfigurácia je:

```text
DATA=1
AUDIO=0
GCP=0
AVI=0
VBLANK_ONLY=1
DEBUG_ISLAND_PHASES=0
```

V tomto režime sa nemá vložiť žiadny data island. Ak sa obraz aj tak posunie doprava a vľavo vznikne zelená čiara, potom je problém v **VIDEO period alignmente**, nie v data island pakete.

## Najpravdepodobnejšia príčina

V `hdmi_tx_core.sv` je táto časť:

```systemverilog
hdmi_period_scheduler u_sched (
  .de_i              (de_r),
  .hblank_i          (hblank_rr),
  .vblank_i          (vblank_r),
  .blank_remaining_i (blank_remaining_rr),
  ...
);
```

Teda scheduler rozhoduje podľa mixu signálov:

```text
de_r              = 1× registrované DE
hblank_rr         = 2× registrovaný hblank
blank_remaining_rr = 2× registrovaný blank_remaining
vblank_r          = 1× registrovaný vblank
```

To je podozrivé. Všetky signály, ktoré scheduler používa na rozhodovanie, musia byť v **rovnakej pipeline fáze**.

Keď sú `de_r`, `hblank_rr` a `blank_remaining_rr` vzájomne posunuté, scheduler môže spustiť:

```text
VIDEO_PREAMBLE
VIDEO_GB
VIDEO
```

o niekoľko cyklov mimo skutočného začiatku platných RGB dát. Výsledok presne sedí:

```text
ľavá zelená čiara
obraz posunutý doprava
```

## Dôležitý dôsledok

Tvoj predchádzajúci 2A „PASS“ by som teraz preklasifikoval na:

```text
2A PARTIAL — obraz je viditeľný, ale posunutý doprava / zelená čiara vľavo.
```

Nie je to čistý PASS.

## Čo by som otestoval ako prvé

### Test A — odstrániť extra oneskorenie `hblank_rr` / `blank_remaining_rr`

Skús dočasne v `hdmi_tx_core.sv` pripojiť scheduler takto:

```systemverilog
.hblank_i          (hblank_r),
.blank_remaining_i (blank_remaining_r),
```

namiesto:

```systemverilog
.hblank_i          (hblank_rr),
.blank_remaining_i (blank_remaining_rr),
```

Teda:

```systemverilog
hdmi_period_scheduler #(
  .ENABLE_DATA_ISLAND  (ENABLE_DATA_ISLAND),
  .VBLANK_ONLY         (VBLANK_ONLY),
  .DEBUG_ISLAND_PHASES (DEBUG_ISLAND_PHASES)
) u_sched (
  .clk_i             (pix_clk_i),
  .rst_ni            (rst_ni),
  .de_i              (de_r),
  .hblank_i          (hblank_r),
  .vblank_i          (vblank_r),
  .blank_remaining_i (blank_remaining_r),
  .packet_pending_i  (packet_pending),
  .packet_start_o    (packet_start),
  .packet_pop_o      (packet_pop),
  .period_o          (period)
);
```

Potom zopakuj 2A:

```text
DATA=1, GCP=0, AVI=0
```

Ak sa zelená čiara posunie alebo zmizne, potvrdíš, že problém je pipeline alignment.

### Test B — použiť `period`, nie `period_d1`

Teraz mux používa:

```systemverilog
.period_i(period_d1)
```

Skús dočasne:

```systemverilog
.period_i(period)
```

Ak sa posun zmení, potvrdí to, že `period_d1` je zle zarovnaný voči encoder výstupom.

### Test C — použiť `period_d2`

Ak `period` zhorší stav, skús opačne pridať ešte jeden stage:

```systemverilog
hdmi_period_t period_d2;

always_ff @(posedge pix_clk_i) begin
  if (!rst_ni)
    period_d2 <= HDMI_PERIOD_CONTROL;
  else
    period_d2 <= period_d1;
end
```

a:

```systemverilog
.period_i(period_d2)
```

Tým zistíš smer chyby.

## Najlepšia simulačná kontrola

Pridaj do `tb_hdmi_tx_core_32x10.sv` alebo nového porovnávacieho TB test:

```text
DVI mode:
  ENABLE_DATA_ISLAND=0

2A mode:
  ENABLE_DATA_ISLAND=1
  ENABLE_GCP_PACKET=0
  ENABLE_AVI_PACKET=0

Porovnať:
  prvý aktívny pixel každého riadku
  posledný aktívny pixel každého riadku
  počet VIDEO cyklov
  pozíciu VIDEO voči de
```

V 2A režime nesmie byť aktívny obraz posunutý ani o jeden pixel oproti baseline. Ak sa líši, test má zlyhať.

## Najdôležitejší invariant

Pre 2A musí platiť:

```text
packet_pending = 0
⇒ scheduler nikdy nesmie prejsť do DATA_PREAMBLE / DATA_GB / DATA_PAYLOAD
⇒ aktívna video oblasť musí byť časovo zhodná s DATA_ISLAND=0 režimom
```

Ak sa obraz posúva aj bez packetu, musíš najprv opraviť toto. Inak T2/T3/2B/2C výsledky môžu byť zavádzajúce.

## Praktický ďalší krok

Neskočil by som ešte na T2/T3. Najprv oprav/over **2A alignment**.

Navrhované poradie:

```text
1. 2A s hblank_r / blank_remaining_r namiesto rr
2. 2A s period namiesto period_d1
3. 2A s period_d2
4. až keď 2A bude čistý obraz bez posunu, pokračovať T2/T3
```

Najpravdepodobnejší koreň je teraz:

```text
nesúlad pipeline fázy medzi de_r, hblank_rr, blank_remaining_rr a period_d1
```

a nie HDMI packet obsah.
