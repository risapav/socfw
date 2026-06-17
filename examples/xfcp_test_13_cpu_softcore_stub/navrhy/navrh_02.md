Projekt sa podľa mňa už posunul z fázy **„debugujeme príklady“** do fázy **„vzniká reálne použiteľná FPGA control/debug knižnica“**.

Jadro smerovania je toto:

```text
socfw + XFCP = univerzálna komunikačná a debug vrstva pre FPGA projekty
```

Teda nie jeden konkrétny demo projekt, ale knižnica, ktorú vieš pripojiť k rôznym FPGA návrhom a cez UART/UDP ovládať registre, streamy, pamäť a neskôr CPU/subsystémy.

## Kde sme teraz

Už máš veľmi slušný základ:

```text
UART transport        hotový
UDP transport         hotový
STATUS odpovede       hotové
AXI-Lite backend      hotový
AXI-Stream backend    hotový
GET_CAPS              hotové
GET_TARGET_INFO       hotové
MEM / AXI-Full        hotové
CPU0 stream mailbox   hotové
CPUM AXI-Lite regs    hotové
CLI nástroj           vznikol a funguje
```

To znamená, že XFCP dnes už vie:

```text
pingnúť FPGA
zistiť capability
zistiť targety
čítať/zapisovať AXI-Lite registre
robiť stream transfery
čítať/zapisovať MEM/AXI-Full priestor
pracovať s CPU mailbox FIFO/register rozhraním
```

Toto je už knižničný základ.

---

## Kam projekt smeruje

Podľa mňa smeruje do troch vrstiev.

### 1. Reusable RTL knižnica

Cieľ:

```text
rtl/xfcp/ = stabilná, znovupoužiteľná knižnica
```

S modulmi ako:

```text
xfcp_rx_parser
xfcp_tx_packetizer
xfcp_fabric_endpoint
xfcp_axi_engine
xfcp_axis_adapter
xfcp_mem_adapter
xfcp_caps_adapter
xfcp_target_info_adapter
xfcp_stream_mux
axil_cpu_mailbox
```

A jasné rozdelenie:

```text
core XFCP
transporty UART/UDP
backendy AXIL/AXIS/MEM/Mailbox
test/demo IP
```

Dôležité: `examples/xfcp_test_*` by už nemali byť hlavným zdrojom pravdy. Majú byť iba regresné príklady. Zdroj pravdy má byť root `rtl/xfcp/`.

---

### 2. Host knižnica a CLI

Druhý smer je Python časť:

```text
tools/xfcp/
```

Tá by mala byť normálny klient:

```bash
xfcp ping
xfcp caps
xfcp targets
xfcp read32
xfcp write32
xfcp stream-read
xfcp stream-write
xfcp mem-read
xfcp mem-write
xfcp mailbox-send
xfcp mailbox-recv
```

Toto je veľmi dôležité. Knižnica nie je len RTL. Knižnica je aj host API a nástroj, ktorým sa dá FPGA reálne ovládať.

---

### 3. Debug/control infraštruktúra pre budúce SoC

Tretí smer je väčší cieľ:

```text
XFCP ako debug/control backplane pre FPGA SoC
```

To znamená:

```text
PC host
  -> UART/UDP
  -> XFCP
  -> AXI-Lite registre
  -> AXI-Stream periférie
  -> AXI-Full pamäť
  -> CPU mailbox
  -> neskôr CPU debug / loader / monitor
```

Toto je už základ pre vlastný softcore/SoC debug ekosystém.

---

## Čo podľa mňa nie je cieľ

Projekt by som teraz nesmeroval k tomu, aby bol iba ďalším konkrétnym example:

```text
xfcp_test_14
xfcp_test_15
xfcp_test_16
...
```

To by sa časom rozsypalo.

Správny smer je:

```text
examples slúžia na overenie knižnice,
ale knižnica žije samostatne.
```

Čiže každý ďalší example má byť regresia alebo demonštrácia konkrétnej funkcie, nie miesto, kde sa donekonečna kopíruje RTL.

---

## Aktuálny problém pri `xfcp_test_13`

Pri `xfcp_test_13_cpu_softcore_stub` sme narazili na dobrý typ problému: nie technický chaos, ale **zmena semantiky systému**.

V `test_12` bol mailbox pasívny:

```text
host zapíše do RX FIFO
AXI-Lite register test ho vie prečítať
```

V `test_13` je mailbox aktívny:

```text
host zapíše do RX FIFO
CPU stub to okamžite spotrebuje
a vyrobí PONG/ERR odpoveď
```

Preto staré CPUM register testy nemôžu bez úprav prejsť. To nie je zlá architektúra. To znamená, že sme sa posunuli od „pasívneho FIFO bloku“ k „živému CPU-side agentovi“.

Správny postup je rozdeliť testy na:

```text
pasívny mailbox register test
aktívny CPU stub integration test
```

---

## Navrhovaná roadmap odtiaľto

### Fáza A — uzavrieť `v1.6`

Najprv by som pevne uzavrel:

```text
xfcp_lib_v1_6_cpu_mailbox_regs_pass
```

Podmienky:

```text
docs sú aktualizované na v1.6
HW log 98/98 je uložený
root rtl/xfcp obsahuje aktuálne moduly
examples používajú root knižnicu
```

Toto je posledný stabilný plne overený stav pred aktívnym CPU stubom.

---

### Fáza B — opraviť `xfcp_test_13`

Cieľ:

```text
host STREAM_WRITE sid=1 "PING"
CPU stub odpovie "PONG"
host STREAM_READ sid=1 dostane "PONG"
```

Ale testy musia rešpektovať, že stub aktívne konzumuje mailbox.

Odporúčam:

```text
T01–T44 základná regresia
T45–T49 iba CPUM sanity, nie pasívny FIFO deep test
T50 PING -> PONG
T51 unknown -> ERR\n
T52 opakovaný PING
T53 STR0/CPU0 izolácia
T54 dlhší payload -> ERR\n
```

Až keď bude:

```text
sim PASS
timing PASS
HW UART+UDP PASS
```

potom tag:

```text
xfcp_lib_v1_7_cpu_stub_pass
```

---

### Fáza C — knižničná konsolidácia

Po v1.7 by som stopol nové features a spravil cleanup:

```text
xfcp_lib_core_cleanup
```

Cieľ:

```text
jeden zdroj pravdy pre RTL
jeden zdroj pravdy pre Python klienta
aktuálne docs
čisté examples
minimum warningov
manifest/ip.yaml pre knižnicu
```

Toto je krok, ktorý z projektu spraví serióznu knižnicu.

---

### Fáza D — ďalší veľký krok: CPU agent alebo loader

Potom máš dve možnosti.

Prvá, jednoduchšia:

```text
xfcp_test_14_cpu_agent
```

CPU-side FSM vie viac príkazov:

```text
PING -> PONG
ECHO payload
READ_ID
READ_STATUS
MEM_CHECKSUM
```

Druhá, ambicióznejšia:

```text
xfcp_test_14_loader
```

Host vie cez XFCP nahrať blok dát do MEM a CPU agent ho vie spracovať.

Ale CPU halt/step/debug by som ešte nerobil. To je až ďalšia etapa.

---

## Strategický cieľ projektu

Môj najpresnejší opis cieľa:

```text
Vyvíjaš malý, prenositeľný FPGA debug/control framework,
ktorý kombinuje RTL knižnicu, protokol, transporty a host nástroje.
```

Niečo ako vlastný interný ekvivalent:

```text
UART/UDP debug bridge
AXI-Lite register access
AXI-Stream data path
memory access
mailbox control plane
future CPU/SoC monitor
```

Pre tvoje projekty to môže byť základná infraštruktúra, ktorú pripojíš k SDRAM, HDMI, Ethernet, CPU alebo iným IP blokom a budeš ich vedieť ovládať bez písania nového debug systému od nuly.

---

## Moje odporúčanie teraz

Teraz by som nerobil nový veľký backend.

Postup:

```text
1. Upevni v1.6 ako stabilnú knižničnú baseline.
2. Oprav test_13 tak, aby testy rešpektovali aktívny CPU stub.
3. Po v1.7 sprav knižničnú konsolidáciu.
4. Až potom rozširuj CPU agenta alebo loader.
```

Krátko: projekt smeruje od examples ku knižnici. A práve teraz sme v bode, kde treba prestať len pridávať funkcie a začať strážiť čistotu architektúry.
