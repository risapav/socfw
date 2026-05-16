Výborne — toto je zásadný posun.

Skontroloval som nahraté súbory. Aktuálny `soc_top.sv` je nastavený takto:

```systemverilog
.DEBUG_ISLAND_PHASES(1),
.ENABLE_ACR_PACKET(0),
.ENABLE_AUDIO(0),
.ENABLE_AUDIO_INFOFRAME(0),
.ENABLE_AUDIO_SAMPLE(0),
.ENABLE_AVI_PACKET(1),
.ENABLE_DATA_ISLAND(1),
.ENABLE_GCP_PACKET(0),
.GCP_FRAME_PERIOD(1),
.VBLANK_ONLY(1)
```

To znamená, že reálny FPGA PASS bol pre:

```text
DATA=1
AUDIO=0
GCP=0
AVI=1
VBLANK_ONLY=1
DEBUG_ISLAND_PHASES=1
```

A `DEBUG_ISLAND_PHASES=1` podľa komentára v `hdmi_period_scheduler.sv` znamená:

```text
T1: DATA_PREAMBLE only
bez guard bandu
bez payloadu
```

## Čo tento PASS dokazuje

Tento PASS **nedokazuje, že AVI packet je v poriadku**. Dokazuje niečo ešte dôležitejšie pre debug:

```text
DATA_PREAMBLE samotný monitor nezahodí.
```

Čiže už vieme:

```text
2A: no packet / no island             PASS
T1: data preamble only                PASS
2B: full GCP packet                   FAIL
2C: full AVI packet                   FAIL
```

Tým sa problém zužuje. Už to pravdepodobne nie je samotný data preamble mapping.

## Čo testovať ďalej

Teraz pokračuj presne po fázach:

### T2 — preamble + data guard bands, bez payloadu

Nastav:

```systemverilog
.DEBUG_ISLAND_PHASES(2),
.ENABLE_DATA_ISLAND(1),
.ENABLE_GCP_PACKET(0),
.ENABLE_AVI_PACKET(1),
.VBLANK_ONLY(1),
.ENABLE_AUDIO(0)
```

Očakávanie:

```text
Ak T2 PASS:
  data guard bandy sú pravdepodobne OK.

Ak T2 FAIL:
  problém je takmer určite v DATA_GB_LEAD / DATA_GB_TRAIL symboloch
  alebo ich channel/bit-order konvencii.
```

### T3 — preamble + guard + 1 payload symbol

Nastav:

```systemverilog
.DEBUG_ISLAND_PHASES(3)
```

Očakávanie:

```text
Ak T2 PASS, T3 FAIL:
  problém je TERC4/payload začiatok alebo formatter/mux zarovnanie.

Ak T3 PASS, full packet FAIL:
  problém je v dĺžke payloadu, postupnosti 32 symbolov,
  ECC/payload obsahu alebo trailing boundary.
```

### T0 / normal — plný packet

Potom:

```systemverilog
.DEBUG_ISLAND_PHASES(0)
```

To je normálny full data island.

## Interpretácia aktuálneho PASS

Aktuálny PASS s `DEBUG_ISLAND_PHASES=1` hovorí:

```text
DATA_PREAMBLE control symboly na reálnom HDMI linku monitor toleruje.
Problém začína až po preamble — teda guard alebo payload.
```

To je veľmi užitočné.

## Dopíš do test matrix

Pridal by som do `TEST_MATRIX.md` novú diagnostickú sekciu:

```markdown
### Data island phase isolation

| #  | DEBUG_ISLAND_PHASES | Meaning                         | Result | Notes |
|----|---------------------|----------------------------------|--------|-------|
| T1 | 1                   | DATA_PREAMBLE only               | PASS   | stable image |
| T2 | 2                   | DATA_PREAMBLE + data guard bands |        |       |
| T3 | 3                   | preamble + guard + 1 payload     |        |       |
| T0 | 0                   | full 32-symbol payload           | FAIL   | GCP/AVI-only no signal |
```

## Najbližší krok

Najbližší rozhodujúci test je:

```text
DEBUG_ISLAND_PHASES=2
```

Ak T2 zlyhá, máš vinníka: **data guard band konštanty alebo ich priradenie na kanály**.

Ak T2 prejde, pokračuj T3.
