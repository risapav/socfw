# ETH_TEST_04 — Status

**Dátum:** 2026-06-06
**Stav:** UZAVRETY — ARP/ICMP/UDP stack, timing clean, HW 10/10 PASS

---

## Cieľ projektu

IEEE 802.3 GMII rozhranie na QMTech EP4CE55 + RTL8211EG PHY.
Plný L2/L3/L4 Ethernet stack s ARP echo, ICMP echo a UDP echo.

Kontext: eth_test_03 odhalil 1-byte offset v gmii_rx_mac výstupe — DST_MAC[0]=0x00
sa neobjaví ako prvý AXI-Stream byte. Fyzická príčina: IOE timing violation na
RXD[3:0] (dolná nibble). Fix: altddio_in s `invert_input_clocks="ON"`.

---

## Konfigurácia

```
Board: QMTech EP4CE55F23C8 (Cyclone IV E)
PHY:   RTL8211EG (GMII 1 Gbps, 125 MHz)
PC:    192.168.0.3  na  enp0s31f6 (priame spojenie, 1000Mb/s)
FPGA:  LOCAL_IP=192.168.0.2, LOCAL_MAC=00:0a:35:01:fe:c0, UDP_PORT=7 (RFC 862)
ARP:   ip neigh replace 192.168.0.2 lladdr 00:0a:35:01:fe:c0 nud permanent dev enp0s31f6
```

---

## Fáza A: MAC/L2 loopback (uzavretá, commit 2c66355)

### Root Cause: GMII RXD[3:0] timing violation

**Diagnostika (gmii_raw_tap + UART):** Implementovaný `gmii_raw_tap.sv` — tapuje RAW GMII
za SFD, odosiela N_BYTES=32 cez UART 8N1 (115200 baud). Systematické chyby iba v bitoch 0–3.

| Pole      | uart  | ref   | xor  | bity  |
|-----------|-------|-------|------|-------|
| DST[5]    | `c8`  | `c0`  | 0x08 | bit 3 |
| SRC[1..5] | rôzne | rôzne | 0x01..0x05 | bity 0,2 |

Príčina: PCB trace delay + crosstalk na RXD[3:0] pri nabehovej hrane RX_CLK.
Riešenie: vzorkovanie na zostupnej hrane (4 ns neskôr = stred dátového okna).

### Fix: altddio_in (invert_input_clocks="ON")

```systemverilog
`ifdef SYNTHESIS
  altddio_in #(
    .intended_device_family ("Cyclone IV E"),
    .invert_input_clocks    ("ON"),
    .width                  (8)
  ) u_rxd_ddr (
    .datain    (eth_rxd_i),
    .inclock   (eth_rx_clk_i),
    .dataout_h (rxd_s_w),   // falling-edge capture
    ...
  );
`else
  assign rxd_s_w  = eth_rxd_i;   // sim fallback
`endif
```

### Výsledky: L2 loopback 10/10 PASS

```
make loopback-test → 10/10 PASS
  PASS  60B min-pad, 64B, 128B, 256B, 512B, 1000B, 1492B
  PASS  all-0x00, all-0xFF, alternating 200B
  offset=14 correct: 10x
```

---

## Fáza B: ARP/ICMP/UDP stack (uzavretá, commit 6ada345)

### Architektúra

```
eth_rx_mac
  -> eth_type_demux
      -> ARP path:  arp_rx -> arp_tx
      -> IPv4 path: ipv4_rx -> icmp_echo
                             -> udp_echo (port 7, RFC 862)
  -> ipv4_tx
  -> eth_tx_arb (3-to-1 fixed-priority: ARP > ICMP > UDP)
  -> eth_tx_mac -> GMII TX
```

### Timing closure (Faza 5)

**Problém:** ETH_TX_CLK setup slack −3.562 ns (Fmax 86 MHz vs 125 MHz).
Root cause: M9K `portb_address_reg0` → mux → eth_tx_mac (~11 ns kombinačná cesta).

**Tri fixes:**

1. **eth_tx_arb**: Registrovaný payload output (skid buffer). `m_tdata_q` FF preruší
   cestu z RAM cez arbiter do eth_tx_mac.

2. **icmp_echo + udp_echo**: Zmena z `assign q = mem[addr]` na `always_ff q <= mem[addr]`.
   Quartus inferuje M9K s `outdata_reg` — eliminuje `portb_address_reg0` z kritickej cesty.

3. **FSM read-ahead**: `tx_rd_addr_q` (read pointer, 1 cyklus napred) + `tx_out_cnt_q`
   (output counter pre tlast). Na TX_HDR→TX_DATA prechode: `tx_rd_addr_q <= 1`, always_ff
   číta mem[0] na rovnakom hrane → mem[0] pripravený v TX_DATA cykle 0.

**Výsledky timing (soc_top.sta.summary):**

```
Slow 85C Setup ETH_TX_CLK: +0.327 ns  (TNS=0, CLEAN)
Slow  0C Setup ETH_TX_CLK: +0.814 ns
Fast  0C Setup ETH_TX_CLK: +4.651 ns
```

### Výsledky: HW PASS (2026-06-06)

```
make test-stack

--- ARP ---
arping 192.168.0.2 → Received 4 response(s)  RTT ~0.6 ms

--- ICMP ---
6 packets transmitted, 6 received, 0% packet loss
rtt min/avg/max/mdev = 0.084/0.087/0.090/0.002 ms

--- UDP echo port 7 ---
Result: 10/10 PASS  (0 FAIL)

--- UDP echo large 1464B ---
Result: 5/5 PASS  (0 FAIL)
```

**Regression: 8/8 ALL PASS** (tb_eth_crc32_8, tb_eth_rx_mac, tb_eth_tx_mac,
tb_eth_echo_app, tb_rx_tx_loopback, tb_arp, tb_icmp_echo, tb_udp_echo)

---

## Kontextuálne poznatky

### Dokazané fakty o HW (neopakovať)

1. **GMII TX fyzicky funguje** — GTxCLK OK, PHY OK, RTT ~0.09 ms
2. **altddio_out invert_output="ON"** — GTxCLK výstup musí byť invertovaný
3. **meta_fifo DEPTH ≥ 32** — Cyclone IV E dual-clock BRAM inference vyžaduje ≥ 3072 bits
4. **PHY preamble**: RTL8211EG RXDV sa asertuje od SFD (0xD5), nie od preamble
5. **altddio_in pattern** — template pre každý ďalší GMII 1G dizajn na tejto karte
6. **M9K timing pattern** — pre M9K RAM feedujúci streaming TX: vždy `always_ff` read +
   FSM read-ahead pattern. `assign q = mem[addr]` → portb_address_reg0 v kritickej ceste.

---

## Príkazy

```bash
make sim              # regression sim (8/8 PASS)
make compile          # Quartus build
make program          # JTAG programming
make test-arp         # arping 4 pakety
make test-icmp        # ping 6 paketov
make test-udp-echo    # UDP echo 10 paketov
make test-stack       # ARP + ICMP + UDP + UDP large
make trace-stack      # tcpdump capture počas test-stack
make loopback-test    # L2 echo test (historický, Faza A)
```
