Áno, presne toto by som pridal do `eth_test_03` ako **dva smerové integračné testy MAC vrstvy**:

```text
1. stream -> gmii_tx_mac -> GMII slučka -> gmii_rx_mac -> stream
2. GMII RX -> gmii_rx_mac -> stream -> gmii_tx_mac -> GMII TX
```

Tieto testy sú veľmi dôležité, lebo overia MAC vrstvu nezávisle od IPv4/UDP aplikácie.

---

# 1. Test A: `stream -> tx -> rx -> stream`

Toto je základný **MAC loopback test**.

## Cieľ

Overiť, že ak do TX MAC pošleš stream payload, tak TX MAC vytvorí korektný Ethernet rámec:

```text
preamble
SFD
Ethernet header
payload
padding
FCS
IFG
```

a RX MAC ho vie znova prijať a vrátiť ako stream.

## Bloková schéma

```text
testbench stream source
        |
        v
  gmii_tx_mac
        |
        | gmii_txd/gmii_tx_en/gmii_tx_er
        v
  gmii_rx_mac
        |
        v
testbench stream sink / scoreboard
```

V testbenchi jednoducho prepojíš:

```systemverilog
assign rx_dv  = tx_en;
assign rx_er  = tx_er;
assign rx_data = tx_data;
```

alebo s jedným oneskorovacím registrom:

```systemverilog
always_ff @(posedge clk) begin
  rx_dv_q   <= tx_en;
  rx_er_q   <= tx_er;
  rx_data_q <= tx_data;
end
```

Tým simuluješ ideálnu GMII slučku.

---

## Čo má test overiť

### Vstup do TX MAC

Metadata:

```text
dst_mac    = DE:AD:BE:EF:12:34
src_mac    = 00:0A:35:01:FE:C0
ethertype  = 08:00
payload    = "HELLO"
```

TX MAC dostane payload stream:

```text
48 45 4C 4C 4F
```

a `tx_payload_len_i = 5`.

### Očakávaný výstup z RX MAC

RX MAC by mal vrátiť Ethernet frame stream **bez preambuly a SFD**:

```text
DE AD BE EF 12 34
00 0A 35 01 FE C0
08 00
48 45 4C 4C 4F
00 00 00 ... 00   // padding do 60 bajtov bez FCS
```

Otázka: má RX MAC púšťať FCS von alebo nie?

Pre knižnicu odporúčam túto politiku:

```text
gmii_rx_mac výstup = Ethernet frame bez preambuly/SFD a bez FCS
```

Teda RX MAC má odstrániť:

```text
7x55 + D5
FCS 4 bajty
```

a von poslať len:

```text
Ethernet header + payload + padding
```

Ak zatiaľ RX MAC FCS neodstraňuje, urob dočasne test podľa aktuálneho správania, ale cieľový stav by mal byť: **FCS sa do streamu nepúšťa**.

---

## Názov testu

```text
sim/mac/tb_stream_tx_rx_stream.sv
```

alebo:

```text
sim/integration/tb_mac_stream_tx_rx_stream.sv
```

---

# 2. Test B: `rx -> stream -> tx`

Toto je opačný smer: overí, že rámec prijatý z GMII sa cez stream spracuje a znova vyšle.

## Cieľ

Overiť, že RX MAC vie prijať reálny GMII frame a že výstupný stream sa dá priamo alebo cez jednoduchý pass-through modul poslať do TX MAC.

## Bloková schéma

```text
testbench GMII RX frame driver
        |
        v
  gmii_rx_mac
        |
        | stream
        v
  stream_pass_through / optional FIFO
        |
        v
  gmii_tx_mac
        |
        v
testbench GMII TX monitor / scoreboard
```

Pre prvý test môže byť `stream_pass_through` len jednoduché prepojenie:

```systemverilog
assign tx_s_axis_tdata  = rx_m_axis_tdata;
assign tx_s_axis_tvalid = rx_m_axis_tvalid;
assign rx_m_axis_tready = tx_s_axis_tready;
assign tx_s_axis_tlast  = rx_m_axis_tlast;
```

Ale pozor: TX MAC potrebuje aj metadata:

```text
dst_mac
src_mac
ethertype
payload_len
```

Ak TX MAC očakáva Ethernet payload a header metadata zvlášť, potom výstup z RX MAC musí ísť najprv cez `eth_header_parser`.

Preto sú možné dve verzie testu.

---

# 3. Dve úrovne testu B

## B1: raw frame replay test

V tejto verzii `gmii_tx_mac` nevkladá nový Ethernet header. Dostane celý Ethernet frame ako payload? Toto by som **nepreferoval**, lebo to mieša vrstvy.

## B2: správny vrstvený test

Lepšia verzia:

```text
GMII RX frame
  -> gmii_rx_mac
  -> eth_header_parser
  -> payload stream
  -> gmii_tx_mac s metadata z parsera
  -> GMII TX frame
```

Teda:

```text
rx -> stream -> parser -> tx
```

Pre úplný „rx-stream-tx“ test by som použil práve túto verziu.

---

## B2 bloková schéma

```text
GMII RX driver
   |
   v
gmii_rx_mac
   |
   v
eth_header_parser
   |                         metadata:
   |                         dst_mac/src_mac/ethertype
   v
payload stream --------------+
                             |
                             v
                       gmii_tx_mac
                             |
                             v
                      GMII TX monitor
```

Na začiatok môže TX poslať rovnaký frame späť:

```text
TX dst_mac = RX dst_mac
TX src_mac = RX src_mac
ethertype  = RX ethertype
payload    = RX payload
```

Neskôr pre echo:

```text
TX dst_mac = RX src_mac
TX src_mac = RX dst_mac
```

---

# 4. Test A detail: `tb_stream_tx_rx_stream.sv`

## Stimulus

```systemverilog
byte unsigned payload[$] = '{
  8'h48, 8'h45, 8'h4C, 8'h4C, 8'h4F
};
```

Spustenie TX:

```systemverilog
tx_start_i       <= 1'b1;
tx_dst_mac_i     <= 48'hDEADBEEF1234;
tx_src_mac_i     <= 48'h000A3501FEC0;
tx_ethertype_i   <= 16'h0800;
tx_payload_len_i <= payload.size();
```

Stream driver:

```systemverilog
task automatic send_axis_payload(input byte unsigned data[$]);
  foreach (data[i]) begin
    do begin
      @(posedge clk);
    end while (!s_axis_tready);

    s_axis_tdata  <= data[i];
    s_axis_tvalid <= 1'b1;
    s_axis_tlast  <= (i == data.size()-1);

    @(posedge clk);
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
  end
endtask
```

Pre `gmii_tx_mac` by som však preferoval plynulý stream bez bublín. Osobitný test s bublinami nech je samostatný.

---

## Scoreboard

Očakávaný RX stream:

```text
Ethernet header:
DE AD BE EF 12 34
00 0A 35 01 FE C0
08 00

Payload:
48 45 4C 4C 4F

Padding:
41 bajtov? Pozor podľa vrstvy.
```

Tu je dôležitý detail:

Ak `gmii_tx_mac` dostane `tx_payload_len_i = 5`, potom Ethernet frame bez FCS je:

```text
14 + 5 = 19
```

Minimum je 60, takže padding je:

```text
60 - 19 = 41 bajtov
```

Ak testuješ čistú MAC vrstvu, payload je len `"HELLO"`, nie celý IPv4 packet. Preto padding je 41 bajtov.

Ak chceš simulovať IPv4/UDP HELLO, potom payload pre `gmii_tx_mac` musí byť celý IPv4 packet dĺžky 33 bajtov:

```text
20 IP + 8 UDP + 5 HELLO = 33
padding = 60 - (14 + 33) = 13
```

Pre MAC unit/integration test je dobré mať oba prípady:

```text
T1 MAC payload HELLO      -> padding 41
T2 IPv4/UDP payload 33 B  -> padding 13
```

---

# 5. Test B detail: `tb_rx_stream_tx.sv`

## Stimulus GMII RX frame

Pošli kompletný GMII frame:

```text
55 55 55 55 55 55 55 D5
DE AD BE EF 12 34
00 0A 35 01 FE C0
08 00
48 45 4C 4C 4F
41x 00 padding
FCS
```

FCS vypočítaj v testbench funkcii.

## RX MAC očakávanie

RX MAC má vyprodukovať stream:

```text
DE AD BE EF 12 34
00 0A 35 01 FE C0
08 00
48 45 4C 4C 4F
41x 00
```

bez FCS.

## Eth parser

`eth_header_parser` z toho vyberie:

```text
dst_mac = DE:AD:BE:EF:12:34
src_mac = 00:0A:35:01:FE:C0
ethertype = 08:00
```

a payload stream:

```text
48 45 4C 4C 4F
41x 00
```

Tu je ale ďalší dôležitý detail: parser nevie rozlíšiť payload od paddingu, ak nemá vyššiu vrstvu. Ethernet header s EtherType `0800` neobsahuje dĺžku payloadu. Dĺžku vie až IPv4 parser.

Preto ak chceš `rx -> stream -> tx` na úrovni čistej L2, TX znovu vyšle aj padding ako súčasť payloadu. To je v poriadku pre raw frame replay test, ale nie pre UDP echo.

Pre správny UDP echo test potrebuješ:

```text
gmii_rx_mac
 -> eth_header_parser
 -> ipv4_header_parser
 -> udp_header_parser
 -> udp_echo_app
 -> udp/ip/eth builders
 -> gmii_tx_mac
```

---

# 6. Dôležité rozlíšenie testov

Navrhujem tri rôzne integračné úrovne.

## Úroveň 1: MAC loopback

```text
stream -> gmii_tx_mac -> gmii_rx_mac -> stream
```

Overuje iba MAC TX/RX:

```text
preamble/SFD
padding
FCS
IFG
RX stripping
```

Nerieši IPv4/UDP.

## Úroveň 2: L2 replay

```text
GMII RX -> gmii_rx_mac -> eth_header_parser -> gmii_tx_mac -> GMII TX
```

Overuje:

```text
RX MAC
Ethernet header parse
TX MAC
```

Ale ešte stále nie je UDP echo.

## Úroveň 3: UDP echo full path

```text
GMII RX
 -> gmii_rx_mac
 -> eth_header_parser
 -> ipv4_header_parser
 -> udp_header_parser
 -> udp_echo_app
 -> udp_header_builder
 -> ipv4_header_builder
 -> gmii_tx_mac
 -> GMII TX
```

Toto je cieľ pre `eth_test_03`.

---

# 7. Konkrétne testbench súbory

Pridal by som:

```text
sim/integration/tb_mac_stream_tx_rx_stream.sv
sim/integration/tb_mac_rx_stream_tx.sv
sim/integration/tb_l2_rx_stream_tx_replay.sv
sim/integration/tb_udp_echo_full_path.sv
```

## `tb_mac_stream_tx_rx_stream.sv`

Testuje:

```text
AXIS payload -> gmii_tx_mac -> gmii_rx_mac -> AXIS frame
```

Scoreboard:

```text
očakáva Ethernet header + payload + padding bez FCS
```

## `tb_mac_rx_stream_tx.sv`

Testuje:

```text
GMII frame -> gmii_rx_mac -> gmii_tx_mac
```

Toto je raw replay test. Buď TX MAC musí vedieť prijať celý Ethernet frame ako payload, alebo medzi RX a TX vložíš parser/header metadata.

Pre čistotu by som ho nazval radšej:

```text
tb_l2_rx_stream_tx_replay.sv
```

## `tb_l2_rx_stream_tx_replay.sv`

Testuje:

```text
GMII RX frame
 -> gmii_rx_mac
 -> eth_header_parser
 -> gmii_tx_mac
 -> GMII TX frame
```

Scoreboard porovná TX frame s očakávaným frame.

## `tb_udp_echo_full_path.sv`

Toto je cieľový test:

```text
UDP request -> UDP response
```

---

# 8. Potrebné helper funkcie v TB

V spoločnom TB package by som mal:

```systemverilog
function automatic void push_byte(ref byte unsigned q[$], input byte unsigned b);
  q.push_back(b);
endfunction
```

```systemverilog
function automatic logic [31:0] crc32_eth_bytes(input byte unsigned data[$]);
```

```systemverilog
function automatic void append_fcs(ref byte unsigned frame[$]);
  logic [31:0] fcs;
  begin
    fcs = crc32_eth_bytes(frame);
    frame.push_back(fcs[7:0]);
    frame.push_back(fcs[15:8]);
    frame.push_back(fcs[23:16]);
    frame.push_back(fcs[31:24]);
  end
endfunction
```

```systemverilog
function automatic void append_preamble(ref byte unsigned gmii[$]);
  repeat (7) gmii.push_back(8'h55);
  gmii.push_back(8'hD5);
endfunction
```

```systemverilog
function automatic int eth_padding_len(input int frame_no_fcs_len);
  if (frame_no_fcs_len < 60)
    return 60 - frame_no_fcs_len;
  else
    return 0;
endfunction
```

Scoreboard:

```systemverilog
task automatic compare_bytes(
  input string name,
  input byte unsigned got[$],
  input byte unsigned exp[$]
);
  if (got.size() != exp.size()) begin
    $fatal(1, "%s length mismatch got=%0d exp=%0d",
           name, got.size(), exp.size());
  end

  foreach (exp[i]) begin
    if (got[i] !== exp[i]) begin
      $fatal(1, "%s mismatch byte %0d got=%02x exp=%02x",
             name, i, got[i], exp[i]);
    end
  end

  $display("PASS %s: %0d bytes matched", name, exp.size());
endtask
```

---

# 9. Čo treba upraviť v RTL, aby tieto testy dávali zmysel

## `gmii_rx_mac`

Musí mať jasnú politiku:

```text
výstup = Ethernet frame bez preambuly/SFD a bez FCS
```

alebo dočasne:

```text
výstup = Ethernet frame bez preambuly/SFD vrátane FCS
```

Ja odporúčam bez FCS.

Na to potrebuješ 4-bajtový skid buffer, aby posledné 4 bajty nešli von.

Ak zatiaľ nechceš FCS strip, označ to parametrom:

```systemverilog
parameter bit STRIP_FCS = 1'b0
```

a testy urob pre aktuálny režim. Ale cieľovo:

```systemverilog
.STRIP_FCS(1'b1)
```

---

## `gmii_tx_mac`

Musí mať vstupnú politiku:

```text
s_axis stream = Ethernet payload bez L2 headera
metadata = dst_mac/src_mac/ethertype/payload_len
```

Potom MAC vie pridať header, padding a FCS.

---

## `eth_header_parser`

Musí z výstupu RX MAC odstrániť 14-bajtový Ethernet header a von poslať payload stream.

Tým sa pripraví na `rx -> stream -> tx`:

```text
RX MAC frame stream -> eth_header_parser -> payload stream + metadata -> TX MAC
```

---

# 10. Odporúčané testy v poradí

Najprv:

```text
1. tb_gmii_tx_mac_min_frame
2. tb_gmii_rx_mac_with_preamble
3. tb_mac_stream_tx_rx_stream
```

Potom:

```text
4. tb_eth_header_parser
5. tb_l2_rx_stream_tx_replay
```

Až potom:

```text
6. tb_ipv4_header_parser
7. tb_udp_header_parser
8. tb_udp_echo_full_path
```

---

## Zhrnutie

Áno, tieto dva testy sú veľmi dobrý nápad a určite ich treba mať:

```text
stream -> tx -> rx -> stream
rx -> stream -> tx
```

Len ich treba rozdeliť podľa vrstvy:

```text
MAC loopback:
  stream -> gmii_tx_mac -> gmii_rx_mac -> stream

L2 replay:
  GMII RX -> gmii_rx_mac -> eth_header_parser -> gmii_tx_mac -> GMII TX

UDP echo:
  GMII RX -> MAC -> ETH -> IPv4 -> UDP -> echo -> UDP/IP/ETH -> MAC -> GMII TX
```

Najväčší prínos bude, že keď full UDP echo zlyhá, hneď budeš vedieť, či je chyba v MAC TX/RX, L2 parseri, IPv4/UDP vrstve alebo aplikácii.
