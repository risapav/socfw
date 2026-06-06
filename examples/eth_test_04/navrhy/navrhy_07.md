Porovnal som TX dvojicu:

```text id="hwtqy6"
1. eth_tx_mac.sv          — tvoj clean TX MAC: metadata + payload-only stream -> GMII
2. taxi_axis_gmii_tx.sv   — referenčný AXI frame -> GMII TX od taxi/Alex Forencich
```

Tvoj modul má iný kontrakt než taxi: `eth_tx_mac` si **sám skladá Ethernet header z metadata**, potom pridá payload, padding, CRC/FCS a IFG. Referenčný `taxi_axis_gmii_tx` očakáva, že AXI stream už obsahuje celý Ethernet frame od DST MAC bajtu; on iba pridá preambulu/SFD, padding/FCS/IFG a rieši MII/GMII/PTP/status.

## Hlavný verdikt

Tvoj `eth_tx_mac.sv` je architektonicky správny pre clean echo cestu, ale má niekoľko bodov, ktoré by som upravil pred ďalším HW testom:

```text id="e34vt9"
1. s_meta_ready_o je kombinatoricky state==IDLE, ale metadata sa berú iba podľa s_meta_valid_i.
2. ST_PAYLOAD nepoužíva fire_w, hoci ho deklaruje.
3. s_axis_tuser_i sa ignoruje.
4. payload_cnt_q saturuje na 63, čiže nestačí ako skutočný payload_len ani diagnostika.
5. TX nepozná payload_len z metadata, spolieha sa iba na tlast.
6. IFG počítanie má pravdepodobne off-by-one.
7. Underflow vetva dáva TXER=1 spolu s TXEN=0, čo PHY nemusí považovať za frame error.
8. Chýbajú detailné statusy: started, header_sent, payload_seen, fcs_sent, user_error, frame_good.
```

---

# 1. Rozdiel kontraktu vstupného streamu

## Tvoj `eth_tx_mac`

Vstupy:

```systemverilog
s_meta_dst_mac_i
s_meta_src_mac_i
s_meta_eth_type_i
s_axis_tdata_i
```

Teda AXI stream je iba payload. Header vzniká tu:

```systemverilog
hdr_shift_q <= {s_meta_dst_mac_i, s_meta_src_mac_i, s_meta_eth_type_i};
```

a potom sa vysiela v `ST_HEADER`.

To sedí s clean RX MAC návrhom:

```text
RX stripne Ethernet header a FCS
echo_app otočí MAC adresy
TX doplní nový Ethernet header a nové FCS
```

## Taxi `taxi_axis_gmii_tx`

Taxi očakáva, že AXI stream už obsahuje celý Ethernet frame. Preto `STATE_PAYLOAD` rovno posiela `s_tdata_reg` a CRC počíta nad týmto streamom. Preambulu/SFD dopĺňa pred stream.

Verdikt:

```text
Nekopírovať taxi 1:1. Tvoj metadata+payload kontrakt je pre eth_test_04 správny.
Z taxi treba prevziať hlavne handshake/pipeline/status filozofiu.
```

---

# 2. Metadata handshake

Tvoj modul má:

```systemverilog
assign s_meta_ready_o = (state_q == ST_IDLE);
```

a v `ST_IDLE`:

```systemverilog
if (s_meta_valid_i) begin
  hdr_shift_q <= {s_meta_dst_mac_i, s_meta_src_mac_i, s_meta_eth_type_i};
  ...
  state_q <= ST_PREAMBLE;
end
```

Funkčne to väčšinou sedí, lebo `ready=1` iba v IDLE. Ale čistejšie a bezpečnejšie je použiť explicitný fire:

```systemverilog
logic meta_fire_w;

assign s_meta_ready_o = (state_q == ST_IDLE);
assign meta_fire_w = s_meta_valid_i && s_meta_ready_o;
```

a v `ST_IDLE`:

```systemverilog
if (meta_fire_w) begin
  ...
end
```

Dôvod: rovnaký štýl ako AXI-S, jasné pre Verible aj pre budúce zmeny.

---

# 3. `fire_w` je deklarovaný, ale reálne sa nepoužíva

V module máš:

```systemverilog
logic fire_w;
assign fire_w = s_axis_tvalid_i && s_axis_tready_o;
```

ale v payload stave testuješ:

```systemverilog
if (!s_axis_tvalid_i) begin
  // Underflow
end else begin
  ...
end
```

Keďže `s_axis_tready_o = (state_q == ST_PAYLOAD)`, je to teraz funkčne skoro rovnaké. Ale správny handshake štýl je:

```systemverilog
if (!fire_w) begin
  // Underflow
end else begin
  ...
end
```

Taxi modul používa registrovaný `tready` a interný `s_tdata_reg`, teda explicitne oddelí prijatie bajtu od jeho vyslania o cyklus.

Pre tvoj modul by som odporúčal buď:

### Jednoduchá oprava

Použiť `fire_w` priamo:

```systemverilog
ST_PAYLOAD: begin
  if (!fire_w) begin
    gmii_tx_en_o   <= 1'b0;
    gmii_tx_er_o   <= 1'b1;
    gmii_txd_o     <= 8'h00;
    tx_underflow_q <= tx_underflow_q + 16'd1;
    ifg_cnt_q      <= 8'(IFG_CYCLES - 1);
    state_q        <= ST_IFG;
  end else begin
    ...
  end
end
```

### Robustnejšia oprava

Pridať payload register:

```systemverilog
logic [7:0] payload_data_q;
logic       payload_last_q;
logic       payload_user_q;
```

a urobiť podobne ako taxi: najprv prijať bajt, potom ho o cyklus neskôr vyslať. To lepšie sedí na „all outputs registered“ kontrakt, ale pre 125 MHz GMII stačí aj jednoduchšia verzia.

---

# 4. `s_axis_tuser_i` sa ignoruje

Tvoj komentár hovorí, že stream má `tuser`, ale TX ho nepoužíva. V `ST_PAYLOAD` by malo platiť:

```text
ak payload stream príde s tuser=1, rámec je chybný
```

Taxi toto robí:

```systemverilog
frame_error_next = !s_axis_tx.tvalid || s_axis_tx.tuser[0] || stat_tx_err_oversize_next;
stat_tx_err_user_next = s_axis_tx.tuser[0];
```

a potom `gmii_tx_er_next = frame_error_reg` v poslednom/pad/FCS stave.

Do tvojho modulu by som pridal:

```systemverilog
logic frame_error_q;
logic [15:0] tx_user_error_q;
```

V `ST_IDLE`:

```systemverilog
frame_error_q <= 1'b0;
```

V `ST_PAYLOAD` pri `fire_w`:

```systemverilog
if (s_axis_tuser_i) begin
  frame_error_q   <= 1'b1;
  tx_user_error_q <= tx_user_error_q + 16'd1;
end
```

A rozhodnúť sa, čo chceš robiť:

```text
A) abortnúť frame hneď pri tuser=1,
B) dokončiť frame s TXER,
C) nezahadzovať, ale počítať status.
```

Pre clean loopback by som volil A: ak payload má error, nepokračovať v generovaní validného FCS.

---

# 5. Padding je logicky správne pre payload-only stream

V tvojom TX module:

```systemverilog
if (payload_cnt_q < 6'd45) begin
  pad_cnt_q <= 6'd45 - payload_cnt_q;
  state_q   <= ST_PAD;
end
```

Keďže `payload_cnt_q` sa zvýši až po cykle, kde práve vysielaš aktuálny bajt, tak pri poslednom bajte:

```text
payload_cnt_q = počet predchádzajúcich bajtov
```

Príklady:

```text
1 bajt payloadu:
  pri tlast payload_cnt_q = 0
  pad_cnt = 45
  výsledok 1 + 45 = 46 OK

46 bajtov payloadu:
  pri tlast payload_cnt_q = 45
  nepaddovať OK

0 bajtov payloadu:
  tento stav modul nevie reprezentovať, lebo čaká na aspoň jeden tvalid/tlast beat
```

Toto je pre normálne testy OK.

Ale:

```text
payload_cnt_q saturuje na 63
```

Pre frame 1492 B nebude `payload_cnt_q` reálna dĺžka. Na padding ti to nevadí, lebo po 63 už určite netreba padding, ale diagnosticky je to slabé.

Odporúčam:

```systemverilog
logic [15:0] payload_len_q;
```

a inkrementovať ho pri každom `fire_w`.

---

# 6. TX modul by mal dostať payload_len z metadata

Tvoj aktuálny TX sa spolieha výlučne na `s_axis_tlast_i`.

To je AXI-S legitímne. Ale v tvojej architektúre RX MAC vytvára metadata a payload FIFO oddelene. Ak sa raz payload/meta rozídu, TX to nevie skontrolovať.

Odporúčam rozšíriť metadata:

```systemverilog
input logic [15:0] s_meta_payload_len_i
```

Potom TX môže overiť:

```text
počet prijatých payload bajtov == s_meta_payload_len_i
```

a pri nesúlade dať:

```systemverilog
stat_tx_len_mismatch
```

Toto je extrémne užitočné pre debug `no echo`.

---

# 7. IFG off-by-one

V tvojom module pri prechode do IFG nastavuješ:

```systemverilog
ifg_cnt_q <= 8'(IFG_CYCLES - 1);
state_q   <= ST_IFG;
```

V `ST_IFG` robíš:

```systemverilog
if (ifg_cnt_q == 8'd0) begin
  state_q <= ST_IDLE;
end else begin
  ifg_cnt_q <= ifg_cnt_q - 8'd1;
end
```

Ak `IFG_CYCLES=12`, tak cykly v ST_IFG budú:

```text
11,10,9,8,7,6,5,4,3,2,1,0
```

Pri cykle s `0` ešte stále držíš `TXEN=0`, takže dostaneš 12 cyklov IFG. To je vlastne OK.

Len si daj pozor, že v taxi je `cfg_tx_ifg` používaný trochu inak a pri MII sa pozerá `ifg_cnt_reg[7:1]`, lebo MII má polovičné bajtové cykly.

Pre GMII-only je tvoj IFG model v poriadku.

---

# 8. Underflow TXER správanie

Pri underflow robíš:

```systemverilog
gmii_tx_en_o <= 1'b0;
gmii_tx_er_o <= 1'b1;
```

V GMII je typicky `TX_ER` významný počas `TX_EN=1`. Ak dáš `TX_ER=1` s `TX_EN=0`, PHY to nemusí interpretovať ako frame error.

Taxi pri error stave zachováva `gmii_tx_en_next = 1'b1` a dáva `gmii_tx_er_next = frame_error_reg` vo fáze posledného payload/pad/FCS bajtu.

Odporúčanie:

Pri underflow v strede frame by som spravil:

```systemverilog
gmii_tx_en_o   <= 1'b1;
gmii_tx_er_o   <= 1'b1;
gmii_txd_o     <= 8'h00;
tx_underflow_q <= tx_underflow_q + 16'd1;
state_q        <= ST_IFG;
```

A až v ďalšom cykle `ST_IFG`:

```systemverilog
gmii_tx_en_o <= 1'b0;
gmii_tx_er_o <= 1'b0;
```

Tak PHY dostane aspoň jeden chybový cyklus v rámci frame.

---

# 9. Chýba max frame length / oversize

Taxi má:

```systemverilog
cfg_tx_max_pkt_len
frame_len_lim_reg
stat_tx_err_oversize
```

Tvoj TX zatiaľ nemá max length kontrolu.

Pre testy do 1492 B to nevadí, ale pre robustný MAC by som pridal:

```systemverilog
parameter int MAX_FRAME_LEN = 1518;
logic [15:0] frame_len_q;
logic [15:0] stat_tx_oversize_q;
```

Počítaj frame bez preambuly/SFD, vrátane header+payload+pad+FCS alebo aspoň header+payload+pad. Pri prekročení abortuj alebo označ frame bad.

---

# 10. Chýbajú detailné TX statusy

Tvoj modul má len:

```systemverilog
stat_tx_frames
stat_tx_underflow
```

Taxi má oveľa bohatšie statusy:

```text
stat_tx_byte
stat_tx_pkt_len
stat_tx_pkt_ucast/mcast/bcast/vlan
stat_tx_pkt_good/bad
stat_tx_err_oversize
stat_tx_err_user
stat_tx_err_underflow
```

Pre HW bring-up by som minimálne doplnil sticky/counter signály:

```systemverilog
output logic        stat_tx_started,
output logic        stat_tx_header_done,
output logic        stat_tx_payload_seen,
output logic        stat_tx_tlast_seen,
output logic        stat_tx_fcs_done,
output logic [15:0] stat_tx_good,
output logic [15:0] stat_tx_user_error,
output logic [15:0] stat_tx_len_mismatch
```

Ak teraz máš `0/10 no echo`, potrebuješ vedieť:

```text
dostal TX meta?
dostal TX payload?
videl tlast?
prešiel do FCS?
asertoval TXEN?
```

---

# 11. Najväčší praktický rozdiel voči taxi: pipeline vstupu

Taxi začína čítať AXI stream už počas konca preambuly:

```systemverilog
if (pre_cnt_reg == 1) begin
  s_axis_tx_tready_next = 1'b1;
  s_tdata_next = s_axis_tx.tdata;
end
```

Potom pri SFD už má prvý payload/header byte pripravený v `s_tdata_reg`.

Tvoj modul začne dávať `s_axis_tready_o` až v `ST_PAYLOAD`, teda po odvysielaní headeru. To je v poriadku, pretože tvoj header negeneruje vstupný stream, ale lokálny `hdr_shift_q`.

Len z toho plynie:

```text
payload FIFO musí držať prvý payload byte validný, kým TX dokončí preambulu + SFD + header.
```

Ak echo_app alebo FIFO nevie takto držať valid, TX vyhodí underflow. Preto je dôležité debugovať `stat_tx_underflow`.

---

# 12. Potenciálny problém s clean echo: TX čaká payload hneď po headeri

Po `ST_HEADER` ideš priamo do:

```systemverilog
state_q <= ST_PAYLOAD;
```

V ďalšom cykle, ak `s_axis_tvalid_i=0`, hneď underflow.

To znamená:

```text
echo_app musí zabezpečiť, že pri odovzdaní tx_meta už bude payload FIFO pripravené.
```

Ak echo_app najprv pošle metadata a až potom začne pripravovať payload, TX stihne spadnúť na underflow. Toto je veľmi pravdepodobný dôvod `no echo`, ak `stat_tx_underflow` rastie.

Možné riešenia:

### Riešenie A — echo_app garantuje payload pred meta

Echo app pošle `tx_meta_valid` až keď vie, že payload FIFO má prvý bajt.

### Riešenie B — TX pridá stav `ST_WAIT_PAYLOAD`

Po headeri:

```systemverilog
ST_WAIT_PAYLOAD: begin
  gmii_tx_en_o <= 1'b0; // toto by ale rozbilo frame, ak už bola vyslaná preambula/header
end
```

To nejde po začatí Ethernet rámca, lebo nesmieš vložiť medzeru medzi header a payload.

### Riešenie C — TX počká na payload ešte pred preambulou

Najlepšie: v `ST_IDLE` začať frame až keď platí:

```systemverilog
meta_fire_w && payload_available_i
```

alebo mať vstup:

```systemverilog
input logic s_axis_frame_ready_i;
```

Prakticky:

```text
TX nesmie začať preambulu/header, kým nie je isté, že celý payload frame alebo aspoň prvý beat je pripravený.
```

Pre tvoj store/cut-through systém by som odporúčal, aby `echo_app` posielal TX meta až po tom, čo je payload frame komplet vo FIFO. Keďže RX meta vzniká až na konci frame, payload už vo FIFO byť má. Takže ak je underflow, problém je skôr v echo_app čítaní FIFO/handshake než v TX MAC.

---

# 13. Kľúčové odporúčané úpravy `eth_tx_mac`

Minimálny patch:

```systemverilog
logic meta_fire_w;

assign s_meta_ready_o  = (state_q == ST_IDLE);
assign s_axis_tready_o = (state_q == ST_PAYLOAD);
assign meta_fire_w     = s_meta_valid_i && s_meta_ready_o;
assign fire_w          = s_axis_tvalid_i && s_axis_tready_o;
```

V `ST_IDLE`:

```systemverilog
if (meta_fire_w) begin
  ...
end
```

V `ST_PAYLOAD`:

```systemverilog
if (!fire_w) begin
  gmii_tx_en_o   <= 1'b1;
  gmii_tx_er_o   <= 1'b1;
  gmii_txd_o     <= 8'h00;
  tx_underflow_q <= tx_underflow_q + 16'd1;
  ifg_cnt_q      <= 8'(IFG_CYCLES - 1);
  state_q        <= ST_IFG;
end else if (s_axis_tuser_i) begin
  gmii_tx_en_o   <= 1'b1;
  gmii_tx_er_o   <= 1'b1;
  gmii_txd_o     <= s_axis_tdata_i;
  tx_user_error_q <= tx_user_error_q + 16'd1;
  ifg_cnt_q      <= 8'(IFG_CYCLES - 1);
  state_q        <= ST_IFG;
end else begin
  ...
end
```

A doplniť aspoň tieto statusy:

```systemverilog
output logic [15:0] stat_tx_good,
output logic [15:0] stat_tx_user_error,
output logic        stat_tx_active,
output logic        stat_tx_payload_seen,
output logic        stat_tx_fcs_seen
```

---

## Záver

Tvoj `eth_tx_mac.sv` je dobrý základ a pre clean MAC architektúru je vhodnejší než priame použitie `taxi_axis_gmii_tx`, pretože skladá header z metadata. Ale z taxi modulu by som prevzal tri dôležité veci:

```text
1. dôsledné oddelenie prijatia bajtu od jeho vyslania cez vstupný register,
2. frame_error mechanizmus s tuser/underflow/oversize,
3. bohatšie statusy pre debug.
```

Najpravdepodobnejší praktický problém v tvojej aktuálnej echo ceste je toto:

```text
TX MAC začne vysielať preambulu/header po prijatí metadata,
ale po headeri nemá okamžite dostupný payload beat,
spadne do underflow a nevygeneruje platný frame.
```

Preto pri ďalšom teste sleduj `stat_tx_underflow`. Ak rastie, problém je medzi `echo_app -> payload FIFO -> eth_tx_mac`, nie v CRC/FCS.
