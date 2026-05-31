Skontroloval som aktuálny `eth_test_03.zip`. Zameral som sa hlavne na `.sv` súbory, `ETH_TEST_03_STATUS.md`, test logy, top-level zapojenie, debug bus a aktuálny Quartus timing.

Najdôležitejšie zistenie: **aktuálny ZIP už nie je v stave, ktorý opisuje časť statusu o timing fail −0.290 ns. Aktuálny `output_files/soc_top.sta.summary` ukazuje timing PASS.** Slow 85 °C `ETH_RXC` má už kladný slack:

```text
ETH_RXC setup slack:   +0.448 ns
ETH_TX_CLK setup:      +0.737 ns
SYS_CLK setup:         +5.303 ns
ETH_RXC hold:          +0.430 ns
```

Čiže timing problém je v tejto verzii prakticky uzavretý. Teraz je hlavný problém už čisto HW dátová diagnostika RX/L2 alebo následne TX handshake.

---

## 1. Stav podľa aktuálneho ZIP-u

Simulácie sú veľmi dobré. Okrem pôvodných testov sú už pridané aj presne tie, ktoré sme chceli pre SFD podozrenie:

```text
tb_gmii_rx_mac_sfd_boundary — PASS
tb_gmii_rx_eth_align        — PASS
```

Tieto testy overujú, že:

```text
55 55 55 55 55 55 55 D5
00 0A 35 01 FE C0 ...
```

sa po `gmii_rx_mac` zarovná ako:

```text
00 0A 35 01 FE C0 ...
```

a nie ako:

```text
D5 00 0A 35 01 FE ...
```

Teda v simulácii je hypotéza „SFD ide do streamu“ vyvrátená. V HW ju ešte treba overiť J10/J11 debug busom, ale dôležité je správne interpretovať `valid`.

---

## 2. `gmii_rx_mac.sv`: SFD sa podľa RTL neposiela ako validný byte

Aktuálny `gmii_rx_mac` má stav:

```systemverilog
RX_SFD
```

a výstup:

```systemverilog
assign m_axis_tvalid = (state_q == RX_DATA) && dv_q;
assign m_axis_tdata  = rxd_q;
```

Časovanie je takéto:

```text
cyklus D5:
  state_q = RX_PRE
  gmii_rxd_i = D5
  po hrane rxd_q = D5, state_q = RX_SFD
  m_axis_tvalid = 0

cyklus prvého MAC bajtu 00:
  gmii_rxd_i = 00
  po hrane rxd_q = 00, state_q = RX_DATA
  m_axis_tvalid = 1
```

Takže `D5` môže byť na internom `rxd_q/mac_tdata`, ale **nemá byť platný stream byte**, lebo `mac_tvalid=0`.

Preto je správne, že si v top-e urobil:

```systemverilog
assign dbg_mac_data_o = mac_tvalid ? mac_tdata : 8'hEE;
```

Toto je veľmi dôležitá oprava debug busu. Ak na J10 uvidíš `0xEE`, znamená to „nevalidný cyklus“. Ak SFD uniká reálne, musíš vidieť `D5` pri `dbg_ctrl_o[0] = 1`.

---

## 3. J10/J11 debug bus je teraz nastavený dobre

Aktuálne top-level vyvádza:

```systemverilog
assign dbg_mac_data_o = mac_tvalid ? mac_tdata : 8'hEE;

assign dbg_ctrl_o = {
  eth_rxer_i,          // [7]
  eth_rxdv_i,          // [6]
  mac_drop_pulse_w,    // [5]
  dbg_mac_accept_w,    // [4] held capture
  mac_hdr_done_w,      // [3]
  mac_frame_done_w,    // [2]
  mac_tlast,           // [1]
  mac_tvalid           // [0]
};
```

Toto je presne vhodné pre aktuálny HW test.

### Ako interpretovať J10/J11

Na logickom analyzéri sleduj:

```text
J10[7:0] = dbg_mac_data_o
J11[0]   = mac_tvalid
J11[1]   = mac_tlast
J11[2]   = frame_done
J11[3]   = eth header done
J11[4]   = captured mac_accept
J11[5]   = mac_drop pulse
J11[6]   = raw RXDV
J11[7]   = RXER
```

Platné bajty sú iba tie, kde:

```text
J11[0] = 1
```

Očakávanie pre správny RX stream:

```text
00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00 45 00 ...
```

Ak uvidíš:

```text
D5 00 0A 35 01 FE C0 ...
```

a zároveň `J11[0]=1`, potom je SFD leak v HW reálny.

Ak uvidíš:

```text
EE D5 EE 00 0A ...
```

alebo `D5` iba pri `J11[0]=0`, SFD leak nie je problém.

---

## 4. `eth_header_parser.sv`: prepis je správny

Aktuálny parser už nepoužíva packed struct. Má explicitné registre:

```systemverilog
logic [47:0] dst_mac_q;
logic [47:0] src_mac_q;
logic [15:0] ethertype_q;
logic        mac_accept_q;
```

a rozhodnutie robí pri byte 5:

```systemverilog
mac_accept_q <= promiscuous_i ||
                (dst_mac_complete_w == local_mac_i) ||
                (accept_broadcast_i &&
                 (dst_mac_complete_w == ETH_BROADCAST_MAC));
```

Toto je dobré riešenie. Navyše `tb_gmii_rx_eth_align` prechádza, takže reťaz:

```text
gmii_rx_mac -> eth_header_parser
```

je v simulácii overený pre strict MAC match.

### Malá slabina debug capture

`dbg_dst_mac_o` a `dbg_mac_accept_o` sú už vyvedené z parsera a v top-e pripojené:

```systemverilog
.dbg_dst_mac_o     (dbg_dst_mac_w),
.dbg_mac_accept_o  (dbg_mac_accept_w)
```

Ale `dbg_dst_mac_w` zatiaľ nie je vyvedený na J10/J11. Na J10 vidíš raw stream, nie zachytený `dst_mac`.

Pre aktuálny debug je to OK ako prvý krok. Ale ak raw stream vyzerá správne a MAC filter stále dropuje, potrebuješ druhý debug režim: rotovať `dbg_dst_mac_w` po bajtoch na J10.

---

## 5. Status dokument je čiastočne zastaraný

`ETH_TEST_03_STATUS.md` stále hovorí:

```text
SOF: posledný build — pred Faza 4A zmenami
ETH_RXC slow slack = −0.290 ns
Faza 4A čaká na rebuild
```

Ale aktuálny ZIP obsahuje nový `output_files/soc_top.flow.rpt` s dátumom:

```text
Successful - Sun May 31 10:46:22 2026
```

a `soc_top.sta.summary` ukazuje:

```text
ETH_RXC slow 85C setup slack = +0.448 ns
```

Čiže status by som aktualizoval:

```text
Quartus build po Fáze 4A: PASS
ETH_RXC timing: PASS, +0.448 ns slow 85C
SOF: aktuálny build po Fáze 4A
```

Tým sa odstráni falošná hypotéza, že aktuálny L2 problém môže byť z timing failu. V tejto verzii už timing nie je hlavný blokér.

---

## 6. Dôležitá chyba v CDC write handshake do packet FIFO

Toto je najväčší konkrétny RTL problém, ktorý som v aktuálnom top-e našiel.

Máš:

```systemverilog
assign txb_tready = pkt_wr_ready && (txb_started_q || meta_wr_ready);
```

Tým hovoríš TX builderu: „môžeš poslať byte iba ak je packet FIFO ready a buď už packet beží, alebo meta FIFO má miesto“.

Ale do packet FIFO zapisuješ:

```systemverilog
.wr_valid_i(txb_tvalid)
```

Toto je zle. FIFO zapisuje, keď `wr_valid_i && !full_w`. Teda ak `txb_tvalid=1` a `pkt_wr_ready=1`, FIFO zapíše byte **aj vtedy, keď `txb_tready=0` kvôli `meta_wr_ready=0`**.

Správne musíš vytvoriť handshake fire:

```systemverilog
logic txb_fire_w;

assign txb_fire_w = txb_tvalid && txb_tready;
```

a packet FIFO zapisovať iba pri fire:

```systemverilog
.wr_valid_i(txb_fire_w)
```

Tiež `txb_started_q` a `commit_pending_q` musia používať `txb_fire_w`, nie `txb_tvalid && pkt_wr_ready`.

### Oprava

```systemverilog
logic txb_fire_w;

assign txb_tready = pkt_wr_ready && (txb_started_q || meta_wr_ready);
assign txb_fire_w = txb_tvalid && txb_tready;
```

Potom:

```systemverilog
always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    txb_started_q <= 1'b0;
  end else if (txb_fire_w && txb_tlast) begin
    txb_started_q <= 1'b0;
  end else if (txb_fire_w) begin
    txb_started_q <= 1'b1;
  end
end
```

Packet FIFO:

```systemverilog
.wr_valid_i(txb_fire_w)
```

Commit:

```systemverilog
if (txb_fire_w && txb_tlast) begin
  meta_wr_data_q   <= {meta_latch_dst_q, meta_latch_src_q};
  commit_pending_q <= 1'b1;
end
```

Toto pravdepodobne nespôsobuje L2 MAC filter drop, ale môže spôsobiť neskorší „TX silence“ alebo rozbitú odpoveď, hlavne ak sa FIFO alebo meta FIFO dostanú do okrajového stavu.

---

## 7. Potenciálny problém s TX controllerom a FWFT FIFO

`async_fifo` má FWFT výstup s registrovaným outputom. V TX controlleri robíš:

```systemverilog
assign meta_rd_ready = (txc_state_q == TXC_IDLE) && meta_rd_valid && !tx_mac_busy_w;
```

To znamená, že metadata sa odoberú v tom istom stave, v ktorom sa latchujú:

```systemverilog
if (meta_rd_valid && !tx_mac_busy_w) begin
  txc_dst_mac_q <= meta_rd_data[95:48];
  txc_src_mac_q <= meta_rd_data[47:0];
  txc_state_q   <= TXC_START;
end
```

Toto je pre FWFT zvyčajne OK. Packet FIFO sa číta až v `TXC_DATA`, teda až po `TXC_START`, takže prvý byte packetu by mal byť k dispozícii.

Ale po oprave `txb_fire_w` by som určite znovu spustil:

```text
tb_echo_path_dual_clock
```

a ideálne pridal stress test s viacerými back-to-back rámcami cez dual-clock top. Status tvrdí, že dual-clock 5/5 PASS, ale nový handshake fix sa ho dotkne.

---

## 8. Čo ďalej v HW: presné poradie

### Krok 1 — najprv otestuj aktuálny MAC_DEBUG build na HW

Nič ďalšie zatiaľ neprepínaj. Tento build je pripravený a presne odpovedá na otázku L2 MAC filtra.

LED:

```text
LED3 = hdr_done_pulse
LED4 = hdr_accept_pulse
LED5 = hdr_drop_pulse
```

Očakávané po odoslaní UDP packetu:

```text
LED3 blikne
LED4 blikne
LED5 neblikne alebo len pri cudzích rámcoch
```

Ak sa toto stane, Fáza 4A vyriešila MAC filter bug a môžeš pokračovať na full path.

Ak:

```text
LED3 blikne, LED5 blikne, LED4 nie
```

potom parser stále zachytáva inú MAC alebo `LOCAL_MAC` nesedí.

Vtedy prejdi na J10/J11.

---

### Krok 2 — zmeraj J10/J11 raw stream

Na J10/J11 očakávaj iba platné bajty pri `dbg_ctrl[0]=1`.

Hľadaj prvých 14 valid bajtov:

```text
00 0A 35 01 FE C0 E0 4F 43 5B 59 3C 08 00
```

Interpretácia:

```text
00 0A 35 01 FE C0 ...:
  RX alignment je správny.
  Ak MAC accept nebliká, problém je LOCAL_MAC/top parameter.

D5 00 0A 35 01 FE ... pri valid=1:
  SFD leak v HW, treba opraviť RX MAC.

0A 35 01 FE C0 E0 ...:
  prvý destination MAC byte sa stráca.

úplne iné bajty:
  RXD mapping, dátová integrita, alebo PC neposiela ten frame, ktorý meriaš.
```

---

### Krok 3 — ak raw stream vyzerá správne, pridaj debug capture `dbg_dst_mac_w`

Ak J10 ukáže raw stream správny, ale LED4 stále nebliká, potom potrebuješ vidieť `dbg_dst_mac_w` a `LOCAL_MAC_OK`.

Navrhovaný druhý debug mód:

```text
J10[7:0]  = rotovaný bajt dbg_dst_mac_w[47:0]
J11[2:0]  = index bajtu 0..5
J11[3]    = dbg_mac_accept_w
J11[4]    = LOCAL_MAC_OK
J11[5]    = hdr_done
J11[6]    = hdr_accept
J11[7]    = hdr_drop
```

`LOCAL_MAC_OK`:

```systemverilog
logic local_mac_ok_w;
assign local_mac_ok_w = (LOCAL_MAC == 48'h000A3501FEC0);
```

Toto ti povie, či parameter v reálnom top-e sedí.

---

## 9. Čo by som aktualizoval v testoch

Testy sú teraz dobré, ale po nájdenom handshake probléme by som pridal ešte jeden test pre top/CDC:

```text
tb_echo_path_dual_clock_meta_backpressure
```

Cieľ: vynútiť stav, kde `meta_fifo` nie je ready na začiatku nového packetu, a overiť, že packet FIFO nezapíše byte bez handshake.

Ak to nechceš teraz komplikovať, minimálne po oprave `txb_fire_w` spusti existujúci:

```bash
make regression
```

a hlavne:

```text
tb_echo_path_dual_clock
```

---

## 10. Čo teraz neriešiť

Momentálne by som neriešil:

```text
FCS strip v gmii_rx_mac
UDP checksum
MDIO master
ARP responder
väčší refaktor RX/TX architektúry
```

Najprv treba odpovedať na dve otázky:

```text
1. Čo reálne lezie z gmii_rx_mac pri mac_tvalid=1?
2. Po Fáze 4A blikne MAC accept v HW?
```

---

## Odporúčaný najbližší patch

Do ďalšieho commitu by som dal iba tieto veci:

```text
1. Opraviť packet FIFO write handshake:
   wr_valid_i = txb_tvalid && txb_tready.

2. Použiť txb_fire_w v:
   - txb_started_q
   - commit_pending_q
   - meta write trigger

3. Aktualizovať ETH_TEST_03_STATUS.md:
   - timing už PASS +0.448 ns
   - SFD boundary tests PASS
   - J10/J11 valid-gated debug bus implementovaný

4. HW test:
   - MAC_DEBUG LED3/4/5
   - J10/J11 capture prvých valid bajtov
```

Krátky verdikt: **aktuálny RTL už simulačne vyvracia SFD leak. Debug bus je dobre upravený, ale pri meraní treba striktne brať iba `mac_tvalid=1`. Timing je už PASS. Najväčšia RTL oprava, ktorú by som ešte spravil pred ďalším serióznym HW testom, je handshake do packet FIFO cez `txb_fire_w`.**
