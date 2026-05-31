Áno, to je veľmi užitočné. V tejto fáze by som určite využil J10/J11 ako **dočasný debug bus**, nie iba 6 onboard LED. Teraz potrebuješ vidieť viac než len „RX prišiel / UDP accept neprišiel“.

Najlepší ďalší krok: pridať do `eth_test_03` samostatný debug výstup, napríklad:

```systemverilog
output logic [15:0] dbg_o
```

a namapovať ho na piny J10/J11. Potom môžeš v hardvéri sledovať viac signálov naraz logickou sondou, lacným logic analyzerom, alebo aj LEDkami cez odpory.

---

## 1. Čo by som vyviedol na J10/J11

Pre aktuálny problém by som debug bus rozdelil takto:

```text
dbg_o[0]  = raw ETH_RXDV
dbg_o[1]  = gmii_rx_mac.frame_start
dbg_o[2]  = gmii_rx_mac.frame_done
dbg_o[3]  = gmii_rx_mac.frame_error / rx_er_seen

dbg_o[4]  = eth_header_parser.hdr_done
dbg_o[5]  = eth_header_parser.mac_accept
dbg_o[6]  = eth_header_parser.hdr_accept_pulse
dbg_o[7]  = eth_header_parser.hdr_drop_pulse

dbg_o[8]  = ipv4_header_parser.hdr_valid
dbg_o[9]  = ipv4_header_parser.drop
dbg_o[10] = udp_header_parser.hdr_valid
dbg_o[11] = udp_header_parser.drop

dbg_o[12] = rx_meta_valid
dbg_o[13] = tx_packet_commit / tx_meta_fifo_wr
dbg_o[14] = gmii_tx_mac.tx_busy
dbg_o[15] = raw ETH_TXEN
```

Toto ti okamžite ukáže, kde sa rámec stratí.

Pri aktuálnom stave očakávam niečo takéto:

```text
dbg[0] bliká  = RXDV fyzicky prichádza
dbg[2] bliká  = gmii_rx_mac dokončil frame
dbg[4] bliká  = L2 parser videl celý header
dbg[5] nebliká = MAC filter nesedí
dbg[7] bliká  = L2 drop
```

Ak `dbg[4]` neblikne, parser nedostáva správny stream z RX MAC. Ak `dbg[4]` blikne a `dbg[5]` nie, treba zistiť, aký `dst_mac` reálne vidíš.

---

## 2. Ešte lepšie: vyviesť zachytený destination MAC

Len pulzy nestačia. Potrebuješ zistiť, či FPGA vidí správnu MAC:

```text
očakávané dst_mac = 00:0A:35:01:FE:C0
```

Keďže 48-bit MAC sa na LED nezmestí, použil by som J10/J11 ako 8-bit alebo 16-bit debug bus s multiplexom.

### Variant A — 8-bit debug byte bus

```systemverilog
output logic [7:0] dbg_data_o,
output logic [3:0] dbg_sel_o,
output logic       dbg_valid_o
```

Mapovanie:

```text
dbg_sel = 0  -> first dst_mac[47:40]
dbg_sel = 1  -> first dst_mac[39:32]
dbg_sel = 2  -> first dst_mac[31:24]
dbg_sel = 3  -> first dst_mac[23:16]
dbg_sel = 4  -> first dst_mac[15:8]
dbg_sel = 5  -> first dst_mac[7:0]
dbg_sel = 6  -> first src_mac[47:40]
...
dbg_sel = 12 -> ethertype[15:8]
dbg_sel = 13 -> ethertype[7:0]
```

Potom na J10/J11 vyvedieš:

```text
J debug[7:0]  = dbg_data_o
J debug[11:8] = dbg_sel_o
J debug[12]   = dbg_valid_o
J debug[13]   = mac_accept
J debug[14]   = hdr_done
J debug[15]   = hdr_drop
```

Toto je veľmi praktické s logic analyzerom.

---

## 3. Modul `eth_debug_bus`

Spravil by som jednoduchý modul:

```systemverilog
module eth_debug_bus #(
  parameter int CLK_DIV_WIDTH = 24
)(
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic [47:0] dbg_dst_mac_i,
  input  wire logic [47:0] dbg_src_mac_i,
  input  wire logic [15:0] dbg_ethertype_i,
  input  wire logic        dbg_capture_valid_i,

  input  wire logic [15:0] dbg_flags_i,

  output      logic [15:0] dbg_o
);

  logic [CLK_DIV_WIDTH-1:0] div_q;
  logic [3:0] sel_q;
  logic [7:0] byte_w;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      div_q <= '0;
      sel_q <= '0;
    end else begin
      div_q <= div_q + 1'b1;
      if (div_q == '0) begin
        sel_q <= sel_q + 1'b1;
      end
    end
  end

  always_comb begin
    unique case (sel_q)
      4'd0:  byte_w = dbg_dst_mac_i[47:40];
      4'd1:  byte_w = dbg_dst_mac_i[39:32];
      4'd2:  byte_w = dbg_dst_mac_i[31:24];
      4'd3:  byte_w = dbg_dst_mac_i[23:16];
      4'd4:  byte_w = dbg_dst_mac_i[15:8];
      4'd5:  byte_w = dbg_dst_mac_i[7:0];

      4'd6:  byte_w = dbg_src_mac_i[47:40];
      4'd7:  byte_w = dbg_src_mac_i[39:32];
      4'd8:  byte_w = dbg_src_mac_i[31:24];
      4'd9:  byte_w = dbg_src_mac_i[23:16];
      4'd10: byte_w = dbg_src_mac_i[15:8];
      4'd11: byte_w = dbg_src_mac_i[7:0];

      4'd12: byte_w = dbg_ethertype_i[15:8];
      4'd13: byte_w = dbg_ethertype_i[7:0];

      default: byte_w = 8'h00;
    endcase
  end

  always_comb begin
    dbg_o[7:0]   = byte_w;
    dbg_o[11:8]  = sel_q;
    dbg_o[12]    = dbg_capture_valid_i;
    dbg_o[15:13] = dbg_flags_i[2:0];
  end

endmodule
```

Tým na J10/J11 vieš pozerať rotujúce bajty prvej zachytenej hlavičky.

---

## 4. Pridaj „capture first frame“ do `eth_header_parser`

Do parsera by som pridal debug výstupy:

```systemverilog
output logic [47:0] dbg_dst_mac_o,
output logic [47:0] dbg_src_mac_o,
output logic [15:0] dbg_ethertype_o,
output logic        dbg_hdr_seen_o,
output logic        dbg_mac_accept_o,
output logic        dbg_hdr_drop_o
```

A zachytiť prvý header po resete:

```systemverilog
logic dbg_locked_q;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    dbg_locked_q     <= 1'b0;
    dbg_dst_mac_o    <= '0;
    dbg_src_mac_o    <= '0;
    dbg_ethertype_o  <= '0;
    dbg_hdr_seen_o   <= 1'b0;
    dbg_mac_accept_o <= 1'b0;
    dbg_hdr_drop_o   <= 1'b0;
  end else begin
    if (hdr_done_pulse_w && !dbg_locked_q) begin
      dbg_locked_q     <= 1'b1;
      dbg_dst_mac_o    <= dst_mac_q;
      dbg_src_mac_o    <= src_mac_q;
      dbg_ethertype_o  <= ethertype_q;
      dbg_hdr_seen_o   <= 1'b1;
      dbg_mac_accept_o <= mac_accept_q;
      dbg_hdr_drop_o   <= !mac_accept_q;
    end
  end
end
```

Takto si zachytíš prvý frame a vieš ho pokojne čítať cez debug bus.

---

## 5. V `project.yaml` by som pridal debug feature

Aby to nebolo natvrdo v produkčnom top-e, dal by som parameter:

```systemverilog
parameter bit ENABLE_DEBUG_BUS = 1'b1
```

a port:

```systemverilog
output logic [15:0] dbg_o
```

V YAML potom:

```yaml
params:
  ENABLE_DEBUG_BUS: true
```

a piny J10/J11 mapovať iba keď ich chceš používať.

---

## 6. Board YAML: piny nenechať mazať

Keďže si už predtým riešil, že programátor mazal porty z `board.yaml`, tu by som zvolil lepší prístup:

```yaml
pins:
  DBG[0]:
    pin: ...
    assign: true
  DBG[1]:
    pin: ...
    assign: true
```

A ak niektoré debug piny nechceš priradiť:

```yaml
assign: false
```

Tým ostanú v definícii boardu, ale generátor ich nezapíše do `board.tcl`.

Pre J10/J11 by som teda pridal niečo v tomto štýle:

```yaml
features:
  onboard.debug_j10_j11:
    ports:
      DBG:
        width: 16
        direction: output
        pins:
          - J10_1
          - J10_2
          ...
```

Presné piny treba zobrať z tvojej board dokumentácie alebo aktuálneho `board.yaml`.

---

## 7. Najpraktickejší debug scenár

S J10/J11 by som spravil presne toto:

### Build 1 — pulse debug

```text
DBG[0]  RXDV
DBG[1]  gmii_frame_done
DBG[2]  eth_hdr_done
DBG[3]  mac_accept
DBG[4]  eth_drop
DBG[5]  ipv4_hdr_valid
DBG[6]  ipv4_drop
DBG[7]  udp_hdr_valid
DBG[8]  udp_drop
DBG[9]  rx_meta_valid
DBG[10] pkt_fifo_wr
DBG[11] meta_fifo_wr
DBG[12] tx_start
DBG[13] tx_busy
DBG[14] TXEN
DBG[15] RXER seen
```

Toto pripojíš na logic analyzer a pošleš jeden packet. Hneď vidíš, kde sa to zastaví.

### Build 2 — header byte capture

```text
DBG[7:0]   = captured byte
DBG[11:8]  = byte index
DBG[12]    = capture valid
DBG[13]    = mac_accept
DBG[14]    = hdr_seen
DBG[15]    = hdr_drop
```

Tým zistíš reálny:

```text
dst_mac
src_mac
ethertype
```

To je teraz kľúčové.

---

## 8. Čo očakávame z merania

Ak zachytený `dst_mac` bude:

```text
00 0A 35 01 FE C0
```

ale `mac_accept=0`, problém je v `local_mac_i` alebo porovnaní.

Ak zachytený `dst_mac` bude napríklad:

```text
AA ...
```

alebo zvláštna bitovo otočená hodnota, problém je RXD bit mapping.

Ak zachytený `dst_mac` bude MAC tvojho PC alebo broadcast, PC neposiela to, čo si myslíme — skontrolovať tcpdump s `-e -XX`.

Ak `ethertype` nie je:

```text
08 00
```

tak je posunutý header alebo zle orezaná preambula/SFD.

---

## 9. Môj návrh ďalšieho postupu

Teraz by som urobil tento konkrétny krok:

```text
1. Pridať dbg_o[15:0] na top.
2. Namapovať dbg_o na J10/J11.
3. Pridať debug výstupy z eth_header_parser:
   dbg_dst_mac, dbg_src_mac, dbg_ethertype, mac_accept, hdr_seen, hdr_drop.
4. Spraviť build s pulse debug busom.
5. Ak L2 stále padá, spraviť build s header byte capture busom.
```

Toto je omnoho lepšie než ďalej hádať medzi timingom, FCS, RXD alebo MAC filtrom.

Najdôležitejšia otázka, na ktorú musíš teraz odpovedať, je:

```text
Aký destination MAC reálne vidí FPGA po gmii_rx_mac?
```

PMOD J10/J11 ti na to dajú priamu odpoveď.
