# XFCP CLI — `xfcp_cli.py`

Command-line client pre interaktívnu komunikáciu s FPGA cez XFCP protokol.
Podporuje UART aj UDP transport.

---

## Inštalácia / spustenie

```bash
cd examples/xfcp_test_10_axifull/tools
python3 xfcp_cli.py --help
```

alebo cez Makefile (z adresára projektu):

```bash
make xfcp-ping
make xfcp-caps XFCP_UDP=192.168.0.5:50000
make xfcp CMD="mem-read 0x00000000 64"
```

---

## Transport

```
--uart PORT[:BAUD]      UART transport (default baud 115200)
--udp  HOST:PORT        UDP transport
--baud N                UART baud rate, ak nie je v --uart (default 115200)
--retries N             počet opakovaní pri timeout (default 1)
```

Príklady:

```bash
python3 xfcp_cli.py --uart /dev/ttyUSB0 ping
python3 xfcp_cli.py --uart /dev/ttyUSB0:115200 ping
python3 xfcp_cli.py --udp  192.168.0.5:50000 ping
```

---

## Príkazy

### `ping`

Overí, že SoC odpovedá. Meria round-trip time.

```bash
python3 xfcp_cli.py --uart /dev/ttyUSB0 ping
# OK  SoC odpovedá  (3.9 ms)
```

---

### `caps`

Zobrazí `GET_CAPS` odpoveď — verzia protokolu, počet slotov, flagy.

```bash
python3 xfcp_cli.py --udp 192.168.0.5:50000 caps
#   proto          1.3
#   axil_slots     2
#   stream_slots   1
#   max_stream     256 B
#   stream_align   4
#   caps_flags     0x1F  (HAS_AXIL | HAS_STREAM | HAS_CAPS | HAS_TARGETS | HAS_MEM)
```

---

### `targets`

Vypíše tabuľku všetkých `GET_TARGET_INFO` záznamov.

```bash
python3 xfcp_cli.py --uart /dev/ttyUSB0 targets
#   Idx  Názov  Typ      Base addr    max_xfer  align
#   ----------------------------------------------------------
#   0    REG0   AXIL    0xFF000000      256 B      4
#   1    SYS    AXIL    0xFF020000      256 B      4
#   2    LB0    STREAM  0x00000000      256 B      4
#   3    MEM0   MEM     0x00000000      256 B      4
```

---

### `read32 ADDR`

Prečíta jeden 32-bitový register.

```bash
python3 xfcp_cli.py --uart /dev/ttyUSB0 read32 0xFF020000
#   0xFF020000 = 0x4F55545F  (1332768095)
```

---

### `write32 ADDR VALUE`

Zapíše jeden 32-bitový register.

```bash
python3 xfcp_cli.py --uart /dev/ttyUSB0 write32 0xFF020004 0x3F
# OK  0xFF020004 <- 0x0000003F
```

---

### `read ADDR COUNT`

Burst read — prečíta `COUNT` 32-bitových slov, vypíše hex dump.

```bash
python3 xfcp_cli.py --udp 192.168.0.5:50000 read 0xFF000000 4
#   FF000000  00 00 00 00 00 00 00 01 00 00 00 02 00 00 00 03  ................
```

---

### `write ADDR VAL [VAL ...]`

Burst write — zapíše jedno alebo viac 32-bitových slov.

```bash
python3 xfcp_cli.py --uart /dev/ttyUSB0 write 0xFF020004 0x01 0x02
# OK  0xFF020004 <- 2 slov
```

---

### `mem-read ADDR COUNT [FILE]`

Prečíta `COUNT` bajtov z AXI4-Full pamäte (MEM backend).
`COUNT` musí byť násobok 4, max 256 B.

```bash
# hex dump na stdout
python3 xfcp_cli.py --uart /dev/ttyUSB0 mem-read 0x00000000 64

# uložiť do súboru
python3 xfcp_cli.py --uart /dev/ttyUSB0 mem-read 0x00000000 256 dump.bin
```

Príklad výstupu:

```
  00000000  00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F  ................
  00000010  10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F  ................
```

---

### `mem-write ADDR FILE`

Zapíše obsah súboru do AXI4-Full pamäte. Dĺžka musí byť násobok 4, max 256 B.
Použiť `-` pre stdin.

```bash
python3 xfcp_cli.py --uart /dev/ttyUSB0 mem-write 0x00000000 data.bin
# OK  0x00000000 <- 256 B z data.bin
```

---

### `stream-read SID COUNT [FILE]`

Prečíta `COUNT` bajtov z AXI-Stream kanála `SID`.

```bash
python3 xfcp_cli.py --uart /dev/ttyUSB0 stream-read 0 256
python3 xfcp_cli.py --uart /dev/ttyUSB0 stream-read 0 256 out.bin
```

---

### `stream-write SID FILE`

Zapíše obsah súboru do AXI-Stream kanála `SID`. Použiť `-` pre stdin.

```bash
python3 xfcp_cli.py --uart /dev/ttyUSB0 stream-write 0 data.bin
# OK  stream sid=0 <- 256 B z data.bin
```

---

## Makefile skratky

V adresári projektu (napr. `examples/xfcp_test_10_axifull/`):

| Cieľ              | Popis                                       |
|-------------------|---------------------------------------------|
| `xfcp-ping`       | ping cez UART (default `/dev/ttyUSB0`)      |
| `xfcp-caps`       | GET_CAPS                                    |
| `xfcp-targets`    | GET_TARGET_INFO tabuľka                     |
| `xfcp-read32`     | read32 ADDR=… (default 0xFF020000)          |
| `xfcp-write32`    | write32 ADDR=… VAL=…                        |
| `xfcp CMD="..."`  | ľubovoľný príkaz                            |

Premenné prostredia:

```makefile
XFCP_UART ?= /dev/ttyUSB0      # UART port (default z UART_PORT)
XFCP_UDP  ?=                   # ak nastavené, použije UDP namiesto UART
ADDR      ?= 0xFF020000
VAL       ?= 0x00000000
CMD       ?= ping
```

Príklady:

```bash
make xfcp-ping
make xfcp-ping   XFCP_UDP=192.168.0.5:50000
make xfcp-caps   XFCP_UDP=192.168.0.5:50000
make xfcp-read32 ADDR=0xFF020000
make xfcp-write32 ADDR=0xFF020004 VAL=0x0F
make xfcp CMD="mem-read 0x00000000 64"
make xfcp CMD="stream-write 0 /tmp/data.bin" XFCP_UDP=192.168.0.5:50000
```

---

## Exit kódy

| Kód | Význam                              |
|-----|-------------------------------------|
| 0   | OK                                  |
| 1   | chyba (timeout, status error, …)    |
| 130 | prerušenie (Ctrl+C)                 |
| 0   | BrokenPipe (výstup bol presmerovaný)|

---

## Chybové hlásenia

Pri FPGA status chybe vypíše meno kódu:

```
FAIL  FPGA status: AXI_SLVERR
FAIL  FPGA status: TIMEOUT
FAIL  FPGA status: BAD_ADDRESS
```

Kompletná tabuľka status kódov: [status.md](status.md).
