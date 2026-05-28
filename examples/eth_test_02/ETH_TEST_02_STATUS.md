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

**RX RAM adresovanie:** ipreceive pise payload od adresy **1** (nie 0) — `data_o_valid_o`
je registrovany signal; RAM write nastane 1 cyklus neskor ked `ram_wr_addr_o` uz
inkrementovalo. `udp_rx_ram_to_stream` zacina citat od `word_addr_q = 9'd1`.

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
| `rtl/eth/ipreceive.sv` | Opraveny (BUG-1 fix), viz Faza 4 |
| `rtl/eth/crc.sv` | Nezmeneny z eth_test (CRC-32/ISO-HDLC) |
| `rtl/eth/ram.sv` | Dual-port M9K, 1-cyklova latencia citania |

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

---

## Faza 2 — Quartus build a timing closure — DOKONCENA

### Vysledky STA (Slow 1200mV 85C)

| Hodina | Slack |
|--------|-------|
| ETH_TX_CLK (125 MHz) | **+0.213 ns** |
| ETH_RXC (125 MHz) | **+0.817 ns** |
| SYS_CLK (50 MHz) | **+6.853 ns** |

Bitfile: `output_files/soc_top.sof` (pred navrhy_02 opravami — treba rebuild)

---

## Faza 3 — HW test — ZLYHANIE (pred opravami)

### Testovaci postup

```bash
sudo arp -s 192.168.20.50 00:0a:35:01:fe:c0
python3 tools/udp_echo_test.py --host 192.168.20.50 --port 8080 --count 10
```

PC interface: `enp0s20f0u4u1` (USB Ethernet, 192.168.20.234/24)

### Vysledky (pred opravami)

| Test | Vysledok |
|------|----------|
| python echo test (10 paketov) | **0/10 — 100% timeout** |
| tcpdump PC→FPGA | vidí odchadzajuce pakety ✓ |
| tcpdump FPGA→PC | **NULA prichadzajucich** |
| Diagnostika timer_en_i=1 | LED 3 bliká ✓ (ipsend fyzicky spusteny) |

**Pricina zlyhania:** BUG-1 (data_receive_o stuck-high) — CDC toggle sa neprepinal →
echo pipeline ignorovala prijate pakety. Opravene v Faze 4.

---

## Faza 4 — navrhy_02 opravy — DOKONCENA (commit 5ca35d8)

### Opravene bugy

#### BUG-1: `ipreceive.data_receive_o` stuck-high (KRITICKE — pricina HW zlyhania)

**Symptom:** Po prvom pakete `data_receive_o` zostalo trvalo na 1. `rx_tog_q` prepinal
KAZDY rx_clk cyklus → spurious CDC triggery. Od druheho paketu: signal 1→1 (ziadna zmena)
→ toggle neprepne → echo pipeline slepa pre vsetky dalsie pakety.

**Oprava** (`rtl/eth/ipreceive.sv`): pridany default `data_receive_o <= 1'b0` pred
`case` blokom v `always_ff`. `ST_RX_FINISH` ho prepisuje na `1'b1` iba na 1 cyklus.

```systemverilog
end else begin
  data_receive_o <= 1'b0;   // default: 1-cyklovy pulz iba v ST_RX_FINISH
  case (state_q)
    ...
    ST_RX_FINISH: begin
      data_o_valid_o <= 1'b0;
      data_receive_o <= 1'b1;  // prepisuje default — presne 1 cyklus
      state_q        <= ST_IDLE;
    end
```

#### BUG-2: RX RAM off-by-one (skryty bug v adresovani)

**Symptom:** TX payload bajty 50..54 = `00 00 00 00 48` namiesto `48 45 4C 4C 4F` (HELLO).
Prvy slovo HELL skonvilo do RX RAM adresy 1 (nie 0), ale `udp_rx_ram_to_stream` citalo
od adresy 0 → 4 nulove bajty + iba H na pozicii 4.

**Pricina:** V `ipreceive.sv` su `data_o_valid_o` a `ram_wr_addr_o` oba NB priradenia
v tom istom cykle. RAM write nastane az nasledujuci cyklus, ked `ram_wr_addr_o` uz
inkrementovalo na `addr+1`. Prvy zapis teda ide na adresu 1, nie 0.

**Oprava** (`rtl/eth/udp_rx_ram_to_stream.sv`): v stave `ST_META` zmena
`word_addr_q <= 9'd0` na `word_addr_q <= 9'd1`.

Opravene aj testbench mocky:
- `sim/unit/tb_rx_stream.sv`: `ram_addr == 0` → `ram_addr == 1`
- `sim/integration/tb_udp_echo_path.sv`: `mem[0]/mem[1]` → `mem[1]/mem[2]`

#### Cleanup (navrhy_02 Krok 7)

- `udp_tx_stream_to_ram.sv`: odstraneny nepouzity `len_latch_q` register
- `eth_udp_echo_test.sv`: odstraneny nepouzity `local_ip_w` wire
- `tools/udp_echo_test.py`: opravene default hodnoty (`--host 192.168.20.50`, `--port 8080`)

### Nove testy (navrhy_02)

| Test | Typ | Popis |
|------|-----|-------|
| `tb_ipreceive_data_receive_pulse` | unit | Overuje presne 1-cyklovy pulz po kazdom GMII ramci (2 pakety) |
| `tb_ethernet_test_echo_gmii_packet` | integration | Kompletny GMII test bez `force` na `ipr_*` — realny GMII RX stream |

`tb_ethernet_test_echo_gmii_packet` overuje celu cestu:
- Realny GMII frame (preamble + SFD + MAC + IP + UDP + "HELLO")
- ipreceive → CDC → RX RAM → echo FSM → TX RAM → ipsend → GMII TX
- T5: TX aktivita (72 B), T6: dst IP = echo, T7: dlzky 13/33
- T8: CRC reziduum `0xDEBB20E3`, T9: 13x padding `0x00`, T10: bez tx_er

### Regresia — 5/5 PASS

| Test | Typ | Vysledok |
|------|-----|----------|
| `tb_rx_stream` | unit | **PASS** |
| `tb_tx_stream` | unit | **PASS** |
| `tb_ipreceive_data_receive_pulse` | unit | **PASS** |
| `tb_udp_echo_path` | integration | **PASS** |
| `tb_ethernet_test_echo_gmii_packet` | integration | **PASS** |

---

## Faza 5 — navrhy_03/04 diagnosticke rozsirenia — DOKONCENA (2026-05-28)

Implementovane odporucania z `navrhy_03.md` a `navrhy_04.md`.

### Nove RTL funkcie

#### 1. `EXPECT_PREAMBLE` parameter v `ipreceive.sv`

RTL8211EG moze v GMII rezime vynechat preamble/SFD. Novy parameter:

```systemverilog
parameter bit EXPECT_PREAMBLE = 1'b1
```

Ked `EXPECT_PREAMBLE=0`, ST_IDLE pri prvom `rx_dv_i` okamzite prechodzi do ST_RX_MAC
a ulozi prvy bajt ako `my_mac_q[7:0]` so `state_counter_q=1`. Zvysok parsovania je zhodny.

#### 2. `rx_er_i` abort logika v `ipreceive.sv`

Nove chovanie: akykolvek PHY error signal abort aktualny stav spat do ST_IDLE:

```systemverilog
if (rx_er_i && (state_q != ST_IDLE))
  state_q <= ST_IDLE;
else
  case (state_q) ... endcase
```

#### 3. 6-bitove diagnosticke LED v `eth_status_leds.sv`

Rozsirenie zo 4 na 6 LED. Kazda je samostatne natiahuta (stretch) na ~0.2 s pre
viditelnost jednorazovych pulsov:

| LED | Signal | Domena | Popis |
|-----|--------|--------|-------|
| 0 | heartbeat | sys_clk | Trvalo bliká, potvrdenie FPGA zivosti |
| 1 | phy_reset_done | sys_clk | PHY reset dokonceny |
| 2 | eth_rx_dv_i | rx_clk → CDC | RX aktivita (paket prijaty) |
| 3 | ipr_data_receive_o | rx_clk → CDC | ipreceive dokoncil paket |
| 4 | tx_start | tx_clk → CDC | echo pipeline spustila TX |
| 5 | eth_tx_en_o | tx_clk → CDC | ipsend fyzicky vysiela |

LED 3 vs LED 5: ak LED 3 svieti ale LED 5 nie → pipeline zasekla v echo FSM alebo ipsend.

#### 4. `DEBUG_TIMER_TX_EN` parameter v `ethernet_test_echo.sv`

Ked `DEBUG_TIMER_TX_EN=1`, ipsend periodicky vysiela (timer_en_i=1) bez cakania na
RX paket. Umoznuje overit fyzicku TX cestu nezavisle od ipreceive.

#### 5. `rx_er_i` teraz prepojeny v `ethernet_test_echo.sv`

Predtym `rx_er_i` sa do ipreceive neprikladal (neimplementovany port). Teraz:
`.rx_er_i(eth_rx_er_i)` — PHY error signal spravne odrusuva prijmany ramec.

### Novy integracny test: `tb_ethernet_test_echo_gmii_no_preamble`

Overuje `EXPECT_PREAMBLE=0`: vstupny GMII stream zacina priamo DST MAC[0] (bez
`55 55 55 55 55 55 55 D5`). Ocakavany TX vystup je identicky (72 B, rovnake CRC,
rovnaky HELLO payload).

### Regresia — 6/6 PASS

| Test | Typ | Vysledok |
|------|-----|----------|
| `tb_rx_stream` | unit | **PASS** |
| `tb_tx_stream` | unit | **PASS** |
| `tb_ipreceive_data_receive_pulse` | unit | **PASS** |
| `tb_udp_echo_path` | integration | **PASS** |
| `tb_ethernet_test_echo_gmii_packet` | integration | **PASS** |
| `tb_ethernet_test_echo_gmii_no_preamble` | integration | **PASS** |

---

## Dalsi postup

### Priorita 1 — Quartus rebuild + HW test

Aktualne `output_files/soc_top.sof` je zo stareho buildu. Treba rebuild s navrhy_02
+ navrhy_03/04 opravami.

```bash
cd examples/eth_test_02
# Rebuild v Quartus Prime 25.1 Lite
# Naflasovat soc_top.sof
sudo arp -s 192.168.20.50 00:0a:35:01:fe:c0
python3 tools/udp_echo_test.py --host 192.168.20.50 --port 8080 --count 10
```

Diagnosticky postup podla LED:
- LED 0 bliká → FPGA zije
- LED 1 on → PHY reset OK
- LED 2 bliká pri prichadzajucich paketoch → ipreceive cita GMII
- LED 3 bliká → ipreceive dokoncil paket (DST MAC filter presiel)
- LED 4 bliká → echo FSM odovzdala TX pipeline
- LED 5 bliká → ipsend fyzicky vysiela

Ak LED 2 nereaguje: skus `EXPECT_PREAMBLE=0` rebuild (RTL8211EG bez preamble).

### Priorita 2 — Dynamicke DST MAC (navrhy_01 P2 / navrhy_03 Krok E)

Aktualny `ipsend.sv` pouziva broadcast `FF:FF:FF:FF:FF:FF` ako DST MAC.
Riesenie: propagovat `ipreceive.pc_mac_o` cez `udp_rx_ram_to_stream` do tx_clk domeny
a pouzit ako DST MAC echo odpovede.

### Volitelne — PLL lock → reset tie (navrhy_03 polozka 7)

Sys_clk pochadzа z PLL. `rst_ni` by mala byt drzana v 0 kym `sys_pll_locked` neni 1.

---

## Subory projektu

```
examples/eth_test_02/
├── ETH_TEST_02_STATUS.md       (tento dokument)
├── Makefile
├── project.yaml
├── soc_top.qpf / soc_top.qsf
├── navrhy/
│   ├── navrhy_01.md            (expertny review — timing + funkcne pripomienky)
│   ├── navrhy_02.md            (expertny review — BUG-1 fix, testy, iteracie B/C/D)
│   ├── navrhy_03.md            (expertny review — LED diagnostika, EXPECT_PREAMBLE, rx_er_i)
│   └── navrhy_04.md            (expertny review — no-preamble variant, force test analiza)
├── rtl/
│   ├── ethernet_test_echo.sv   (EXPECT_PREAMBLE, DEBUG_TIMER_TX_EN, [5:0] status_led_o)
│   ├── eth_udp_echo_test.sv    (echo FSM + AXI-Lite)
│   └── eth/
│       ├── ipreceive.sv        (EXPECT_PREAMBLE param, rx_er_i abort, BUG-1 opraveny)
│       ├── ipsend.sv           (rozsireny: padding, ip_cur_word_q, tx_start_i)
│       ├── eth_status_leds.sv  (6 LED: heartbeat, PHY, RXDV, ipr_done, tx_start, TXEN)
│       ├── udp_rx_ram_to_stream.sv  (cita od adresy 1 po BUG-2 oprave)
│       ├── udp_tx_stream_to_ram.sv  (pise do TX RAM od adresy 1, MSB-first)
│       ├── crc.sv
│       └── ram.sv
├── sim/
│   ├── Makefile
│   ├── integration/
│   │   ├── tb_udp_echo_path.sv                       (force-based)
│   │   ├── tb_ethernet_test_echo_gmii_packet.sv      (GMII realny test)
│   │   └── tb_ethernet_test_echo_gmii_no_preamble.sv (EXPECT_PREAMBLE=0 test)
│   └── unit/
│       ├── tb_tx_stream.sv
│       ├── tb_rx_stream.sv
│       └── tb_ipreceive_data_receive_pulse.sv
├── tools/
│   └── udp_echo_test.py        (default: --host 192.168.20.50 --port 8080)
└── output_files/
    └── soc_top.sof             (STARY build — treba rebuild)
```
