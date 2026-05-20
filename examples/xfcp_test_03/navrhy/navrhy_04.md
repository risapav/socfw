Áno, už sa to dá porovnať. Tvoje XFCP je niekde medzi:

```text
jednoduchý UART register bridge  <  XFCP  <  LiteX UARTBone/Etherbone / JTAG-to-AXI / OpenOCD-GDB
```

Nie je to ešte plnohodnotný debug ekosystém ako OpenOCD/GDB, ale už má viac než obyčajný UART „peek/poke“ most.

## Čo má naše XFCP navyše

### 1. Je jednoduché, malé a nezávislé od vendorov

Veľká výhoda je, že nie si viazaný na Xilinx/AMD debug IP, JTAG chain, Vivado hw_server alebo konkrétny CPU debug modul. Napríklad AMD JTAG-to-AXI Master je určený na generovanie AXI/AXI-Lite transakcií do bežiaceho FPGA systému, ale je to vendor riešenie naviazané na Vivado debug flow. ([AMD Documentation][1])

Naše XFCP je:

```text
UART → vlastný parser → AXI-Lite/MMIO → tvoje moduly
```

To je dobré pre tvoj vlastný framework, Quartus/Intel FPGA, malé dosky a vlastné SoC generovanie.

### 2. Má multi-slave fabric, nie iba jeden bridge

Oproti pôvodnému `xfcp_axil_bridge` máš nový `xfcp_fabric_endpoint`, ktorý nahrádza ručný 1-to-N dekodér. Má interný adresový dekodér cez `SLAVE_BASE/SLAVE_MASK`, order FIFO a N paralelných AXI engines, jeden na slave. Status to uvádza ako hlavný upgrade oproti starému projektu.

To je oproti obyčajnému UART-MMIO bridge riešeniu veľké plus. Vieš mať viac periférií:

```text
sys_ctrl
uart_adapter
gpio/regs
seven_seg
ďalšie testované moduly
CPU control
RAM window
```

### 3. Vie garantovať in-order odpovede

Order FIFO je dôležitý. Znamená, že aj keď máš viac paralelných engine vetiev, odpovede sa môžu vracať v poradí requestov. V statuse je priamo uvedené, že oproti `xfcp_test` pribudol order FIFO a paralelné engines.

To je dobrý základ pre budúce pipelining/retry/sequence ID.

### 4. Je integrované s tvojou testovacou pyramídou

Máš unit aj integration testy. Status ukazuje PASS pre parser, packetizer, AXI engine, fabric endpoint aj top test.

To je veľká výhoda oproti ad-hoc debug mostíkom, ktoré často fungujú len na doske a nemajú poriadnu simuláciu.

### 5. Má už riešený niektorý recovery/robustness základ

Už máš doplnený RX FIFO medzi UART RX a parserom, aby parser backpressure nezahadzoval UART bajty. Status uvádza, že `axis_uart_rx` bez buffra mohol zahodiť bajt, keď parser mal `tready=0`, a riešením je `u_rx_fifo` s depth 8.

Tiež už máš opravený timeout v `xfcp_axi_engine`, aby timeout nebol tichý drop, ale odpoveď.

---

## Čo má konkurencia navyše

### 1. LiteX UARTBone/Etherbone má širší ekosystém

LiteX má host bridge prístup, kde sa dá SoC ovládať cez UARTBone, JTAGBone alebo Etherbone. LiteX dokumentácia opisuje Ethernet bridge ako pohodlný spôsob debugovania SoC cez lokálnu sieť a s lepšou rýchlosťou než UART. ([GitHub][2])

Tvoje XFCP zatiaľ má hlavne UART. Chýba mu:

```text
- TCP/Ethernet transport
- vyššia prenosová rýchlosť
- hotové host nástroje podobné litex_server / wishbone-tool
- väčšia komunita
- hotové integrácie so simulátormi
```

Etherbone/Wishbone bridge sa používa aj v hybridnom HW/simulačnom workflow, napríklad pri Renode + Fomu, kde sa časť platformy spúšťa v Renode a časť na FPGA hardvéri. ([renode.readthedocs.io][3])

### 2. OpenOCD/GDB má skutočný CPU debug

OpenOCD vie vystupovať ako GDB server a používa sa na remote debugging cez GDB. ([openocd.org][4]) Vie teda veci, ktoré XFCP zatiaľ nerobí:

```text
- breakpointy
- single-step
- čítanie CPU registrov
- zastavenie/jadro/reset cez debug modul
- symbolický debug C programu
- GDB integrácia
```

OpenOCD má aj koncept background memory access, kde debugger pristupuje do pamäte, kým target beží. ([openocd.org][5]) To je cieľ, ku ktorému sa môžeš priblížiť cez XFCP memory window, ale zatiaľ to nebude plnohodnotný CPU debugger.

### 3. Vendor debug riešenia majú robustnejšie transakčné jadro

AMD JTAG-to-AXI Master je navrhnutý na generovanie AXI/AXI-Lite transakcií a debug interných AXI signálov za behu FPGA. ([AMD Documentation][1]) Má výhodu v tom, že:

```text
- používa existujúci JTAG debug transport
- má podporu vo Vivado Tcl
- má reset/debug flow
- netreba písať vlastný UART protokol
```

Dokumentácia tiež explicitne rieši reset JTAG-to-AXI debug core cez `reset_hw_axi`, čo je presne typ recovery logiky, ktorú by si mal mať aj v XFCP. ([AMD Documentation][6])

---

## Čo nášmu XFCP ešte chýba

Najväčšie chýbajúce veci by som zoradil takto:

```text
1. jasný error/status model
2. sequence ID / transaction ID
3. CRC alebo checksum
4. explicitný RESP_ERROR paket
5. robustný invalid-address handling
6. robustný invalid-WRITE payload drain
7. module/slave timeout ako prvotriedna vlastnosť
8. recovery/reset logika endpointu
9. sys_ctrl diagnostické registre
10. discovery modulov
11. burst read/write s presným count handlingom
12. viac transportov: UART dnes, neskôr USB/Ethernet/JTAG
```

V aktuálnom stave je stále evidovaný problém, že HW test mal 17 % nedeterministické zlyhania s 0B odpoveďou.  Tiež je otvorené riziko Problem F: WRITE na neplatnú adresu môže defaultovať payload na slave 0, pretože `wdata_valid` nie je gateované cez `dec_valid`.

To znamená, že projekt už je dobrý, ale ešte nie je „odolný debug port“.

---

# Aká logika by mala byť implementovaná

Rozdelil by som to na **RTL logiku** a **Python/tools logiku**.

---

## A. Logika, ktorá má byť v RTL

### 1. Transaction ID

Do každého requestu aj response pridať `seq_id`.

```text
request:
  SOP, LEN, SEQ, OP, ADDR, COUNT, PAYLOAD, CRC

response:
  SOP, LEN, SEQ, RESP_TYPE, STATUS, PAYLOAD, CRC
```

Výhoda:

```text
- PC vie zahodiť starú odpoveď
- stale bytes už nerozbijú nasledujúcu transakciu
- retry je bezpečnejší
- diagnostika je jasnejšia
```

Toto by som dal ako jednu z najvyšších priorít.

---

### 2. CRC16 alebo aspoň CRC8

UART bez CRC znamená, že nevieš spoľahlivo rozlíšiť poškodený paket od chybnej logiky.

Odporúčanie:

```text
CRC16-CCITT pre celý paket okrem SOP
```

Parser musí vedieť:

```text
- CRC OK → packet valid
- CRC FAIL → zahodiť packet, zvýšiť crc_error_count
- ak príde nový SOP počas packetu → resync
```

---

### 3. Explicitný RESP_ERROR

Dnes sa chyby miešajú s timeoutom alebo chýbajúcou odpoveďou. Lepšie je mať:

```text
RESP_ERROR:
  status_code
  failing_addr
  info
```

Status kódy:

```text
0x00 OK
0x01 BAD_OPCODE
0x02 BAD_LENGTH
0x03 BAD_CRC
0x04 BAD_ADDRESS
0x05 SLAVE_TIMEOUT
0x06 SLAVE_ERROR
0x07 BUSY
0x08 PROTOCOL_ERROR
0x09 INTERNAL_ERROR
```

Potom invalid address nikdy neskončí ako „0B odpoveď“, ale ako normálna odpoveď:

```text
BAD_ADDRESS @ 0xFF060000
```

---

### 4. Invalid request handler

Toto je priame riešenie Problem F.

V `xfcp_fabric_endpoint` by mala byť vetva:

```text
valid request   → dispatch to engine
invalid address → drain payload if WRITE → send RESP_ERROR
invalid opcode  → drain packet → send RESP_ERROR
```

Pri WRITE je dôležité odčerpať celý payload, nie iba zahodiť header.

Logicky:

```systemverilog
if (req_valid && !dec_valid) begin
  if (req_op == WRITE)
    enter DROP_WRITE_PAYLOAD;
  schedule_error_response(BAD_ADDRESS, req_addr);
end
```

Stavový automat:

```text
ST_IDLE
ST_DISPATCH
ST_DROP_WRITE_PAYLOAD
ST_WAIT_ENGINE_DONE
ST_SEND_RESPONSE
ST_RECOVER
```

---

### 5. Slave/module timeout priamo vo fabric/engine

Každý AXI engine má mať watchdog:

```text
timeout_cfg_cycles
```

Sledovať treba minimálne:

```text
- AW handshake timeout
- W handshake timeout
- B response timeout
- AR handshake timeout
- R response timeout
```

Pri timeout:

```text
- ukončiť danú transakciu
- neuvoľniť systém do deadlocku
- poslať RESP_ERROR alebo RESP_WRITE so SLAVE_TIMEOUT
- zapísať last_timeout_addr
- increment timeout_count
```

Ak timeout ostane len v Python tools, vieš zistiť „neprišla odpoveď“, ale nevieš bezpečne zotaviť RTL.

---

### 6. Endpoint soft reset / recovery FSM

Potrebujeme interný reset iba pre XFCP endpoint, nie nutne pre celý SoC.

Register alebo command:

```text
XFCP_SOFT_RESET
```

Resetovať má:

```text
- RX parser FSM
- TX packetizer FSM
- order FIFO
- write FIFO/drop FSM
- busy flags
- error latches voliteľne
```

Nemusí resetovať testované moduly, ak nechceš.

Dôležité je, aby po chybe Python vedel urobiť:

```text
flush UART
send soft reset
ping
continue
```

---

### 7. Diagnostické registre

Do `sys_ctrl` alebo `xfcp_status` modulu by som dal:

```text
MAGIC
VERSION
BUILD_ID
CAPABILITIES
NUM_SLAVES
RX_PACKET_COUNT
TX_PACKET_COUNT
CRC_ERROR_COUNT
BAD_ADDR_COUNT
TIMEOUT_COUNT
DROPPED_PACKET_COUNT
LAST_ERROR
LAST_BAD_ADDR
LAST_TIMEOUT_ADDR
LAST_SEQ
ENDPOINT_STATE
```

Tieto registre sú extrémne užitočné pri HW debugovaní.

---

### 8. Discovery / ID ROM per slave

Každý slave by mal mať prvých 16 alebo 32 bajtov jednotný identifikačný blok:

```text
base + 0x00 MAGIC
base + 0x04 TYPE_ID
base + 0x08 VERSION
base + 0x0C SIZE
base + 0x10 CAPABILITIES
```

Potom scanner nemusí hádať `num_slots`, čo už raz spôsobilo problém. V statuse je uvedené, že scanner `num_slots=8` voči `NUM_SLAVES=6` viedol k timeoutom/deadlocku a potom sa opravil na 6.

---

## B. Logika, ktorá má byť v Python tools

### 1. Rozdelené timeouty

Nie jeden timeout. Minimálne:

```python
byte_timeout_s
response_timeout_s
module_timeout_s
recovery_timeout_s
```

Použitie:

```python
xfcp.read32(addr, response_timeout_s=0.5)
mod.wait_done(timeout_s=5.0)
xfcp.recover(timeout_s=0.2)
```

### 2. Retry iba so sequence ID

Retry bez `seq_id` je nebezpečný, lebo môžeš omylom prijať starú odpoveď ako novú.

Správny flow:

```text
send request seq=N
wait response seq=N
ak timeout:
  flush
  recover
  send request seq=N+1
ak príde starý seq=N:
  zahodiť
```

### 3. Recovery manager

Tools by mali mať funkciu:

```python
xfcp.recover()
```

Kroky:

```text
1. serial input flush
2. serial output flush
3. wait recovery_timeout
4. ping
5. ak fail: XFCP_SOFT_RESET
6. ping
7. ak fail: hard fail
```

### 4. Diagnostika pri každej chybe

Pri chybe nech tools automaticky vypíšu:

```text
last_error
last_bad_addr
timeout_count
crc_error_count
endpoint_state
last_seq
```

Nie iba:

```text
TimeoutError: no response
```

### 5. Modulové ovládače

Pre každý modul:

```text
drivers/gpio.py
drivers/uart.py
drivers/sevenseg.py
drivers/cpu.py
drivers/memory.py
```

Každý driver by mal mať:

```python
probe()
selftest()
read_status()
clear_error()
wait_done(timeout_s)
```

---

# Čo má byť cieľová architektúra

Navrhol by som toto:

```text
PC tools
 ├── transport: serial/tcp/future
 ├── protocol: encode/decode/CRC/SEQ
 ├── bus: read32/write32/burst/wait_reg
 ├── recovery: flush/ping/reset
 ├── scanner: discovery
 └── drivers: cpu/mem/gpio/uart/custom

UART / future Ethernet / future USB

XFCP endpoint
 ├── rx parser + CRC + seq
 ├── request validator
 ├── address decoder
 ├── invalid/drop/error handler
 ├── order FIFO
 ├── N AXI engines
 ├── timeout watchdogs
 ├── response arbiter
 ├── tx packetizer
 └── status/recovery registers

AXI-Lite/MMIO slaves
 ├── sys_ctrl
 ├── cpu_ctrl
 ├── ram window
 ├── gpio
 ├── uart
 └── custom modules
```

---

# Najbližšie konkrétne poradie implementácie

Keby som to mal zoradiť prakticky:

```text
1. Opraviť invalid WRITE path vo fabricu.
2. Prepojiť resp_type/error_timeout z engine do fabricu.
3. Pridať RESP_ERROR alebo aspoň error status do odpovede.
4. Pridať sys_ctrl diagnostické registre.
5. Pridať endpoint soft reset.
6. Pridať seq_id.
7. Pridať CRC.
8. Pridať discovery ID bloky.
9. Upratať Python tools: transport/protocol/bus/recovery/drivers.
10. Až potom riešiť rýchlejší transport, napr. vyšší baud, USB alebo Ethernet.
```

Moje hodnotenie: **naše XFCP má dobrú architektúru pre vlastný FPGA framework — najmä multi-slave fabric, order FIFO, parametrický adresový dekodér a testovaciu pyramídu. Chýba mu však robustný protokolový obal: sequence ID, CRC, error responses, discovery, diagnostika a recovery reset.** Keď tieto veci doplníš, bude to veľmi použiteľný interný debug/control štandard pre tvoje moduly aj CPU aplikácie.

[1]: https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/JTAG-to-AXI-Master?utm_source=chatgpt.com "JTAG-to-AXI Master - 2025.2 English - UG908"
[2]: https://github.com/enjoy-digital/litex/wiki/Use-Host-Bridge-to-control-debug-a-SoC?utm_source=chatgpt.com "Use Host Bridge to control debug a SoC · enjoy-digital/litex ..."
[3]: https://renode.readthedocs.io/en/latest/tutorials/fomu-example.html?utm_source=chatgpt.com "Renode, Fomu and EtherBone bridge example"
[4]: https://openocd.org/doc/html/GDB-and-OpenOCD.html?utm_source=chatgpt.com "20 GDB and OpenOCD"
[5]: https://openocd.org/doc/html/General-Commands.html?utm_source=chatgpt.com "General Commands (OpenOCD User's Guide)"
[6]: https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/Resetting-the-JTAG-to-AXI-Master-Debug-Core?utm_source=chatgpt.com "Resetting the JTAG-to-AXI Master Debug Core"
