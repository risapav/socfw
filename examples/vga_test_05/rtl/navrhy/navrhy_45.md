Aktuálne logy sú konzistentné a všetky nahraté simulácie prešli.

## Regression stav

`regression_full.log` končí:

```text
HDMI SIM REGRESSION PASSED
```

a posledný test `tb_hdmi_tmds_decode` tiež prešiel:

```text
GCP decoded: 3
AVI decoded: 3
guard bands: 24
ALL ASSERTIONS PASSED
```

## Prehľad testov

| Test                             | Výsledok | Dôležitý obsah                                                |
| -------------------------------- | -------: | ------------------------------------------------------------- |
| `tb_hdmi_bch_ecc`                |     PASS | GCP all-zero header ECC `0x0e`, SP all-zero ECC `0xf5`        |
| `tb_terc4_encoder`               |     PASS | 2-cycle latency potvrdená, všetkých 16 symbolov OK            |
| `tb_data_island_formatter`       |     PASS | formatter unit test OK                                        |
| `tb_hdmi_period_scheduler`       |     PASS | `DATA_PAYLOAD=32`, `packet_pop=31`, no DE overlap             |
| `tb_acr_packet_builder`          |     PASS | ACR packet builder OK                                         |
| `tb_audio_sample_packet_builder` |     PASS | audio sample packet builder OK                                |
| `tb_hdmi_tx_core_32x10`          |     PASS | GCP/AVI packet starty, BCH hodnoty, period timing OK          |
| `tb_hdmi_tmds_decode`            |     PASS | GCP aj AVI spätne dekódované z TERC4 výstupu                  |
| audio scenario TBs               |     PASS | ACR-only, IF-only, sample-only, full audio bez assertion chýb |

## Najdôležitejší dôkaz z logov

`tb_hdmi_tmds_decode.log` je teraz najhodnotnejší, lebo potvrdzuje end-to-end cestu:

```text
ch0/ch1/ch2
→ TERC4 decode
→ GCP/AVI packet fields
→ BCH/ECC kontrola
```

Pre GCP:

```text
HB = 00 00 00
BCH_hdr = 0e
BCH_sp0 = f5
```

Pre AVI:

```text
HB = 82 02 0d
PB0 = 0x3f
PB1 = 0x10
```

Čiže simulačne je packet obsah na `ch*_o` správny.

## Dôležitá poznámka k umiestneniu packetu

V `tb_hdmi_tx_core_32x10.log` je vidieť:

```text
PKT_START cy=7216 col=48 row=0 blank_rem=65 vblank=0 hb=00 00 00
```

To znamená, že v tejto sim konfigurácii sa GCP vkladá pri:

```text
vblank = 0
```

Čiže tento konkrétny `tb_hdmi_tx_core_32x10` log nie je VBLANK-only test. Ak chceš overovať režim `VBLANK_ONLY=1`, treba mať samostatný sim target alebo generiká, ktoré kontrolujú:

```text
pri každom PKT_START musí byť vblank=1
```

Toto je dôležité, lebo HW debug teraz pracuje aj s `VBLANK_ONLY=1`.

## Čo z logov vyplýva pre HW problém

Keďže HW má:

```text
2A PASS
2B FAIL
2C FAIL
T1 PASS
```

ale simulácia hovorí:

```text
GCP decode OK
AVI decode OK
guard bands detegované
scheduler OK
TERC4 OK
```

tak najbližší podozrivý už nie je packet obsah v RTL, ale rozdiel medzi simulovaným `ch*_o` a reálnym fyzickým HDMI výstupom, alebo fáza data islandu, ktorú ešte HW nerozlíšil.

Najdôležitejšie ďalšie HW testy ostávajú:

```text
T2: DEBUG_ISLAND_PHASES=2
    DATA_PREAMBLE + DATA_GB_LEAD + DATA_GB_TRAIL
    bez payloadu

T3: DEBUG_ISLAND_PHASES=3
    preamble + guard + 1 payload symbol
```

Interpretácia:

```text
T2 FAIL:
  problém je data guard band alebo jeho fyzická bitová/kanálová konvencia.

T2 PASS, T3 FAIL:
  problém je TERC4/payload fyzická konvencia.

T3 PASS, full packet FAIL:
  problém je dlhý payload / opakovanie / boundary / sink kompatibilita.
```

## Odporúčaná sim doplnková kontrola

Pridal by som ešte jeden target pre `VBLANK_ONLY=1`, ktorý overí:

```text
každý packet_start má vblank=1
```

a ideálne vypíše:

```text
PKT_START row, col, blank_remaining, vblank, hb
```

Pretože aktuálny log ukazuje `vblank=0`, čo je dobré pre bežný režim, ale nie pre aktuálny HW experiment s `VBLANK_ONLY`.
