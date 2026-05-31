Skontroloval som aktuálny `eth_test_03.zip`. Zhrniem to priamo: **simulačne je projekt veľmi dobrý, ale aktuálny bitstream nie je dôveryhodný pre HW test**, lebo má vážny timing fail v `ETH_RXC` doméne. To je podľa mňa najpravdepodobnejší dôvod, prečo na FPGA nevidíš odozvu.

## 1. Aktuálny stav

Regresia je silná:

```text
tb_crc32_eth                  PASS
tb_gmii_tx_mac                PASS
tb_gmii_rx_mac                PASS
tb_mac_stream_tx_rx_stream    PASS
tb_eth_header_builder         PASS
tb_eth_header_parser          PASS
tb_ipv4_checksum              PASS
tb_ipv4_header_parser         PASS
tb_udp_header_parser          PASS
tb_udp_ipv4_tx_builder        PASS
tb_rx_path                    PASS
tb_echo_path                  PASS
tb_echo_path_dual_clock       PASS
```

Top-level už nie je stub. `ethernet_test_03_top.sv` má zapojené:

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
  async_fifo pre packet stream
  async_fifo pre metadata

TX domain:
  TX controller FSM
  gmii_tx_mac

SYS domain:
  PHY reset extender
  LED diagnostika
```

To je architektonicky správne.

Ale Quartus timing:

```text
ETH_RXC setup slack: -7.183 ns
ETH_TX_CLK setup slack: +0.992 ns
SYS_CLK setup slack: +5.364 ns
```

Teda `ETH_RXC` doména **neprechádza 125 MHz ani zďaleka**. Nie je to tesný fail. Je to veľký fail.

---

# 2. Najpravdepodobnejšia príčina bez HW odozvy

Najhoršia cesta v STA je:

```text
udp_ipv4_tx_builder:u_txb|total_len_q[*]
  -> async_fifo:u_pkt_fifo|mem write data
```

Data delay je približne:

```text
14–15 ns
```

pri požiadavke 8 ns.

To znamená, že v jednom `ETH_RXC` takte sa v RX doméne počíta alebo multiplexuje veľká časť IPv4/UDP TX headeru a zároveň sa zapisuje do packet FIFO.

Konkrétne `udp_ipv4_tx_builder` má veľký kombinačný mux:

```systemverilog
case (hdr_cnt_q)
  5'd0:  hdr_byte_w = 8'h45;
  ...
  5'd10: hdr_byte_w = ipv4_csum_w[15:8];
  ...
  5'd27: hdr_byte_w = 8'h00;
endcase
```

a `ipv4_checksum` je tiež kombinačne závislý od `total_len_q`, `tx_meta_q.src_ip`, `tx_meta_q.dst_ip`, atď.

Potom:

```systemverilog
assign m_axis_tdata = (state_q == ST_HDR) ? hdr_byte_w : s_axis_tdata;
```

ide priamo do:

```systemverilog
async_fifo u_pkt_fifo .wr_data_i({txb_tlast, txb_tdata})
```

Toto je presne cesta, ktorú Quartus hlási ako kritickú.

## Dôležitý záver

Nie je bezpečné tvrdiť:

```text
Fast corner prechádza, pri izbovej teplote to bude fungovať.
```

Pri slacku `-7.183 ns` v slow corner a `-5.978 ns` aj v slow 0C je to veľa. Aj keď fast corner ukazuje plus, reálny čip nemusí byť fast corner. HW bez odozvy úplne sedí s týmto timing problémom.

---

# 3. Čo opraviť ako prvé: pipeline `udp_ipv4_tx_builder`

Toto je P0. Pred ďalším HW testom by som nešiel ďalej, kým `ETH_RXC` timing neprejde.

## Cieľ

Rozbiť cestu:

```text
tx_meta_q / total_len_q / checksum / header mux
  -> txb_tdata
  -> async FIFO write data
```

na registrované stupne.

## Najjednoduchšia oprava

V `udp_ipv4_tx_builder` pridaj registrovaný výstupný byte:

```systemverilog
logic [7:0] m_axis_tdata_q;
logic       m_axis_tvalid_q;
logic       m_axis_tlast_q;
```

a výstup:

```systemverilog
assign m_axis_tdata  = m_axis_tdata_q;
assign m_axis_tvalid = m_axis_tvalid_q;
assign m_axis_tlast  = m_axis_tlast_q;
```

Namiesto priameho:

```systemverilog
assign m_axis_tdata = (state_q == ST_HDR) ? hdr_byte_w : s_axis_tdata;
assign m_axis_tvalid = ...
```

urob registrované emitovanie. Tým FIFO write data už nebude závisieť na veľkom header muxe v tom istom cykle.

Ale ešte lepšie je ísť o krok ďalej.

---

# 4. Lepší fix: precompute header do 28 registrov

Pre Cyclone IV a 125 MHz by som odporučil toto:

Pri prijatí `tx_meta_valid_i` vypočítaj a ulož celý IPv4+UDP header do malého poľa:

```systemverilog
logic [7:0] hdr_q [0:27];
```

Napríklad v `ST_IDLE` pri prijatí metadata:

```systemverilog
if (tx_meta_valid_i && tx_meta_ready_o) begin
  tx_meta_q   <= tx_meta_i;
  total_len_q <= 16'd28 + tx_meta_i.payload_len;
  udp_len_q   <= 16'd8  + tx_meta_i.payload_len;

  hdr_q[0]  <= 8'h45;
  hdr_q[1]  <= 8'h00;
  hdr_q[2]  <= total_len_next[15:8];
  hdr_q[3]  <= total_len_next[7:0];
  ...
  hdr_q[20] <= tx_meta_i.src_port[15:8];
  ...
end
```

IP checksum môžeš spraviť jedným z dvoch spôsobov.

## Variant A — 1 extra checksum stav

FSM:

```text
ST_IDLE
ST_PREP
ST_HDR
ST_PAYLOAD
```

V `ST_IDLE` latchneš metadata a dĺžky.

V `ST_PREP` vypočítaš checksum a naplníš header registre.

V `ST_HDR` už len vysielaš:

```systemverilog
m_axis_tdata_q <= hdr_q[hdr_cnt_q];
```

Toto je jednoduché a zvyčajne stačí.

## Variant B — pipelined checksum

Ak by aj checksum zostal dlhý, rozbiť ho na dva cykly:

```text
ST_CSUM0: spočítaj čiastkové súčty
ST_CSUM1: fold + complement
ST_HDR:   vysielaj header
```

Ale pre 20-bajtový header by Variant A pravdepodobne stačil.

---

# 5. Významný bonus: presuň TX builder do TX domény

Teraz architektúra je:

```text
RX domain:
  udp_echo_app
  udp_ipv4_tx_builder
  -> async FIFO hotového IPv4 packetu

TX domain:
  gmii_tx_mac
```

To funguje simulačne, ale timingovo zaťažuje `ETH_RXC`. Alternatíva:

```text
RX domain:
  parsery + echo app
  -> metadata FIFO
  -> payload FIFO

TX domain:
  udp_ipv4_tx_builder
  -> gmii_tx_mac
```

Výhoda:

```text
kritická TX builder logika sa presunie do ETH_TX_CLK domény
ETH_TX_CLK má teraz +0.992 ns slack a môžeš ho pipelineovať
RX doména sa odľahčí
```

Nevýhoda:

```text
CDC je zložitejší, lebo musíš spárovať metadata a payload
```

Pre rýchly fix by som najprv pipelineoval builder v RX doméne. Pre dlhodobú knižnicu by som builder presunul do TX domény.

---

# 6. Ešte jeden možný HW blokér: ARP

Tvoj stack je UDP echo, ale nevidím ARP responder. To znamená:

```text
PC samé od seba nezistí MAC adresu FPGA.
```

Pre HW test musíš mať statický ARP záznam alebo posielať raw Ethernet frame cez Scapy.

Pri defaultoch:

```text
LOCAL_MAC = 00:0A:35:01:FE:C0
LOCAL_IP  = 192.168.20.50
UDP_PORT  = 8080
```

na PC musí byť niečo ako:

```bash
sudo ip addr add 192.168.20.100/24 dev <iface>
sudo ip neigh replace 192.168.20.50 lladdr 00:0a:35:01:fe:c0 nud permanent dev <iface>
```

Potom test:

```bash
echo -n "HELLO" | nc -u -w1 192.168.20.50 8080
```

Ale pri aktuálnom timing faili by som ARP riešil až po timing oprave. Ak si static ARP nemal, tak je to druhý možný dôvod bez odozvy.

---

# 7. Skontroluj LED diagnostiku pri HW teste

Aktuálne LED mapovanie je dobré:

```text
LED0 = SYS heartbeat
LED1 = PHY reset released
LED2 = GMII RXDV activity
LED3 = UDP frame accepted / rx_meta_valid
LED4 = TX MAC active
LED5 = GMII TXEN activity
```

Pri ďalšom HW teste si zapíš presne:

```text
LED0 bliká?
LED1 svieti?
LED2 blikne pri odoslaní packetu?
LED3 blikne?
LED4 blikne?
LED5 blikne?
```

Interpretácia:

```text
LED2 nebliká:
  PHY/link/PC/ARP/L2 packet sa do FPGA vôbec nedostáva.

LED2 bliká, LED3 nie:
  RX fyzicky prichádza, ale parser ho dropuje.
  Skontroluj dst MAC, dst IP, UDP port, EXPECT_PREAMBLE.

LED3 bliká, LED4 nie:
  RX parser prijal packet, ale echo/TX builder/CDC/TX controller sa nerozbehli.
  Pri aktuálnom timing faili je toto veľmi pravdepodobné.

LED4 bliká, LED5 nie:
  TX controller chce vysielať, ale gmii_tx_mac nezačne.

LED5 bliká, tcpdump nič:
  TX fyzická vrstva, GTX_CLK, TXD/TXEN timing, link speed.
```

Bez tejto LED informácie sa HW problém nedá dobre lokalizovať.

---

# 8. Ďalšie poznámky k warningom

## `ETH_RXER` no output dependent

Quartus hlási:

```text
No output dependent on input pin ETH_RXER
```

`gmii_rx_mac` síce má:

```systemverilog
assign m_axis_tuser = gmii_rx_er_i;
```

ale ak downstream `tuser` nikde nepoužíva, optimalizácia odstráni závislosť. Nie je to hlavný problém.

Ak chceš mať RXER diagnostiku, pripoj ho do LED alebo error countera. Napríklad dočasne:

```text
LED5 alebo debug counter = RXER seen
```

## `ETH_MDC` stuck at GND

To je zámerné, keď MDIO master nepoužívaš:

```systemverilog
assign eth_mdc_o   = 1'b0;
assign eth_mdio_io = 1'bz;
```

V poriadku.

## `ETH_TXER` stuck at GND

Tiež v poriadku, ak nikdy nevysielaš TX error.

## PLL -> ETH_GTX_CLK non-dedicated routing

Toto je stále dôležitý HW rizikový warning:

```text
PLL output feeds ETH_GTX_CLK via non-dedicated routing
```

Ale keďže `eth_test` alebo predchádzajúci TX bring-up fungoval, nie je to prvá vec, ktorú by som riešil. Ak LED5 bliká a tcpdump nič nevidí, vráť sa k tomu.

---

# 9. Čo by som spravil teraz v poradí

## Krok 1 — opraviť timing v `udp_ipv4_tx_builder`

Cieľ:

```text
ETH_RXC setup slack >= 0 ns v Slow 85C
```

Konkrétne:

```text
- registrovať m_axis_tdata/m_axis_tvalid/m_axis_tlast
- alebo pridať ST_PREP a hdr_q[0:27]
- odstrániť priamu cestu checksum/header mux -> async_fifo mem write
```

Po tejto zmene znovu spusti:

```bash
make regression
quartus_sh --flow compile soc_top
```

## Krok 2 — pridať timing regresiu ako gate

Do statusu nedávaj „SOF pripravený pre HW“, kým:

```text
ETH_RXC slack >= 0
ETH_TX_CLK slack >= 0
SYS_CLK slack >= 0
```

Aktuálne kompilácia síce skončí a `.sof` vznikne, ale STA hlási:

```text
Critical Warning: Timing requirements not met
```

To je pre HW bring-up zásadné.

## Krok 3 — static ARP / raw Scapy test

Po timing PASS:

```bash
sudo ip addr add 192.168.20.100/24 dev <iface>
sudo ip neigh replace 192.168.20.50 lladdr 00:0a:35:01:fe:c0 nud permanent dev <iface>
sudo tcpdump -i <iface> -e -n -XX 'ether host 00:0a:35:01:fe:c0 or udp port 8080'
```

Potom pošli UDP.

## Krok 4 — podľa LED lokalizovať problém

Ak po timing PASS stále nebude odpoveď, LED mapa ti povie, či je problém RX, parser, CDC/TX alebo fyzický TX.

---

# 10. Krátky odborný záver

Aktuálny projekt je **simulačne veľmi dobrý**, ale HW bez odozvy ma neprekvapuje, pretože **aktuálny bitstream má masívny setup timing fail v `ETH_RXC` doméne**.

Najbližšie nerieš ARP responder, MDIO ani FCS strip. Rieš:

```text
P0: ETH_RXC timing closure
P1: static ARP / správny PC test
P2: LED lokalizácia cesty
```

Konkrétne prvý RTL zásah: **pipeline alebo precompute header v `udp_ipv4_tx_builder` tak, aby cesta `udp_ipv4_tx_builder -> async_fifo.mem` nebola cez 28-bajtový mux + checksum logiku v jednom 125 MHz cykle.**
