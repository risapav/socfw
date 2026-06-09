Skvelé, poďme sa pozrieť pod kapotu XFCP, ako **vyzerá frame/packet** a **čo robí XFCP switch**. Budem konkrétny, krok po kroku.

---

# 1️⃣ XFCP frame / packet

XFCP je **ľahký protokol založený na pakete**. Cieľ: smerovať príkazy a dáta k modulom v FPGA.

**Základná štruktúra paketu (v zjednodušenej forme):**

```text
+---------+----------+-----------------+-------------+
| Header  | Path     | Command/Address | Data/Payload|
+---------+----------+-----------------+-------------+
```

### Popis polí

1. **Header**

   * Typ paketu (request/response)
   * ID transakcie
   * Voliteľné flags (napr. ACK)

2. **Path**

   * Source-routing adresa
   * Každý byte alebo nibble určuje “pozíciu” v hierarchii switcha
   * Príklad: `[1, 0]` → Root → Node1 → Node0

3. **Command / Address**

   * Typ operácie (read/write)
   * Adresa registra alebo submodulu v module
   * Môže byť relatívna k cieľovému modulu (node)

4. **Data / Payload**

   * Hodnota zapisovaná alebo čítaná
   * Môže byť 1, 2, 4 alebo viac bajtov podľa implementácie

---

### Príklad paketu

Predstav si zápis do registru 0x10 v module, ktorý je cestou `[1,0]`:

```text
Header: 0x01         # Write, no flags
Path:   [1, 0]       # Root -> Node1 -> Node0
Command/Address: 0x10
Data: 0xDEADBEEF
```

Python client môže použiť:

```python
node = xfcp.Root.node(1).node(0)
node.register.write(0x10, 0xDEADBEEF)
```

XFCP automaticky skonvertuje tento volanie do packetu s cestou `[1,0]`, odošle cez UDP alebo UART, a FPGA switch doručí správnemu modulu.

---

# 2️⃣ XFCP switch

XFCP switch je **v FPGA centrálna logika**, ktorá prijíma XFCP pakety a smeruje ich do správnych modulov.

### Hlavné body fungovania

1. **Prijatie paketu**

   * Switch prijme paket z transportnej vrstvy (UART/UDP)
   * Prečíta **Path** pole

2. **Parsing path**

   * Switch číta prvý byte z Path
   * Vyberie **port / subnode** podľa hodnoty
   * Odstráni tento byte z Path
   * Forwarduje zvyšok paketu do podriadeného uzla

3. **Cieľový modul**

   * Ak Path pole je prázdne, switch vie, že paket je pre aktuálny modul
   * Modul vykoná príkaz (read/write) a prípadne vráti odpoveď

4. **Return path**

   * Odpoveď sa posiela späť rovnakou cestou (reverse routing)

---

### Schematické znázornenie switcha

```text
        XFCP Switch (FPGA)
        ┌───────────┐
        │ Path[0]=0 │──> Node 0
        │ Path[0]=1 │──> Node 1
        │ Path[0]=2 │──> Node 2
        └───────────┘
```

* Ak Node1 má poduzly, pokračuje ďalší byte z Path.
* Switch je **rekurzívny alebo hierarchický**, podobne ako stromová štruktúra.

---

### Výhody switcha

* Dynamické smerovanie modulov bez pevnej adresy
* Podpora stromovej hierarchie periférií
* Modulárne pridávanie nových blokov bez premapovania adries
* Jednoduché API na PC (Python XFCP client)
* Transparentné pre rôzne typy transportu (UART, UDP, PCIe)

---

### Bonus: Ako vyzerá packet pri odpovedi (response)

```text
Header: 0x81         # Response, success
Path:   [0, 1]       # reverse path
Command/Address: 0x10
Data: 0xDEADBEEF     # hodnota čítaná z registra
```

* Switch jednoducho vráti paket späť cez rovnaký port
* PC Python client automaticky dekóduje hodnotu

---

Ako je vyriešená situácia ak sa dotazujú 2 xfcp zariadenia, napr. uart a eth a je veľkosť pazloadu fixná alebo variabilná ?

---

Toto sú veľmi dobré otázky, pretože práve tu sa ukazuje, že XFCP nie je len "register access", ale skutočne paketová prepínaná zbernica.

## 1. Čo ak súčasne prídu požiadavky z UART aj Ethernetu?

Autor XFCP to rieši explicitne pomocou **arbiteru** pred XFCP switchom. Framework obsahuje "parametrizable arbiter to enable simultaneous use of multiple interfaces". ([alexforencich.com][1])

Architektúra vyzerá približne takto:

```text
          UART XFCP
               │
               ▼
        +-------------+
        |             |
        |             |
        |   Arbiter   |
        |             |
        +------+------+ 
               ▲
               │
          UDP XFCP

               │
               ▼
        +-------------+
        | XFCP Switch |
        +-------------+
```

Arbiter pracuje na úrovni AXI-Stream rámcov.

Ak:

```text
UART -> WRITE reg 0x10
ETH  -> READ  reg 0x20
```

prídu naraz, arbiter:

1. prijme celý packet z jedného vstupu,
2. odošle ho do XFCP fabric,
3. až potom pustí packet z druhého vstupu.

Takže nedochádza k premiešaniu bajtov dvoch packetov.

---

## 2. Môžu nastať kolízie?

Áno, logické kolízie.

Príklad:

```text
UART:
WRITE CONTROL = 1

ETH:
WRITE CONTROL = 0
```

XFCP samotné:

* neposkytuje locking,
* neposkytuje ownership,
* neposkytuje transakčnú ochranu.

Platí jednoducho:

```text
last writer wins
```

Rovnako ako pri AXI-Lite alebo Wishbone registroch.

Ak potrebuješ synchronizáciu medzi viacerými hostmi, musí ju implementovať tvoj FPGA dizajn.

---

## 3. Je XFCP master-slave?

Prakticky áno.

Typický model:

```text
Python Host
     │
     ▼
 FPGA
```

Host posiela request.

Node vracia response.

Nie je to peer-to-peer protokol.

---

## 4. Je payload fixný?

Nie.

Payload je **variabilný**.

XFCP používa AXI-Stream transport vo vnútri FPGA. ([alexforencich.com][1])

To znamená:

```text
Packet
 ├─ Header
 ├─ Path
 ├─ Command
 └─ Payload (0..N bytes)
```

Napríklad:

### Čítanie registra

```text
READ
Path=[1,0]
Addr=0x20
```

payload:

```text
0 byte
```

---

### Zápis 32-bit registra

```text
WRITE
Path=[1,0]
Addr=0x20
Data=0x12345678
```

payload:

```text
4 bytes
```

---

### EEPROM transfer

```text
WRITE BLOCK
Addr=0x100
Length=256
Data=...
```

payload:

```text
256 bytes
```

---

### Firmware upload

```text
WRITE BLOCK
Length=4096
```

payload:

```text
4096 bytes
```

alebo viac packetov za sebou.

---

## 5. Ako switch vie, kde končí packet?

Keďže XFCP interná fabric používa AXI-Stream, využíva sa signál:

```text
TLAST
```

Príklad:

```text
Beat0
Beat1
Beat2
Beat3
TLAST=1
```

Switch vie:

```text
tu packet končí
```

a môže ho odovzdať ďalej.

Nemusí poznať pevnú veľkosť rámca.

---

## 6. Musí switch bufferovať celý packet?

Závisí od implementácie.

Typicky:

```text
Ingress FIFO
       │
       ▼
Path decode
       │
       ▼
Output port
```

Switch nemusí uložiť celý packet do RAM.

Vie fungovať streamingovo:

```text
RX ---> Switch ---> Node
```

po bajtoch alebo po AXI-Stream slovách.

To výrazne šetrí BRAM.

---

## 7. Ako sa vracajú odpovede pri viacerých hostoch?

To je najzaujímavejšia časť.

Predstav si:

```text
UART host
ETH host
```

obidva pošlú request.

XFCP si musí pamätať:

```text
Request prišiel z UART
```

alebo

```text
Request prišiel z ETH
```

A odpoveď sa musí vrátiť správnym rozhraním.

Typická implementácia preto pridáva do packetu internú routing informáciu (alebo používa samostatné návratové cesty v arbitri).

Schematicky:

```text
UART ----+
         |
         v
      Arbiter
         |
         v
      Switch
         |
      Node
         |
      Response
         |
         +----> UART
```

alebo

```text
ETH ----+
        |
        v
     Arbiter
        |
        v
     Switch
        |
     Node
        |
     Response
        |
        +----> ETH
```

Host teda dostane len odpovede na svoje vlastné requesty.

---

## 8. Aký je praktický limit veľkosti payloadu?

Nie je definovaný samotným XFCP konceptom.

Limit určuje transport:

### UART

Typicky:

```text
desiatky až stovky bajtov
```

kvôli latencii.

### UDP

Typicky:

```text
MTU = 1500 B
Payload ≈ 1472 B
```

bez fragmentácie.

### Interná AXI-Stream fabric

Môže prenášať aj:

```text
4 kB
16 kB
64 kB
```

ak to zvládnu FIFO a endpointy.

---

Z pohľadu FPGA architektúry sa XFCP najviac podobá na:

```text
AXI-Stream packet network
          +
source routing
          +
register/device discovery
```

a menej na klasický adresný bus typu AXI-Lite alebo Wishbone. To je dôvod, prečo vie prirodzene podporovať viac vstupných rozhraní (UART, UDP, PCIe bridge, atď.) bez potreby globálnej adresnej mapy.

[1]: https://alexforencich.com/wiki/en/verilog/xfcp/start?utm_source=chatgpt.com "Extensible FPGA Control Platform [Alex Forencich]"

---

Super, teraz sa dostávame do praktickej FPGA architektúry: ako prepojiť **XFCP switch** s rôznymi AXI “backendami” – AXI-Lite, AXI-Stream, AXI Full. Poďme to rozobrať krok po kroku.

---

# 1️⃣ Predpokladaná situácia

* Máme **XFCP switch**, ktorý smeruje pakety podľa cesty k modulom.
* Na strane modulov potrebujeme komunikovať s rôznymi typmi zberníc:

| Typ AXI        | Použitie             | Poznámky                                                     |
| -------------- | -------------------- | ------------------------------------------------------------ |
| **AXI-Lite**   | registrový prístup   | jednoduché čítanie/zápis registrov, nízka šírka dát (32-bit) |
| **AXI-Stream** | streaming dát        | FIFO, DSP pipeline, UART/ETH data stream                     |
| **AXI Full**   | DMA, veľké bloky dát | bursty, prenosy do pamäte, vysoká priepustnosť               |

Cieľ: XFCP paket → **správny AXI backend** → modul.

---

# 2️⃣ Princíp prepojenia

XFCP switch poskytuje **packet-based routing**, takže potrebujeme **protocol adapter**:

```text
XFCP Switch
     │
     ├──> XFCP → AXI-Lite Adapter
     │         (adresné registre)
     │
     ├──> XFCP → AXI-Stream Adapter
     │         (FIFO, streaming)
     │
     └──> XFCP → AXI Full Adapter
               (burst write/read)
```

---

# 3️⃣ XFCP → AXI-Lite

* **Použitie:** modul registrov, konfigurácia periférií, status bity.
* **Princíp:** každá XFCP write/read transakcia sa mapuje na **jednu AXI-Lite transakciu**.
* **Proces:**

1. XFCP packet s path → switch → modul.
2. XFCP-Lite adapter:

   * dekóduje **Command/Address**
   * prevezme payload (32 bit)
   * vykoná **AXI-Lite write/read**
3. Získa hodnotu z registra (read) → vytvorí XFCP response packet → pošle späť.

**Diagram:**

```text
XFCP packet
    │
    ▼
XFCP switch
    │
    ▼
AXI-Lite adapter
    │
    ▼
AXI-Lite peripheral (registre)
```

* **Poznámka:** Fixed-size payload 32-bit je štandard, ale môže byť rozšírené na 64-bit, ak AXI-Lite podporuje.

---

# 4️⃣ XFCP → AXI-Stream

* **Použitie:** streaming dát, DSP pipeline, UART/Ethernet buffers.
* **Princíp:** XFCP paket je rozdelený na **AXI-Stream words** a posielaný do FIFO alebo streamového modulu.

**Proces zápisu:**

1. XFCP write packet → switch → AXI-Stream adapter.
2. Adapter vezme payload a generuje `tdata`, `tvalid`, `tlast` signály AXI-Stream.
3. FIFO alebo streamový modul spracuje dáta.

**Proces čítania (z AXI-Stream do XFCP):**

* Ak modul generuje dáta (napr. DSP filter):

  1. Stream sa číta z FIFO.
  2. Rozdelí sa na XFCP pakety podľa MTU.
  3. Odošle sa späť cez XFCP switch.

**Diagram:**

```text
XFCP packet
    │
    ▼
XFCP switch
    │
    ▼
AXI-Stream adapter
    │
    ▼
FIFO / DSP / stream module
```

**Poznámka:**

* TLAST sa používa na ukončenie XFCP paketu v streaming adaptore.
* Variabilná veľkosť payloadu nie je problém, adapter rozdelí data na AXI-Stream slová (napr. 32/64-bit).

---

# 5️⃣ XFCP → AXI Full (AXI Memory-Mapped)

* **Použitie:** DMA prenosy veľkých blokov dát (napr. FPGA→DDR alebo DDR→FPGA)
* **Princíp:** XFCP packet → adapter → AXI Full burst write/read.
* **Proces zápisu do pamäte:**

1. XFCP write packet obsahuje path + adresu + payload (napr. 4 KB)
2. AXI Full adapter:

   * rozdelí payload na bursty podľa maximálneho burst length AXI
   * vygeneruje `AWADDR`, `AWLEN`, `WVALID`, `WLAST` signály
3. Modul alebo DMA engine zapisuje do pamäte

* **Proces čítania z pamäte:**

1. AXI Full read burst → adapter získa dáta
2. Rozdelí do XFCP paketov podľa MTU alebo FIFO
3. Odošle späť cez switch hostovi

**Diagram:**

```text
XFCP packet
    │
    ▼
XFCP switch
    │
    ▼
AXI Full adapter
    │
    ▼
AXI Full peripheral / DDR controller
```

* **Výhody:** umožňuje vysokú priepustnosť, DMA transfery a veľké bloky dát.

---

# 6️⃣ Koordinácia viacerých zberníc

Keď máš napr. **UART a Ethernet**, môžeš použiť:

```text
          ┌───────────────┐
UART ---->│ XFCP Switch   │----> AXI-Lite peripheral
ETH  ---->│ Arbiter       │----> AXI-Stream peripheral
          └───────────────┘----> AXI Full / DMA
```

* Switch + arbiter rozlišuje, ktorý host (UART/Eth) posiela request.
* Každý adapter (AXI-Lite / AXI-Stream / AXI Full) má **samostatný FIFO alebo handshake**, aby sa zabránilo kolíziám.
* Variabilná veľkosť payloadu je podporovaná AXI-Stream aj AXI Full, AXI-Lite sa mapuje vždy na fixnú šírku (32-bit, 64-bit).

---

# 7️⃣ Zhrnutie

| XFCP Packet →      | Adapter    | AXI signály                               |
| ------------------ | ---------- | ----------------------------------------- |
| Registers / config | AXI-Lite   | AWADDR, WDATA, RDATA, WVALID, RVALID      |
| Streaming data     | AXI-Stream | TDATA, TVALID, TLAST                      |
| Large blocks / DMA | AXI Full   | AWADDR, AWLEN, WDATA, WLAST, RDATA, RLAST |

**Kľúčové body:**

* XFCP switch **source-routes** pakety do správneho modulu.
* Každý AXI typ má **protocol adapter**, ktorý prevádza XFCP paket na správny AXI handshake.
* Variabilná veľkosť payloadu je bezpečne zvládnutá AXI-Stream a AXI Full adapterom.
* AXI-Lite adapter typicky fixuje payload na 32-bit a ignoruje TLAST.
* Viac hostov (UART + ETH) je riešené **arbitrom a FIFO bufferingom**.

---

preposkladajme že máme switch pre xfcp máme niekoľko tzpov zberníc ktoré chceme zapisovať a čítať, ako vyriešime prenos do axilite, axistream a axi full?

---

Ak zadám požiadavku cez xfcp, je komunikácia zablokovaná az do prijatia odozvy resp. timeoutu alebo komunikácia pokračuje ďalej ?


To závisí od **konkrétnej implementácie XFCP klienta**, ale ak sa pozrieme na pôvodný XFCP framework od Alex Forencicha, odpoveď je:

> **XFCP protokol samotný nie je navrhnutý ako striktne "stop-and-wait" protokol.**
> Je packetovo orientovaný a podporuje viac požiadaviek v systéme súčasne.

Treba rozlišovať tri vrstvy:

---

# 1. XFCP protokol

Na úrovni protokolu môže existovať:

```text
REQ1
REQ2
REQ3
REQ4
```

bez toho, aby si čakal na:

```text
RESP1
```

pred odoslaním ďalšej požiadavky.

To znamená, že samotná packetová fabric vo FPGA nie je zablokovaná.

Prakticky:

```text
Host
 │
 ├─ READ NodeA
 ├─ READ NodeB
 ├─ WRITE NodeC
 └─ READ NodeD
```

môže mať viac rozpracovaných transakcií.

---

# 2. XFCP switch vo FPGA

Switch typicky funguje ako packet switch:

```text
Packet1 -> NodeA
Packet2 -> NodeB
Packet3 -> NodeC
```

Po odoslaní packetu do cieľového uzla switch nečaká.

Spracúva ďalšie pakety.

Podobne ako ethernetový switch:

```text
RX FIFO
   │
   ▼
Route
   │
   ▼
TX FIFO
```

Nie je tam globálny stav:

```text
waiting_for_response = true
```

ktorý by zastavil celý systém.

---

# 3. Endpoint (AXI-Lite bridge, I2C bridge...)

Tu vzniká najväčší rozdiel.

## AXI-Lite endpoint

Typicky:

```text
XFCP READ
   │
   ▼
AXI READ
   │
wait RVALID
   │
   ▼
response
```

Konkrétny endpoint musí počkať na dokončenie AXI transakcie.

Ale:

```text
NodeA čaká
```

neznamená:

```text
NodeB čaká
```

---

## I2C endpoint

Ešte výraznejšie.

Predstav si:

```text
READ EEPROM
```

na 400 kHz I²C.

To môže trvať:

```text
100 us
500 us
1 ms
```

Počas toho:

```text
NodeI2C = busy
```

ale ostatné uzly môžu fungovať.

---

# 4. Ako sa párujú odpovede?

Typicky pomocou:

```text
Transaction ID
```

alebo interného request contextu.

Príklad:

```text
REQ #10 -> NodeA
REQ #11 -> NodeB
REQ #12 -> NodeC
```

odpovede môžu prísť:

```text
RESP #11
RESP #10
RESP #12
```

v inom poradí.

Dobre navrhnutý klient to musí vedieť spárovať.

---

# 5. Čo robí štandardný Python klient?

Tu je dôležitá praktická vec.

Veľa XFCP Python API volaní vyzerá synchrónne:

```python
value = node.read_reg(0x100)
```

a používateľ vidí:

```text
send request
wait response
return value
```

To však neznamená, že protokol je blokovací.

Je to len vlastnosť API.

Pod kapotou môže existovať:

```text
TX queue
RX queue
request tracker
```

a viac rozpracovaných transakcií.

---

# 6. Timeout

Každý request musí mať timeout.

Príklad:

```text
REQ
 │
 ├─ response -> OK
 │
 └─ timeout -> ERROR
```

Najčastejšie:

```text
10 ms
100 ms
1 s
```

podľa typu endpointu.

---

# 7. Praktický príklad

Predstav si FPGA:

```text
XFCP Root
 │
 ├─ AXI-Lite Node
 ├─ I2C Node
 └─ DDR Node
```

Host odošle:

```text
T=0 ms
READ AXI register

T=0.1 ms
READ EEPROM

T=0.2 ms
READ DDR buffer
```

Výsledky:

```text
DDR response      0.5 ms
AXI response      1.0 ms
EEPROM response   5.0 ms
```

Úplne korektné.

Nie je potrebné čakať na EEPROM, aby sa vybavili ostatné požiadavky.

---

# 8. Najčastejší návrh vo FPGA

Ak by som dnes navrhoval XFCP bridge pre AXI systémy, použil by som:

```text
XFCP RX
   │
   ▼
Request FIFO
   │
   ├── AXI-Lite Worker
   ├── AXI Stream Worker
   └── AXI Full Worker

Responses
   │
   ▼
Response FIFO
   │
   ▼
XFCP TX
```

Takýto návrh umožňuje:

* viac požiadaviek naraz (multiple outstanding requests),
* nezávislé timeouty,
* paralelné AXI operácie,
* neblokovanie celej fabric pri pomalom I²C alebo SPI zariadení.

Z architektonického hľadiska je teda vhodné uvažovať o XFCP skôr ako o malej packetovej sieti vo FPGA než ako o klasickej zbernici typu AXI-Lite, kde master často čaká na dokončenie každej transakcie.

---
