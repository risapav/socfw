Výborne. Toto je rozumný bod na uzavretie simulačnej fázy.

Aktuálny stav by som označil ako:

```text
SIMULATION BASELINE: COMPLETE
```

Najdôležitejšie je, že máš teraz zosúladené:

```text
ACR builder RTL
ACR testbench
HDMI_PACKET_LAYOUT.md
```

a že `make report` prešiel cez všetkých 11 scenárov. To znamená, že ďalší debug už nemá začínať ďalším refaktorom RTL, ale **kontrolovaným HW matrix testom**.

## Ďalší postup

### 1. Commitni aktuálny sim baseline

Odporúčaná commit správa:

```text
hdmi: complete simulation baseline for data islands and audio packets

- document HDMI packet layouts as single source of truth
- verify ACR MSB-first layout across RTL, testbench, and docs
- add known issue for unused InfoFrame config path
- add hardware test matrix metadata
- pass full make report regression including audio scenarios
```

Do poznámky commitu alebo changelogu dopíš:

```text
Simulation:
- make report PASS
- 11 scenarios PASS
- logs generated under sim/logs/ and excluded from git
```

---

### 2. Rebuild bitstream z presného commitu

Pred HW testom si poznač:

```bash
git rev-parse --short HEAD
```

Tento hash vlož do `TEST_MATRIX.md`.

Potom buildni bitstream presne z tejto verzie. Ak používaš `socfw`, odporúčam uložiť aj vygenerovaný `soc_top.sv` alebo aspoň build report hash, aby si neskôr vedel, že testovaný bitstream zodpovedal danému RTL stavu.

---

### 3. Vyplň session header v `TEST_MATRIX.md`

Pred testom:

```text
Git commit  : <short hash>
RTL hash    : <short hash alebo git rev-parse --short HEAD>
Sim log     : sim/logs/regression_full.log
Date        : 2026-05-13
Monitor     : <model monitora>
```

Ak nevieš model monitora, zapíš aspoň výrobcu a vstup, napríklad:

```text
Monitor: Dell HDMI input, exact model unknown
```

---

### 4. HW testuj presne v poradí tabuľky

Nemeň naraz viac vecí.

Poradie:

```text
#1 DATA=0 AUDIO=0
#2 DATA=1 AUDIO=0
#3 ACR only
#4 Audio IF only
#5 Sample only
#6 ACR + Audio IF
#7 ACR + Sample
#8 ACR + Audio IF + Sample
#9 DATA=1 AUDIO=1 full audio
```

Pri každom teste zapíš:

```text
PASS / FAIL / PARTIAL
sleep / black screen / obraz OK / audio OK / audio mute / šum
```

---

## Ako interpretovať výsledky

### Ak prejdú #1 a #2

Znamená to:

```text
video PHY + GCP/AVI data island sú OK
```

### Ak zlyhá #3 ACR only

Potom je problém pravdepodobne:

```text
ACR packet layout
ACR BCH/ECC cez formatter
ACR scheduling
sink netoleruje ACR bez Audio IF
```

Aj keď simulácia prešla, toto by bol konkrétny HW rozdiel na presné riešenie.

### Ak zlyhá #4 Audio IF only

Pozri:

```text
Audio InfoFrame checksum
channel count CC
InfoFrame timing
```

### Ak zlyhá #5 Sample only

To môže byť očakávane citlivé, lebo sample packets bez ACR/Audio IF môžu byť pre niektoré sinky zvláštne. Dôležité kritérium je hlavne:

```text
monitor nesmie zaspať
```

Ak obraz ide, ale audio nie, je to `PARTIAL`, nie `FAIL`.

### Ak #3–#6 prejdu, ale #8 alebo #9 zlyhá

Potom je najpravdepodobnejší problém:

```text
packet rate
audio sample source bez rate limitu
arbiter prioritizácia
príliš husté audio sample packets
```

To už zodpovedá `PKT-001`.

---

## Ak full audio stále zaspí

Nerob hneď ďalší veľký refaktor. Sprav iba jeden experiment:

```text
ENABLE_AUDIO_SAMPLE = 0
ENABLE_ACR_PACKET = 1
ENABLE_AUDIO_INFOFRAME = 1
```

Ak obraz drží, potom je jasné, že problém je sample packet tok alebo rate.

Potom druhý experiment:

```text
ENABLE_AUDIO_SAMPLE = 1
ale posielať sample packet len raz za frame
```

Ak to drží, problém nie je formát sample packetu, ale hustota/rate scheduling.

---

## Po úspešnom HW teste

Ak prejde aspoň:

```text
#1 PASS
#2 PASS
#3 PASS
#4 PASS
#6 PASS
```

máš stabilné HDMI data island + audio metadata.

Potom ďalší roadmap krok je:

```text
audio FIFO + rate-limited audio packet scheduler
```

Nie ďalší packet-layout refaktor.

---

## Aktuálny odporúčaný stav projektu

Zapísal by som do changelogu:

```markdown
### Simulation baseline complete
- `make report` passes all 11 HDMI simulation scenarios.
- ACR layout verified MSB-first across RTL, TB, and docs.
- Audio scenarios pass in simulation:
  - ACR only
  - Audio IF only
  - Audio sample only
  - full audio
- Remaining work: hardware test matrix on AC608 / HDMI monitor.
```

Toto je dobrý míľnik. Ďalší rozhodujúci dôkaz už dá iba reálny monitor.
