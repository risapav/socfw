Toto je kľúčové zistenie:

```text
#2A DATA=1 AUDIO=0 GCP=0 AVI=0  PASS
#2B DATA=1 AUDIO=0 GCP=1 AVI=0  FAIL
#2C DATA=1 AUDIO=0 GCP=0 AVI=1  FAIL
```

Tým sa problém **presúva preč od konkrétneho GCP alebo AVI obsahu**. Zlyhá každý reálny data-island packet. To znamená, že hlavný kandidát je spoločná cesta:

```text
packet_start
→ scheduler DATA_PREAMBLE / DATA_GB / DATA_PAYLOAD / DATA_GB_TRAIL
→ data_island_formatter
→ TERC4
→ channel_mux
→ fyzický TMDS výstup
```

2A PASS hovorí, že samotné `ENABLE_DATA_ISLAND=1` video nerozbije, ak sa nevloží packet. 2B/2C FAIL hovorí, že prvý reálny data island zhodí monitor.

## Najpravdepodobnejší vinník teraz

Najviac podozrivá je **data-island guard band / preamble / mux vo finálnom TMDS výstupe**, nie payload konkrétneho packetu.

Aj keď simulácia tvrdí, že preamble/guard prechádzajú, reálny sink môže byť citlivý na presné 10-bit konštanty a ich kanálové priradenie.

Skontroluj hlavne tieto konštanty v `hdmi_pkg.sv` / `hdmi_channel_mux.sv`:

```text
DATA_GB na CH1/CH2
VIDEO_GB na CH1/CH2
DATA_PREAMBLE control symboly
```

Pre HDMI sú guard band symboly špecifické pre kanály. Chyba typu „CH1 a CH2 prehodené“, „použitý video GB namiesto data GB“, alebo „invertovaný bit order“ môže presne spôsobiť:

```text
DVI/video režim ide
data-island bez packetov ide
akýkoľvek data-island packet = no signal
```

## Teraz nerieš ACR/audio

Audio matica #3–#9 stále nemá zmysel. Zlyháva spoločný data-packet transport.

## Ďalší test: dummy packet s kontrolovaným payloadom

Vytvor diagnostický packet, ktorý nie je GCP ani AVI, ale používa rovnakú transportnú cestu:

```text
HB = 00 00 00
PB = všetko 00
```

To je v podstate GCP all-zero, takže už zlyháva.

Potom ešte skús:

```text
HB = FF FF FF
PB = FF alebo pattern AA/55
```

Nie ako platné HDMI, ale diagnosticky. Ak aj to zlyhá rovnakým spôsobom, potvrdené: problém je transport/preamble/guard, nie packet semantic.

Ale dôležitejší než dummy packet je ďalší test nižšie.

---

# Najdôležitejší ďalší test: data island bez payloadu, iba preamble + guard

Potrebujeme zistiť, či monitor zhodí už samotné:

```text
DATA_PREAMBLE + DATA_GB_LEAD + DATA_GB_TRAIL
```

alebo až `DATA_PAYLOAD`.

Pridaj dočasný debug parameter:

```systemverilog
parameter bit DEBUG_ZERO_LENGTH_DATA_ISLAND = 0;
```

V scheduleri sprav režim:

```text
DATA_PREAMBLE 8 cyklov
DATA_GB_LEAD 2 cykly
DATA_GB_TRAIL 2 cykly
bez DATA_PAYLOAD
```

alebo ešte lepšie dva režimy:

```text
T1: DATA_PREAMBLE only, potom CONTROL
T2: DATA_PREAMBLE + DATA_GB_LEAD + DATA_GB_TRAIL, bez payload
T3: DATA_PREAMBLE + DATA_GB_LEAD + 1 payload symbol + DATA_GB_TRAIL
```

Interpretácia:

```text
T1 FAIL:
  problém je DATA_PREAMBLE control mapping.

T1 PASS, T2 FAIL:
  problém je DATA_GB symbol.

T2 PASS, T3 FAIL:
  problém je TERC4/payload/formatter/advance.

T3 PASS, 32-symbol payload FAIL:
  problém je payload dĺžka/advance/trailing boundary.
```

Toto je najčistejší spôsob, ako nájsť hranicu zlyhania.

---

# Praktickejší rýchly test: vypnúť data guard band

Ak sa nechceš hneď hrať s nulovou dĺžkou payloadu, sprav dočasne:

```text
DATA_PREAMBLE → DATA_PAYLOAD → CONTROL
```

bez data guard bandov. Toto nie je štandardné HDMI, ale diagnosticky:

```text
Ak bez data GB monitor nespadne inak alebo správanie sa zmení,
guard band je silný kandidát.
```

No lepší je vyššie uvedený T1/T2/T3 postup.

---

# Skontroluj, či bit order 10-bit TMDS slov nie je problém iba pre TERC4/GB

Video funguje, takže video TMDS bit order je pravdepodobne dosť správny. Ale data island používa TERC4 a guard band konštanty, ktoré nemajú rovnaký running-disparity charakter ako video. Ak sú 10-bit slová posielané opačne, video môže byť náhodou tolerované menej? Skôr nie, ale guard/preamble budú určite zle.

Over v sim/PHY:

```text
ch*_o[0] ide ako prvý bit do serializeru?
alebo ch*_o[9] ide ako prvý?
```

HDMI/TMDS serializuje LSB-first pre 10-bit symbol. Ak PHY posiela opačne, video by zvyčajne tiež nešlo, takže toto nie je top kandidát. Ale ak video encoder generuje už obrátené slová a TERC4/GB nie, môže to byť reálny problém.

Skontroluj, či:

```text
tmds_video_encoder
tmds_control_encoder
terc4_encoder
guard band constants
```

všetky používajú rovnakú bit-order konvenciu.

Toto je veľmi dôležité.

---

# Silný kandidát: guard band konštanty nemajú rovnakú konvenciu ako encoder výstupy

Ak `tmds_video_encoder` na výstupe robí napríklad invertovanie alebo bitové usporiadanie podľa tvojej lokálnej PHY konvencie, ale guard band konštanty sú zapísané priamo zo špecifikácie bez prevrátenia, potom:

```text
video ide
control môže ísť
TERC4 payload možno simulačne sedí
ale fyzicky data guard band je zlý
```

Preto porovnaj konvenciu:

```systemverilog
tmds_control_encoder output for CTL=00
```

má byť rovnaká konvencia ako:

```systemverilog
GB_DATA_CHx constants
TERC4 LUT
VIDEO_GB constants
```

Ak kontrolné symboly v `tmds_control_encoder` sú bitovo reverzované oproti HDMI tabuľke, potom aj TERC4 a GB tabuľky musia byť v rovnakej reverzovanej konvencii.

## Urob jednoduchý test konvencie

V simulácii vypíš:

```text
CTL00 encoded ch0
TERC4(0)
DATA_GB_CH1
DATA_GB_CH2
VIDEO_GB_CH1
VIDEO_GB_CH2
```

A vedľa si zapíš, či sú to hodnoty:

```text
spec order
serializer order
bit-reversed order
```

Musí to byť konzistentné.

---

# Čo dopísať do TEST_MATRIX

Aktualizuj:

```text
2C FAIL — no signal; AVI-only fails while 2A passes.
```

A pridaj záver:

```text
2B + 2C both FAIL → failure is common data-island packet transport path, not GCP/AVI-specific.
```

---

# Najbližší konkrétny plán

1. Zastaviť audio testy.
2. Overiť bit-order konvenciu pre:

   ```text
   control encoder
   TERC4 LUT
   data guard band constants
   video guard band constants
   PHY serializer
   ```
3. Pridať debug testy:

   ```text
   T1: data preamble only
   T2: data preamble + data guard only
   T3: data preamble + guard + 1 payload symbol
   T4: full 32 payload
   ```
4. Ak sa ukáže guard band chyba, opraviť konštanty alebo ich bit-reversal.
5. Zopakovať HW:

   ```text
   2B GCP-only
   2C AVI-only
   ```

## Krátky verdikt

Teraz vieme:

```text
žiadny packet: PASS
akýkoľvek packet: FAIL
```

To je spoločná data-island transport chyba. Najbližší najpravdepodobnejší vinník: **data preamble / data guard band / TERC4 bit-order konvencia voči PHY**.
