Potvrdzujem: aktuálne logy ukazujú **kompletný simulačný PASS 13/13** vrátane nového PHY loopback testu.

## Stav simulácie

`regression_full.log` končí úspešne:

```text
HDMI SIM REGRESSION PASSED
```

a všetky jednotlivé logy majú `Errors: 0`.

Prehľad:

| Test                             | Výsledok |
| -------------------------------- | -------: |
| `tb_hdmi_bch_ecc`                |     PASS |
| `tb_terc4_encoder`               |     PASS |
| `tb_data_island_formatter`       |     PASS |
| `tb_hdmi_period_scheduler`       |     PASS |
| `tb_acr_packet_builder`          |     PASS |
| `tb_audio_sample_packet_builder` |     PASS |
| `tb_hdmi_tx_core_32x10`          |     PASS |
| `tb_di_2a`                       |     PASS |
| `tb_di_2b`                       |     PASS |
| `tb_di_2c`                       |     PASS |
| `tb_di_2d`                       |     PASS |
| `tb_hdmi_tmds_decode`            |     PASS |
| `tb_tmds_phy_loopback`           |     PASS |
| audio scenario logs              |     PASS |

Presnejšie: regression obsahuje aj audio scenáre `ACR only`, `Audio IF only`, `Sample only`, `Full audio`, všetky bez assertion failures.

## Najdôležitejšie výsledky

### 1. Data-island izolácia 2A–2D prešla v simulácii

```text
2A: GCP=0 AVI=0 → GCP packets 0, AVI packets 0 → PASS
2B: GCP=1 AVI=0 → GCP packets 4, AVI packets 0 → PASS
2C: GCP=0 AVI=1 → GCP packets 0, AVI packets 4 → PASS
2D: GCP=1 AVI=1 → GCP packets 4, AVI packets 3 → PASS
```

Tým je simulačne potvrdené, že gating `ENABLE_GCP_PACKET` / `ENABLE_AVI_PACKET` funguje a že samostatné aj kombinované data-island scenáre sú korektné.

### 2. `tb_hdmi_tmds_decode` dekóduje reálne výstupné TMDS symboly

Log potvrdzuje:

```text
PKT_DEC GCP #3  HB={00 00 00}  BCH_hdr=0e  BCH_sp0=f5
PKT_DEC AVI #3  HB={82 02 0d}  PB0=0x3f PB1=0x10
--- GCP decoded: 3  AVI decoded: 3  guard bands: 24 ---
ALL ASSERTIONS PASSED
```

To znamená, že na úrovni `hdmi_tx_core → ch0/ch1/ch2 → TERC4 decode` je packet obsah správny.

### 3. PHY loopback prešiel

Najdôležitejší riadok:

```text
PHY [GB_mixed] ch0=1010001110 ch1=0101110001 ch2=1011000110 clk=1111100000
PHY [PAYLOAD_ch0] ch0=1010011100 ch1=0101110001 ch2=1011000110 clk=1111100000
=== PHY loopback: 32 checks, 0 failure(s) ===
PHY LOOPBACK PASS
```

Toto je silný dôkaz, že **bit order cez DDR/PHY chain je v simulácii správny**, vrátane DATA_GB a TERC4 symbolov.

## Čo z toho vyplýva pre HW problém

Keďže simulácia teraz preukázala:

```text
packet obsah OK
BCH/ECC OK
TERC4 decode OK
guard bandy OK v sim
PHY bit order OK v sim
2A–2D OK v sim
```

ale HW mal:

```text
2A PASS
2B FAIL
2C FAIL
```

tak sa podozrenie presúva na rozdiel medzi sim a reálnym FPGA/monitorom:

```text
1. konkrétny Samsung monitor odmieta data islands v 800×600 VESA režime,
2. fyzická signal integrity / PMOD HDMI elektrika je hraničná pri data-island vzoroch,
3. reálny vendor ALTDDIO_OUT / pin packing sa správa inak než behavioral model,
4. VBLANK_ONLY alebo DEBUG_ISLAND_PHASES HW konfigurácia ešte nie je otestovaná po poslednom refaktore,
5. build/top parametre sa pri konkrétnom bitstreame líšia od simulovanej konfigurácie.
```

## Najbližší HW krok

Keďže T1 už bol PASS a plný packet zlyhával, pokračoval by som presne:

```text
T2: DEBUG_ISLAND_PHASES=2
    preamble + data guard bands
    bez payloadu

T3: DEBUG_ISLAND_PHASES=3
    preamble + guard + 1 payload symbol

T0: DEBUG_ISLAND_PHASES=0
    full packet
```

Interpretácia ostáva:

```text
T2 FAIL:
  problém je reálny data guard band alebo fyzická link/sink reakcia na guard phase.

T2 PASS, T3 FAIL:
  problém začína prvým TERC4 payload symbolom.

T3 PASS, T0 FAIL:
  problém je dlhý 32-symbol payload alebo sink kompatibilita s packetom.

T0 PASS:
  refaktor opravil problém, pokračovať na 2D/full HDMI.
```

## Poznámka k VBLANK_ONLY

V aktuálnych logoch je vidieť, že štandardný `tb_hdmi_tx_core_32x10` stále hlási packet start s `vblank=0` v niektorých scenároch. To nie je chyba, ak daný sim target nemá zapnuté `VBLANK_ONLY=1`.

Pre aktuálny HW experiment by som však pridal ešte jeden sim target:

```text
vblank_only_decode
```

ktorý assertuje:

```text
každý packet_start má vblank=1
```

Nie je to blokujúce, ale zlepší zhodu medzi HW testom a simuláciou.

## Záver

Simulačne je HDMI jadro teraz veľmi dobre pokryté. Najbližší rozhodujúci dôkaz už dá iba reálny FPGA test s:

```text
DEBUG_ISLAND_PHASES=2
```

Ak T2 prejde, pokračuj T3. Ak T2 zlyhá, problém je už veľmi úzko v reálnom data guard band / sink / fyzickej linke.
