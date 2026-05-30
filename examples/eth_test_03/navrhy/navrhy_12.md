Aktuálny stav je veľmi dobrý. Z pohľadu vývoja by som ho pomenoval ako:

```text
ETH_TEST_03 — simulačne uzavretý single-clock UDP echo stack
```

Už nie si vo fáze „ladíme parsery“. Teraz si na hranici medzi **simulačne overenou knižnicou** a **HW integráciou do FPGA topu**.

## 1. Čo je teraz hotové

Podľa aktuálneho ZIP-u a logov máš:

```text
unit/layer testy: PASS
integration rx_path: PASS
integration echo_path: PASS
make regression: PASS
```

Konkrétne prechádza:

```text
crc32_eth
gmii_tx_mac
gmii_rx_mac
mac_stream_tx_rx_stream
eth_header_builder
eth_header_parser
ipv4_checksum
ipv4_header_parser
udp_header_parser
udp_ipv4_tx_builder
rx_path
echo_path
```

Najdôležitejší posun je:

```text
tb_echo_path: ALL PASS
```

To znamená, že už máš overené:

```text
GMII RX UDP request
 -> gmii_rx_mac
 -> eth_header_parser
 -> ipv4_header_parser
 -> udp_header_parser
 -> udp_rx_meta_assembler
 -> udp_echo_app
 -> udp_ipv4_tx_builder
 -> gmii_tx_mac
 -> GMII TX response
```

Toto je hlavný míľnik. Predtým to bol otvorený blocker, teraz je vyriešený.

---

## 2. Čo by som teraz nerobil

Nerobil by som hneď veľký refaktor FCS alebo MDIO. Teraz máš vzácny stav: celý echo path prešiel. Nechcel by som ho rozbiť pred prvým HW topom.

Zatiaľ by som odložil:

```text
gmii_rx_mac STRIP_FCS
RX FCS check
UDP checksum full validation
MDIO master
ARP responder
veľké AXI-stream FIFO refaktory
dual-clock optimalizácie
```

To všetko má zmysel, ale až po prvom funkčnom HW bring-upe alebo aspoň po dual-clock simulácii.

---

# 3. Najbližší krok: opraviť „known issue“ zero-payload echo

Status ešte obsahuje známy problém:

```text
Zero-payload UDP echo
```

Toto by som opravil ešte pred top-level integráciou, lebo ide o malý, dobre ohraničený bug v L4/echo logike.

## Problém

V `udp_header_parser` je podľa statusu:

```systemverilog
header_next_w[31:16] > 16'd8
```

To znamená, že pri:

```text
udp_len = 8
payload_len = 0
```

sa nevygeneruje metadata event.

Správne má byť:

```systemverilog
header_next_w[31:16] >= 16'd8
```

Ale to nestačí. `udp_echo_app` musí vedieť obslúžiť `payload_len_q == 0`.

## Odporúčaná oprava v `udp_echo_app`

FSM by pri metadata handshaku mala rozhodnúť:

```text
payload_len == 0:
  neísť do ST_RX
  ísť rovno do ST_TX_META
```

Pseudo:

```systemverilog
if (rx_meta_valid_i && rx_meta_ready_o) begin
  rx_meta_q     <= rx_meta_i;
  payload_len_q <= rx_meta_i.payload_len;
  write_ptr_q   <= '0;
  read_ptr_q    <= '0;

  if (rx_meta_i.payload_len == 16'd0)
    state_q <= ST_TX_META;
  else
    state_q <= ST_RX;
end
```

A vo výstupe:

```systemverilog
assign m_axis_tvalid = (state_q == ST_TX_PAYLOAD) && (payload_len_q != 16'd0);
assign m_axis_tlast  = m_axis_tvalid && (read_ptr_q == payload_len_q - 16'd1);
```

`ST_TX_PAYLOAD` sa pri zero-payload vôbec nemá použiť.

## Testy, ktoré treba pridať

Doplniť:

```text
tb_udp_header_parser:
  zero-payload už má PASS, ale over aj hdr_pre_valid/pre metadata

tb_udp_echo_app:
  zero-payload metadata -> tx_meta_valid, žiadny payload

tb_echo_path:
  zero-payload UDP request -> zero-payload UDP response
```

Toto by som dal ako úplne najbližší commit.

---

# 4. Potom sprav dual-clock simulačný test

Aktuálny `tb_echo_path` je single-clock. To je super pre funkciu, ale FPGA bude mať minimálne dve relevantné domény:

```text
eth_rx_clk_i = RXC z PHY
eth_tx_clk_i = PLL 125 MHz
```

Tieto clocky nemožno považovať za fázovo rovnaké.

Teraz potrebuješ rozhodnúť CDC architektúru.

## Odporúčanie pre prvý HW bring-up

Najjednoduchší bezpečný variant:

```text
RX domain:
  gmii_rx_mac
  eth_header_parser
  ipv4_header_parser
  udp_header_parser
  udp_rx_meta_assembler
  udp_echo_app
  udp_ipv4_tx_builder

CDC:
  async stream FIFO pre celý IPv4 packet
  plus metadata pre gmii_tx_mac: dst_mac/src_mac/ethertype/payload_len

TX domain:
  gmii_tx_mac
```

Ale pozor: `gmii_tx_mac` potrebuje metadata:

```text
tx_dst_mac
tx_src_mac
tx_ethertype
tx_payload_len
```

Preto do TX domény musíš preniesť:

```text
1. stream IPv4 packetu z udp_ipv4_tx_builder
2. metadata pre gmii_tx_mac
```

Pre prvú verziu by som to riešil jednoduchým **packet mailboxom**:

```text
tx_packet_fifo:
  payload stream bytes + tlast

tx_meta_fifo:
  dst_mac, src_mac, ethertype, payload_len
```

Oba FIFO sa zapisujú spolu v RX doméne. V TX doméne `gmii_tx_mac` začne až keď:

```text
tx_meta_fifo not empty
tx_packet_fifo has packet
gmii_tx_mac not busy
```

## Prečo nie priamo RX → TX drôty

Nerob toto:

```text
udp_ipv4_tx_builder m_axis -> gmii_tx_mac s_axis priamo
```

ak sú v rôznych clock doménach.

To by simulačne v single-clock prešlo, ale v FPGA by to bolo CDC hazard.

## Test

Pridať:

```text
tb_echo_path_dual_clock
```

S clockmi:

```text
rx_clk period = 8.000 ns
tx_clk period = 8.013 ns
```

alebo s fázovým posunom. Cieľ je odhaliť každé priame nelegálne RX/TX prepojenie.

---

# 5. Až potom dokonči `ethernet_test_03_top.sv`

Status správne hovorí, že top je ešte HW integration. Aktuálny `ethernet_test_03_top.sv` je stále skôr stub.

Top by mal mať tieto časti:

```text
SYS_CLK domain:
  reset extender
  LED heartbeat
  PHY reset control

ETH_RXC domain:
  RX parser + echo + tx builder alebo RX časť podľa CDC architektúry

ETH_TX_CLK domain:
  gmii_tx_mac

CDC:
  async FIFO/mailbox medzi RX a TX
```

## Minimálny top pre prvý FPGA pokus

Porty:

```systemverilog
module ethernet_test_03_top #(
  parameter logic [47:0] LOCAL_MAC = 48'h000A3501FEC0,
  parameter logic [31:0] LOCAL_IP  = 32'hC0A81432,
  parameter logic [15:0] UDP_PORT  = 16'd8080,
  parameter bit EXPECT_PREAMBLE    = 1'b1
)(
  input  wire logic        sys_clk_i,
  input  wire logic        eth_rx_clk_i,
  input  wire logic        eth_tx_clk_i,
  input  wire logic        rst_ni,

  input  wire logic [7:0]  eth_rxd_i,
  input  wire logic        eth_rxdv_i,
  input  wire logic        eth_rxer_i,

  output      logic [7:0]  eth_txd_o,
  output      logic        eth_txen_o,
  output      logic        eth_txer_o,
  output      logic        eth_gtx_clk_o,

  output      logic        eth_mdc_o,
  inout  wire              eth_mdio_io,
  output      logic        eth_phyrstb_o,

  output      logic [5:0]  led_o
);
```

Dočasne:

```systemverilog
assign eth_gtx_clk_o = eth_tx_clk_i;
assign eth_mdc_o     = 1'b0;
assign eth_mdio_io   = 1'bz;
```

---

# 6. LED diagnostika musí byť súčasť prvého HW topu

Pred prvým FPGA testom doplň alebo obnov `eth_debug_leds.sv`.

Odporúčaná LED mapa:

```text
LED0 = SYS heartbeat
LED1 = PHY reset released
LED2 = raw RXDV activity
LED3 = UDP frame accepted
LED4 = TX packet start
LED5 = raw TXEN activity
```

Toto ti okamžite povie, kde sa systém zastavil:

```text
LED2 nie, LED3 nie:
  PHY/PC/link/RX problém

LED2 áno, LED3 nie:
  frame prišiel, ale parser ho zahodil

LED3 áno, LED4 nie:
  RX parser OK, echo/TX builder/CDC problém

LED4 áno, LED5 nie:
  TX metadata/packet prišiel, ale gmii_tx_mac nezačal

LED5 áno, tcpdump nič:
  fyzický TX/GTX_CLK/timing/PHY režim problém
```

---

# 7. Status dokument by som upravil

Tvoj status je užitočný, ale má jednu starú položku:

```text
Zero-payload UDP echo known issue
```

Ponechaj ju, kým ju neopravíš. Ale po oprave by som stav pomenoval takto:

```text
Stav: Single-clock UDP echo stack PASS; pripravuje sa dual-clock CDC a HW top
```

Toto bude presnejšie než len „zostáva HW top“, lebo medzi single-clock sim a HW topom ešte stojí CDC.

---

# 8. Konkrétne poradie ďalších commitov

## Commit 1 — zero payload

```text
[ ] udp_header_parser: hdr_pre_valid pre udp_len >= 8
[ ] udp_echo_app: payload_len==0 path
[ ] udp_ipv4_tx_builder: zero-payload TX response
[ ] tb_echo_path: zero-payload echo case
```

## Commit 2 — regression hygiene

```text
[ ] uistiť sa, že make regression zahŕňa echo_path
[ ] linter filelist sim/eth_test_03.f používa eth_pkg.sv ako prvý
[ ] pridať target lint/verilator-lint, ak ešte nie je
```

## Commit 3 — CDC návrh

```text
[ ] vybrať RX-domain builder + async FIFO + TX-domain gmii_tx_mac
[ ] pridať axis_async_fifo alebo jednoduchý packet FIFO
[ ] pridať tx_meta_async_fifo
[ ] tb_echo_path_dual_clock
```

## Commit 4 — HW top

```text
[ ] dokončiť ethernet_test_03_top.sv
[ ] eth_debug_leds.sv
[ ] PHY reset extender
[ ] strap-only MDIO/MDC
[ ] project.yaml / ip yaml
[ ] sim top smoke test
```

## Commit 5 — Quartus build

```text
[ ] vygenerovať soc_top
[ ] skontrolovať ETH_MDIO=inout
[ ] skontrolovať ETH_GTX_CLK z PLL
[ ] skontrolovať board.tcl pin assignments
[ ] timing: najprv interný PASS
[ ] neskôr GMII IO constraints
```

---

# 9. Odborný záver

Aktuálny stav je výborný pre fázu simulácie. Máš už:

```text
MAC PASS
L2 PASS
L3 PASS
L4 PASS
TX builder PASS
RX path PASS
full echo path PASS
```

Najbližší rozhodujúci bod už nie je parser ani CRC. Teraz je to:

```text
CDC medzi RXC a TX_CLK + HW top integrácia
```

Moje odporúčanie: **nechoď ešte priamo do Quartusu**, kým nemáš dual-clock `tb_echo_path_dual_clock`. Single-clock echo path je dôkaz funkčnosti protokolu, ale nie dôkaz bezpečného FPGA zapojenia. Po dual-clock PASS bude HW top oveľa menej rizikový.
