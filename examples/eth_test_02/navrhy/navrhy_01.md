Porovnal som aktuálne ZIP-y:

```text
eth_test.zip      = fungujúci periodický TX test
eth_test_02.zip   = nový UDP echo test
```

Najdôležitejší záver: **`eth_test_02` je architektonicky ambicióznejší, ale zatiaľ má najmenej tri reálne blokery**:

```text
1. Pri krátkom UDP payload-e generuje runt Ethernet frame bez paddingu.
2. Quartus timing neprechádza: ETH_TX_CLK slack -2.609 ns.
3. Na reálnom PC potrebuje statický ARP záznam a presný cieľový MAC/port/IP; inak sa k nemu UDP rámec vôbec nedostane.
```

---

# 1. Základný rozdiel medzi projektmi

## `eth_test`

`eth_test` je jednoduchší. Vysiela periodický statický UDP packet z RAM.

Top-level:

```systemverilog
ethernet_test.sv
```

Používa:

```text
ipreceive
udp
ipsend
crc
ram
eth_status_leds
```

Ale prakticky je to hlavne **TX bring-up test**. Aj keď má RX parser, paket vie vysielať periodicky aj bez prijatého rámca.

Preto môže na doske „fungovať“ aj vtedy, keď PC nič neposiela.

---

## `eth_test_02`

`eth_test_02` je skutočný echo pokus.

Top-level:

```systemverilog
ethernet_test_echo.sv
```

Tok je:

```text
PHY RX
  -> ipreceive
  -> RX RAM
  -> udp_rx_ram_to_stream
  -> eth_udp_echo_test
  -> udp_tx_stream_to_ram
  -> TX RAM
  -> ipsend
  -> PHY TX
```

To je oveľa zložitejšia cesta. Má viac CDC, viac RAM, AXI-Lite register file, stream handshake a dynamické dĺžky.

Preto aj Quartus rozdiel:

```text
eth_test:
  Logic elements: 1,430
  Registers:      895
  Memory bits:    16,384
  Timing:         OK, worst ETH_TX_CLK slack +0.047 ns

eth_test_02:
  Logic elements: 7,030
  Registers:      5,367
  Memory bits:    32,768
  Timing:         FAIL, worst ETH_TX_CLK slack -2.609 ns
```

---

# 2. Najväčší funkčný problém: `eth_test_02` generuje runt frame

Toto je podľa mňa hlavný dôvod, prečo simulácia môže prejsť, ale reálna sieť nemusí nič vidieť.

V `eth_test_02/sim/integration/tb_udp_echo_path.sv` je test s payloadom `"HELLO"`:

```text
payload = 5 bajtov
UDP length = 5 + 8 = 13
IP total length = 5 + 28 = 33
```

Test očakáva:

```text
8 preamble + 14 Ethernet + 20 IP + 8 UDP + 5 payload + 4 FCS = 59 bajtov
```

A log hovorí:

```text
PASS frame length: 59
PASS T8 CRC residue: 0xdebb20e3
```

Lenže toto je z pohľadu Ethernetu zlé.

Minimálna Ethernet dĺžka od destination MAC po FCS je:

```text
64 bajtov
```

Minimálna dĺžka od destination MAC po koniec payload/padding bez FCS je:

```text
60 bajtov
```

Tvoj `eth_test_02` pre 5-bajtový UDP payload vyrába:

```text
14 Ethernet header
20 IPv4 header
8 UDP header
5 payload
= 47 bajtov bez FCS
```

Chýba padding:

```text
60 - 47 = 13 bajtov paddingu
```

Správna dĺžka s preambulou a FCS má byť:

```text
8 preamble/SFD + 60 frame bez FCS + 4 FCS = 72 bajtov
```

Nie 59.

Takže `eth_test_02` v simulácii explicitne schvaľuje rámec, ktorý je na reálnej sieti **runt frame**. PHY alebo PC NIC ho môže zahodiť.

## Prečo `eth_test` funguje

`eth_test` vysiela statický payload `"HELLO QM TECH BOARD"` s dĺžkou okolo 20 bajtov.

Jeho dĺžky sú:

```systemverilog
tx_data_length_w  = 16'd28; // UDP length = 8 + 20 payload
tx_total_length_w = 16'd48; // IP total = 20 + 8 + 20
```

Ethernet frame bez FCS:

```text
14 Ethernet + 48 IP packet = 62 bajtov
```

To je viac než minimum 60. Preto nepotrebuje padding a rámec nie je runt.

## Oprava

V `ipsend.sv` alebo pred ním treba zaviesť Ethernet padding.

Pre ľubovoľný payload:

```text
ip_total_length = UDP payload + 28
ethernet_no_fcs = 14 + ip_total_length
padding_len = max(0, 60 - ethernet_no_fcs)
```

Keďže:

```text
ethernet_no_fcs = payload_len + 42
```

tak:

```text
padding_len = max(0, 18 - payload_len)
```

Pre payload `"HELLO"`:

```text
payload_len = 5
padding_len = 13
```

Do CRC sa padding musí počítať tiež.

V `ipsend.sv` teda nesmie po poslednom payload bajte hneď prejsť na CRC, ale musí mať napríklad stav:

```text
ST_SEND_PAD
```

a až potom:

```text
ST_SEND_CRC
```

---

# 3. Druhý veľký problém: `eth_test_02` neprechádza timingom

`eth_test`:

```text
Slow 1200mV 85C:
  ETH_TX_CLK setup slack: +0.047 ns
  ETH_RXC setup slack:    +0.992 ns
  SYS_CLK setup slack:    +5.165 ns
```

Tesné, ale formálne prejde.

`eth_test_02`:

```text
Slow 1200mV 85C:
  ETH_TX_CLK setup slack: -2.609 ns
  ETH_RXC setup slack:    +1.027 ns
  SYS_CLK setup slack:    +5.849 ns
```

Čiže problém je čisto v TX doméne.

Najhoršie cesty sú:

```text
eth_udp_echo_test:u_echo|rd_ptr_r[*]
  -> udp_tx_stream_to_ram:u_tx_to_ram|buf_q[*]
```

Konkrétne STA ukazuje napríklad:

```text
From: eth_udp_echo_test:u_echo|rd_ptr_r[7]
To:   udp_tx_stream_to_ram:u_tx_to_ram|buf_q[25]
Data delay: 10.515 ns
Slack: -2.609 ns
```

To znamená, že v jednom 125 MHz cykle ide cesta:

```text
rd_ptr_r
  -> výber bajtu z payload_mem_r[rd_ptr_r]
  -> udp_tx_data_o
  -> udp_tx_stream_to_ram.buf_next_w
  -> buf_q
```

Táto cesta je príliš dlhá.

## Prečo vznikla

V `eth_udp_echo_test.sv`:

```systemverilog
assign udp_tx_data_o = payload_mem_r[rd_ptr_r];
assign udp_tx_valid_o = (fsm_r == ST_SEND_PAY);
```

Toto je asynchrónne čítanie veľkej pamäte/bufferu podľa `rd_ptr_r`.

Potom `udp_tx_stream_to_ram.sv` v tom istom takte robí:

```systemverilog
if (valid_i) begin
  ...
  buf_q <= buf_next_w;
end
```

kde `buf_next_w` závisí od `data_i`.

Teda pamäťový výber + stream + packing do RAM beží v jednom cykle.

## Oprava

Pridaj register/skid buffer medzi `payload_mem_r` a `udp_tx_stream_to_ram`.

Najjednoduchšie v `eth_udp_echo_test.sv`:

```systemverilog
logic        udp_tx_valid_q;
logic [7:0]  udp_tx_data_q;
logic        udp_tx_last_q;

assign udp_tx_valid_o = udp_tx_valid_q;
assign udp_tx_data_o  = udp_tx_data_q;
assign udp_tx_last_o  = udp_tx_last_q;
```

A namiesto kombinačného:

```systemverilog
assign udp_tx_data_o = payload_mem_r[rd_ptr_r];
```

spraviť registrovaný výstup.

Ešte čistejšie: zmeniť `eth_udp_echo_test` na dvojstavový TX:

```text
ST_SEND_LOAD:
  udp_tx_data_q <= payload_mem_r[rd_ptr_r]
  udp_tx_last_q <= ...
  udp_tx_valid_q <= 1

ST_SEND_PAY:
  čakaj na ready
  po handshake posuň rd_ptr
```

Tým sa najdlhšia cesta rozbije a timing by mal výrazne zlepšiť.

---

# 4. Tretí problém: `eth_test_02` potrebuje statický ARP / presný L2 packet

`eth_test` funguje aj bez RX, lebo vysiela periodicky.

`eth_test_02` nevysiela nič, kým nedostane UDP rámec.

Ale nemáš implementovaný ARP. To znamená:

```text
PC nevie MAC adresu FPGA.
PC najprv pošle ARP request.
FPGA na ARP neodpovie.
PC nikdy nepošle UDP unicast frame.
eth_test_02 nikdy nespustí echo.
```

V komentári v `ethernet_test_echo.sv` je správne uvedené:

```text
sudo arp -s <BOARD_IP> 00:0a:35:01:fe:c0
```

To nie je voliteľné. Pre aktuálny stav je to povinné.

## Navyše IP a port sú iné

`eth_test_02` má default:

```systemverilog
parameter logic [31:0] BOARD_IP  = 32'hC0A81432; // 192.168.20.50
parameter logic [15:0] ECHO_PORT = 16'd8080
```

Teda PC musí posielať na:

```text
IP:   192.168.20.50
UDP:  8080
MAC:  00:0A:35:01:FE:C0
```

Ak stále testuješ podľa starších hodnôt typu:

```text
192.168.1.50
port 0x1234
```

tak `eth_test_02` nebude odpovedať.

## Dôležité: `ipreceive` filtruje destination MAC

V `ipreceive.sv` sa akceptuje iba cieľová MAC:

```text
00:0A:35:01:FE:C0
```

Broadcast frame sa tu neakceptuje ako cieľ pre RX. Čiže nestačí poslať UDP broadcast na L2 broadcast. Musí to byť rámec s destination MAC boardu, alebo treba rozšíriť filter aj na broadcast.

---

# 5. Štvrtý problém: TX destination MAC je stále broadcast

V `eth_test_02/rtl/eth/ipsend.sv` je MAC header stále hardcoded:

```systemverilog
localparam logic [7:0] MAC_ADDR [0:13] = '{
  8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF,
  8'h00, 8'h0A, 8'h35, 8'h01, 8'hFE, 8'hC0,
  8'h08, 8'h00
};
```

To znamená, že odpoveď z echo testu ide na Ethernet broadcast MAC, nie na MAC odosielateľa.

Pre `eth_test` je to v poriadku, lebo cieľ je „nech to Wireshark vidí“.

Pre `eth_test_02` echo by to však malo byť:

```text
dst MAC = pc_mac_o z ipreceive
src MAC = 00:0A:35:01:FE:C0
```

Teda do `ipsend` treba pridať vstupy:

```systemverilog
input wire [47:0] tx_dst_mac_i,
input wire [47:0] tx_src_mac_i
```

a MAC header generovať dynamicky.

Broadcast L2 odpoveď možno Wireshark uvidí, ale ako seriózny UDP echo server je to nesprávne.

---

# 6. Piaty problém: simulácie v `eth_test_02` nie sú plný Ethernet test

`eth_test_02` má simulačné logy zelené:

```text
tb_rx_stream.log       PASS
tb_tx_stream.log       PASS
tb_udp_echo_path.log   PASS
```

Ale `tb_udp_echo_path.sv` nepúšťa reálny GMII RX packet cez `ipreceive`.

Namiesto toho robí:

```systemverilog
force dut.u_rx_ram.mem[0] = 32'h48454C4C;
force dut.u_rx_ram.mem[1] = 32'h4F000000;

force dut.ipr_pc_ip_w       = SRC_IP;
force dut.ipr_board_ip_w    = DST_IP;
force dut.ipr_udp_layer_w   = {SRC_PORT, DST_PORT, UDP_LEN, 16'd0};
force dut.ipr_rx_data_len_w = UDP_LEN;
force dut.ipr_data_receive_w = 1'b1;
```

Čiže test obchádza skutočný RX parser.

To je užitočné pre test echo cesty, ale neoveruje:

```text
GMII RX preambulu/SFD
MAC filter
IP header parsing
UDP header parsing
reálny zápis payloadu cez ipreceive
```

A čo je ešte horšie: test explicitne považuje 59-bajtový runt frame za PASS.

Preto simulácia teraz neodhalí hlavný problém.

---

# 7. Porovnanie fungujúceho `eth_test` vs nefungujúceho `eth_test_02`

## `eth_test` výhody

```text
+ vysiela periodicky bez potreby RX
+ používa dlhší payload, takže nejde pod Ethernet minimum
+ timing prechádza, aj keď tesne
+ jednoduchá cesta: RAM -> ipsend -> CRC -> GMII TX
+ broadcast MAC spôsobí, že paket je ľahko viditeľný vo Wiresharku
```

## `eth_test_02` výhody

```text
+ lepšia architektúra pre budúci UDP echo
+ oddelená RX RAM a TX RAM
+ má RX->TX stream adaptéry
+ má AXI-Lite diagnostický echo modul
+ má dynamickú IP/port odpoveď
+ má triggerovaný TX namiesto periodického timeru
```

## `eth_test_02` riziká/blokery

```text
- krátke payloady generujú runt frame bez paddingu
- timing v ETH_TX_CLK neprechádza o -2.609 ns
- plný GMII RX test chýba
- PC musí mať statický ARP
- PC musí posielať na 192.168.20.50:8080
- RX MAC filter akceptuje iba 00:0A:35:01:FE:C0
- TX destination MAC je stále broadcast, nie MAC odosielateľa
```

---

# 8. Čo by som opravil ako prvé

## P0.1 — doplniť Ethernet padding

Toto je najpravdepodobnejší funkčný dôvod, prečo odpoveď nevidíš pri krátkom payloade.

Do `ipsend.sv` pridať:

```systemverilog
logic [15:0] payload_len_w;
logic [15:0] pad_len_q;
logic [15:0] pad_cnt_q;

assign payload_len_w = tx_data_length_i - 16'd8;
```

Pri štarte TX vypočítať:

```systemverilog
if (payload_len_w < 16'd18)
  pad_len_q <= 16'd18 - payload_len_w;
else
  pad_len_q <= 16'd0;
```

Po `ST_SEND_DATA`:

```text
ak pad_len_q != 0 -> ST_SEND_PAD
inak -> ST_SEND_CRC
```

V `ST_SEND_PAD`:

```systemverilog
tx_data_o <= 8'h00;
crc_en_o  <= 1'b1;
```

Až potom FCS.

Potom pre `"HELLO"` musí mať TX stream:

```text
8 preambula/SFD
14 Ethernet
20 IP
8 UDP
5 payload
13 padding
4 FCS
= 72 bajtov
```

Nie 59.

---

## P0.2 — opraviť testbench, aby už 59 bajtov nepovažoval za PASS

V `tb_udp_echo_path.sv` zmeniť očakávanie:

```text
expected length = 72
```

a overiť padding:

```text
tx_bytes[55..67] == 00
```

Ak chceš počítať bez preambuly, potom:

```text
14 + 20 + 8 + 5 + 13 + 4 = 64
```

---

## P0.3 — hardvérový test robiť s presným nastavením PC

Na PC:

```bash
sudo ip addr add 192.168.20.100/24 dev <iface>
sudo arp -s 192.168.20.50 00:0a:35:01:fe:c0
```

Potom poslať UDP:

```bash
echo -n "HELLO QM TECH BOARD" | nc -u -w1 192.168.20.50 8080
```

Na úplne prvý test odporúčam payload aspoň 18 bajtov, aby sa dočasne obišiel padding problém:

```text
"HELLO QM TECH BOARD"
```

Má 19 alebo 20 bajtov podľa zakončenia. Tým by si mal dostať nerunt odpoveď aj bez padding opravy.

Ak s dlhým payloadom odpoveď začne fungovať, padding problém je potvrdený.

---

## P1 — opraviť timing v `eth_test_02`

Najhoršia cesta je:

```text
eth_udp_echo_test.rd_ptr_r
  -> payload_mem_r[rd_ptr_r]
  -> udp_tx_data_o
  -> udp_tx_stream_to_ram.buf_q
```

Oprava: registrovať výstup payload bufferu.

Napríklad prerobiť `ST_SEND_PAY` v `eth_udp_echo_test` tak, aby nemal kombinačný výstup z pamäte, ale registrovaný stream byte.

Cieľ:

```text
ETH_TX_CLK setup slack > 0 ns
```

---

## P2 — pridať dynamickú TX MAC

Do `ipreceive` už máš `pc_mac_o`.

Treba ho dostať do TX cesty:

```text
ipreceive.pc_mac_o
  -> udp_rx_ram_to_stream metadata
  -> echo metadata
  -> ipsend tx_dst_mac_i
```

Alebo jednoduchšie dočasne priamo v top:

```systemverilog
.tx_dst_mac_i(ipr_pc_mac_w)
```

a v `ipsend` namiesto hardcoded `FF:FF:FF:FF:FF:FF`.

---

## P3 — pridať plný GMII integračný test

Nový test:

```text
tb_ethernet_test_echo_gmii_packet.sv
```

Nesmie používať `force dut.ipr_*`.

Musí poslať reálny GMII RX frame:

```text
55 55 55 55 55 55 55 D5
DA = 00:0A:35:01:FE:C0
SA = DE:AD:BE:EF:12:34
IPv4
UDP dst port 8080
payload "HELLO"
FCS
```

A očakávať TX:

```text
preambula
DA = DE:AD:BE:EF:12:34 alebo dočasne FF:FF:FF:FF:FF:FF
SA = 00:0A:35:01:FE:C0
IPv4 src = 192.168.20.50
IPv4 dst = 192.168.20.100
UDP src port = 8080
UDP dst port = pôvodný source port
payload "HELLO"
padding 13x 00
valid FCS
```

Tento test by hneď odhalil padding aj MAC problémy.

---

# 9. Najpravdepodobnejší dôvod, prečo `eth_test_02` zatiaľ nefunguje

V poradí pravdepodobnosti:

```text
1. Posielaš krátky UDP payload a FPGA odpovedá runt frame-om bez paddingu.
   PC/NIC ho zahodí.

2. PC neposiela UDP frame do FPGA, lebo chýba statický ARP.
   FPGA nemá ARP responder.

3. Posielaš na nesprávnu IP/port.
   eth_test_02 očakáva 192.168.20.50:8080.

4. Timing ETH_TX_CLK neprechádza o -2.609 ns.
   Aj keď logicky správny rámec vznikne, HW môže byť nestabilný.

5. Simulácia neoveruje skutočný GMII RX packet a má nesprávne očakávanie 59 bajtov.
```

---

## Krátky akčný plán

Najrýchlejší overovací experiment:

```text
1. Na PC nastav statický ARP:
   192.168.20.50 -> 00:0a:35:01:fe:c0

2. Pošli UDP payload dlhý aspoň 18 bajtov na port 8080:
   "HELLO QM TECH BOARD"

3. Sleduj LED:
   LED2 RX aktivita
   LED3 TX aktivita

4. Sleduj Wireshark.
```

Ak pri dlhom payloade odpoveď uvidíš, ale pri `"HELLO"` nie, problém je jednoznačne padding/runt frame.

Potom oprav `ipsend.sv` padding a testbench očakávanie zo 59 na 72 bajtov.
