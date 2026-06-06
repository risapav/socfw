# ETH_TEST_04 — Status

**Dátum:** 2026-06-05
**Stav:** ACTIVE — Faza 2 RTL hotová, čaká na Quartus build + HW overenie

---

## Cieľ projektu

IEEE 802.3 GMII rozhranie na QMTech EP4CE55 + RTL8211EG PHY.

Kontext: eth_test_03 odhalil 1-byte offset v gmii_rx_mac výstupe — DST_MAC[0]=0x00
sa neobjaví ako prvý AXI-Stream byte. Fyzická príčina neznáma (IOE pipeline, CDC,
PHY behavior). Cieľom eth_test_04 je preskúmať a opraviť GMII RX cestu.

---

## Konfigurácia

```
Board: QMTech EP4CE55F23C8 (Cyclone IV E)
PHY:   RTL8211EG (GMII 1 Gbps, 125 MHz)
PC:    192.168.0.3  na  enp0s31f6 (priame spojenie, 1000Mb/s)
FPGA:  LOCAL_IP=192.168.0.2, LOCAL_MAC=00:0a:35:01:fe:c0, UDP_PORT=8080
ARP:   ip neigh replace 192.168.0.2 lladdr 00:0a:35:01:fe:c0 nud permanent dev enp0s31f6
```

---

## Quartus Build Status

- **Stav:** BUILD OK — async_fifo.sv + gmii_tx_mac.sv (ST_PREAMBLE fix) skompilované

---

## Výsledky testov

### HW loopback (test_loopback.py) — 2026-06-05

| Test | Výsledok |
|---|---|
| make loopback-test (unicast) | 0/10 PASS (timeout 2s) |
| make loopback-test-bcast (broadcast) | 0/10 PASS (timeout 2s) |

**Potvrdené (neopakovať):**
- `ethtool enp0s31f6`: Speed=**1000Mb/s**, Duplex=Full, Link=**yes** — PHY link je UP
- Preamble fix (ST_PREAMBLE v gmii_tx_mac.sv) aplikovaný, ale nezmenil výsledok
- PACKET_OUTGOING filter v test_loopback.py funguje, nie je zdrojom false FAIL

**Root cause:** 1-byte RX offset (z eth_test_03) pravdepodobne spôsobuje, že prvý
byte v CDC FIFO je DST_MAC[0] namiesto SFD (0xD5). TX potom vysiela:
  preamble(7×0x55) + DST_MAC[0]=0xFF — bez SFD → PHY frame zahodí.
  
**Riešenie:** Faza 2 — clean MAC architektúra (RX MAC explicitne stripuje preamble/SFD,
TX MAC rebuiluje kompletný frame vrátane SFD+FCS).

---

## Kontextuálne poznatky z eth_test_03

### Dokazané fakty o HW (neopakovať investigácie)

1. **GMII TX fyzicky funguje** — beacony viditeľné v pcap, GTxCLK OK, PHY OK
2. **altddio_out invert_output="ON"** — GTxCLK výstup musí byť invertovaný (setup 4 ns vs. spec 2 ns)
3. **meta_fifo DEPTH ≥ 32** — Quartus Cyclone IV E: dual-clock BRAM inference vyžaduje ≥ 3072 bits
4. **GMII RX 1-byte offset** — gmii_rx_mac stream začína na ETH[1], nie ETH[0]
   - RTL analýza: `m_axis_tdata = rxd_q` — prvý výstup by mal byť DST_MAC[0]=0x00
   - HW realita: prvý byte = DST_MAC[1]=0x0a
   - Príčina: NEZNÁMA — možnosti: IOE vstupný pipeline register, reset CDC, tap FIFO
5. **PHY preamble**: RTL8211EG RXDV sa asertuje od SFD (0xD5), nie od preamble
   - gmii_rx_mac musí akceptovať `RXDV && rxd==0xD5` priamo z RX_IDLE stavu

### Dokazané fakty o timing

| Clock | Slack Setup Slow 85°C | Pozn. |
|---|---|---|
| ETH_RXC (125 MHz) | > +1 ns | Po GLOBAL_SIGNAL false path pre hold |
| ETH_TX_CLK (125 MHz) | > +0.3 ns | Po altddio_out output FF |
| SYS_CLK (50 MHz) | > +4 ns | Bez problémov |

### Kľúčové RTL rozhodnutia prenesené z eth_test_03

- `crc32_eth`: LSB-first, poly 0xEDB88320, init 0xFFFFFFFF, fcs_o = ~crc_reg
- `gmii_tx_mac`: output registers na txd_o/tx_en_o; IFG_BYTES=13 (kompenzácia output FF)
- `txb_fire_w = txb_tvalid && txb_tready` (AXI-S handshake, nie len tvalid)
- `eth_header_parser`: HDR_STRIP parameter (14=sim, 13=HW kvôli offsetu)

---

## Vykonne prikazy

- Build:   `make compile` z `examples/eth_test_04/`
- Program: `make program` z `examples/eth_test_04/`
- HW test: `make tap-test` z `examples/eth_test_04/` (po 5s od programovania)
- Sim:     `make regression` z `examples/eth_test_04/sim/`

---

## Implementované zmeny (chronologicky)

1. **gmii_tx_mac.sv** — pridaný stav ST_PREAMBLE (7×0x55 pred SFD); PHY vyžaduje preamble
2. **test_loopback.py** — PACKET_OUTGOING filter; `--broadcast` flag; sniff mode pkttype labels
3. **Makefile** — pridané targety `loopback-test`, `loopback-test-bcast`, `loopback-sniff`

### Faza 2 — clean MAC architektúra (2026-06-05)

4. **rtl/eth/mac/taxi_lfsr.sv** — Alex Forencich LFSR/CRC engine (CERN-OHL-S-2.0)
5. **rtl/eth/mac/eth_crc32_8.sv** — kombinatorický CRC32 wrapper (Galois, poly=0x04c11db7, REVERSE=1)
6. **rtl/eth/mac/eth_rx_mac.sv** — clean RX MAC: GMII → AXI-S payload + metadata
   - Explicitný strip preamble/SFD/header/FCS; 5-byte shift window pre FCS
   - Kombinatorický FCS check; meta emitovaný pri tlast (cut-through)
   - LOCAL_MAC filter + broadcast akceptácia
7. **rtl/eth/mac/eth_tx_mac.sv** — clean TX MAC: metadata + AXI-S payload → GMII
   - Generuje: preamble(7×0x55), SFD(0xD5), header(14B), payload, padding, CRC32 FCS
   - Registered GMII výstupy; underflow handling; IFG=12 cyklov
8. **rtl/eth/eth_echo_app.sv** — echo aplikácia v eth_tx_clk doméne
   - MAC swap: tx_dst=rx_src, tx_src=LOCAL_MAC; frame discard pri fcs_ok=0
   - FSM: ST_IDLE → ST_TX_META → ST_FORWARD/ST_DISCARD
9. **rtl/eth/ethernet_test_04_top.sv** — nový top modul
   - Payload async FIFO (DATA_WIDTH=10, DEPTH=2048); meta async FIFO (DATA_WIDTH=113, DEPTH=8)
   - LOCAL_MAC=00:0a:35:01:fe:c0; sticky overflow flag
10. **ip/ethernet_test_04_top.ip.yaml** — aktualizovaný zoznam artefaktov
11. **test_loopback.py** — pridaný `--mode clean/raw`; clean: offset==14, src==FPGA_MAC
12. **Makefile** — pridaný target `loopback-test-raw`

### Očakávané výsledky HW po Faza 2

- `make loopback-test`: 10/10 PASS; marker na offset=14; recv_src=00:0a:35:01:fe:c0
- LED[4]=rx_activity bliká, LED[5]=tx_activity bliká pri prenosoch
- Ak FAIL: skontrolovať `make loopback-sniff` pre raw frame analýzu
