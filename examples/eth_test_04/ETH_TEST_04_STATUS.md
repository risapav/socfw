# ETH_TEST_04 — Status

**Dátum:** 2026-06-06
**Stav:** UZAVRETY — altddio_in fix, loopback 10/10 PASS, HW potvrdený

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

## Root Cause: GMII RXD[3:0] timing violation

### Diagnostika (gmii_raw_tap + UART)

Implementovaný `gmii_raw_tap.sv` — tapuje RAW GMII za SFD, odosiela N_BYTES=32 cez UART
8N1 (115200 baud). `tools/read_tap.py` prijíma + porovnáva po-bajte s pcap referenciou
(subprocess tcpdump -r, binárne XOR s názvami polí).

**1. run (bez altddio_in):** 6/6 ramcov zachytených, SYSTEMATICKÉ chyby iba v bitoch 0–3:

| Pole      | uart  | ref   | xor  | bity  |
|-----------|-------|-------|------|-------|
| DST[5]    | `c8`  | `c0`  | 0x08 | bit 3 |
| SRC[1..5] | rôzne | rôzne | 0x01..0x05 | bity 0,2 |
| ETH[1]    | `05`  | `00`  | 0x05 | bity 0,2 |
| PAY[0]    | `40`  | `45`  | 0x05 | bity 0,2 |

Všetky chyby v RXD[3:0] (dolná nibble). RXD[7:4] vždy správny.

**Príčina:** PCB trace delay + crosstalk spôsobuje glitche na RXD[3:0] pri nabehovej hrane
RX_CLK (125 MHz = 8 ns perioda). PHY drive z nabehovej hrany, FPGA vzorkuje na nabehovej
hrane → tesnésní setup time pre dolnú nibble. Riešenie: vzorkovanie na zostupnej hrane (4 ns
neskôr = stred dátového okna).

**Dôsledok:** DST MAC corrupted → mac_match=0 → 0/6 echo.

---

## Fix: altddio_in (invert_input_clocks="ON")

Tri instancie v `rtl/eth/ethernet_test_04_top.sv`:

```systemverilog
`ifdef SYNTHESIS
  altddio_in #(
    .intended_device_family ("Cyclone IV E"),
    .invert_input_clocks    ("ON"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_in"),
    .width                  (8)
  ) u_rxd_ddr (
    .datain    (eth_rxd_i),
    .inclock   (eth_rx_clk_i),
    .dataout_h (rxd_s_w),   // falling-edge capture
    ...
  );
  // analogicky u_rxdv_ddr (width=1), u_rxer_ddr (width=1)
`else
  assign rxd_s_w  = eth_rxd_i;   // sim fallback
  assign rxdv_s_w = eth_rxdv_i;
  assign rxer_s_w = eth_rxer_i;
`endif
```

`u_rx_mac` a `u_gmii_raw_tap` prepojené na `rxd_s_w`/`rxdv_s_w`/`rxer_s_w`.

**Latencia:** altddio_in přidáva 1 cycle (eth_rx_mac má vlastný 1-cycle pipeline → celkom 2).
Uniformné oneskorenie všetkých signálov, logika je korektná.

**Sim 5/5 PASS** (nezmenené — fallback assign v else vetve).

**2. run (s altddio_in):** DST MAC `00:0a:35:01:fe:c0` — perfektný na všetkých 6 ramcoch.

---

## Výsledky testov

### HW loopback (test_loopback.py) — 2026-06-06

```
make loopback-test → 10/10 PASS
  offset=14 (correct): 10x

  PASS  min-pad  60B frame      60B   [offset=14 OK]  body OK
  PASS  64B  data               84B   [offset=14 OK]  body OK
  PASS  128B data               148B  [offset=14 OK]  body OK
  PASS  256B data               276B  [offset=14 OK]  body OK
  PASS  512B data               532B  [offset=14 OK]  body OK
  PASS  1000B data              1020B [offset=14 OK]  body OK
  PASS  1492B data (near max)   1512B [offset=14 OK]  body OK
  PASS  all-0x00  200B          220B  [offset=14 OK]  body OK
  PASS  all-0xFF  200B          220B  [offset=14 OK]  body OK
  PASS  alternating  200B       220B  [offset=14 OK]  body OK
```

Cela cesta GMII RX → eth_rx_mac → async FIFOs (CDC) → eth_echo_app → eth_tx_mac → GMII TX
funguje pre všetky veľkosti rámcov (60B–1512B) a všetky dátové vzory.

### Poznámka k test_fpga.py (UDP socket)

`test_fpga.py` používa štandardný `AF_INET/SOCK_DGRAM` socket. `eth_echo_app` je Layer-2
MAC-swap echo (IP DST/UDP DST sa nemení). Linux kernel zahodí echovaný rámec (IP DST ≠ PC IP).
**test_fpga.py vždy 0/6 s týmto dizajnom — nie je HW bug, ale protocol mismatch.**
Pre UDP test treba v echo_app vymeniť IP SRC↔DST + UDP SRC↔DST + prepočítať checksums.

---

## Quartus Build Status

- **Stav:** BUILD OK — kompilovaný s altddio_in, naprogramovaný, HW overený

---

## Finálna architektúra

```
eth_rxdv/rxd/rxer (FPGA vstup, 125 MHz)
  → altddio_in (invert_input_clocks="ON") → rxdv_s_w, rxd_s_w, rxer_s_w
      ├→ eth_rx_mac (eth_rx_clk_i)
      │    ├→ payload_fifo (DATA_WIDTH=10, DEPTH=2048) [CDC]
      │    └→ meta_fifo (DATA_WIDTH=113, DEPTH=8) [CDC]
      │         → eth_echo_app (eth_tx_clk_i)
      │              → eth_tx_mac → eth_txen/txd/txer
      └→ gmii_raw_tap (N_BYTES=32) → uart_tap_tx_o (J11)

GTX_CLK: altddio_out (invert_output="ON") na eth_tx_clk_i (PLL 125 MHz)
```

---

## Kontextuálne poznatky z eth_test_03

### Dokazané fakty o HW (neopakovať)

1. **GMII TX fyzicky funguje** — beacony viditeľné v pcap, GTxCLK OK, PHY OK
2. **altddio_out invert_output="ON"** — GTxCLK výstup musí byť invertovaný (setup 4 ns vs. spec 2 ns)
3. **meta_fifo DEPTH ≥ 32** — Quartus Cyclone IV E: dual-clock BRAM inference vyžaduje ≥ 3072 bits
4. **PHY preamble**: RTL8211EG RXDV sa asertuje od SFD (0xD5), nie od preamble
5. **altddio_in pattern** — template pre každý ďalší GMII 1G dizajn na tejto karte

---

## Vykonné príkazy

```
make sim            # regression sim (5/5 PASS)
make compile        # Quartus build
make program        # JTAG programming
make tap-test       # GMII raw tap + pcap comparison
make loopback-test  # L2 echo test (10/10 PASS)
make loopback-sniff # raw frame sniffer
```
