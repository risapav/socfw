Áno, toto podozrenie je veľmi rozumné. Ak by `gmii_rx_mac` pustil `0xD5` do výstupného streamu, `eth_header_parser` by videl Ethernet header posunutý o 1 bajt:

```text
očakávané:
00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00 ...

ak unikne SFD:
D5 00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 ...
```

Potom by L2 MAC filter samozrejme zlyhal, lebo destination MAC by bol:

```text
D5:00:0A:35:01:FE
```

namiesto:

```text
00:0A:35:01:FE:C0
```

To veľmi dobre sedí na symptóm: `gmii_rx_mac.frame_done` blikne, ale `eth_header_parser.hdr_valid` nie; status presne uvádza, že L1 frame_done prebehlo, ale L2 parser zahadzuje rámce.

## 1. Najdôležitejší nový test: SFD leak test

Pridal by som samostatný unit test:

```text
sim/mac/tb_gmii_rx_mac_sfd_boundary.sv
```

Cieľ: poslať do `gmii_rx_mac` preambulu, SFD a jasne rozpoznateľný Ethernet header. Test musí zlyhať, ak sa na výstupe objaví `0xD5`.

### Stimulus

Použi frame:

```text
55 55 55 55 55 55 55 D5
00 0A 35 01 FE C0
E0 4F 43 5B 59 3C
08 00
A1 A2 A3 A4
```

Výstup `gmii_rx_mac` musí začínať presne:

```text
00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00 A1 A2 A3 A4
```

Zakázané výstupy:

```text
D5 00 0A 35 01 FE C0 ...
55 55 ...
```

### Kritické asserty

```systemverilog
if (rx_bytes[0] !== 8'h00)
  $fatal(1, "SFD leak/shift: first output byte got %02x, expected 00", rx_bytes[0]);

if (rx_bytes[0] === 8'hD5)
  $fatal(1, "SFD byte leaked into output stream");

if (rx_bytes[1] !== 8'h0A ||
    rx_bytes[2] !== 8'h35 ||
    rx_bytes[3] !== 8'h01 ||
    rx_bytes[4] !== 8'hFE ||
    rx_bytes[5] !== 8'hC0)
  $fatal(1, "Destination MAC shifted/corrupted");
```

---

## 2. Test musí vzorkovať rovnako ako reálny downstream

Pôvodné testy môžu prejsť, ak monitor zachytáva signály v inom poradí než downstream logika. Preto test musí mať **skutočný parser za RX MAC**, nie iba testbench monitor.

Pridaj integračný test:

```text
sim/integration/tb_gmii_rx_to_eth_parser_sfd_align.sv
```

Zapojenie:

```text
GMII driver
  -> gmii_rx_mac
  -> eth_header_parser
```

A nastav:

```systemverilog
local_mac_i = 48'h000A3501FEC0
promiscuous_i = 1'b0
accept_broadcast_i = 1'b0
```

Pošli frame s destination MAC:

```text
00:0A:35:01:FE:C0
```

Očakávanie:

```text
eth_header_parser.hdr_accept_pulse_o = 1
eth_header_parser.hdr_drop_pulse_o   = 0
dbg_dst_mac_o = 00:0A:35:01:FE:C0
```

Ak uniká `D5`, parser zachytí:

```text
D5:00:0A:35:01:FE
```

a test spadne na `dbg_dst_mac_o`.

Tento test je dôležitejší než samotný `tb_gmii_rx_mac`, lebo presne simuluje to, čo sa deje v HW: výstup RX MAC používa ďalší synchronný modul.

---

## 3. Pridaj test posunu o ±1 bajt

Spravil by som test, ktorý explicitne rozlíši tri prípady:

```text
PASS:
  00 0A 35 01 FE C0

SFD leak:
  D5 00 0A 35 01 FE

first-byte lost:
  0A 35 01 FE C0 E0
```

V testbenchi:

```systemverilog
function automatic string mac_to_str(input byte unsigned b[6]);
  return $sformatf("%02x:%02x:%02x:%02x:%02x:%02x",
                   b[0], b[1], b[2], b[3], b[4], b[5]);
endfunction
```

Po zachytení prvých 6 bajtov:

```systemverilog
byte unsigned got_dst[6];

for (int i = 0; i < 6; i++)
  got_dst[i] = rx_bytes[i];

if (got_dst == '{8'hD5,8'h00,8'h0A,8'h35,8'h01,8'hFE})
  $fatal(1, "Detected +1 byte shift: SFD leaked as dst_mac[0]");

if (got_dst == '{8'h0A,8'h35,8'h01,8'hFE,8'hC0,8'hE0})
  $fatal(1, "Detected -1 byte shift: first dst_mac byte lost");

if (got_dst != '{8'h00,8'h0A,8'h35,8'h01,8'hFE,8'hC0})
  $fatal(1, "Unexpected dst_mac alignment");
```

SystemVerilog pri porovnávaní unpacked arrays môže byť otravný, takže praktickejšie je poskladať `logic [47:0]`:

```systemverilog
logic [47:0] got_dst_mac;

got_dst_mac = {
  rx_bytes[0], rx_bytes[1], rx_bytes[2],
  rx_bytes[3], rx_bytes[4], rx_bytes[5]
};

case (got_dst_mac)
  48'h000A3501FEC0: $display("PASS: dst_mac aligned");
  48'hD5000A3501FE: $fatal(1, "SFD leaked into dst_mac");
  48'h0A3501FEC0E0: $fatal(1, "first dst byte lost");
  default:          $fatal(1, "dst_mac unexpected: %012h", got_dst_mac);
endcase
```

---

## 4. Test so skutočným PC rámcom z tcpdump

Podľa statusu PC posiela:

```text
000a 3501 fec0 e04f 435b 593c 0800 ...
```

teda:

```text
dst_mac = 00:0a:35:01:fe:c0
src_mac = e0:4f:43:5b:59:3c
ethertype = 0800
```

Tento exact prefix je v statuse uvedený pri tcpdump overení.

Preto urob test s presne týmto headerom:

```text
55 55 55 55 55 55 55 D5
00 0A 35 01 FE C0
E0 4F 43 5B 59 3C
08 00
45 00 ...
```

Výstup parsera musí zachytiť:

```text
dbg_dst_mac = 00:0A:35:01:FE:C0
dbg_src_mac = E0:4F:43:5B:59:3C
dbg_ethertype = 0800
```

Toto priamo prepája simuláciu s tým, čo reálne vidíš cez `tcpdump`.

---

## 5. Test s `RXDV` predčasne aktívnym pred preambulou

V HW môže byť pred frame niekoľko cyklov s `RXDV=0`, potom hneď `55`. Ale pre robustnosť otestuj aj drobný jitter:

```text
idle
RXDV=1, RXD=55
55 55 55 55 55 55 D5
header...
```

A tiež:

```text
idle
RXDV=1, RXD=00   // garbage
RXDV=0
idle
RXDV=1, RXD=55...
```

Očakávanie: parser sa nesmie zaseknúť a po validnom frame musí zarovnať header správne.

Testy:

```text
T1 normal preamble
T2 extra idle pred frame
T3 aborted short preamble, potom valid frame
T4 two frames back-to-back
```

---

## 6. Test RX MAC výstupu s pripojeným `eth_header_parser` a promiscuous=0

Toto je najviac relevantné k HW chybe.

### Testbench zapojenie

```systemverilog
gmii_rx_mac #(
  .EXPECT_PREAMBLE(1'b1)
) u_rx (
  .clk_i(clk),
  .rst_ni(rst_n),

  .gmii_rxd_i(rx_data),
  .gmii_rx_dv_i(rx_dv),
  .gmii_rx_er_i(1'b0),

  .m_axis_tdata(rx_axis_tdata),
  .m_axis_tvalid(rx_axis_tvalid),
  .m_axis_tready(1'b1),
  .m_axis_tlast(rx_axis_tlast),
  .m_axis_tuser(rx_axis_tuser),

  .frame_done_o(rx_frame_done)
);

eth_header_parser u_l2 (
  .clk_i(clk),
  .rst_ni(rst_n),

  .local_mac_i(48'h000A3501FEC0),
  .accept_broadcast_i(1'b0),
  .promiscuous_i(1'b0),

  .s_axis_tdata(rx_axis_tdata),
  .s_axis_tvalid(rx_axis_tvalid),
  .s_axis_tready(),
  .s_axis_tlast(rx_axis_tlast),
  .s_axis_tuser(rx_axis_tuser),

  .m_axis_tdata(),
  .m_axis_tvalid(),
  .m_axis_tready(1'b1),
  .m_axis_tlast(),
  .m_axis_tuser(),

  .hdr_done_pulse_o(hdr_done),
  .hdr_accept_pulse_o(hdr_accept),
  .hdr_drop_pulse_o(hdr_drop),
  .dbg_dst_mac_o(dbg_dst_mac),
  .dbg_mac_accept_o(dbg_mac_accept)
);
```

### Očakávanie

```systemverilog
wait (rx_frame_done);
repeat (5) @(posedge clk);

if (!hdr_done)
  $fatal(1, "L2 parser did not complete header");

if (!hdr_accept)
  $fatal(1, "L2 parser did not accept MAC, dbg_dst_mac=%012h", dbg_dst_mac);

if (dbg_dst_mac !== 48'h000A3501FEC0)
  $fatal(1, "L2 parser captured shifted dst_mac=%012h", dbg_dst_mac);
```

Pozor: `hdr_done` a `hdr_accept` sú pulzy, takže ich v testbenchy buď latchni, alebo čakaj na event:

```systemverilog
logic hdr_done_seen, hdr_accept_seen, hdr_drop_seen;

always_ff @(posedge clk) begin
  if (!rst_n) begin
    hdr_done_seen   <= 1'b0;
    hdr_accept_seen <= 1'b0;
    hdr_drop_seen   <= 1'b0;
  end else begin
    if (hdr_done)   hdr_done_seen   <= 1'b1;
    if (hdr_accept) hdr_accept_seen <= 1'b1;
    if (hdr_drop)   hdr_drop_seen   <= 1'b1;
  end
end
```

---

## 7. Verilator test: jednoduchší a tvrdší

Pre túto konkrétnu chybu by som preferoval Verilator/C++ test, lebo byte arrays sa kontrolujú pohodlnejšie.

Test:

```text
tb_gmii_rx_l2_align.cpp
```

Zbiera:

```text
rx_axis_tdata pri rx_axis_tvalid
dbg_dst_mac z eth_header_parser
hdr_accept/drop
```

A vypíše:

```text
first 16 output bytes:
D5 00 0A 35 01 FE C0 ...
```

ak je problém.

Výhoda: presne uvidíš posun.

---

## 8. HW test cez J10/J11: capture prvých 16 RX MAC output bajtov

Keďže máš J10/J11, najrýchlejšie potvrdenie na FPGA je vyviesť výstup **hneď za `gmii_rx_mac`**, nie až za parser.

### Debug bus

```text
DBG[7:0]  = rx_axis_tdata
DBG[8]    = rx_axis_tvalid
DBG[9]    = rx_axis_tlast
DBG[10]   = frame_done
DBG[11]   = hdr_done
DBG[12]   = hdr_accept
DBG[13]   = hdr_drop
DBG[14]   = rx_dv
DBG[15]   = rx_er
```

S logic analyzerom uvidíš prvé bajty streamu. Pri správnom zarovnaní:

```text
00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00 45 00 ...
```

Pri SFD leaku:

```text
D5 00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00 45 ...
```

Toto je najrýchlejší dôkaz v HW.

---

## 9. Ak sa potvrdí SFD leak, oprava v `gmii_rx_mac`

Robustný RX FSM by mal mať jasný medzistav po SFD:

```text
RX_IDLE
RX_PREAMBLE
RX_SFD
RX_DATA
```

Ale kritické je, aby po detekcii `D5` nebol `D5` uložený do výstupného hold registru ako dátový bajt.

Bezpečný princíp:

```systemverilog
case (state_q)
  RX_PREAMBLE: begin
    if (gmii_rx_dv_i && gmii_rxd_i == 8'hD5) begin
      state_q <= RX_DATA;
      // NEemitovať gmii_rxd_i v tomto cykle
      out_valid_q <= 1'b0;
    end
  end

  RX_DATA: begin
    if (gmii_rx_dv_i) begin
      out_data_q  <= gmii_rxd_i;
      out_valid_q <= 1'b1;
    end else begin
      out_valid_q <= 1'b0;
      frame_done_o <= 1'b1;
      state_q <= RX_IDLE;
    end
  end
endcase
```

Tým je `D5` len prechodová značka, nikdy nie payload.

Ak používaš oneskorený `rxd_q/dv_q`, musíš si dať pozor, aby `m_axis_tvalid` v prvom `RX_DATA` cykle neemitoval predchádzajúci `rxd_q = D5`.

To je typický zdroj tejto chyby.

---

## 10. Najdôležitejšie testy, ktoré by som pridal do regresie

V tomto poradí:

```text
1. tb_gmii_rx_mac_sfd_boundary
   GMII RX -> RX stream, over prvý byte != D5

2. tb_gmii_rx_to_eth_parser_sfd_align
   GMII RX -> gmii_rx_mac -> eth_header_parser, strict MAC filter musí prijať frame

3. tb_gmii_rx_mac_abort_then_valid
   krátka/rozbitá preambula, potom valid frame

4. tb_gmii_rx_mac_back_to_back
   dva frame za sebou, oba správne zarovnané

5. tb_hw_like_udp_prefix
   presný Ethernet prefix z tcpdump:
   00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00
```

---

## Krátky záver

Tvoje podozrenie je veľmi dobré. Ak `0xD5` uniká do streamu, vysvetľuje to presne:

```text
gmii_rx_mac frame_done bliká
eth_header_parser strict MAC filter dropuje
promiscuous L2 pustí frame ďalej
```

Prvý test, ktorý by som napísal, je `tb_gmii_rx_to_eth_parser_sfd_align`: nie iba samostatný RX MAC monitor, ale priamo RX MAC napojený na `eth_header_parser` so strict `LOCAL_MAC`. Ten najlepšie simuluje reálnu chybu v HW a okamžite ukáže, či `dbg_dst_mac_o` je `00:0A:35:01:FE:C0` alebo `D5:00:0A:35:01:FE`.
