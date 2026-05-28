Teraz som analyzoval **aktuálny `eth_test_02.zip`**, vrátane:

```text
ETH_TEST_02_STATUS.md
project.yaml
timing_config.yaml
ip/ethernet_test_echo.ip.yaml
rtl/ethernet_test_echo.sv
rtl/eth_udp_echo_test.sv
rtl/eth/ipreceive.sv
rtl/eth/ipsend.sv
rtl/eth/udp_rx_ram_to_stream.sv
rtl/eth/udp_tx_stream_to_ram.sv
rtl/eth/eth_status_leds.sv
sim/logs/*
output_files/soc_top.*.rpt
build/rtl/soc_top.sv
build/timing/soc_top.sdc
```

## Stručný verdikt

`eth_test_02` je už koncepčne dobrý krok smerom k reálnemu UDP echo systému. Má padding, CDC modul, RX/TX RAM, PLL TX clock, LED diagnostiku, AXI-Lite register file a timing formálne prechádza.

Ale hardvérové zlyhanie je stále vysvetliteľné. V aktuálnom RTL je stále otvorený kritický bug:

```text
ipreceive.data_receive_o sa nastaví na 1 a nikdy sa sám nevráti na 0.
```

Presne to už správne popisuje `ETH_TEST_02_STATUS.md`, ale kód v `rtl/eth/ipreceive.sv` ešte opravený nie je.

---

# 1. Stav podľa `ETH_TEST_02_STATUS.md`

Status dokument je už pomerne presný a užitočný. Hovorí:

```text
Fáza 1: simulácia 3/3 PASS
Fáza 2: Quartus build a timing closure PASS
Fáza 3: HW test FAIL
```

Dôležité z dokumentu:

```text
UDP echo cieľ:
  FPGA IP: 192.168.20.50
  Echo port: 8080
  MAC: 00:0A:35:01:FE:C0

HW test:
  python echo test: 0/10, timeout
  tcpdump PC -> FPGA: vidí odchádzajúce pakety
  tcpdump FPGA -> PC: nič
  timer_en_i=1 diagnostika: LED3 bliká, ipsend fyzicky beží
```

Pozor: v aktuálnom `rtl/ethernet_test_echo.sv` je `timer_en_i` priamo pripojené na `1'b0`:

```systemverilog
.timer_en_i (1'b0)
```

Takže poznámka v statuse o `timer_en_i=1` musela byť z manuálne upravenej alebo testovacej zostavy. Nie je to priamo stav aktuálneho RTL v ZIP-e.

---

# 2. Quartus stav aktuálnej verzie

Kompilácia je úspešná:

```text
Flow Status: Successful
Device: EP4CE55F23C8
Logic elements: 1,920 / 55,856
Registers: 1,366
Pins: 33 / 325
Memory bits: 36,864
PLLs: 1 / 4
```

Timing je formálne OK:

```text
Slow 1200mV 85C:
  ETH_TX_CLK setup slack: +0.086 ns
  ETH_RXC    setup slack: +0.602 ns
  SYS_CLK    setup slack: +5.324 ns

Hold:
  ETH_RXC:    +0.409 ns
  ETH_TX_CLK: +0.429 ns
  SYS_CLK:    +0.448 ns
```

Status dokument uvádza `ETH_TX_CLK +0.213 ns`, ale aktuálny `output_files/soc_top.sta.summary` ukazuje `+0.086 ns`. Stále je to PASS, ale rezerva je veľmi malá.

Najtesnejšia TX cesta je stále v `ipsend`:

```text
ipsend.i_cnt_q -> ipsend.tx_data_o
slack +0.086 ns
data delay ~7.687 ns
```

Čiže timing closure je formálne hotový, ale veľmi tesný. Každá menšia RTL úprava môže timing znova zhodiť.

---

# 3. Simulácia: PASS, ale stále nie plný systémový test

Sim logy:

```text
tb_rx_stream.log       PASS
tb_tx_stream.log       PASS
tb_udp_echo_path.log   PASS
```

`tb_udp_echo_path` už správne očakáva 72 bajtov pre krátky payload `"HELLO"`:

```text
8 preamble/SFD
14 Ethernet
20 IPv4
8 UDP
5 payload
13 padding
4 FCS
= 72 bajtov
```

Teda môj predchádzajúci problém s runt frame je v aktuálnej verzii už opravený.

Ale integračný test stále nerobí skutočný GMII RX príjem. V `tb_udp_echo_path.sv` sa RX časť obchádza cez `force`:

```systemverilog
force dut.u_rx_ram.mem[0] = 32'h48454C4C;
force dut.u_rx_ram.mem[1] = 32'h4F000000;

force dut.ipr_pc_ip_w       = SRC_IP;
force dut.ipr_board_ip_w    = DST_IP;
force dut.ipr_udp_layer_w   = {SRC_PORT, DST_PORT, UDP_LEN, 16'd0};
force dut.ipr_rx_data_len_w = UDP_LEN;

force dut.ipr_data_receive_w = 1'b1;
...
force dut.ipr_data_receive_w = 1'b0;
```

Toto presne maskuje reálny bug v `ipreceive.sv`. Test ručne vytvorí krásny jednocykový `data_receive` pulz, ale skutočný `ipreceive` ho nevytvára správne.

---

# 4. Kritický bug: `data_receive_o` sa nikdy nemaže

V `rtl/eth/ipreceive.sv`:

```systemverilog
ST_RX_FINISH: begin
  data_o_valid_o <= 1'b0;
  data_receive_o <= 1'b1;
  state_q        <= ST_IDLE;
end
```

Ale v `ST_IDLE` nie je:

```systemverilog
data_receive_o <= 1'b0;
```

Čiže po prvom prijatom pakete ostane `data_receive_o = 1`.

To je kritické, pretože `udp_rx_ram_to_stream.sv` používa `data_receive_i` ako pulse event:

```systemverilog
always_ff @(posedge rx_clk_i or negedge rst_ni) begin
  if (!rst_ni)
    rx_tog_q <= 1'b0;
  else if (data_receive_i)
    rx_tog_q <= ~rx_tog_q;
end
```

Ak `data_receive_i` ostane trvalo v 1, `rx_tog_q` sa bude preklápať každý RX clock cyklus. To môže spôsobiť:

```text
- záplavu falošných eventov cez CDC
- opakované spracovanie starého RAM obsahu
- strata reálnych nových paketov
- úplne nedefinované správanie echo cesty
```

Toto treba opraviť ako prvé.

## Odporúčaná oprava

Najčistejšie by som urobil `data_receive_o` ako skutočný jednocykový pulse.

V `always_ff` po reset vetve dať default:

```systemverilog
end else begin
  data_receive_o <= 1'b0;

  case (state_q)
    ...
    ST_RX_FINISH: begin
      data_o_valid_o <= 1'b0;
      data_receive_o <= 1'b1;
      state_q        <= ST_IDLE;
    end
    ...
  endcase
end
```

Tým bude `data_receive_o` trvať presne jeden takt `eth_rx_clk_i`.

Minimálna oprava iba v `ST_IDLE`:

```systemverilog
ST_IDLE: begin
  data_receive_o <= 1'b0;
  valid_ip_p_o   <= 1'b0;
  ...
end
```

Tiež by fungovala, ale default pulse štýl je bezpečnejší.

---

# 5. Druhý problém: `ETH_RXER` je stále nepoužitý

Quartus hlási:

```text
No output dependent on input pin "ETH_RXER"
```

V `soc_top.sv` je `ETH_RXER` pripojený do `ethernet_test_echo`:

```systemverilog
.eth_rx_er_i(ETH_RXER)
```

Ale v `ethernet_test_echo.sv` sa nikam nepoužíva. `ipreceive` ani nemá `rx_er_i` vstup.

To je škoda, lebo práve pri hardvérovom bring-upe by `RXER` mohol byť veľmi užitočný.

Odporúčanie:

1. Pridať do `ipreceive` vstup:

```systemverilog
input wire rx_er_i
```

2. Ak `rx_er_i == 1` počas príjmu, zahodiť frame a inkrementovať error counter alebo vyviesť error pulse.

3. Minimálne dočasne pripojiť `eth_rx_er_i` do LED/debug logiky.

Napríklad:

```text
LED2 = raw RXDV activity
LED3 = TX activity
LED4 = ipreceive.data_receive pulse
LED5 = RXER/error latch
```

Aktuálne máš 6 fyzických LED, ale používaš iba 4:

```systemverilog
assign ONB_LEDS = { 2'b0, w_ethernet_test_echo_status_led_o };
```

Pre debug by som dočasne využil všetkých 6.

---

# 6. Tretí problém: `ipsend` stále vysiela na broadcast MAC

V `rtl/eth/ipsend.sv`:

```systemverilog
localparam logic [7:0] MAC_ADDR [0:13] = '{
  8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF,
  8'h00, 8'h0A, 8'h35, 8'h01, 8'hFE, 8'hC0,
  8'h08, 8'h00
};
```

Teda každý TX frame má destination MAC:

```text
FF:FF:FF:FF:FF:FF
```

Pre Wireshark/debug to môže byť praktické, ale pre UDP echo je správnejšie:

```text
dst MAC = MAC odosielateľa prijatého paketu
src MAC = MAC FPGA
```

`ipreceive` už má výstup:

```systemverilog
pc_mac_o
```

ale top ho nepoužíva v TX ceste.

Nemyslím si, že broadcast MAC je hlavný dôvod, prečo `tcpdump` nevidí nič. `tcpdump` by broadcast frame videl. Ale ako ďalší krok pre korektný UDP echo server to treba opraviť.

Odporúčanie:

Do `ipsend` pridať:

```systemverilog
input wire [47:0] tx_dst_mac_i,
input wire [47:0] tx_src_mac_i
```

a MAC header skladať dynamicky, nie cez hardcoded `MAC_ADDR`.

V `ethernet_test_echo.sv` potom:

```systemverilog
.tx_dst_mac_i(ipr_pc_mac_w),
.tx_src_mac_i(48'h000A3501FEC0)
```

Pozor: `ipr_pc_mac_w` je RX doména. Treba ho preniesť spolu s ostatnými metadátami cez `udp_rx_ram_to_stream` do TX domény, nie pripojiť priamo.

---

# 7. Štvrtý problém: RX metadata CDC je „fungujúce predpokladom“, nie explicitným handshake

`udp_rx_ram_to_stream.sv` robí CDC takto:

```systemverilog
data_receive_i -> toggle -> synchronizer -> rx_pulse_w
```

a potom v TX doméne latcheuje:

```systemverilog
src_ip_q      <= pc_ip_i;
dst_ip_q      <= board_ip_i;
src_port_q    <= udp_layer_i[63:48];
dst_port_q    <= udp_layer_i[47:32];
payload_len_q <= rx_data_length_i - 16'd8;
```

Komentár hovorí, že metadáta sú stabilné dlho po `data_receive_i`, takže je to OK. Pre jednoduchý systém to môže fungovať.

Ale dlhodobo je lepšie mať explicitný CDC mailbox:

```text
RX doména:
  metadata_shadow <= metadata
  event_toggle <= ~event_toggle

TX doména:
  synchronizuje event_toggle
  latcheuje metadata_shadow až po synchronizácii
```

Toto už prakticky robíš, ale `metadata_shadow` sú priamo výstupy `ipreceive`. Bolo by čistejšie ich najprv zaregistrovať v RX doméne do samostatného `rx_meta_q` v momente `ST_RX_FINISH`.

Pre aktuálnu fázu to nie je P0. Najprv oprav `data_receive_o`.

---

# 8. Piaty problém: aktuálny build je neúplne prenositeľný zo ZIP-u

`build/hal/files.tcl` obsahuje absolútne cesty:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE "/home/palo/Projekty/socfw/rtl/axi/axi_interfaces.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "/home/palo/Projekty/socfw/rtl/axi/axi_pkg.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "/home/palo/Projekty/socfw/rtl/axil/axil_regfile.sv"
set_global_assignment -name SYSTEMVERILOG_FILE "/home/palo/Projekty/socfw/rtl/cdc/cdc_two_flop_synchronizer.sv"
```

V ZIP-e tieto repo-level súbory nie sú zabalené pod `eth_test_02/rtl/axi`, `rtl/axil`, `rtl/cdc`.

To je v poriadku, ak ZIP berieme ako príklad v rámci celého socfw repozitára. Ale ak má byť `eth_test_02.zip` samostatne reprodukovateľný, treba pridať aj tieto závislosti alebo generovať relatívne cesty.

---

# 9. SDC / constraints stav

Aktuálny `build/timing/soc_top.sdc`:

```tcl
create_clock -name ETH_RXC -period 8.000 [get_ports {ETH_RXC}]
create_clock -name SYS_CLK -period 20.000 [get_ports {SYS_CLK}]

create_generated_clock -name ETH_TX_CLK ...
```

Clock groups:

```tcl
set_clock_groups -asynchronous -group {ETH_RXC} -group {ETH_TX_CLK} -group {SYS_CLK}
```

To je logicky správne.

Ale TX GMII výstupy sú stále false-pathované:

```tcl
set_false_path -to [get_ports {ETH_GTX_CLK}]
set_false_path -to [get_ports {ETH_TXD[*]}]
set_false_path -to [get_ports {ETH_TXEN}]
set_false_path -to [get_ports {ETH_TXER}]
```

A RX vstupy tiež:

```tcl
set_false_path -from [get_ports {ETH_RXD[*]}]
set_false_path -from [get_ports {ETH_RXDV}]
set_false_path -from [get_ports {ETH_RXER}]
```

Pre bring-up to viem akceptovať, ale pre finálny referenčný príklad by som nechcel mať celé GMII IO časovanie vypnuté. Formálne teraz STA kontroluje interné domény, ale externé GMII rozhranie je do veľkej miery mimo kontroly.

Hlavne zostáva warning:

```text
PLL output port clk[0] feeds output pin ETH_GTX_CLK via non-dedicated routing
```

Ak `eth_test` na rovnakom hardvéri funguje, nie je to prvé podozrenie. Ale ak `timer_en_i=1` naozaj generuje TX aktivitu a PC nevidí žiadne rámce, potom treba znova preveriť fyzickú TX cestu:

```text
GTX_CLK kvalita
link speed
PHY režim
pinout
TXD/TXEN timing voči GTX_CLK
```

---

# 10. `tools/udp_echo_test.py` má staré defaulty

Status dokument hovorí:

```bash
python3 tools/udp_echo_test.py --host 192.168.20.50 --port 8080 --count 10
```

To je správne.

Ale samotný script má default:

```python
--host default="192.168.1.50"
--port default=50000
```

To je starý default a môže zbytočne miasť.

Odporúčam upraviť defaulty na:

```python
ap.add_argument("--host", default="192.168.20.50")
ap.add_argument("--port", type=int, default=8080)
```

A do výpisu pridať pripomienku:

```text
Required static ARP:
sudo arp -s 192.168.20.50 00:0a:35:01:fe:c0
```

---

# 11. Čo by som urobil ďalej — konkrétny postup

## Krok 1 — opraviť `ipreceive.data_receive_o`

Toto je P0.

V `rtl/eth/ipreceive.sv` zmeniť správanie na jednocykový pulse.

Odporúčaný patch štýl:

```systemverilog
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    ...
    data_receive_o <= 1'b0;
    ...
  end else begin
    // default: pulse outputs low unless explicitly asserted below
    data_receive_o <= 1'b0;

    case (state_q)
      ...
      ST_RX_FINISH: begin
        data_o_valid_o <= 1'b0;
        data_receive_o <= 1'b1;
        state_q        <= ST_IDLE;
      end
      ...
    endcase
  end
end
```

Potom pridať minimálny test:

```text
tb_ipreceive_data_receive_pulse.sv
```

Test musí overiť:

```text
- po jednom validnom GMII frame sa data_receive_o assertne presne na 1 clk
- v ďalšom clk je späť 0
- pri druhom frame sa znovu assertne presne raz
```

Bez tohto testu sa bug ľahko vráti.

---

## Krok 2 — prestať maskovať RX parser v integračnom teste

Súčasný `tb_udp_echo_path.sv` je dobrý test **echo pipeline**, nie celej zostavy.

Treba pridať nový test:

```text
sim/integration/tb_ethernet_test_echo_gmii_packet.sv
```

Ten nesmie robiť:

```systemverilog
force dut.ipr_...
force dut.u_rx_ram.mem...
```

Musí poslať skutočný GMII stream:

```text
55 55 55 55 55 55 55 D5
DA = 00:0A:35:01:FE:C0
SA = napr. DE:AD:BE:EF:12:34
EtherType = 0800
IPv4 header
UDP header dst port 8080
payload "HELLO"
padding + FCS
```

A očakávať TX frame:

```text
preamble/SFD
Ethernet header
IPv4 echo
UDP echo
payload HELLO
13x padding
valid FCS residue 0xDEBB20E3
```

Toto je najdôležitejší simulačný krok, lebo spojí `ipreceive` + RX RAM + CDC + echo + TX RAM + `ipsend`.

---

## Krok 3 — hardvérová diagnostika cez LED rozšíriť na 6 LED

Aktuálne LED ukazujú:

```text
LED0 heartbeat
LED1 PHY reset released
LED2 raw RXDV activity
LED3 TXEN activity
LED4/LED5 = 0
```

Pre debug `eth_test_02` by som dočasne použil všetkých 6:

```text
LED0 = SYS_CLK heartbeat
LED1 = PHY reset released
LED2 = raw ETH_RXDV activity
LED3 = ipreceive.data_receive pulse stretched
LED4 = tx_start_w pulse stretched
LED5 = raw ETH_TXEN activity
```

Tým hneď zistíš:

```text
LED2 bliká, LED3 nie:
  fyzicky niečo prichádza, ale ipreceive neuznal paket

LED3 bliká, LED4 nie:
  parser skončil, ale RX->TX/echo pipeline zlyhala

LED4 bliká, LED5 nie:
  echo pipeline spustila TX, ale ipsend nevysiela

LED5 bliká, tcpdump nič:
  fyzická TX/PHY/clock/link vrstva problém
```

Toto je oveľa lepšia diagnostika než iba RXDV/TXEN.

---

## Krok 4 — overiť skutočný PHY link speed

Status to už navrhuje a súhlasím.

Na PC:

```bash
ethtool enp0s20f0u4u1
```

Očakávané:

```text
Speed: 1000Mb/s
Duplex: Full
Link detected: yes
```

Ak je link 100 Mbps, tento dizajn s `ETH_GTX_CLK = 125 MHz` nemusí byť správny pre aktuálny režim PHY. Vtedy by bolo treba podporovať 10/100 cez `ETH_TXCLK`/MII režim alebo vynútiť 1G link.

Ak `eth_test` fungoval na rovnakom PC/adaptéri/kábli, speed mismatch je menej pravdepodobný, ale stále ho treba overiť.

---

## Krok 5 — potvrdiť TX fyzicky nezávisle od RX

Aktuálny RTL má:

```systemverilog
.timer_en_i(1'b0)
```

Odporúčam pridať parameter do `ethernet_test_echo`:

```systemverilog
parameter bit DEBUG_TIMER_TX_EN = 1'b0
```

a pripojiť:

```systemverilog
.timer_en_i(DEBUG_TIMER_TX_EN)
```

Potom môžeš mať dve zostavy:

```text
DEBUG_TIMER_TX_EN=1:
  overenie, že PHY TX fyzicky viditeľne vysiela

DEBUG_TIMER_TX_EN=0:
  normálny echo režim
```

Ak `DEBUG_TIMER_TX_EN=1` a LED5 bliká, ale `tcpdump` stále nevidí nič, problém nie je echo logika. Je to PHY/TX clock/TX pins/link/MAC frame validita.

---

## Krok 6 — dynamický destination MAC

Po oprave P0 a diagnostike by som pridal dynamický MAC.

Rozšíriť RX metadata z `udp_rx_ram_to_stream`:

```systemverilog
output logic [47:0] udp_rx_src_mac_o
```

A do `ipsend`:

```systemverilog
input logic [47:0] tx_dst_mac_i,
input logic [47:0] tx_src_mac_i
```

Potom echo odpoveď:

```text
dst MAC = MAC pôvodného odosielateľa
src MAC = 00:0A:35:01:FE:C0
```

---

## Krok 7 — upratať drobné warningy

Nie sú blokery, ale oplatí sa ich upratať:

### `local_ip_w` nepoužitý

V `eth_udp_echo_test.sv`:

```systemverilog
wire [31:0] local_ip_w = hw_wdata_w[4*32 +: 32];
```

Použiť ho na filtrovanie:

```systemverilog
if (!promis_w && udp_rx_dst_ip_i != local_ip_w)
  drop
```

alebo ho zatiaľ odstrániť.

### `len_latch_q` nepoužitý

V `udp_tx_stream_to_ram.sv` je `len_latch_q`, ale reálne sa nepoužíva. Odstrániť alebo využiť.

### Drive strength

Doplniť do board packu:

```tcl
ONB_LEDS[*] current strength
ETH_MDIO current strength
```

### `ETH_MDC` stuck at GND

Toto je v strap-only režime zámerné. Nechal by som to, ale zdokumentoval ako:

```text
MDIO disabled, PHY configured by straps
```

---

# 12. Najpravdepodobnejšia príčina súčasného HW failu

Podľa aktuálneho stavu by som príčiny zoradil takto:

## Najpravdepodobnejšie

```text
1. data_receive_o bug v ipreceive
   Simulácia ho maskuje, RTL ho stále obsahuje.
```

## Potom

```text
2. Test neprichádza do MAC filtra / nesedí cieľový MAC/IP/port.
   Musí byť:
   MAC dst = 00:0A:35:01:FE:C0
   IP dst  = 192.168.20.50
   UDP dst = 8080
   static ARP musí byť nastavený.
```

## Ak LED ukáže TX aktivitu, ale tcpdump stále nič

```text
3. fyzická TX vrstva:
   GTX_CLK non-dedicated routing
   link speed nie je 1G
   PHY nie je v GMII 1G režime
   TXD/TXEN/GTX timing
```

## Menej pravdepodobné, ale treba opraviť

```text
4. broadcast destination MAC v TX odpovedi
```

Tcpdump by broadcast rámec videl, takže to nevysvetľuje „nula prichádzajúcich“, ale je to nekorektné pre finálny echo server.

---

# Odporúčaný najbližší pracovný plán

## Iterácia A — opraviť logický blocker

1. Opraviť `data_receive_o` na jednocykový pulse.
2. Pridať `tb_ipreceive_data_receive_pulse.sv`.
3. Upraviť `tb_udp_echo_path.sv`, aby aspoň jedna verzia testu nepoužívala `force dut.ipr_data_receive_w`.
4. Spustiť:

   ```bash
   make -C sim regression
   ```

## Iterácia B — pridať plný GMII test

1. Pridať `tb_ethernet_test_echo_gmii_packet.sv`.
2. Poslať skutočný RX GMII frame.
3. Overiť celý TX frame bajt po bajte vrátane paddingu a FCS.

## Iterácia C — HW diagnostika

1. Rozšíriť LED na 6 signálov:

   ```text
   heartbeat, reset, RXDV, ipreceive_done, tx_start, TXEN
   ```
2. Overiť `ethtool`.
3. Skúsiť `DEBUG_TIMER_TX_EN=1`.
4. Ak TXEN bliká, ale tcpdump nič, riešiť GTX_CLK/link/PHY.

## Iterácia D — korektnosť echo servera

1. Preniesť source MAC do TX domény.
2. Pridať dynamický destination MAC do `ipsend`.
3. Použiť `LOCAL_IP` register na IP filter.
4. Neskôr pridať ARP responder alebo aspoň ARP reply pre statickejší bring-up bez manuálneho `arp -s`.

---

## Finálny záver

Aktuálny `eth_test_02` už nie je v stave „timing fail“ ani „runt frame“. Tieto veci sú opravené.

Aktuálny hlavný problém je, že **simulácia stále obchádza skutočný RX parser** a **skutočný RX parser má stále chybný `data_receive_o` pulse**.

Preto by som teraz neriešil ďalšie veľké refaktory. Najprv opraviť `ipreceive`, pridať test na `data_receive_o` a plný GMII integračný test. Až potom má zmysel pokračovať s HW debugom PHY/TX vrstvy.
