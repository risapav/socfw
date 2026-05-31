Skontroloval som aktuálny ZIP so zameraním na `.sv` súbory a otvorené problémy v `ETH_TEST_03_STATUS.md`. Môj záver je: **simulačne máš už veľmi dobrý stav, ale HW debug treba teraz viesť cez presné meranie `valid/data` za `gmii_rx_mac`, nie iba cez LED pulzy.** Zároveň je tam jedno dôležité varovanie: aktuálne Quartus reporty v ZIP-e zrejme nie sú úplne zhodné s aktuálnym RTL.

## 1. K podozreniu, že `0xD5` ide do streamu

V aktuálnom `gmii_rx_mac.sv` je použitý stav `RX_SFD`, ktorý má presne zabrániť tomu, aby sa `0xD5` poslal ďalej:

```systemverilog
RX_PRE:
  if      (!gmii_rx_dv_i)       state_d = RX_IDLE;
  else if (gmii_rxd_i == 8'hD5) state_d = RX_SFD;

RX_SFD:
  if (!gmii_rx_dv_i) state_d = RX_IDLE;
  else               state_d = RX_DATA;

assign m_axis_tvalid = (state_q == RX_DATA) && dv_q;
assign m_axis_tdata  = rxd_q;
```

Časovo to vychádza takto:

```text
cyklus SFD:
  state_q = RX_PRE
  gmii_rxd_i = D5
  po hrane: state_q = RX_SFD, rxd_q = D5
  m_axis_tvalid = 0, lebo state_q = RX_SFD

ďalší cyklus, prvý MAC byte:
  gmii_rxd_i = 00
  po hrane: state_q = RX_DATA, rxd_q = 00
  m_axis_tvalid = 1
```

Teda **v simulácii by sa `D5` do platného streamu dostať nemal**. A to potvrdzujú aj nové testy v ZIP-e:

```text
tb_gmii_rx_mac_sfd_boundary: ALL PASS
tb_gmii_rx_eth_align:        ALL PASS
```

Tie už testujú presne rizikový scenár:

```text
55 55 55 55 55 55 55 D5
00 0A 35 01 FE C0 ...
```

a overujú, že výstup začína `00`, nie `D5`.

### Dôležitý detail pre J10/J11 debug

V top-e máš:

```systemverilog
assign dbg_mac_data_o = mac_tdata;
assign dbg_ctrl_o = {
  eth_rxer_i,
  eth_rxdv_i,
  mac_drop_pulse_w,
  mac_accept_pulse_w,
  mac_hdr_done_w,
  mac_frame_done_w,
  mac_tlast,
  mac_tvalid
};
```

Toto znamená, že na `dbg_mac_data_o` môžeš **fyzicky vidieť `D5`**, aj keď `mac_tvalid=0`. To ešte neznamená, že `D5` ide do streamu.

Pre logic analyzer musíš dekódovať iba cykly, kde:

```text
dbg_ctrl_o[0] = mac_tvalid = 1
```

Ak budeš pozerať `dbg_mac_data_o` bez validu, uvidíš aj neplatné bajty z pipeline registra, vrátane `D5`.

Pre HW overenie teda triggeruj alebo filtruj takto:

```text
valid stream byte = dbg_ctrl[0] == 1
data byte         = dbg_mac_data[7:0]
```

Očakávané platné bajty:

```text
00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00 45 00 ...
```

Ak pri `dbg_ctrl[0]=1` uvidíš:

```text
D5 00 0A 35 01 FE ...
```

potom je SFD leak skutočný HW problém. Ak `D5` vidíš len pri `valid=0`, je to len neplatná hodnota na debug buse.

---

## 2. `eth_header_parser.sv` je po Fáze 4A lepší, ale má ešte jednu slabinu

Prepis bez packed struct je správny smer. Aktuálna logika:

```systemverilog
4'd5: begin
  dst_mac_q[7:0] <= s_axis_tdata;
  mac_accept_q   <= promiscuous_i ||
                    (dst_mac_complete_w == local_mac_i) ||
                    (accept_broadcast_i &&
                     (dst_mac_complete_w == ETH_BROADCAST_MAC));
end
```

je synteticky čistejšia než predtým.

Ale upozorňujem na vec okolo debug capture:

```systemverilog
if (!dbg_locked_q) begin
  dbg_locked_q     <= 1'b1;
  dbg_dst_mac_o    <= dst_mac_q;
  dbg_mac_accept_o <= mac_accept_q;
end
```

Toto je v byte 13, takže `dst_mac_q` by už mal byť kompletný. To je v poriadku.

Čo by som však doplnil pre HW debug:

```systemverilog
output logic [47:0] dbg_local_mac_o,
output logic [47:0] dbg_dst_mac_live_o
```

alebo aspoň porovnávací signál:

```systemverilog
assign dbg_local_mac_match_o = (LOCAL_MAC == 48'h000A3501FEC0);
```

Prečo: ak `dbg_dst_mac_o` bude správne `00:0A:35:01:FE:C0`, ale `mac_accept=0`, potom už nezostáva RX alignment — problém je v tom, čo sa reálne dostalo ako `LOCAL_MAC` parameter do syntézy/topu.

---

## 3. Najväčší praktický problém: top používa debug bus správne, ale zatiaľ nevyvádza zachytený `dbg_dst_mac`

V `ethernet_test_03_top.sv` máš z parsera tieto porty odpojené:

```systemverilog
.dbg_dst_mac_o     (),
.dbg_mac_accept_o  ()
```

To znamená, že J10/J11 teraz ukazujú **raw stream za `gmii_rx_mac`**, nie zachytený L2 header.

To je dobrý debug mód, ale pre aktuálnu MAC filter záhadu by som pridal druhý režim:

### Debug mód A — raw RX stream za `gmii_rx_mac`

Aktuálny stav:

```text
DBG[7:0] = mac_tdata
CTRL[0]  = mac_tvalid
CTRL[1]  = mac_tlast
CTRL[2]  = frame_done
CTRL[3]  = hdr_done
CTRL[4]  = mac_accept
CTRL[5]  = mac_drop
CTRL[6]  = raw RXDV
CTRL[7]  = RXER
```

Toto použiješ na overenie SFD leak / byte shiftu.

### Debug mód B — captured Ethernet header

Pridaj multiplex, napríklad parameter:

```systemverilog
parameter bit DEBUG_CAPTURE_HEADER = 1'b1
```

a signály:

```systemverilog
logic [47:0] dbg_dst_mac_w;
logic        dbg_mac_accept_w;
```

Pripoj parser:

```systemverilog
.dbg_dst_mac_o     (dbg_dst_mac_w),
.dbg_mac_accept_o  (dbg_mac_accept_w)
```

Potom na J10/J11 rotuj bajty:

```text
index 0..5  = dbg_dst_mac_o
index 6..11 = eth_src_mac
index 12..13 = ethertype
```

Minimálne stačí:

```systemverilog
logic [2:0] dbg_byte_sel_q;
logic [23:0] dbg_div_q;
logic [7:0] dbg_capture_byte_w;

always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    dbg_div_q      <= '0;
    dbg_byte_sel_q <= '0;
  end else begin
    dbg_div_q <= dbg_div_q + 1'b1;
    if (dbg_div_q == '0)
      dbg_byte_sel_q <= dbg_byte_sel_q + 1'b1;
  end
end

always_comb begin
  unique case (dbg_byte_sel_q)
    3'd0: dbg_capture_byte_w = dbg_dst_mac_w[47:40];
    3'd1: dbg_capture_byte_w = dbg_dst_mac_w[39:32];
    3'd2: dbg_capture_byte_w = dbg_dst_mac_w[31:24];
    3'd3: dbg_capture_byte_w = dbg_dst_mac_w[23:16];
    3'd4: dbg_capture_byte_w = dbg_dst_mac_w[15:8];
    3'd5: dbg_capture_byte_w = dbg_dst_mac_w[7:0];
    default: dbg_capture_byte_w = 8'h00;
  endcase
end

assign dbg_mac_data_o = dbg_capture_byte_w;
assign dbg_ctrl_o = {
  1'b0,
  1'b0,
  mac_drop_pulse_w,
  mac_accept_pulse_w,
  mac_hdr_done_w,
  dbg_mac_accept_w,
  dbg_byte_sel_q[1],
  dbg_byte_sel_q[0]
};
```

Takto vieš bez osciloskopu aspoň postupne prečítať, či `dbg_dst_mac_o` je:

```text
00 0A 35 01 FE C0
```

alebo:

```text
D5 00 0A 35 01 FE
```

alebo:

```text
0A 35 01 FE C0 E0
```

---

## 4. V aktuálnom RTL je jedna systémová chyba v CDC/TX ceste: packet FIFO môže predbiehať meta FIFO

V top-e máš:

```systemverilog
assign txb_tready = pkt_wr_ready;
```

a packet FIFO zapisuješ vždy, keď `txb_tvalid && pkt_wr_ready`.

Metadata zapisuješ až po poslednom byte cez `commit_pending_q`.

To znamená, že pri plnom `meta_fifo` môžeš zapísať celý packet do `pkt_fifo`, ale metadata sa ešte nezapíšu. V praxi to s malou prevádzkou nemusí nastať, ale architektonicky je to bug.

Pre robustnosť by `txb_tready` mal brať do úvahy aj schopnosť neskôr uložiť metadata. Minimálne pred začatím TX builder packetu musíš rezervovať miesto v meta FIFO.

Jednoduché dočasné riešenie:

```systemverilog
assign txb_tready = pkt_wr_ready && (meta_wr_ready || commit_pending_q);
```

Ale pozor: toto môže zastaviť builder až počas packetu, a `udp_ipv4_tx_builder` podporuje `m_axis_tready`, takže to je funkčne možné.

Lepšie riešenie je mať samostatný stav:

```text
TXB packet start povoliť len keď:
  pkt_fifo má miesto
  meta_fifo má miesto
```

Toto nie je príčina L2 MAC dropu, ale bude to ďalší problém pri vyššej prevádzke.

---

## 5. Timing report v ZIP-e nezodpovedá aktuálnemu `udp_ipv4_tx_builder.sv`

Toto je dôležité. Aktuálny `udp_ipv4_tx_builder.sv` používa:

```systemverilog
csum_q
ST_CSUM0
ST_CSUM1
ST_CSUM2
ST_CSUM3
ST_FOLD
```

Ale `output_files/soc_top.sta.rpt` hlási cesty cez:

```text
partial0_q
partial1_q
```

Tieto signály v aktuálnom zdrojáku `udp_ipv4_tx_builder.sv` neexistujú.

To znamená, že `output_files/soc_top.sta.rpt` je pravdepodobne zo staršieho buildu než aktuálny RTL v ZIP-e. Status tiež hovorí, že `soc_top.sof` bol posledný build pred Fázou 4A.

Preto by som aktuálny timing neposudzoval podľa `output_files`, kým nespravíš čistý rebuild.

### Odporúčanie

Sprav:

```bash
make clean
make build
make compile
```

alebo ekvivalent, ktorý zmaže staré `db/`, `incremental_db/`, `output_files/`.

Pri Quartuse by som tentokrát odporúčal tvrdé čistenie:

```bash
rm -rf db incremental_db output_files
```

Potom znova skontroluj:

```text
output_files/soc_top.sta.summary
```

Ak sa po rebuild-e stále objavia `partial0_q/partial1_q`, tak build neberie aktuálny `rtl/eth/l4/udp_ipv4_tx_builder.sv`.

---

## 6. `gmii_rx_mac` má v sim správne SFD správanie, ale debug bus musí byť valid-gated

Zhrnutie k hlavnej hypotéze:

```text
SFD leak v sim: nepotvrdený, nové testy PASS.
SFD leak v HW: stále možné iba ak sa správa inak syntéza/časovanie, alebo ak LA číta data bez validu.
```

Preto ďalší HW experiment musí byť:

```text
Zachytiť len bajty, kde dbg_ctrl[0] = 1.
```

Ak nemáš logic analyzer schopný kvalifikovať valid, uprav debug bus tak, aby v nevalid cykloch dával sentinel hodnotu:

```systemverilog
assign dbg_mac_data_o = mac_tvalid ? mac_tdata : 8'hEE;
```

Toto je veľmi praktické. Potom na analyzéri jasne uvidíš:

```text
EE EE EE 00 0A 35 ...
```

a nebudeš si mýliť `D5` v nevalid cykle s dátovým bajtom.

Pre aktuálny debug by som túto zmenu urobil hneď:

```systemverilog
assign dbg_mac_data_o = mac_tvalid ? mac_tdata : 8'hEE;
```

a prípadne:

```systemverilog
assign dbg_ctrl_o[0] = mac_tvalid;
```

---

## 7. Testy sú dobré, ale pridal by som jeden „HW-like debug bus“ test

Keďže teraz debug bus hrá kľúčovú úlohu, pridaj test na top-level debug správanie:

```text
tb_debug_bus_valid_gating
```

Overí:

```text
počas RX_SFD cyklu dbg_mac_data_o = EE, nie D5
keď mac_tvalid=1, dbg_mac_data_o = prvý MAC byte 00
```

Ak debug bus necháš ako raw `mac_tdata`, test by mal aspoň dokumentovať:

```text
D5 sa na dbg_mac_data_o objaví, ale dbg_ctrl[0]=0
```

To zabráni falošnému záveru pri HW meraní.

---

## 8. Konkrétny návrh ďalšieho postupu

### Krok 1 — upraviť debug bus

V top-e zmeň dočasne:

```systemverilog
assign dbg_mac_data_o = mac_tdata;
```

na:

```systemverilog
assign dbg_mac_data_o = mac_tvalid ? mac_tdata : 8'hEE;
```

a nechaj `dbg_ctrl[0] = mac_tvalid`.

Potom HW meranie:

```text
očakávané:
EE ... 00 0A 35 01 FE C0 E0 4F ...
```

Ak uvidíš:

```text
D5 00 0A ...
```

pri `valid=1`, potom SFD leak existuje v HW.

Ak uvidíš:

```text
EE D5 EE 00 0A ...
```

alebo `D5` iba pri `valid=0`, SFD leak nie je príčina.

---

### Krok 2 — pripojiť `dbg_dst_mac_o`

Do top-u pripoj:

```systemverilog
logic [47:0] dbg_dst_mac_w;
logic        dbg_mac_accept_w;
```

a v parseri:

```systemverilog
.dbg_dst_mac_o    (dbg_dst_mac_w),
.dbg_mac_accept_o (dbg_mac_accept_w)
```

Pridaj druhý debug režim, ktorý na J10 rotuje bajty `dbg_dst_mac_w`.

Toto je kľúčové pre odpoveď:

```text
Aký dst_mac reálne zachytil eth_header_parser?
```

---

### Krok 3 — spustiť MAC_DEBUG build

Aktuálne je:

```systemverilog
.LAYER_DEBUG(1'b0),
.MAC_DEBUG(1'b1)
```

To je správne. Pošli jeden UDP packet a pozri:

```text
LED3 = hdr_done
LED4 = mac_accept
LED5 = mac_drop
```

Interpretácia:

```text
LED3 nie:
  eth_header_parser nevidí celý header, problém je medzi rx_mac a parserom.

LED3 áno, LED4 nie, LED5 áno:
  parser header vidí, ale dst_mac != local_mac.

LED3 áno, LED4 áno:
  Fáza 4A parser fix funguje; ďalší problém je L3/L4/TX.
```

---

### Krok 4 — clean rebuild Quartusu

Pretože STA report nezodpovedá aktuálnemu RTL:

```bash
rm -rf db incremental_db output_files
make build
make compile
```

Až potom posudzuj timing.

---

### Krok 5 — ak MAC accept stále zlyhá

Podľa debug capture:

#### Prípad A: `dbg_dst_mac = D5:00:0A:35:01:FE`

Opraviť `gmii_rx_mac`, ale najprv skontrolovať valid. Ak `D5` je validný, je to reálny SFD leak.

#### Prípad B: `dbg_dst_mac = 00:0A:35:01:FE:C0`, ale `mac_accept=0`

Problém je `local_mac_i` v reálnom top-e/generovanom parameter override. Vyveď `LOCAL_MAC_OK` na debug:

```systemverilog
assign dbg_ctrl_o[7] = (LOCAL_MAC == 48'h000A3501FEC0);
```

#### Prípad C: `dbg_dst_mac` je úplne iný

Rieš RXD pin mapping, data corruption alebo to, že PC posiela iný frame než očakávaš.

---

## 9. Veci, ktoré by som teraz neriešil

Kým nevieš, čo je na `dbg_dst_mac_o`, neriešil by som:

```text
UDP checksum
FCS strip
ARP responder
MDIO
veľký CDC refaktor
RX FCS validation
```

Teraz je cieľ veľmi úzky:

```text
dokázať, aké bajty dostáva eth_header_parser ako destination MAC
```

---

## Krátky verdikt

Aktuálna verzia je dobrý krok. Pridané testy na SFD hranicu a `gmii_rx_mac -> eth_header_parser` sú presne správne a prechádzajú. Preto by som už netvrdil, že `gmii_rx_mac` určite púšťa `D5`. Skôr by som povedal:

```text
SFD leak nie je potvrdený v simulácii.
V HW ho treba overiť valid-gated debug busom, lebo dbg_mac_data_o môže ukazovať D5 aj pri mac_tvalid=0.
```

Najbližší praktický patch: **zmeniť debug bus na `mac_tvalid ? mac_tdata : 8'hEE` a pripojiť `dbg_dst_mac_o` z `eth_header_parser` do druhého debug módu.** Potom už nebudeš hádať — priamo uvidíš, či parser zachytáva správne `00:0A:35:01:FE:C0` alebo posunutý/poškodený header.
