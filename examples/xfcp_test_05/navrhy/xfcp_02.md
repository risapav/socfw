Analyzoval som `xfcp_test_05.zip`.

```text
xfcp_test_05.zip
SHA-256: f9142edf98a5424b3c60d9b4e4b2aa9172a2425b37797cd930e42c24463879d4
```

## Krátky verdikt

`xfcp_test_05` je zatiaľ **dobrý Fáza A skeleton** pre budúci dual-transport XFCP systém:

```text
UART XFCP  +  budúci ETH/UDP XFCP
        -> xfcp_arbiter_2to1
        -> xfcp_fabric_endpoint
        -> AXI-Lite periférie
```

Aktuálny stav podľa `XFCP_TEST_05_STATUS.md` sedí s kódom:

```text
Fáza A: UART XFCP + arbiter + endpoint — uzavretá
Fáza B: ETH-UDP XFCP integrácia — pripravená, ale ešte nezapojená
```

Simulácie v logoch sú pozitívne:

```text
tb_xfcp_arbiter_2to1: ALL PASSED
tb_xfcp_test_05_top:  ALL PASSED
```

Ale dôležité: integračný test **zámerne netestuje ETH XFCP cestu**, lebo v top-e je stále stub.

---

# 1. Čo je aktuálne implementované

## UART XFCP cesta

Táto časť je reálne zapojená:

```text
UART RX
  -> axis_uart_rx
  -> xfcp_fifo
  -> xfcp_arbiter_2to1.s0
  -> xfcp_fabric_endpoint
  -> AXI-Lite slaves
  -> xfcp_arbiter_2to1 response port m0
  -> UART TX
```

To je dobrý základ. Testbench prešiel čítania komponentov:

```text
Slot 0: SYSC
Slot 3: J10
Slot 4: J11
Slot 5: SEG7
Slot 6: DIAG
```

a aj zápis na LED register.

## ETH sieťový základ

Top už obsahuje architektúru pre Ethernet:

```text
GMII RX
  -> altddio_in sampler
  -> eth_rx_mac
  -> async FIFO
  -> eth_type_demux
  -> ARP
  -> IPv4
  -> ICMP
```

Toto je správne prevzaté z predchádzajúcich Ethernet testov. Dôležité je, že zostal zachovaný `altddio_in` RX sampling fix, ktorý nám predtým vyriešil GMII RX chyby.

## ETH XFCP cesta

Táto časť je zatiaľ stubnutá:

```systemverilog
assign xfcp_eth_rx_valid_w = 1'b0;
assign xfcp_eth_rx_data_w  = 8'h0;
assign xfcp_eth_rx_last_w  = 1'b0;

assign xfcp_eth_tx_ready_w = 1'b0;
assign arb2_meta_valid_w   = 1'b0;
assign arb2_tvalid_w       = 1'b0;
```

Čiže `udp_xfcp_server.sv` existuje, ale **nie je zapojený v top-level**. Preto `xfcp_arbiter_2to1.s1` zatiaľ nikdy nedostane ETH request a `m1` response port sa nikam neposiela.

---

# 2. Poznámky k `navrhy/xfcp_01.md`

Dokument v `navrhy/xfcp_01.md` je užitočný konceptuálne, ale nie je úplne presný voči tvojej aktuálnej implementácii.

V návrhu sa hovorí o všeobecnom XFCP switchi s path routingom:

```text
Header + Path + Command/Address + Payload
```

Ale aktuálna implementácia v `xfcp_pkg.sv` a `XFCP_TEST_05_STATUS.md` používa jednoduchý formát:

```text
Bajt 0:   SOP
Bajt 1:   OPCODE
Bajt 2:   SEQ
Bajt 3-4: COUNT
Bajt 5-8: ADDR
Bajt 9+:  PAYLOAD
```

Teda teraz je to skôr:

```text
transport -> arbiter -> single XFCP endpoint -> address decode -> AXI-Lite slaves
```

nie plný hierarchický path-routing switch.

To nie je problém, len by som to pomenoval jasnejšie:

```text
Terajší projekt: XFCP endpoint s viacvstupovým transportným arbiterom.
Nie ešte: plný source-routed XFCP switch strom.
```

Odporúčam `navrhy/xfcp_01.md` rozdeliť na dve časti:

```text
1. Implementované teraz:
   jednoduchý request/response packet + AXI-Lite endpoint

2. Možné neskoršie rozšírenie:
   path routing, hierarchický switch, stream/full AXI adaptéry
```

---

# 3. Najväčšie riziko v aktuálnom návrhu

## ETH-UDP XFCP odpoveď potrebuje správny request/response kontext

Toto je najdôležitejšia vec pre Fázu B.

Pri UDP requeste musíš uložiť:

```text
source MAC
source IP
source UDP port
```

a pri odpovedi ich použiť ako:

```text
Ethernet dst MAC = request source MAC
IPv4 dst IP      = request source IP
UDP dst port     = request source UDP port
```

Toto sme už riešili pri `eth_test_03`, kde presne tento typ metadátovej chyby spôsobil:

```text
FPGA_BAD_L2_DST_UDP_REPLY
```

V `udp_xfcp_server.sv` už vidím, že sa to snažíš robiť:

```systemverilog
src_ip_q  <= s_ip_src_ip_i;
src_mac_q <= s_eth_src_mac_i;
src_p0_q  <= s_axis_tdata;
src_p1_q  <= ...
```

a pri TX:

```systemverilog
tx_dst_mac_q <= src_mac_q;
tx_dst_ip_q  <= src_ip_q;
```

To je správna myšlienka. Ale Fáza B musí mať test, ktorý explicitne overí:

```text
TX ETH dst = PC MAC
TX IP dst  = PC IP
TX UDP dst = PC source port
```

Bez toho sa môže zopakovať problém z `eth_test_03`.

---

# 4. Problém v `udp_xfcp_server.sv`: port filter má jemné riziko

V RX FSM:

```systemverilog
RX_IDLE:
  src_p0_q  <= s_axis_tdata;
  port_ok_q <= 1'b1;
  rx_byte_cnt_q <= 3'd1;

RX_HDR:
  3'd1: src_p1_q  <= s_axis_tdata;
  3'd2: port_ok_q <= (s_axis_tdata == XFCP_PORT[15:8]);
  3'd3: port_ok_q <= port_ok_q && (s_axis_tdata == XFCP_PORT[7:0]);
```

Toto dekóduje UDP header:

```text
byte0 src_port[15:8]
byte1 src_port[7:0]
byte2 dst_port[15:8]
byte3 dst_port[7:0]
byte4 length[15:8]
byte5 length[7:0]
byte6 checksum[15:8]
byte7 checksum[7:0]
```

Logika je v princípe správna, ale `port_ok_q <= port_ok_q && ...` v sekvenčnom bloku používa starú hodnotu `port_ok_q`. Pri byte 3 by to malo fungovať, lebo po byte 2 je už port_ok uložený z predchádzajúceho cyklu. Je to však krehké a horšie čitateľné.

Čistejšie by bolo mať samostatné:

```systemverilog
logic dst_port_hi_ok_q;
logic dst_port_ok_q;
```

alebo zachytiť `dst_port_q` a porovnať až po byte 3:

```systemverilog
dst_port_q <= {dst_port_q[7:0], s_axis_tdata};

if (rx_byte_cnt_q == 3'd3) begin
  port_ok_q <= ({dst_port_q[7:0], s_axis_tdata} == XFCP_PORT);
end
```

Tým sa zníži riziko off-by-one chyby.

---

# 5. Problém v `udp_xfcp_server.sv`: chýba použitie UDP length

Server teraz ignoruje UDP length z hlavičky. Spolieha sa len na `s_axis_tlast`.

Pre čisté správanie by som doplnil:

```text
udp_len_q
payload_len_expected = udp_len - 8
payload_len_seen
```

A kontroloval:

```text
udp_len >= 8
payload_len_seen == udp_len - 8
payload_len <= MAX_PKT_BYTES
```

Dôvod: pri UDP/XFCP budeš chcieť presne vedieť, či celý XFCP paket prišiel a či nebol skrátený/predĺžený. Teraz by frame s chybnou UDP length mohol prejsť, ak má `tlast`.

---

# 6. Problém v `udp_xfcp_server.sv`: overflow by mal dropnúť celý packet

V `RX_DATA`:

```systemverilog
if (int'(rx_len_q) < MAXB)
  rx_buf[...] <= s_axis_tdata;
if (int'(rx_len_q) < MAXB)
  rx_len_q <= rx_len_q + 1'b1;
if (s_axis_tlast) begin
  rx_complete_q <= 1'b1;
end
```

Ak príde payload dlhší ako `MAX_PKT_BYTES`, ďalšie bajty sa ignorujú, ale na konci sa stále nastaví `rx_complete_q`.

To znamená:

```text
dlhý UDP packet sa potichu oreže a odošle do XFCP ako platný kratší packet
```

To je zlé. Pri overflowe by sa mal celý packet dropnúť:

```systemverilog
if (rx_len_q >= MAXB) begin
  rx_overflow_q <= 1'b1;
  rx_state_q    <= RX_DRAIN;
end
```

a `rx_complete_q` nastaviť iba ak `!rx_overflow_q`.

Pre Fázu B odporúčam pridať statusy:

```text
stat_rx_udp_ok
stat_rx_bad_port
stat_rx_oversize
stat_rx_short
stat_tx_reply
```

Tie vyveď aspoň na debug registre alebo `pmod_j10/j11`.

---

# 7. Problém: `udp_xfcp_server` je single outstanding

Komentár hovorí:

```text
One request-response cycle at a time.
```

To je pre prvú HW fázu úplne v poriadku. Len treba explicitne ošetriť, čo sa stane, keď príde ďalší UDP request počas toho, ako:

```text
rx_complete_q = 1
alebo resp_complete_q = 1
alebo TX ešte posiela odpoveď
```

Teraz RX_IDLE podmienka má:

```systemverilog
!rx_complete_q
```

ale nevidím blokovanie voči `resp_complete_q` alebo `tx_state_q != TX_IDLE`.

Bezpečnejšie pre Fázu B:

```systemverilog
server_busy = rx_complete_q ||
              resp_complete_q ||
              (out_state_q != OUT_IDLE) ||
              (tx_state_q != TX_IDLE);
```

a nový request prijať len keď `!server_busy`.

Inak môžeš prepísať `src_ip_q/src_mac_q/src_p0_q/src_p1_q` skôr, než sa dokončí odpoveď na predchádzajúci request.

To je presne typ chyby, ktorá by spôsobila odpoveď na zlú MAC/IP/port.

---

# 8. `xfcp_udp_transport.sv` a adaptery sú momentálne alternatívna architektúra

Máš dve podobné cesty:

```text
A) udp_xfcp_server.sv
   monolit: UDP header parse + XFCP buffering + UDP reply header

B) xfcp_udp_transport.sv
   xfcp_udp_rx_adapter + xfcp_udp_tx_adapter
```

Momentálne top-level spomína `udp_xfcp_server`, ale nie `xfcp_udp_transport`.

Odporúčam vybrať jednu cestu.

Pre tento projekt by som odporúčal **monolit `udp_xfcp_server.sv`** pre Fázu B, pretože:

```text
- má prístup k ETH src MAC,
- vie uložiť IP/MAC/port kontext,
- vie generovať UDP header a IPv4 metadata,
- jednoduchšie sa testuje ako jeden request-response server.
```

`xfcp_udp_transport.sv` môže zostať v `rtl/xfcp/experimental/` alebo ho dočasne vyradiť z filelistu, aby nevznikla nejasnosť.

---

# 9. `xfcp_arbiter_2to1.sv` — dobrý základ, ale pozor na order FIFO

Arbiter má order FIFO, ktoré mapuje odpoveď späť na port 0 alebo port 1. To je presne správny koncept.

Jedno riziko:

```systemverilog
wire ord_push0_w = (arb_q == ARB_IDLE) && s0_valid_i && !ord_full_w;
wire ord_push1_w = (arb_q == ARB_IDLE) && !s0_valid_i && s1_valid_i && !ord_full_w;
```

Order sa pushne hneď pri začatí grantovania requestu, nie až po úspešnom prvom byte handshake.

Ak `s0_valid_i=1`, `m_ready_i=0`, order FIFO sa môže naplniť aj keď request ešte reálne neprešiel do endpointu. V testoch to možno nevadí, ale robustnejšie je pushovať až pri prvom reálnom beat-e:

```text
ord_push0 = first beat of grant0 accepted
ord_push1 = first beat of grant1 accepted
```

Teda napríklad:

```systemverilog
wire grant0_first_beat_w =
  (arb_q == ARB_GRANT0) &&
  (p0_state_q == P0_SOP) &&
  s0_valid_i && m_ready_i;

wire grant1_first_beat_w =
  (arb_q == ARB_GRANT1) &&
  s1_valid_i && m_ready_i &&
  grant1_first_q;
```

Alebo si držať `req_order_pushed_q` počas grantu.

Toto by som dal do Fázy A.1 hardening, lebo pri backpressure sa inak môže order FIFO rozísť s reálne prijatými requestmi.

---

# 10. `xfcp_arbiter_2to1.sv` — Port 0 syntetický TLAST je špeciálny

Port 0 UART nemá TLAST a arbiter ho generuje podľa XFCP hlavičky. Port 1 ETH má prirodzený TLAST.

To je rozumné, ale znamená to:

```text
UART transport musí posielať presne dobre formované XFCP pakety.
Ak stratí bajt, parser sa môže rozísť.
```

Do budúcna by som pre UART cestu doplnil SOP recovery:

```text
ak očakávam SOP a príde niečo iné, zahadzovať do najbližšieho 0xFE
ak príde 0xFE uprostred pokazeného packetu, resync
```

Možno už toto rieši `xfcp_rx_parser` v endpoint-e, ale arbiter Port 0 generuje TLAST pred endpointom, takže aj on by mal vedieť resetovať stav pri chybe.

---

# 11. Top-level zatiaľ nie je Fáza B napriek existencii `udp_xfcp_server.sv`

V `xfcp_test_05_top.sv` je dôležité:

```systemverilog
// Faza A: ETH XFCP receive side — stub
assign xfcp_eth_rx_valid_w = 1'b0;

// Faza A: ETH XFCP transmit side — stub
assign arb2_meta_valid_w   = 1'b0;
```

To znamená:

```text
ETH/UDP XFCP nie je ešte funkčne zapojené.
```

Preto ďalší postup by nemal začať na PC Python nástrojoch. Najprv treba zapojiť a nasimulovať `udp_xfcp_server`.

---

# 12. Navrhovaný ďalší postup

## Fáza A.1 — upratať a spevniť existujúci základ

1. Aktualizovať `XFCP_TEST_05_STATUS.md`:

```text
Fáza A: UART XFCP + arbiter + endpoint — uzavretá
Fáza A.1: hardening arbitra/order FIFO — TODO
Fáza B: ETH-UDP XFCP — TODO
```

2. Upraviť `xfcp_arbiter_2to1` order FIFO push na prvý úspešný beat, nie iba na `valid`.

3. Doplniť test arbitra s backpressure:

```text
s0_valid=1, m_ready=0 niekoľko cyklov
overiť, že order FIFO sa neposunie predčasne
```

4. Odstrániť alebo presunúť nepoužívané alternatívne UDP adaptéry, prípadne jasne označiť:

```text
experimental / unused in top
```

---

## Fáza B.0 — unit test `udp_xfcp_server`

Pred top-level zapojením vytvoriť:

```text
sim/unit/tb_udp_xfcp_server.sv
```

Testy:

```text
T1: UDP packet na zlý port -> drop, žiadny xfcp_rx
T2: UDP packet na XFCP_PORT s 9B READ requestom -> xfcp_rx stream sedí
T3: XFCP response stream -> UDP reply header:
    src port = XFCP_PORT
    dst port = pôvodný src port
    dst IP   = pôvodná src IP
    dst MAC  = pôvodná src MAC
T4: oversize payload > MAX_PKT_BYTES -> drop
T5: druhý request počas busy -> drop alebo ignorovať podľa špecifikácie
```

Bez tohto by som ho nezapájal do top-u.

---

## Fáza B.1 — zapojiť ETH request path

V top-e:

```text
ipv4_rx L4 stream
  -> udp_xfcp_server RX
  -> xfcp_arbiter_2to1.s1
```

Treba dať pozor na to, že `ipv4_rx` L4 stream aktuálne používa aj `icmp_echo`. Ak chceš UDP a ICMP súčasne, potrebuješ L4 demux podľa `ipv4_hdr_proto_w`:

```text
proto 0x01 -> ICMP
proto 0x11 -> UDP/XFCP
```

Momentálne `icmp_echo` dostáva celý `l4_tdata_w` stream a sám filtruje podľa proto. To môže fungovať, ak iba pasívne ignoruje non-ICMP, ale pri dvoch konzumentoch bez tready je to krehké. Pre čistotu by som pridal `ipv4_l4_demux`.

---

## Fáza B.2 — zapojiť ETH response path

`xfcp_arbiter_2to1.m1`:

```text
m1_valid/m1_data/m1_last
  -> udp_xfcp_server xfcp_tx
  -> ipv4_tx
  -> eth_tx_arb port 2
  -> eth_tx_mac
```

V top-e máš pre arb2 už pripravené signály, takže cieľ je:

```systemverilog
udp_xfcp_server
  .m_meta_* -> ipv4_tx_udp_xfcp
ipv4_tx_udp_xfcp
  .m_meta_* / .m_axis_* -> eth_tx_arb port 2
```

Neposielaj UDP server priamo do `eth_tx_arb`, lebo server generuje UDP header + payload a IPv4 metadata, nie Ethernet metadata.

---

## Fáza B.3 — integračná simulácia ETH UDP XFCP

Rozšíriť `tb_xfcp_test_05_top.sv`:

```text
T11: pošli cez GMII/IPv4/UDP XFCP READ SYSC ID
     očakávaj UDP odpoveď s XFCP response payloadom

T12: pošli cez UART READ a ETH READ skoro súčasne
     očakávaj, že odpovede idú späť na správny transport

T13: ETH WRITE LED register
     overiť led_o

T14: UART WRITE + ETH READ kolízia
     overiť fixed priority a order FIFO
```

Toto je jadro projektu. Bez T12 by som neuzatváral dual-transport fázu.

---

## Fáza C — PC tools

Až keď B simulácie prejdú:

```text
tools/xfcp_client.py
  --transport uart
  --transport udp
```

Minimálne testy:

```bash
python3 tools/xfcp_client.py --uart /dev/ttyUSB0 id
python3 tools/xfcp_client.py --udp 192.168.0.5:50000 id
python3 tools/xfcp_client.py --uart ... read 0xff000000
python3 tools/xfcp_client.py --udp ... read 0xff000000
```

Potom simultánny test:

```text
UART loop číta DIAG
UDP loop zapisuje LED/J10
```

---

# 13. Odporúčaná priorita

Najbližší konkrétny krok:

```text
1. Opraviť/hardennúť order FIFO push v xfcp_arbiter_2to1.
2. Pridať tb_udp_xfcp_server.sv.
3. Až potom zapojiť udp_xfcp_server do top-u.
```

Poradie by som nemenil. Ak rovno zapojíš ETH cestu do top-u, budeš debugovať naraz:

```text
UDP header parser
metadata context
order FIFO
response demux
ipv4_tx
eth_tx_arb
eth_tx_mac
```

To bude zbytočne ťažké. Unit test `udp_xfcp_server` ti izoluje najrizikovejšiu časť.

---

## Záver

`xfcp_test_05` je dobre rozbehnutý. Fáza A je reálne uzavretá: UART XFCP cesta, arbiter a AXI-Lite endpoint sú simuláciou overené. Návrhový dokument je užitočný, ale opisuje aj širšiu víziu, ktorá zatiaľ nie je implementovaná.

Ďalší postup by som viedol disciplinovane:

```text
Fáza A.1: spevniť arbiter/order FIFO pod backpressure
Fáza B.0: unit test udp_xfcp_server
Fáza B.1: zapojiť ETH request path
Fáza B.2: zapojiť ETH response path
Fáza B.3: integračné testy UART+ETH súčasne
Fáza C: Python dual-transport tools
```

Najväčšie riziko je opakovanie chyby z `eth_test_03`: nesprávne prenesený request context do TX odpovede. Preto v ETH XFCP testoch musíš explicitne overovať `dst_mac`, `dst_ip` a `dst_port` odpovede.
