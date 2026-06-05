# ETH_TEST_04 — Status

**Dátum:** 2026-06-05
**Stav:** NASTAVENIE — scaffold vytvorený, čaká na zadanie RTL cieľa

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

- **Stav:** —  (RTL zatiaľ neimplementovaný)

---

## Výsledky testov

- **Stav:** —

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

*(zatiaľ žiadne — čaká na zadanie)*
