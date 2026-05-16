Skontroloval som aktuálne nahraté simulačné súbory priamo z `/mnt/data`.

## Manifest aktuálnej TB sady

| Súbor                         |  SHA256 prefix |
| ----------------------------- | -------------: |
| `Makefile`                    | `0f25d5d84af6` |
| `tb_hdmi_tmds_decode.sv`      | `37ad98e7e446` |
| `tb_hdmi_tx_core_32x10.sv`    | `520729190a0a` |
| `tb_hdmi_period_scheduler.sv` | `070f986caec3` |
| `transcript`                  | `6507e22fa677` |

## Čo aktuálna simulácia potvrdzuje

`transcript` je beh testu:

```text
tb_hdmi_tmds_decode
```

a skončil úspešne:

```text
PKT_DEC GCP #1  HB={00 00 00}  BCH_hdr=0e  BCH_sp0=f5
PKT_DEC AVI #1  HB={82 02 0d}  PB0=0x3f PB1=0x10
PKT_DEC GCP #2  HB={00 00 00}  BCH_hdr=0e  BCH_sp0=f5
PKT_DEC AVI #2  HB={82 02 0d}  PB0=0x3f PB1=0x10
PKT_DEC GCP #3  HB={00 00 00}  BCH_hdr=0e  BCH_sp0=f5
PKT_DEC AVI #3  HB={82 02 0d}  PB0=0x3f PB1=0x10
--- GCP decoded: 3  AVI decoded: 3  guard bands: 24 ---
ALL ASSERTIONS PASSED
```

Toto je veľmi dobrý výsledok. Znamená to, že na úrovni `hdmi_tx_core → TERC4 output ch0/ch1/ch2` sa dajú data-island packety spätne dekódovať a obsah sedí:

```text
GCP:
  HB = 00 00 00
  BCH header = 0x0E
  BCH subpacket 0 = 0xF5

AVI:
  HB = 82 02 0D
  PB0 = 0x3F
  PB1 = 0x10
  checksum OK

Guard band:
  zachytený 24×
```

Čiže simulačne je teraz overené viac než predtým: nejde len o dĺžky periód, ale aj o spätné dekódovanie TERC4 payloadu.

---

## Dôležité obmedzenie

Aktuálny `tb_hdmi_tmds_decode.sv` je pevne nastavený na:

```systemverilog
.ENABLE_GCP_PACKET(1),
.ENABLE_AVI_PACKET(1),
.ENABLE_ACR_PACKET(0),
.ENABLE_AUDIO_INFOFRAME(0),
.ENABLE_AUDIO_SAMPLE(0)
```

Čiže tento test overuje hlavne **2D: GCP + AVI**.

Nepokrýva samostatné varianty:

```text
2A: GCP=0 AVI=0
2B: GCP=1 AVI=0
2C: GCP=0 AVI=1
```

Naopak `tb_hdmi_tx_core_32x10.sv` už generiká pre `ENABLE_GCP_PACKET` a `ENABLE_AVI_PACKET` má, takže je vhodný na 2A–2D izoláciu.

---

## Makefile stav

Aktuálny `Makefile` už obsahuje:

```makefile
tmds_decode
```

a `all` spúšťa:

```makefile
bch_ecc
terc4_encoder
data_island
scheduler
acr_packet
audio_sample_pkt
tx_core_32x10
audio_scenarios
tmds_decode
```

Má aj samostatný target:

```makefile
di_isolation
```

ktorý spúšťa 2A–2D cez `tb_hdmi_tx_core_32x10`.

To je dobré.

Ale `di_isolation` **nie je súčasťou `all`**. Momentálne `all` obsahuje `tmds_decode`, ale nie `di_isolation`.

Odporúčam zmeniť:

```makefile
all: bch_ecc terc4_encoder data_island scheduler acr_packet audio_sample_pkt \
     tx_core_32x10 audio_scenarios tmds_decode
```

na:

```makefile
all: bch_ecc terc4_encoder data_island scheduler acr_packet audio_sample_pkt \
     tx_core_32x10 di_isolation audio_scenarios tmds_decode
```

Pretože práve 2A–2D sú teraz najdôležitejšie HW-debug scenáre.

---

## Čo z toho vyplýva pre aktuálny HW problém

Máme:

```text
HW:
  2A PASS
  2B FAIL
  2C FAIL

SIM:
  2D GCP+AVI decode PASS
```

To znamená, že v simulácii je packet obsah a TERC4 decode správny, ale reálny monitor stále stráca signál pri reálnom data-island packete.

Tým sa zvyšuje podozrenie na jednu z týchto vecí:

```text
1. Guard band / TERC4 / control symboly sú simulačne konzistentné, ale fyzická bitová konvencia voči serializeru je iná.
2. PHY serializuje video/control dostatočne dobre, ale data island symboly odhalia bit-order alebo alignment problém.
3. Monitor Samsung je citlivý na data islandy v 800×600 VESA režime.
4. Data island je časovo platný v mini sim móde, ale v reálnom 800×600 je umiestnenie vo frame/blankingu iné.
```

---

## Najbližšie odporúčané sim zlepšenie

Pridal by som do `tb_hdmi_tmds_decode.sv` generiká:

```systemverilog
parameter bit ENABLE_GCP_PACKET = 1;
parameter bit ENABLE_AVI_PACKET = 1;
```

a použiť ich v DUT:

```systemverilog
.ENABLE_GCP_PACKET(ENABLE_GCP_PACKET),
.ENABLE_AVI_PACKET(ENABLE_AVI_PACKET),
```

Potom pridať Makefile targety:

```makefile
tmds_decode_2b:
	vsim -G ENABLE_GCP_PACKET=1 -G ENABLE_AVI_PACKET=0 ...

tmds_decode_2c:
	vsim -G ENABLE_GCP_PACKET=0 -G ENABLE_AVI_PACKET=1 ...

tmds_decode_2d:
	vsim -G ENABLE_GCP_PACKET=1 -G ENABLE_AVI_PACKET=1 ...
```

Cieľ:

```text
2B SIM decode:
  GCP decoded > 0
  AVI decoded = 0
  GCP obsah OK

2C SIM decode:
  GCP decoded = 0
  AVI decoded > 0
  AVI obsah OK
```

Nie je to blokujúce, ale zosúladí to sim presne s HW maticou.

---

## Najbližší HW krok ostáva T2/T3

Keďže si predtým mal:

```text
T1: DATA_PREAMBLE only → PASS
```

a full packety zlyhávajú, ďalší najlepší HW test je stále:

```text
T2: DATA_PREAMBLE + DATA_GB_LEAD + DATA_GB_TRAIL, bez payloadu
```

Ak T2 zlyhá, problém je guard band / bitová konvencia.
Ak T2 prejde, pokračuj T3: jeden payload symbol.

## Krátky verdikt

Aktuálne simulácie sú dobrý krok dopredu:

```text
PASS: GCP/AVI sa dajú spätne dekódovať z TERC4 výstupu.
PASS: BCH header/subpacket pre GCP sedí.
PASS: AVI checksum sedí.
PASS: guard bandy sú v sim zachytené.
```

Ale pre HW problém ešte treba zistiť, či reálny monitor padá na:

```text
T2: guard band
T3: prvý payload symbol
T0: celý payload
```

Najbližší rozhodujúci test je teda **DEBUG_ISLAND_PHASES=2** na FPGA.
