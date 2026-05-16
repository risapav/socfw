Tento výsledok je dôležitý, ale nesúhlasil by som so záverom:

```text
ak VBLANK_ONLY=1 stále FAIL, monitor definitívne odmieta HDMI data islands pre 800×600 VESA
```

To je **príliš silný záver**. Správnejší záver je:

```text
VBLANK_ONLY=1 FAIL znamená, že problém pravdepodobne nie je iba v tom,
že data island bol vkladaný počas horizontálneho blankingu aktívnych riadkov.
```

Stále môžu byť chybné:

```text
data island guard band symboly,
TERC4 bitová konvencia,
BCH/ECC mapping,
channel mux výber,
preamble/control mapping,
AVI payload/checksum,
alebo sink netoleruje konkrétnu kombináciu VESA 800×600 + HDMI packets.
```

## Čo teraz vieme

Aktuálny rozhodovací strom je:

```text
2A: DATA=1, GCP=0, AVI=0  PASS
2B: GCP-only              FAIL
2C: AVI-only              FAIL
2C + VBLANK_ONLY=1        FAIL
```

Z toho vyplýva:

```text
samotné ENABLE_DATA_ISLAND video nerozbije,
ale akýkoľvek reálny data island packet zhodí link,
a nezachráni to ani presun packetu do vertical blankingu.
```

To zužuje problém na **spoločnú data-island packet cestu alebo HDMI/VESA kompatibilitu**, nie na audio.

---

# Najbližšie by som spravil tieto 3 testy

## 1. Otestuj CEA 640×480p60 / VIC 1

Toto je najlepší ďalší compatibility test.

Nastavenie:

```text
640×480 @ 60 Hz
pixel clock ~25.175 MHz
VIC = 1
aspect = 4:3
RGB
quantization = default alebo full
```

Prečo: 640×480p60 je bezpečnejší HDMI/CEA režim než 800×600 VESA s `VIC=0`.

Ak v 640×480 VIC 1 prejde:

```text
DATA=1, AVI-only PASS
GCP-only PASS
GCP+AVI PASS
```

potom je veľmi pravdepodobné, že problém je kompatibilita monitora so **VESA 800×600 + HDMI data islands / AVI InfoFrame**.

Ak 640×480 VIC 1 tiež zlyhá, problém je skôr v samotnej data-island implementácii.

Pozor: 1024×768 nie je dobrý „CEA test“. Je to tiež skôr PC/VESA režim. Na HDMI kompatibilitu testuj radšej:

```text
640×480p60 VIC 1
1280×720p60 VIC 4, ak zvládneš pixel clock 74.25 MHz
1920×1080p60 VIC 16, ak zvládneš vyšší clock/serializer
```

Pre tvoj FPGA/PMOD setup je najrealistickejší prvý krok **640×480p60**.

---

## 2. Otestuj iný sink: TV alebo HDMI capture

Ak máš možnosť, skús rovnaký bitstream na:

```text
full HD TV,
inom HDMI monitore,
HDMI capture dongle,
alebo HDMI analyzátore, ak je dostupný.
```

Interpretácia:

```text
Samsung FAIL, TV PASS:
  monitor je prísny alebo má problém s týmto režimom.

Samsung FAIL, TV FAIL:
  chyba je takmer určite v HDMI data-island implementácii.

Samsung PASS v 640×480, FAIL v 800×600:
  problém je režim/AVI kompatibilita, nie základná transportná cesta.
```

---

## 3. Urob diagnostický test bez payloadu

Ak chceš ešte pokračovať v RTL diagnostike pred zmenou video módu, pridaj debug režimy:

```text
T1: DATA_PREAMBLE only, bez guard/payload
T2: DATA_PREAMBLE + DATA_GB_LEAD + DATA_GB_TRAIL, bez payload
T3: DATA_PREAMBLE + DATA_GB_LEAD + 1 payload symbol + DATA_GB_TRAIL
T4: plný 32-symbol payload
```

Toto povie, kde presne monitor stratí lock:

```text
T1 FAIL:
  problém v data preamble/control mappingu.

T1 PASS, T2 FAIL:
  problém v data guard band symboloch.

T2 PASS, T3 FAIL:
  problém v TERC4/payload/formatter/bit order.

T3 PASS, T4 FAIL:
  problém v payload dĺžke/advance/trailing boundary.
```

Tento test je neštandardný HDMI, ale diagnosticky veľmi cenný.

---

# Čo by som teraz nezáveroval

Nezáveroval by som ešte:

```text
monitor definitívne odmieta HDMI data islands pre 800×600
```

Lepšie zapísať:

```text
VBLANK_ONLY=1 did not fix 2C AVI-only failure.
This rules out active-line hblank placement as the primary cause.
Next test: CEA 640×480p60 VIC 1 and/or second HDMI sink.
```

---

# Odporúčaný ďalší praktický krok

Najefektívnejší ďalší test je podľa mňa:

```text
prepnúť projekt na 640×480p60, VIC=1, DATA=1, AUDIO=0
otestovať:
2A no packet
2B GCP-only
2C AVI-only
2D GCP+AVI
```

Ak 640×480 VIC 1 prejde, potom sa vrátiš k otázke, ako posielať AVI pre 800×600 VESA tak, aby ho tento monitor akceptoval — prípadne či pre 800×600 nepoužívať DVI-compatible režim bez data islands.
