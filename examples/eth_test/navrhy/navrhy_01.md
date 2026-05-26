Navrhol by som pre socfw modul v dvoch úrovniach:

```text
eth_port_test
  1. základný PHY/MAC link test
  2. UDP echo / packet counter test
```

Cieľ nie je hneď spustiť celé XFCP cez Ethernet. Najprv potrebujeme overiť:

```text
- či PHY clocky bežia,
- či link je UP,
- či MAC prijíma Ethernet rámce,
- či MAC vysiela Ethernet rámce,
- či vieme z PC poslať UDP paket a dostať odpoveď,
- či máme použiteľné diagnostické registre cez AXI-Lite.
```

---

# 1. Navrhovaný názov modulu

```text
eth_port_test
```

alebo ak chceš viac socfw štýl:

```text
eth_udp_echo_test
```

Ja by som zvolil:

```text
eth_port_test
```

pretože prvá verzia nemusí byť iba UDP echo. Môže obsahovať aj link status, PHY reset a základné countery.

---

# 2. Bloková architektúra

```text
PC
 │
 │ Ethernet UDP packet
 ▼
Ethernet PHY
 │
 ▼
eth_mac / eth_rx_axis / eth_tx_axis
 │
 ▼
eth_port_test
 ├── RX frame counter
 ├── optional ARP responder
 ├── IPv4 filter
 ├── UDP port filter
 ├── UDP echo responder
 ├── TX frame counter
 └── AXI-Lite status/config registers
```

Ak ešte nemáš hotový Ethernet stack, modul môže mať dve vrstvy:

```text
eth_port_test_raw
  - testuje iba raw Ethernet frames

eth_udp_echo_test
  - testuje IPv4/UDP
```

Ale pre praktické použitie odporúčam rovno UDP echo, lebo to ľahko otestuješ z Linuxu alebo Pythonu.

---

# 3. Odporúčaná funkcionalita prvej verzie

## Režim A — link/status test

AXI-Lite registre:

```text
STATUS:
  bit0 link_up
  bit1 rx_activity
  bit2 tx_activity
  bit3 rx_error
  bit4 tx_error
  bit5 phy_reset_done

RX_FRAME_COUNT
TX_FRAME_COUNT
RX_BYTE_COUNT
TX_BYTE_COUNT
RX_DROP_COUNT
LAST_ETH_TYPE
LAST_SRC_MAC_LO
LAST_SRC_MAC_HI
```

Toto pomôže overiť, či vôbec vidíš Ethernet rámce.

---

## Režim B — UDP echo test

PC pošle:

```text
UDP dst port = 50000
payload      = ľubovoľné bajty
```

FPGA odpovie späť:

```text
UDP src port = 50000
UDP dst port = pôvodný source port
payload      = rovnaký payload
```

Príklad PC testu:

```python
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(1.0)

sock.sendto(b"hello fpga", ("192.168.1.50", 50000))
data, addr = sock.recvfrom(2048)

print(addr, data)
```

Očakávanie:

```text
('192.168.1.50', 50000) b'hello fpga'
```

---

# 4. Navrhovaná register mapa

Base adresa napríklad:

```text
0xFF070000 : ETH_TEST
```

Ak teraz máš:

```text
0xFF000000 SYSC
0xFF010000 UART
0xFF020000 LED0
0xFF030000 LED1
0xFF040000 LED2
0xFF050000 SEG7
0xFF060000 DIAG
```

tak ETH test môže byť slot 7:

```text
0xFF070000 ETH_
```

Register mapa:

```text
Offset  Name              R/W   Popis
0x00    ID                RO    "ETH_"
0x04    VERSION           RO    napr. 0x00010000
0x08    CONTROL           RW
0x0C    STATUS            RO
0x10    LOCAL_MAC_LO      RW
0x14    LOCAL_MAC_HI      RW
0x18    LOCAL_IP          RW
0x1C    UDP_PORT          RW
0x20    RX_FRAME_COUNT    RO
0x24    TX_FRAME_COUNT    RO
0x28    RX_BYTE_COUNT     RO
0x2C    TX_BYTE_COUNT     RO
0x30    RX_DROP_COUNT     RO
0x34    RX_ERROR_COUNT    RO
0x38    TX_ERROR_COUNT    RO
0x3C    LAST_SRC_IP       RO
0x40    LAST_SRC_PORT     RO
0x44    LAST_DST_PORT     RO
0x48    LAST_PAYLOAD_LEN  RO
0x4C    LAST_ERROR        RO
0x50    CLEAR_COUNTERS    WO
```

`CONTROL`:

```text
bit0 enable
bit1 echo_enable
bit2 promiscuous
bit3 arp_enable
bit4 loopback_enable
bit8 clear_counters pulse
```

`STATUS`:

```text
bit0 link_up
bit1 enabled
bit2 rx_active
bit3 tx_active
bit4 arp_ready
bit5 udp_ready
bit6 rx_fifo_full
bit7 tx_fifo_full
```

---

# 5. Navrhované SystemVerilog rozhranie

Modul by som nedával priamo na PHY piny. Lepšie je oddeliť MAC/PHY od test logiky.

## Variant s AXI-Stream Ethernet rámcami

```systemverilog
module eth_port_test #(
  parameter logic [47:0] DEFAULT_MAC = 48'h02_00_00_00_00_01,
  parameter logic [31:0] DEFAULT_IP  = {8'd192, 8'd168, 8'd1, 8'd50},
  parameter logic [15:0] DEFAULT_UDP_PORT = 16'd50000
)(
  input  logic clk_i,
  input  logic rst_ni,

  // AXI-Lite control/status
  axi4lite_if.slave s_axil,

  // Ethernet RX frame stream from MAC
  axi4s_if.slave eth_rx,

  // Ethernet TX frame stream to MAC
  axi4s_if.master eth_tx,

  // PHY/MAC status
  input logic link_up_i,

  // optional debug
  output logic irq_o
);
```

Tento modul očakáva, že už máš niekde:

```text
PHY → MAC → eth_rx AXIS
eth_tx AXIS → MAC → PHY
```

Toto je najčistejšie do frameworku.

---

## Variant s UDP payload streamom

Ak použiješ UDP/IP stack ako samostatný blok, potom `eth_port_test` nemusí riešiť Ethernet/IP/UDP hlavičky. Dostane už len UDP payload.

```systemverilog
module eth_udp_echo_test #(
  parameter logic [15:0] DEFAULT_UDP_PORT = 16'd50000
)(
  input logic clk_i,
  input logic rst_ni,

  axi4lite_if.slave s_axil,

  // UDP RX metadata
  input  logic        udp_rx_meta_valid_i,
  output logic        udp_rx_meta_ready_o,
  input  logic [31:0] udp_rx_src_ip_i,
  input  logic [31:0] udp_rx_dst_ip_i,
  input  logic [15:0] udp_rx_src_port_i,
  input  logic [15:0] udp_rx_dst_port_i,
  input  logic [15:0] udp_rx_length_i,

  // UDP RX payload
  input  logic        udp_rx_valid_i,
  output logic        udp_rx_ready_o,
  input  logic [7:0]  udp_rx_data_i,
  input  logic        udp_rx_last_i,

  // UDP TX metadata
  output logic        udp_tx_meta_valid_o,
  input  logic        udp_tx_meta_ready_i,
  output logic [31:0] udp_tx_dst_ip_o,
  output logic [15:0] udp_tx_dst_port_o,
  output logic [15:0] udp_tx_src_port_o,
  output logic [15:0] udp_tx_length_o,

  // UDP TX payload
  output logic        udp_tx_valid_o,
  input  logic        udp_tx_ready_i,
  output logic [7:0]  udp_tx_data_o,
  output logic        udp_tx_last_o,

  input logic link_up_i
);
```

Toto je podľa mňa najlepšia verzia pre prvý funkčný test.

---

# 6. Jednoduchý vnútorný návrh UDP echo testu

Pre UDP echo potrebuješ dočasne uložiť payload, lebo pre odpoveď často potrebuješ najprv poslať TX metadata s dĺžkou payloadu.

Pre prvú verziu:

```text
UDP RX payload
  → malý FIFO / RAM buffer 1536 B
  → po RX_LAST poznáš dĺžku
  → odošleš UDP TX metadata
  → vyčítaš buffer do UDP TX payloadu
```

FSM:

```text
IDLE
  čaká na udp_rx_meta_valid

DROP
  ak dst_port != configured_port alebo echo disabled

RECV
  ukladá payload do bufferu
  počíta bajty
  pri udp_rx_last ide do SEND_META

SEND_META
  pošle dst_ip=src_ip, dst_port=src_port, src_port=configured_port, length=count

SEND_PAYLOAD
  číta buffer a streamuje bajty do UDP TX
  poslednému bajtu dá last

DONE
  update counters, späť do IDLE
```

---

# 7. Odporúčaný buffer pre UDP payload

Na prvý test stačí:

```text
MAX_PAYLOAD_BYTES = 512
```

Neskôr môžeš dať:

```text
1472 B = Ethernet MTU 1500 - IPv4 header 20 - UDP header 8
```

Parametre:

```systemverilog
parameter int MAX_PAYLOAD_BYTES = 512;
```

Interná RAM:

```systemverilog
logic [7:0] payload_mem [0:MAX_PAYLOAD_BYTES-1];
```

Pre malé FPGA testy pokojne:

```systemverilog
(* ramstyle = "logic" *)
```

Pre 1472 B už skôr block RAM.

---

# 8. Prečo modul najprv len echo, nie XFCP

ETH bring-up má byť čo najjednoduchší. Ak by si hneď pripojil XFCP, pri chybe nevieš, či je problém:

```text
- PHY,
- MAC,
- ARP,
- IP checksum,
- UDP checksum,
- payload stream,
- XFCP parser,
- fabric,
- packetizer,
- PC tools.
```

Echo test izoluje transport.

Poradie:

```text
1. link_up register
2. RX frame count
3. UDP echo
4. UDP counters
5. XFCP-over-UDP
```

---

# 9. Návrh IP descriptoru pre socfw

Napríklad:

```yaml
version: 1
kind: ip

ip:
  name: eth_udp_echo_test
  vendor: socfw
  version: 0.1.0
  description: Ethernet UDP echo test peripheral with AXI-Lite status/control

rtl:
  sources:
    - rtl/eth/eth_udp_echo_test.sv
    - rtl/stream/stream_reg_slice.sv
    - rtl/stream/stream_skid_buffer.sv
    - rtl/stream/axis_reg_slice.sv
    - rtl/stream/axis_skid_buffer.sv

bus:
  type: axil
  data_width: 32
  addr_width: 32

ports:
  clocks:
    - name: clk_i
      domain: sys_clk
  resets:
    - name: rst_ni
      active_low: true

params:
  DEFAULT_UDP_PORT:
    type: int
    default: 50000
  MAX_PAYLOAD_BYTES:
    type: int
    default: 512
```

Ak bude modul napojený za UDP stackom, musí descriptor vedieť opísať aj stream porty.

---

# 10. Socfw example

Vytvoril by som nový example projekt:

```text
examples/eth_test_01/
├── project.yaml
├── timing_config.yaml
├── ip/
│   └── eth_udp_echo_test.ip.yaml
├── rtl/
│   ├── eth -> ../../../rtl/eth
│   ├── stream -> ../../../rtl/stream
│   ├── axil -> ../../../rtl/axil
│   └── ...
└── tools/
    └── udp_echo_test.py
```

---

# 11. Python test nástroj

```python
#!/usr/bin/env python3
import socket
import time
import argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.1.50")
    ap.add_argument("--port", type=int, default=50000)
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--size", type=int, default=32)
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1.0)

    ok = 0
    fail = 0

    for i in range(args.count):
        payload = bytes([(i + j) & 0xFF for j in range(args.size)])
        t0 = time.time()
        sock.sendto(payload, (args.host, args.port))

        try:
            data, addr = sock.recvfrom(2048)
            dt = (time.time() - t0) * 1000

            if data == payload:
                ok += 1
                print(f"OK {i}: {len(data)} B from {addr}, {dt:.2f} ms")
            else:
                fail += 1
                print(f"BAD {i}: got {len(data)} B")
        except socket.timeout:
            fail += 1
            print(f"TIMEOUT {i}")

    print(f"RESULT: ok={ok} fail={fail}")

if __name__ == "__main__":
    main()
```

---

# 12. Testovací plán

## Fáza A — link only

```text
- reset FPGA
- pripojiť Ethernet kábel
- overiť link_up bit
- meniť kábel/switch a sledovať link_up
```

## Fáza B — RX counter

Z PC pošli broadcast alebo ping/ARP a sleduj:

```text
RX_FRAME_COUNT
RX_BYTE_COUNT
LAST_ETH_TYPE
```

## Fáza C — ARP

Ak máš ARP responder:

```bash
arping 192.168.1.50
```

Očakávaš odpoveď.

## Fáza D — UDP echo

```bash
python3 tools/udp_echo_test.py --host 192.168.1.50 --count 100 --size 32
```

## Fáza E — payload sizes

```bash
for s in 1 8 32 128 512 1024 1472; do
  python3 tools/udp_echo_test.py --host 192.168.1.50 --count 100 --size $s
done
```

---

# 13. Diagnostické výstupy

Modul by mal mať minimálne:

```text
rx_udp_count
tx_udp_count
rx_drop_count
rx_bad_port_count
rx_too_long_count
tx_busy_drop_count
last_src_ip
last_src_port
last_len
last_error
```

Error kódy:

```text
0 = OK
1 = BAD_PORT
2 = TOO_LONG
3 = TX_BUSY
4 = RX_OVERFLOW
5 = INTERNAL
```

---

# 14. Čo s checksumami

Pre UDP/IPv4:

```text
IPv4 header checksum musí byť správny.
UDP checksum v IPv4 môže byť 0, teda vypnutý.
```

Pre prvú FPGA verziu môžeš posielať UDP checksum = 0. Linux to prijme pre IPv4 UDP.

Pre RX môžeš UDP checksum ignorovať, ak chceš jednoduchý test. Neskôr doplniť validáciu.

---

# 15. Odporúčaná implementačná stratégia

Najprv nepíš celý Ethernet stack. Rozhodni sa, či:

```text
A. už máš alebo použiješ existujúci MAC/IP/UDP stack,
B. alebo potrebuješ najprv vytvoriť minimálny UDP stack.
```

Ak ešte nemáš stack, odporúčam toto poradie:

```text
1. MAC/PHY bring-up
2. RX Ethernet frame parser
3. TX raw Ethernet frame generator
4. ARP responder
5. IPv4 RX filter
6. UDP RX filter
7. UDP TX generator
8. eth_udp_echo_test
```

Ak stack už máš, začni priamo `eth_udp_echo_test`.

---

# 16. Modul ako príprava na XFCP-over-UDP

Keď `eth_udp_echo_test` prejde, z neho priamo vznikne:

```text
xfcp_udp_transport
```

Rozdiel:

```text
eth_udp_echo_test:
  UDP payload uloží a pošle späť rovnaký

xfcp_udp_transport:
  UDP payload pošle do xfcp_mmio_core
  response z xfcp_mmio_core pošle späť ako UDP payload
```

Teda testovací modul bude dobrý medzikrok, nie slepá ulička.

---

# 17. Moje odporúčanie

Pre socfw by som vytvoril tieto moduly:

```text
rtl/eth/
├── eth_udp_echo_test.sv      // prvý test ETH portu
├── xfcp_udp_transport.sv     // neskôr XFCP transport
└── eth_diag_ctrl.sv          // voliteľne samostatná diagnostika
```

A example:

```text
examples/eth_test_01/
```

Minimálny cieľ prvej verzie:

```text
PC pošle UDP payload → FPGA odpovie rovnaký payload
```

Až keď toto bude stabilné, napojiť XFCP.

---

# Záver

Navrhovaný testovací modul pre ETH port:

```text
eth_udp_echo_test
```

Účel:

```text
- overiť PHY/MAC/IP/UDP cestu,
- overiť RX/TX Ethernet tok,
- získať countery a diagnostiku,
- pripraviť základ pre xfcp_udp_transport.
```

Najlepšie rozhranie je za UDP stackom, teda modul neparsuje priamo PHY signály, ale dostáva už UDP metadata a payload stream. Ak ešte UDP stack nemáš, začni raw Ethernet/ARP/UDP bring-upom, ale cieľový testovací modul by mal byť UDP echo s AXI-Lite diagnostikou.
