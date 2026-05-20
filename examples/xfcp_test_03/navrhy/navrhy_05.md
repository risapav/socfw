Áno aj nie.

**Neexistuje žiadna norma priamo pre tvoje „XFCP“**, pokiaľ ho nedefinujeme ako vlastný interný protokol. Ale existuje viacero štandardov a zaužívaných návrhov, podľa ktorých sa dá XFCP navrhnúť tak, aby bolo rozumné, robustné a kompatibilné s bežnou praxou.

Najbližšie k XFCP sú tieto oblasti:

```text
1. on-chip bus štandardy:
   - AXI4-Lite
   - Wishbone

2. remote register access protokoly:
   - IPbus
   - Etherbone
   - LiteX UARTBone/Etherbone

3. debug ekosystémy:
   - JTAG-to-AXI
   - OpenOCD/GDB remote debug
```

## Najbližší vzor pre tvoje XFCP: IPbus

Najpodobnejší koncept je podľa mňa **IPbus**.

IPbus je packet-based control protocol na čítanie a modifikáciu memory-mapped zdrojov vo FPGA zariadeniach s A32/D32 adresovým priestorom. Má softvér aj firmware a používa sa v reálnych veľkých FPGA systémoch, najmä v particle physics elektronike. ([GitHub][1])

To je veľmi blízke tvojej myšlienke:

```text
PC tools
  ↓ paketový protokol
FPGA endpoint
  ↓ memory-mapped bus
registre / moduly / CPU control
```

Rozdiel je, že IPbus je typicky nad Ethernet/UDP alebo iným rýchlejším transportom, kým tvoje XFCP teraz ide cez UART.

Z IPbus by som si zobral hlavne tieto princípy:

```text
- paketový protokol pre A32/D32 read/write
- jasný request/response formát
- transaction ID
- status/error kódy
- burst read/write
- address table/discovery filozofia
- softvérová vrstva oddelená od transportu
```

## Druhý dobrý vzor: Etherbone

**Etherbone** robí podobnú vec pre Wishbone bus. Je to sieťová vrstva, ktorá rozširuje Wishbone bus tak, aby mohol bežať cez sieť. Špecifikácia definuje Etherbone pre UDP aj TCP. ([Open Hardware Repository][2])

Dôležitá myšlienka z Etherbone:

```text
remote bus access = existujúci interný bus + transportný obal
```

Presne tak by som definoval aj XFCP:

```text
XFCP = remote AXI-Lite/MMIO access protocol over UART/other transport
```

Z Etherbone by som si zobral:

```text
- neviazať protokol len na UART
- mať jasne oddelenú transportnú vrstvu
- podporovať viac operácií v jednom pakete
- mať presný wire-format
- definovať endianitu, alignment a chybové stavy
```

## Tretí vzor: AXI4-Lite response pravidlá

Pre vnútornú FPGA stranu sa treba držať AXI4-Lite sémantiky. AXI definuje odpovede ako `OKAY`, `SLVERR` a `DECERR`; `DECERR` je typicky generovaný interconnectom, keď na danej adrese nie je žiadny slave. ([archive.alvb.in][3])

Toto je dôležité pre tvoje XFCP:

```text
invalid address nemá spôsobiť timeout alebo deadlock
invalid address má vrátiť decode error
```

Čiže v XFCP by to malo byť mapované napríklad takto:

```text
AXI OKAY   → XFCP_STATUS_OK
AXI SLVERR → XFCP_STATUS_SLAVE_ERROR
AXI DECERR → XFCP_STATUS_BAD_ADDRESS / DECODE_ERROR
```

Toto je asi najdôležitejšie pravidlo, ktoré by som prebral zo štandardov.

## Štvrtý vzor: Wishbone

Wishbone je otvorená SoC interconnect špecifikácia, určená na spájanie IP cores v čipe. FOSSi dokumentácia ju popisuje ako otvorenú, voľne použiteľnú interconnect architektúru pre IP cores. ([wishbone-interconnect.readthedocs.io][4])

Pre teba je zaujímavá hlavne filozofia:

```text
každý modul má mať jasne zdokumentované registre,
šírku dát,
správanie,
reset hodnoty,
chybové stavy.
```

Čiže aj keď používaš AXI-Lite, nie Wishbone, odporúčanie je rovnaké: každý XFCP-kompatibilný modul by mal mať register mapu a identifikačný blok.

## Debug štandardy: OpenOCD/GDB

OpenOCD je skôr iná kategória. Poskytuje on-chip programming/debugging, JTAG/SWD, breakpointy, single-step, flash ovládače a GDB server. ([GitHub][5])

XFCP by som preto neporovnával ako náhradu OpenOCD. Skôr:

```text
OpenOCD/GDB = CPU debug
XFCP        = SoC/peripheral/control debug
```

Ale z OpenOCD štýlu sa oplatí prevziať:

```text
- command-line tools
- skriptovateľnosť
- oddelenie transportu od target logiky
- jasné error hlásenia
- možnosť reset/recover
```

---

# Praktické odporúčanie: vytvoriť vlastnú „XFCP špecifikáciu“

Nemusíš hľadať normu pre XFCP. Odporúčam napísať vlastný dokument:

```text
docs/xfcp_protocol.md
```

A v ňom špecifikovať:

```text
1. cieľ protokolu
2. transport nezávislý packet format
3. UART framing
4. endianita
5. request typy
6. response typy
7. status/error kódy
8. timeout/recovery pravidlá
9. register access pravidlá
10. discovery/register-map pravidlá
11. kompatibilita verzií
```

## Navrhovaný minimálny wire format

Napríklad:

```text
SOP      8b   0xFE
VER      8b
LEN      16b
SEQ      8b alebo 16b
OP       8b
FLAGS    8b
ADDR     32b
COUNT    16b
PAYLOAD  N bytes
CRC16    16b
```

Response:

```text
SOP      8b   0xFE
VER      8b
LEN      16b
SEQ      rovnaký ako request
RESP     8b
STATUS   8b
COUNT    16b
PAYLOAD  N bytes
CRC16    16b
```

## Odporúčané operácie

```text
0x01 READ32
0x02 WRITE32
0x03 READ_BLOCK
0x04 WRITE_BLOCK
0x05 PING
0x06 RESET_ENDPOINT
0x07 GET_STATUS
0x08 CLEAR_ERROR
```

## Odporúčané status kódy

```text
0x00 OK
0x01 BAD_OPCODE
0x02 BAD_LENGTH
0x03 BAD_CRC
0x04 BAD_ADDRESS / DECERR
0x05 SLAVE_ERROR / SLVERR
0x06 SLAVE_TIMEOUT
0x07 BUSY
0x08 SEQ_MISMATCH
0x09 PROTOCOL_ERROR
0x0A INTERNAL_ERROR
```

## Odporúčané pravidlá

Toto by som definoval ako „normu“ pre tvoj framework:

```text
1. Každý request musí dostať response.
2. Invalid address musí vrátiť BAD_ADDRESS, nie timeout.
3. Slave timeout musí vrátiť SLAVE_TIMEOUT, nie tiché zablokovanie.
4. Každá response musí niesť rovnaký SEQ ako request.
5. Každý paket musí mať CRC.
6. Parser musí vedieť resync pri novom SOP.
7. WRITE na invalid address musí odčerpať payload a vrátiť error.
8. Každý slave musí mať ID/register block.
9. Tools musia vedieť recoverovať endpoint.
10. Protokol musí mať verziu a capabilities.
```

---

# Čo by som použil ako „štandardy“ pre návrh

Pre náš projekt by som to zhrnul takto:

| Oblasť    | Odporúčané prevziať                                |
| --------- | -------------------------------------------------- |
| AXI4-Lite | `OKAY`, `SLVERR`, `DECERR`, handshake disciplína   |
| IPbus     | packet-based remote register access, A32/D32 model |
| Etherbone | transport nezávislý remote bus princíp             |
| Wishbone  | jednoduchá otvorená SoC/register filozofia         |
| OpenOCD   | CLI, recovery, scripting, target abstraction       |

---

# Krátka odpoveď

**Nie, neexistuje univerzálna norma priamo pre tvoje XFCP.** Ale existujú veľmi relevantné vzory: IPbus, Etherbone, Wishbone, AXI4-Lite a OpenOCD/GDB debug architektúra.

Najbližšie k tomu, čo robíš, je **IPbus**: paketový protokol na čítanie/zápis memory-mapped FPGA registrov. Z neho by som zobral hlavne transaction ID, status kódy, burst operácie, address-table filozofiu a jasné oddelenie softvér/firmvér/transport vrstiev.

Pre tvoj framework by som preto vytvoril vlastnú špecifikáciu **XFCP v0.1/v1.0**, inšpirovanú IPbus/Etherbone, ale jednoduchú a vhodnú pre UART a AXI-Lite.

[1]: https://github.com/ipbus/ipbus-software?utm_source=chatgpt.com "IPbus software"
[2]: https://ohwr.org/projects/etherbone-core/?utm_source=chatgpt.com "EtherBone Core"
[3]: https://archive.alvb.in/bsc/TCC/correlatos/amba_axi4.pdf?utm_source=chatgpt.com "AMBA AXI Protocol Specification"
[4]: https://wishbone-interconnect.readthedocs.io/en/latest/?utm_source=chatgpt.com "WISHBONE System-on-Chip (SoC) Interconnection ..."
[5]: https://github.com/openocd-org/openocd/?utm_source=chatgpt.com "Official OpenOCD Read-Only Mirror (no pull requests)"
