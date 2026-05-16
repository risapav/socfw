Doplnenie „no signal“ pri #2 je zásadné. Teraz máme:

```text
#1 DATA=0 AUDIO=0 → PASS
#2 DATA=1 AUDIO=0 → FAIL: no signal
```

v presne označenej HW konfigurácii: QMTech EP4CE55F23C8, 800×600@60, commit/hash `d39ff93`, monitor Samsung LS29E790CNS/EN, pričom simulačný regression je 11/11 PASS.

To znamená: **nepokračovať na audio testy #3–#9**. Zlyháva základný HDMI data-island režim bez audia.

## Najpravdepodobnejšie príčiny pri „no signal“

Keď DVI režim ide, ale data-island režim dá „no signal“, najpravdepodobnejšie je, že po zapnutí `ENABLE_DATA_ISLAND` sa fyzický TMDS tok stane neplatným pre sink. Nie je to audio-rate problém. Kandidáti v poradí:

```text
1. nesprávne DATA_GB_LEAD / DATA_GB_TRAIL symboly,
2. nesprávny DATA_PREAMBLE mapping na kanáloch,
3. data-island payload ešte stále nie je správne zarovnaný na finálnom ch*_o,
4. BCH/ECC alebo byte/nibble order pre GCP/AVI je odlišný od očakávania sinku,
5. scheduler vkladá data island príliš blízko video preamble / active video,
6. GCP/AVI sa posielajú v nevhodnom čase vo frame.
```

## Ďalší krok: nerozširovať audio, ale rozbiť test #2

Pridaj dočasné debug parametre pre data-island-only režim:

```systemverilog
parameter bit ENABLE_GCP_PACKET = 1;
parameter bit ENABLE_AVI_PACKET = 1;
```

a urob tri HW varianty:

```text
2A: DATA=1, AUDIO=0, GCP=0, AVI=0
2B: DATA=1, AUDIO=0, GCP=1, AVI=0
2C: DATA=1, AUDIO=0, GCP=0, AVI=1
2D: DATA=1, AUDIO=0, GCP=1, AVI=1
```

Interpretácia:

```text
2A FAIL → problém je data-island period/preamble/guard/mux, nie packet obsah.
2A PASS, 2B FAIL → problém je GCP packet/layout/ECC.
2A PASS, 2C FAIL → problém je AVI packet/layout/checksum/ECC.
2B PASS, 2C PASS, 2D FAIL → problém je sekvencia alebo timing medzi packetmi.
```

Ak nevieš jednoducho poslať „DATA=1 bez paketov“, sprav dočasný variant, kde `packet_pending_i=0`, ale `ENABLE_DATA_ISLAND=1` ostane zapnuté. Cieľ je zistiť, či samotná prítomnosť data-island FSM logiky mení video cestu, alebo až reálny packet.

## Simulačný test, ktorý teraz chýba

Keďže sim 11/11 prešla, ale monitor hlási „no signal“, treba doplniť kontrolu mimo samotného payloadu:

```text
DATA_PREAMBLE presné TMDS control symboly na ch0/ch1/ch2,
DATA_GB_LEAD presné 10-bit symboly na ch0/ch1/ch2,
DATA_PAYLOAD TERC4 symboly 0..31,
DATA_GB_TRAIL presné 10-bit symboly,
návrat do CONTROL alebo VIDEO_PREAMBLE bez off-by-one.
```

Doteraz sme sa sústredili najmä na payload. Pri „no signal“ v #2 je rovnako podozrivý **guard band** a **preamble mapping**.

## Čo zapísať do `TEST_MATRIX.md`

Doplň pod #2 do Notes viac detailov:

```text
FAIL: no signal immediately after enabling DATA=1/AUDIO=0; DVI baseline #1 PASS on same bitstream family/monitor.
```

A pridaj pod tabuľku dočasnú sekciu:

```markdown
### Data island debug sub-matrix

| #  | DATA | AUDIO | GCP | AVI | Expected | Result | Notes |
|----|------|-------|-----|-----|----------|--------|-------|
| 2A | 1    | 0     | 0   | 0   | Stable image; no packets inserted |        |       |
| 2B | 1    | 0     | 1   | 0   | Stable image; GCP only |        |       |
| 2C | 1    | 0     | 0   | 1   | Stable image; AVI only |        |       |
| 2D | 1    | 0     | 1   | 1   | Stable image; GCP+AVI | FAIL   | no signal |
```

## Verdikt

Stav teraz nie je „audio bug“. Je to:

```text
HDMI data-island bring-up bug.
```

Najbližší konkrétny cieľ: **izolovať, či zlyháva samotný data-island timing/guard/preamble, alebo konkrétne GCP/AVI packet payload.**
