# ETH Test 02 — stav projektu

> Stav k: 2026-05-28
> Board: QMTech EP4CE55F23C8
> PHY: Realtek RTL8211EG-VB-CG (GMII, 10/100/1000 Mbps)
> Predchodca: `examples/eth_test` (Faza 1 — periodicky TX, HW PASS)

---

## Ciel projektu

Implementacia plneho UDP echo systemu: FPGA prijme UDP paket, zrkadle payload spat odosielatelovi.
Rozsirenie oproti eth_test: dynamicke IP/porty, echo pipeline s AXI-Lite diagnostickymi registrami,
Ethernet padding (minimum frame 64 B), timing closure na 125 MHz.

---

## Architektura

```
PHY RX -> ipreceive -> RX RAM -> udp_rx_ram_to_stream -> eth_udp_echo_test
                                                               |
PHY TX <- ipsend <- crc <- TX RAM <- udp_tx_stream_to_ram <---+
```

Hodinove domeny:
- `eth_rx_clk_i` (125 MHz, PHY recovered): ipreceive, zapis RX RAM
- `eth_tx_clk_i` (125 MHz, PLL clkpll): vsetko ostatne
- CDC: toggle-based synchronizacia `data_receive_o` v `udp_rx_ram_to_stream`

FPGA IP: `192.168.20.50` (0xC0A81432), Echo port: `8080`, MAC: `00:0A:35:01:FE:C0`

---

## Faza 1 — Implementacia a simulacia — DOKONCENA

### Nove moduly

| Subor | Popis |
|-------|-------|
| `rtl/ethernet_test_echo.sv` | Top-level wrapper, CDC, RAM instancie |
| `rtl/eth_udp_echo_test.sv` | Echo FSM + AXI-Lite registre (DEFAULT_IP, ECHO_PORT) |
| `rtl/eth/udp_rx_ram_to_stream.sv` | CDC toggle + RX RAM -> byte stream |
| `rtl/eth/udp_tx_stream_to_ram.sv` | Byte stream -> TX RAM + tx_start pulz |
| `rtl/eth/ipsend.sv` | Rozsireny: dynamicke IP/porty, tx_start_i, timer_en_i, ST_SEND_PAD |
| `rtl/eth/ipreceive.sv` | Nezmeneny z eth_test |
| `rtl/eth/crc.sv` | Nezmeneny z eth_test (CRC-32/ISO-HDLC) |
| `rtl/eth/ram.sv` | Dual-port M9K, 2-cyklova latencia citania |

### Klucove dizajnove rozhodnutia

**Ethernet padding (navrhy_01 P0.1):**
- Minimum Ethernet frame: 60 B data field (14 MAC + 46 min payload)
- `pad_len_q = max(0, 46 - tx_total_length_i)` — vypocitane v `ST_START`
- Stav `ST_SEND_PAD` v ipsend: vysiela nuly, CRC zahrnuje padding

**Timing closure (navrhy_01 P1):**
- Problem 1: `payload_mem_r` (512x8) ako distributed RAM — 10.5 ns kriticka cesta
  Riesenie: odstranit `(* ramstyle = "logic" *)` → M9K inference, pridat `ST_SEND_LOAD`
- Problem 2: `len_latch_q + adder → tx_data_length_o` — 9.5 ns
  Riesenie: registrovane vystupy `tx_data_length_o`, `tx_total_length_o` v `udp_tx_stream_to_ram`
- Problem 3: `j_cnt_q → ip_header_q[j_cnt_q] → tx_data_o` — 8.2 ns
  Riesenie: `ip_cur_word_q` register, prednahravany v `ST_SEND_MAC` a `ST_SEND_HEAD`

**M9K registered read (eth_udp_echo_test.sv):**
```systemverilog
// Separate always_ff pre M9K inference
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) tx_data_q <= 8'd0;
  else         tx_data_q <= payload_mem_r[rd_ptr_r];
end
```
Stav `ST_SEND_LOAD`: 1 cyklus cakania na platny M9K vystup pred `ST_SEND_PAY`.

### Simulacia — 3/3 PASS

| Test | Typ | Vysledok | Popis |
|------|-----|----------|-------|
| `tb_tx_stream` | unit | PASS | RAM packing MSB-first, dlzky, tx_start pulz |
| `tb_rx_stream` | unit | PASS | CDC toggle, metadata, byte order, last signal |
| `tb_udp_echo_path` | integration | PASS | End-to-end echo, FCS reziduum 0xDEBB20E3, padding 13x 0x00 |

Integracny test verifikuje:
- T5: TX aktivita (72 bajtov: 8 preamble + 14 MAC + 20 IP + 8 UDP + 5 payload + 13 pad + 4 FCS)
- T6: Dst IP v odoslanopm pakete = src IP z prijateho paketu (echo)
- T7: `tx_data_length=13`, `tx_total_length=33`
- T8: CRC reziduum 0xDEBB20E3 (CRC-32/ISO-HDLC)
- T9: 13 bajtov paddingu = 0x00
- T10: `tx_er_o` nikdy neassertovany

---

## Faza 2 — Quartus build a timing closure — DOKONCENA

### Vysledky STA (Slow 1200mV 85C)

| Hodina | Slack |
|--------|-------|
| ETH_TX_CLK (125 MHz) | **+0.213 ns** |
| ETH_RXC (125 MHz) | **+0.817 ns** |
| SYS_CLK (50 MHz) | **+6.853 ns** |

Bitfile: `output_files/soc_top.sof` (checksum 0x003B81E2)

---

## Faza 3 — HW test — ZLYHANIE

### Testovaci postup

```bash
# PC strana
sudo arp -s 192.168.20.50 00:0a:35:01:fe:c0
python3 tools/udp_echo_test.py --host 192.168.20.50 --port 8080 --count 10
```

PC interface: `enp0s20f0u4u1` (USB Ethernet, 192.168.20.234/24)

### Vysledky

| Test | Vysledok |
|------|----------|
| arp záznam nastavený | OK |
| python echo test (10 paketov) | **0/10 — 100% timeout** |
| tcpdump (PC→FPGA pakety) | vidi odchadzajuce pakety ✓ |
| tcpdump (FPGA→PC pakety) | **NULA prichadzajucich** |
| Diagnostika timer_en_i=1 | LED 3 bliká ✓ (ipsend fyzicky spusteny) |

### Zaver diagnostiky

**ipsend vie vysielat** — LED 3 potvrdzuje `eth_tx_en_o` pulsovanie pri periodickom timeri.
**PC nevidí žiadne rámce od FPGA** — ani pri timer_en_i=1 tcpdump nič nezachytil.

---

## Identifikovane problemy

### BUG-1 (Kriticke): `ipreceive.data_receive_o` nikdy nevymaze

**Subor:** `rtl/eth/ipreceive.sv`

**Popis:**
Po prichode prveho paketu sa `data_receive_o` nastavi na 1 a uz nikdy neklesne.
V stave `ST_IDLE` nie je ziadne `data_receive_o <= 1'b0`.

```systemverilog
// ipreceive.sv — PROBLEM
ST_RX_FINISH: begin
  data_receive_o <= 1'b1;   // nastavi
  state_q        <= ST_IDLE;
end
ST_IDLE: begin
  // CHYBA: data_receive_o <= 1'b0  <-- toto CHYBA
  ...
end
```

**Dosledky:**
1. `rx_tog_q` v `udp_rx_ram_to_stream` prepina KAZDY rx_clk cyklus (125 MHz) kym signal=1
2. Po prvom pakete: zaplava spurious CDC pulzov → udp_rx_ram_to_stream dostava falošné triggery
3. Od druhého paketu: `data_receive_o` = 1→1 (bez zmeny) → toggle sa neprepne → **echo cesta slepa pre vsetky dalsie pakety**

**Simulacny testbench toto maskuje:**
```systemverilog
// tb_udp_echo_path.sv — maskuje bug
force dut.ipr_data_receive_w = 1'b1;
@(posedge rx_clk); #1;
force dut.ipr_data_receive_w = 1'b0;   // <-- force na 0 po 1 cykle
release dut.ipr_data_receive_w;
```

**Navrhovana oprava:**
```systemverilog
// ipreceive.sv ST_IDLE — pridat
ST_IDLE: begin
  data_receive_o  <= 1'b0;   // OPRAVA: vymaz po 1 cykle
  valid_ip_p_o    <= 1'b0;
  ...
end
```

### BUG-2 (Podozrenie): PHY link speed mismatch

**Popis:**
`enp0s20f0u4u1` je USB Ethernet adapter — typicky 100 Mbps.
FPGA poskytuje `ETH_GTX_CLK = 125 MHz` (pre 1 Gbps GMII).
Ak PHY vyjednalo 100 Mbps, ocakava 25 MHz GTX_CLK → TX moze byt nefunkcny.

**Overenie:** `ethtool enp0s20f0u4u1` → skontroluj `Speed:` a `Duplex:`.

**Poznamka:** eth_test (predchodca) testoval TX cestu uspesne s rovnakym hardware.
Ak eth_test prebehol na rovnakom PC+NIC, PHY/speed mismatch je nepravdepodobny.

---

## Dalsi postup

### Priorita 1 — Opravit BUG-1

```systemverilog
// rtl/eth/ipreceive.sv — ST_IDLE vetva
ST_IDLE: begin
  data_receive_o  <= 1'b0;  // PRIDAT
  valid_ip_p_o    <= 1'b0;
  byte_counter_q  <= 3'd0;
  ...
```

Potom:
1. Aktualizovat testbench (odstrânit `force/release` data_receive_w — test by mal bezat s realnym signalom)
2. Spustit `make regression` → overit 3/3 PASS
3. Rekompilovaat Quartus + reprogram FPGA
4. Zopakovat echo test

### Priorita 2 — Overit link speed

```bash
ethtool enp0s20f0u4u1
# Ocakavame: Speed: 1000Mb/s
# Ak: Speed: 100Mb/s → problem s GTX_CLK
```

### Priorita 3 (navrhy_01 P2) — Dynamicke DST MAC

Aktualny `ipsend.sv` pouziva broadcast `FF:FF:FF:FF:FF:FF` ako DST MAC.
Riesenie: pouzit `ipreceive.pc_mac_o` ako DST MAC echo odpovede.

---

## Subory projektu

```
examples/eth_test_02/
├── ETH_TEST_02_STATUS.md       (tento dokument)
├── Makefile
├── project.yaml
├── soc_top.qpf / soc_top.qsf
├── navrhy/
│   └── navrhy_01.md            (expertny review — timing + funkcne pripomienky)
├── rtl/
│   ├── ethernet_test_echo.sv   (top-level)
│   ├── eth_udp_echo_test.sv    (echo FSM + AXI-Lite)
│   └── eth/
│       ├── ipreceive.sv        (BUG-1: data_receive_o nevymaza)
│       ├── ipsend.sv           (rozsireny: padding, ip_cur_word_q)
│       ├── udp_rx_ram_to_stream.sv
│       ├── udp_tx_stream_to_ram.sv
│       ├── crc.sv
│       └── ram.sv
├── sim/
│   ├── integration/tb_udp_echo_path.sv
│   └── unit/tb_tx_stream.sv, tb_rx_stream.sv
├── tools/
│   └── udp_echo_test.py
└── output_files/
    └── soc_top.sof             (bitfile, checksum 0x003B81E2)
```
