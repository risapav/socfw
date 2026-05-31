Súhlasím s týmto rozdelením. Teraz už máš dve jasne oddelené vetvy práce:

```text
A) Timing fail v ETH_RXC — reálny, ale nie príčina MAC filter failu.
B) MAC filter fail v HW — treba zmerať, aký header FPGA reálne vidí.
```

Najdôležitejšie: **neprepájaj tieto dve veci dokopy**. Timing rieš ako P1 pre stabilný finálny build, ale MAC filter problém teraz rieš ako P0 cez priamy HW capture.

---

# 1. Timing problém: `udp_ipv4_tx_builder`

Timing report je jednoznačný:

```text
partial_csum_q[1] -> hdr_q[10][5]                      -0.824 ns
rx_meta_q.dst_ip[16] -> partial_csum_q[9]               -0.620 ns
rx_meta_q.payload_len[0] -> meta_wr_data_q[3] enable    -0.581 ns
```

To znamená, že `udp_ipv4_tx_builder` stále robí príliš veľa v jednom ETH_RXC cykle. Hlavne:

```text
partial checksum fold
+ doplnenie IPv4 checksum bajtov do hdr_q[10]/hdr_q[11]
+ závislosť od rx_meta_q/payload_len
```

## Odporúčaný fix

Rozdeľ `udp_ipv4_tx_builder` na viac prípravných stavov. Namiesto:

```text
ST_IDLE -> ST_PREP -> ST_HDR
```

by som použil:

```text
ST_IDLE
ST_LEN
ST_CSUM0
ST_CSUM1
ST_HDR
ST_PAYLOAD
```

### Navrhovaná pipeline

```text
ST_IDLE:
  latch tx_meta_i
  latch payload_len
  vypočítaj total_len_q = 28 + payload_len
  vypočítaj udp_len_q   = 8 + payload_len

ST_LEN:
  priprav 16-bitové slová IPv4 headera bez checksumu
  partial_sum0_q = word0 + word1 + word2 + word3

ST_CSUM0:
  partial_sum1_q = partial_sum0_q + word4 + word5 + word6 + word7 + word8 + word9

ST_CSUM1:
  fold checksum
  ipv4_csum_q <= ~folded_sum

ST_HDR:
  zapisuj/emituj hdr_q[0:27] už len z registrovaných hodnôt
```

Hlavné pravidlo: **`hdr_q[10]` a `hdr_q[11]` nesmú byť priamo závislé od hlbokého checksum výpočtu v tom istom cykle.** Najprv zaregistruj `ipv4_csum_q`, až v ďalšom cykle ho vlož do `hdr_q`.

Napríklad:

```systemverilog
ST_CSUM1: begin
  ipv4_csum_q <= ~fold2_w[15:0];
  state_q     <= ST_FILL_HDR;
end

ST_FILL_HDR: begin
  hdr_q[10] <= ipv4_csum_q[15:8];
  hdr_q[11] <= ipv4_csum_q[7:0];
  state_q   <= ST_HDR;
end
```

Tým odstrániš najhoršiu cestu:

```text
partial_csum_q -> hdr_q[10]
```

---

# 2. Timing cesta do `meta_wr_data_q`

Tretia cesta:

```text
udp_echo_app|rx_meta_q.payload_len[0] -> meta_wr_data_q[3] enable path
```

vyzerá ako problém v commit logike packetu/metadát. Pravdepodobne máš niekde enable odvodený z:

```text
txb_tvalid && txb_tlast && pkt_wr_ready && meta_wr_ready
```

a niektorý z týchto signálov závisí dlhšie od payload length / state.

## Odporúčaný fix

Oddeliť „detekciu konca packetu“ a „zápis meta FIFO“ do dvoch cyklov:

```text
ST_STREAM_PACKET:
  zapisuj packet bytes do pkt_fifo
  keď vidíš posledný byte, nastav commit_pending_q

ST_COMMIT_META:
  zapíš meta_wr_data_q do meta FIFO
  potom späť do IDLE
```

Teda namiesto jedného kombinačného:

```systemverilog
assign meta_wr_valid = txb_tvalid && pkt_wr_ready && txb_tlast;
```

urobiť registrovaný commit:

```systemverilog
always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    commit_pending_q <= 1'b0;
    meta_wr_valid_q  <= 1'b0;
  end else begin
    meta_wr_valid_q <= 1'b0;

    if (txb_fire_w && txb_tlast) begin
      commit_pending_q <= 1'b1;
      meta_wr_data_q   <= {meta_latch_dst_q, meta_latch_src_q};
    end

    if (commit_pending_q && meta_wr_ready) begin
      meta_wr_valid_q  <= 1'b1;
      commit_pending_q <= 1'b0;
    end
  end
end
```

Toto odstráni enable path z payload_len do FIFO write.

---

# 3. MAC filter problém: teraz musíš merať, nie hádať

Tu je dôležité tvoje zistenie:

```text
eth_header_parser sa v timing failujúcich cestách nevyskytuje.
mac_accept_q timing spĺňa.
```

To znamená, že MAC filter problém je takmer určite **dátový problém**, nie timing problém v samotnom porovnaní.

Možnosti:

```text
1. gmii_rx_mac výstup je posunutý o 1 bajt — SFD leak alebo prvý byte stratený.
2. eth_header_parser skladá dst_mac v inom poradí, než si myslíme.
3. FPGA reálne vidí iné RXD bajty než tcpdump na PC.
4. LOCAL_MAC parameter v reálnom build-e nie je ten, ktorý očakávaš.
5. Debug build neprogramuješ tým SOF, ktorý si myslíš.
```

Najlepší ďalší krok je preto nie ďalšia teória, ale **capture prvých bajtov po `gmii_rx_mac`**.

---

# 4. Testovanie podozrenia: SFD ide do streamu

Tvoje podozrenie je dobré. Ak `0xD5` ide do streamu, L2 parser uvidí:

```text
D5 00 0A 35 01 FE ...
```

a MAC compare zlyhá.

## Pridaj test 1: `tb_gmii_rx_mac_sfd_boundary`

Tento test musí overiť samotný RX MAC, ale prísnejšie než doterajší test.

### Stimulus

```text
55 55 55 55 55 55 55 D5
00 0A 35 01 FE C0
E0 4F 43 5B 59 3C
08 00
A1 A2 A3 A4
```

### Očakávanie

Výstup `gmii_rx_mac` musí začínať:

```text
00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00 A1 A2 A3 A4
```

Nie:

```text
D5 00 0A 35 01 FE C0 ...
```

Ani:

```text
0A 35 01 FE C0 E0 ...
```

### Explicitný check

```systemverilog
logic [47:0] got_dst_mac;

got_dst_mac = {
  rx_bytes[0],
  rx_bytes[1],
  rx_bytes[2],
  rx_bytes[3],
  rx_bytes[4],
  rx_bytes[5]
};

case (got_dst_mac)
  48'h000A3501FEC0:
    $display("PASS: dst_mac aligned");

  48'hD5000A3501FE:
    $fatal(1, "FAIL: SFD leaked into output stream");

  48'h0A3501FEC0E0:
    $fatal(1, "FAIL: first destination MAC byte lost");

  default:
    $fatal(1, "FAIL: unexpected dst_mac alignment: %012h", got_dst_mac);
endcase
```

---

## Pridaj test 2: `tb_gmii_rx_to_eth_parser_sfd_align`

Toto je ešte dôležitejšie, lebo testuje presne reálnu reťaz:

```text
gmii_rx_mac -> eth_header_parser
```

### Zapojenie

```text
GMII driver
  -> gmii_rx_mac
  -> eth_header_parser strict local_mac=00:0A:35:01:FE:C0
```

### Očakávanie

```text
hdr_done_pulse   = 1
hdr_accept_pulse = 1
hdr_drop_pulse   = 0
dbg_dst_mac      = 00:0A:35:01:FE:C0
```

Toto je test, ktorý by mal byť v regresii vždy. Ak prejde, ale HW stále dropuje, potom je problém v reálnych RXD dátach alebo v build/top/constraints, nie v RTL logike.

---

# 5. HW debug: vyveď RX stream na J10/J11

Keďže máš J10/J11, najrýchlejší dôkaz je dať na piny výstup hneď za `gmii_rx_mac`.

## Debug bus A — RX MAC output

```text
DBG[7:0]  = rx_axis_tdata
DBG[8]    = rx_axis_tvalid
DBG[9]    = rx_axis_tlast
DBG[10]   = gmii_rx_mac.frame_done
DBG[11]   = eth_header_parser.hdr_done_pulse
DBG[12]   = eth_header_parser.hdr_accept_pulse
DBG[13]   = eth_header_parser.hdr_drop_pulse
DBG[14]   = raw ETH_RXDV
DBG[15]   = ETH_RXER
```

Potom s logic analyzerom očakávaš:

```text
00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00 45 00 ...
```

Ak vidíš:

```text
D5 00 0A 35 01 FE C0 ...
```

potvrdený SFD leak.

Ak vidíš:

```text
0A 35 01 FE C0 E0 ...
```

strácaš prvý byte.

Ak vidíš úplne iné hodnoty, rieš RXD pin mapping alebo dátové chyby.

---

# 6. HW debug: capture `dbg_dst_mac_o`

Druhý debug mód:

```text
DBG[7:0]   = selected captured byte
DBG[11:8]  = byte index
DBG[12]    = dbg_capture_valid
DBG[13]    = dbg_mac_accept
DBG[14]    = hdr_done
DBG[15]    = hdr_drop
```

Rotuj cez:

```text
0..5   = dst_mac
6..11  = src_mac
12..13 = ethertype
```

Očakávaný `dst_mac`:

```text
00 0A 35 01 FE C0
```

Ak capture ukáže správne `dst_mac`, ale `mac_accept=0`, potom je problém v `local_mac_i` v reálnom top-e.

Ak capture ukáže posunuté bajty, rieš RX MAC / SFD / zarovnanie.

---

# 7. Over `LOCAL_MAC` v reálnom build-e

Paralelne by som vyviedol na debug bus aj `LOCAL_MAC`, alebo aspoň pridal compile-time assertion do topu:

```systemverilog
initial begin
  if (LOCAL_MAC !== 48'h000A3501FEC0) begin
    $error("LOCAL_MAC mismatch");
  end
end
```

Quartus initial `$error` nemusí byť použiteľný synteticky, takže praktickejšie:

```systemverilog
localparam logic LOCAL_MAC_OK = (LOCAL_MAC == 48'h000A3501FEC0);
```

a dať ho na LED/debug:

```text
DBG[15] = LOCAL_MAC_OK
```

Lebo ak YAML/generátor parameter neoverrideuje tak, ako čakáš, budeš márne ladiť parser.

---

# 8. Čo spraviť s timingom teraz

Timing `-0.824 ns` v RXC treba opraviť, ale podľa tvojho reportu to nesúvisí s L2 MAC compare. Preto by som paralelizoval:

```text
Vetva A: pridať HW debug capture a nájsť L2 dátový problém.
Vetva B: pipeline udp_ipv4_tx_builder, aby timing prešiel.
```

Poradie pre rýchly HW debug:

```text
1. Pridať debug bus na J10/J11.
2. Overiť prvých 16 bajtov rx_axis_tdata.
3. Popritom pipeline udp_ipv4_tx_builder.
```

Nesnažil by som sa najprv dokonale zavrieť timing a až potom merať L2. L2 problém je teraz dobre izolovaný a debug bus ho môže potvrdiť okamžite.

---

# 9. Ak sa SFD leak potvrdí, typická oprava

V `gmii_rx_mac` je rizikový vzor:

```systemverilog
assign m_axis_tvalid = (state_q == RX_DATA) && dv_q;
assign m_axis_tdata  = rxd_q;
```

Ak `state_q` prejde do `RX_DATA` v cykle po detekcii SFD, ale `rxd_q` ešte drží `D5`, prvý výstup bude `D5`.

Bezpečnejšie je emitovať dáta priamo iba z cyklov, kde bol **aktuálny byte prijatý v stave RX_DATA**, nie predchádzajúci SFD byte.

Princíp:

```systemverilog
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    out_valid_q <= 1'b0;
    state_q     <= RX_IDLE;
  end else begin
    out_valid_q <= 1'b0;

    unique case (state_q)
      RX_PRE: begin
        if (gmii_rx_dv_i && gmii_rxd_i == 8'hD5) begin
          state_q <= RX_DATA;
          // neemitovať D5
        end
      end

      RX_DATA: begin
        if (gmii_rx_dv_i) begin
          out_data_q  <= gmii_rxd_i;
          out_valid_q <= 1'b1;
        end else begin
          state_q <= RX_IDLE;
          frame_done_o <= 1'b1;
        end
      end
    endcase
  end
end
```

Ak potrebuješ `tlast`, pridaj 1-byte hold buffer, ale nedovoľ, aby hold buffer obsahoval SFD ako dátový byte.

---

# 10. Môj odporúčaný najbližší checklist

```text
[ ] Pridať tb_gmii_rx_mac_sfd_boundary.
[ ] Pridať tb_gmii_rx_to_eth_parser_sfd_align.
[ ] Pridať debug bus na J10/J11:
    DBG[7:0]=rx_axis_tdata, DBG[8]=valid, DBG[9]=last, DBG[11..13]=L2 pulses.
[ ] Spraviť HW capture prvých bajtov za gmii_rx_mac.
[ ] Ak bajty sú posunuté, opraviť gmii_rx_mac.
[ ] Ak bajty sú správne, vyviesť captured dbg_dst_mac a LOCAL_MAC_OK.
[ ] Separátne pipeline udp_ipv4_tx_builder checksum fázy, aby ETH_RXC slow slack >= 0.
```

Krátky záver: **áno, testuj najprv SFD boundary a potom priamo `gmii_rx_mac -> eth_header_parser`.** To je najpresnejší spôsob, ako potvrdiť alebo vyvrátiť hypotézu, že `0xD5` posúva MAC header o jeden bajt.
