Áno, toto je presne ďalší správny krok. Momentálne máš XFCP ako funkčný bring-up/debug kanál, ale aby bol použiteľný dlhodobo na vývoj modulov a CPU aplikácií, treba ho posunúť z „funguje na dobrý deň“ na **odolnú servisnú infraštruktúru**.

Navrhol by som postup v 5 vrstvách.

---

# 1. Najprv oddeliť typy timeoutov

Teraz sa pravdepodobne mieša viac významov slova timeout. Odporúčam zaviesť minimálne tieto štyri kategórie:

```text
1. UART/transport timeout
   - ako dlho čakáme na bajt z UARTu

2. XFCP transaction timeout
   - ako dlho čakáme na kompletnú XFCP odpoveď

3. target/module timeout
   - ako dlho môže testovaný modul alebo AXI-Lite slave nereagovať

4. recovery timeout
   - ako dlho čakáme po chybe, flushi, resete alebo resyncu
```

V Python tools by to mohlo vyzerať napríklad takto:

```python
@dataclass
class XfcpTimeouts:
    byte_timeout_s: float = 0.05
    response_timeout_s: float = 0.5
    module_timeout_s: float = 0.1
    recovery_timeout_s: float = 0.2
    open_timeout_s: float = 1.0
```

Potom by transakcia nemala mať iba jeden `timeout`, ale napríklad:

```python
xfcp.read32(addr, response_timeout=0.5)
xfcp.write32(addr, value, response_timeout=0.5)
xfcp.wait_reg(addr, mask, value, timeout=2.0)
```

Pre vývoj CPU aplikácií bude dôležité, aby si vedel povedať:

```python
cpu.run(timeout=5.0)
cpu.wait_done(timeout=10.0)
ram.verify(timeout=2.0)
```

---

# 2. Pridať recovery mechanizmus do tools

Po chybe by tools nemali iba skončiť na `TimeoutError`. Mali by vedieť urobiť riadené zotavenie.

Navrhovaný recovery postup:

```text
1. zastaviť aktuálnu transakciu
2. vyčistiť UART input buffer
3. počkať recovery_timeout
4. poslať resync / ping / scratch read
5. ak ping zlyhá, skúsiť soft reset XFCP endpointu
6. ak stále zlyhá, zahlásiť hard fail
```

V Python API:

```python
class XfcpBus:
    def recover(self) -> bool:
        self.serial.reset_input_buffer()
        self.serial.reset_output_buffer()
        time.sleep(self.timeouts.recovery_timeout_s)

        try:
            self.ping()
            return True
        except XfcpError:
            pass

        try:
            self.soft_reset()
            time.sleep(self.timeouts.recovery_timeout_s)
            self.ping()
            return True
        except XfcpError:
            return False
```

A pri transakcii:

```python
def transact(self, packet, *, retries=2, recover=True):
    for attempt in range(retries + 1):
        try:
            return self._transact_once(packet)
        except XfcpTimeoutError:
            if not recover or attempt == retries:
                raise
            self.recover()
```

Toto je dôležité najmä pri náhodných 0B odpovediach.

---

# 3. Zaviesť explicitný XFCP error/status model

Teraz máš timeout/error skôr implicitne. Navrhoval by som zaviesť jasné chybové stavy:

```text
OK
TIMEOUT
BAD_CRC / BAD_PACKET
BAD_OPCODE
BAD_ADDRESS
SLAVE_TIMEOUT
SLAVE_ERROR
BUSY
DROPPED_PACKET
```

Aj keby ich protokol zatiaľ neposielal všetky, Python API by ich malo poznať.

Napríklad:

```python
class XfcpStatus(Enum):
    OK = 0
    TIMEOUT = 1
    BAD_PACKET = 2
    BAD_ADDRESS = 3
    SLAVE_TIMEOUT = 4
    SLAVE_ERROR = 5
    BUSY = 6
```

A výnimky:

```python
class XfcpError(Exception): pass
class XfcpTimeoutError(XfcpError): pass
class XfcpProtocolError(XfcpError): pass
class XfcpSlaveError(XfcpError): pass
class XfcpRecoveryError(XfcpError): pass
```

Potom testy nemusia len hádať, či „0B response“ znamená UART problém, invalid address alebo zaseknutý slave.

---

# 4. Tools rozdeliť na vrstvy

Odporúčam túto štruktúru:

```text
tools/
├── xfcp/
│   ├── transport.py       # Serial/UART transport
│   ├── protocol.py        # packet encode/decode
│   ├── bus.py             # read32/write32/read_block/write_block
│   ├── errors.py
│   ├── timeouts.py
│   ├── recovery.py
│   └── scanner.py
│
├── drivers/
│   ├── sys_ctrl.py
│   ├── gpio.py
│   ├── uart.py
│   ├── sevenseg.py
│   ├── memory.py
│   └── cpu.py
│
├── apps/
│   ├── scan.py
│   ├── poke.py
│   ├── peek.py
│   ├── load_mem.py
│   ├── run_cpu.py
│   └── test_module.py
│
└── tests/
    ├── test_protocol.py
    ├── test_transport_mock.py
    ├── test_recovery.py
    └── test_hw_smoke.py
```

Dôležité je, aby `protocol.py` nepoznal UART a `transport.py` nepoznal registre. Potom vieš robiť unit testy bez FPGA.

---

# 5. Pridať CLI použiteľné pri vývoji

Veľmi by ti pomohli malé príkazy:

```bash
xfcp scan --port /dev/ttyUSB0
xfcp ping
xfcp read32 0xFF000000
xfcp write32 0xFF020000 0x55
xfcp dump 0xFF000000 --words 16
xfcp wait 0xFF000010 --mask 0x1 --value 0x1 --timeout 5
xfcp recover
xfcp reset-endpoint
xfcp load app.hex --base 0x00000000
xfcp run-cpu --timeout 10
```

Pre vývoj modulov:

```bash
xfcp test gpio
xfcp test uart
xfcp test sevenseg
xfcp test my_module --base 0xFF060000 --timeout 2
```

---

# Konkrétny návrh pre timeout testovaného modulu

Na úrovni tools by som zaviedol univerzálnu funkciu:

```python
def wait_reg(
    self,
    addr: int,
    *,
    mask: int,
    value: int,
    timeout_s: float,
    poll_interval_s: float = 0.01,
) -> int:
    deadline = time.monotonic() + timeout_s

    while time.monotonic() < deadline:
        current = self.read32(addr)
        if (current & mask) == value:
            return current
        time.sleep(poll_interval_s)

    raise XfcpTimeoutError(
        f"Timeout waiting for 0x{addr:08X}: "
        f"(reg & 0x{mask:08X}) == 0x{value:08X}"
    )
```

Potom pre modul:

```python
mod.write_control(START)
mod.wait_done(timeout_s=1.0)
result = mod.read_result()
```

Pre CPU:

```python
cpu.reset()
memory.load_hex("app.hex")
cpu.release_reset()
cpu.wait_halted(timeout_s=10.0)
exit_code = cpu.read_exit_code()
```

---

# Odolnosť protokolu: čo by som doplnil do RTL/XFCP

## 1. Transaction ID

Ak ho ešte nemáš, doplniť `seq_id` alebo `transaction_id`.

```text
request:  seq_id
response: rovnaký seq_id
```

Výhoda:

```text
- stará oneskorená odpoveď sa dá zahodiť
- Python vie rozlíšiť odpoveď na aktuálnu transakciu
- pomáha pri recovery po stale bytes
```

Toto je veľmi dôležité pri tvojom probléme so stale bytes a 0B odpoveďami.

## 2. CRC alebo aspoň checksum

Ak protokol beží cez UART, odporúčam minimálne CRC8/CRC16.

```text
SOP | LEN | SEQ | OP | ADDR | COUNT | PAYLOAD | CRC
```

Bez CRC nevieš rozlíšiť:

```text
- zlý bajt
- posunutý packet
- starý packet
- poškodenú odpoveď
```

## 3. Resync pravidlo

Parser by mal mať jasné pravidlo:

```text
Ak príde SOP 0xFE v strede pokazeného packetu:
- zahodiť aktuálny packet
- začať nový packet
```

Toto asi čiastočne riešiš, ale tools by s tým mali rátať.

## 4. Explicitná ERROR response

Pri invalid address, slave timeout alebo zlý opcode by endpoint nemal ticho dropnúť request. Mal by vrátiť response typu:

```text
RESP_ERROR
payload:
  status_code
  failing_addr
  optional_info
```

Minimálne:

```text
RESP_WRITE + status byte
```

Ak nechceš meniť protokol hneď, dočasne môže byť error zakódovaný ako špeciálna write response.

---

# Systémové registre pre recovery

Odporúčam mať v `sys_ctrl` alebo `xfcp_id_rom` pevné registre:

```text
0xFF000000  MAGIC        napr. "XFCP"
0xFF000004  VERSION
0xFF000008  BUILD_ID
0xFF00000C  NUM_SLAVES
0xFF000010  CAPABILITIES
0xFF000014  SCRATCH
0xFF000018  ERROR_STATUS
0xFF00001C  ERROR_CLEAR
0xFF000020  XFCP_RESET
0xFF000024  RX_PACKET_COUNT
0xFF000028  TX_PACKET_COUNT
0xFF00002C  ERROR_COUNT
0xFF000030  LAST_ERROR
0xFF000034  LAST_BAD_ADDR
0xFF000038  LAST_TIMEOUT_ADDR
```

Potom `xfcp diagnose` vie vypísať:

```text
XFCP alive: yes
version: 0.2.0
build_id: 20260519
num_slaves: 6
rx_packets: 124
tx_packets: 123
errors: 1
last_error: SLAVE_TIMEOUT
last_bad_addr: 0xFF060000
```

Toto veľmi zrýchli debug.

---

# Testovanie tools bez FPGA

Toto je veľmi dôležité. Tools by si mal vedieť testovať aj bez dosky.

Pridaj mock transport:

```python
class MockTransport:
    def __init__(self):
        self.rx = bytearray()
        self.tx = bytearray()

    def write(self, data: bytes):
        self.tx.extend(data)

    def read(self, n: int, timeout: float) -> bytes:
        ...
```

Potom vieš testovať:

```text
- timeout
- poškodený packet
- oneskorená odpoveď
- stará odpoveď s nesprávnym seq_id
- 0B odpoveď
- bad CRC
- recovery flow
```

Bez toho, aby si zakaždým programoval FPGA.

---

# Navrhovaný krátkodobý roadmap

## Fáza A — stabilizácia súčasného stavu

```text
1. opraviť invalid WRITE path vo fabric endpoint
2. prepojiť resp_type z engine do fabric endpoint
3. overiť multi-word READ cez fabric
4. pridať T4 späť namiesto SKIP
5. make regression
6. Quartus rebuild
7. HW smoke test
```

Toto by som spravil ešte pred väčšou úpravou tools.

---

## Fáza B — tools cleanup

```text
1. vytvoriť xfcp/errors.py
2. vytvoriť xfcp/timeouts.py
3. rozdeliť xfcp.py na transport/protocol/bus
4. pridať retry + recover
5. pridať logging/debug dump packetov
6. pridať CLI príkazy ping/read/write/scan/recover
```

---

## Fáza C — robustný protokol

```text
1. pridať sequence ID
2. pridať CRC
3. pridať RESP_ERROR
4. pridať sys_ctrl error/status registre
5. pridať recovery command alebo soft reset endpointu
```

---

## Fáza D — vývoj modulov

```text
1. zaviesť jednotný register layout pre každý modul
2. každý modul má ID/version/capabilities/status/control
3. každý modul má Python driver
4. každý modul má HW smoke test
5. každý modul má YAML descriptor
```

Štandardný layout by mohol byť:

```text
base + 0x00  MODULE_MAGIC
base + 0x04  MODULE_VERSION
base + 0x08  MODULE_CAPABILITIES
base + 0x0C  MODULE_STATUS
base + 0x10  MODULE_CONTROL
base + 0x14  MODULE_ERROR
base + 0x18  MODULE_ERROR_CLEAR
base + 0x1C  MODULE_TIMEOUT_CFG
base + 0x20+ modulovo špecifické registre
```

---

## Fáza E — CPU aplikácie

```text
1. CPU reset/release cez sys_ctrl
2. RAM write/read cez XFCP
3. HEX/ELF loader
4. run + wait_done
5. exit code register
6. stdout/debug UART alebo memory log buffer
```

Cieľový workflow:

```bash
xfcp load build/app.hex --base 0x00000000
xfcp cpu reset
xfcp cpu run --timeout 10
xfcp cpu status
xfcp cpu exit-code
```

---

# Čo by som urobil ako prvé prakticky

Najbližší konkrétny krok by som zvolil tento:

```text
tools/xfcp/
├── __init__.py
├── errors.py
├── timeouts.py
├── transport.py
├── protocol.py
├── bus.py
└── recovery.py
```

A do `bus.py` dať základné stabilné API:

```python
class XfcpBus:
    def ping(self) -> bool: ...
    def read32(self, addr: int, timeout_s: float | None = None) -> int: ...
    def write32(self, addr: int, value: int, timeout_s: float | None = None) -> None: ...
    def read_block(self, addr: int, words: int, timeout_s: float | None = None) -> list[int]: ...
    def write_block(self, addr: int, data: list[int], timeout_s: float | None = None) -> None: ...
    def wait_reg(self, addr: int, mask: int, value: int, timeout_s: float) -> int: ...
    def recover(self) -> bool: ...
```

Toto je základ, na ktorom sa dá ďalej stavať.

---

# Záver

Áno, určite má zmysel pridať možnosť zadať timeout na odozvu testovaného modulu aj timeout na zotavenie XFCP. Ale nerobil by som to ako jeden univerzálny timeout. Rozdeľ ho na:

```text
byte_timeout
response_timeout
module_timeout
recovery_timeout
```

A nad tým postav:

```text
retry → recover → ping → soft reset → fail with diagnostics
```

Tým sa XFCP zmení z jednoduchého UART-MMIO mosta na použiteľnú debug infraštruktúru pre:

```text
- testovanie nových FPGA modulov,
- bring-up SoC,
- vývoj CPU aplikácií,
- automatizované HW regression testy,
- diagnostiku po chybách.
```
