Po porovnaní oboch top-levelov je najväčší rozdiel v tom, že **funkčný dizajn (`ethernet_test.sv`) má TX a RX cestu logicky previazané v jednom module `udp`**, zatiaľ čo v novom dizajne (`ethernet_test_03_top.sv`) si zaviedol:

* RX doména → builder
* async FIFO pre payload
* async FIFO pre metadata
* TX FSM
* gmii_tx_mac

a tým vzniklo niekoľko miest, kde sa môže TX úplne zastaviť.

### Prvá podozrivá chyba: meta commit po poslednom bajte

V RX doméne:

```systemverilog
if (commit_pending_q && meta_wr_ready) begin
    meta_wr_valid_q  <= 1'b1;
    commit_pending_q <= 1'b0;
end

if (txb_fire_w && txb_tlast) begin
    meta_wr_data_q   <= {meta_latch_dst_q, meta_latch_src_q};
    commit_pending_q <= 1'b1;
end
```

Ak:

```systemverilog
txb_fire_w && txb_tlast
```

nastane v rovnakom cykle, keď je:

```systemverilog
meta_wr_ready = 1
```

tak sa `commit_pending_q` nastaví na 1 až po hrane.

Meta sa teda zapíše až v ďalšom cykle.

To je OK.

Ale problém je inde:

```systemverilog
meta_wr_valid_q <= 1'b0;
```

sa nastavuje každý takt.

Ak tvoj `async_fifo` očakáva držanie `wr_valid_i` až do handshake (klasický AXI štýl), môžeš generovať iba jednocyklický pulz.

Potreboval by som vidieť implementáciu `async_fifo`.

---

### Druhá podozrivá chyba: TX FSM môže odštartovať bez payloadu

V TX doméne:

```systemverilog
TXC_IDLE:
    if (meta_rd_valid && !tx_mac_busy_w)
```

FSM štartuje iba podľa metadata FIFO.

Nekontroluje:

```systemverilog
pkt_rd_valid
```

V dôsledku CDC môže nastať:

1. meta FIFO sa objaví na TX strane
2. payload FIFO ešte nie

Potom:

```systemverilog
TXC_START
TXC_DATA
```

a GMII MAC čaká na prvý payload bajt.

Ak `gmii_tx_mac` očakáva payload ihneď po `tx_start_i`, môže sa zaseknúť.

V starom dizajne toto nehrozilo, pretože TX čítal priamo RAM.

Ja by som minimálne skúšobne zmenil:

```systemverilog
if (meta_rd_valid && pkt_rd_valid && !tx_mac_busy_w)
```

---

### Tretia podozrivá chyba: strata prvého bajtu

Pozri:

```systemverilog
TXC_IDLE -> TXC_START
TXC_START -> TXC_DATA
```

a:

```systemverilog
assign pkt_rd_ready =
    (txc_state_q == TXC_DATA) &&
    txmac_s_tready;
```

Prvý payload bajt je vo FIFO už počas:

```systemverilog
TXC_START
```

ale FIFO ešte nečítaš.

Ak `gmii_tx_mac` po `tx_start_i` začne okamžite požadovať payload, prvý bajt sa môže minúť.

Veľa MAC jadier má sekvenciu:

```text
tx_start
↓
vloží DA/SA/TYPE
↓
po niekoľkých taktoch začne čítať payload
```

ale nie všetky.

Toto je veľmi častá chyba.

---

### Štvrtá podozrivá chyba: meta sa latche z nesprávneho handshake

Tu:

```systemverilog
if (tx_meta_valid && tx_meta_ready) begin
    meta_latch_dst_q <= tx_meta.dst_mac;
    meta_latch_src_q <= tx_meta.src_mac;
end
```

Meta sa uloží pri handshaku:

```systemverilog
tx_meta_valid && tx_meta_ready
```

ale do meta FIFO sa zapisuje až pri:

```systemverilog
txb_fire_w && txb_tlast
```

Ak medzi prijatím metadata a posledným payload bajtom príde ďalší paket, môže sa prepísať:

```systemverilog
meta_latch_dst_q
meta_latch_src_q
```

a payload paketu A dostane metadata paketu B.

Starý dizajn tento problém nemal.

---

### Piata podozrivá chyba: reset

V novom dizajne:

```systemverilog
wire rst_w = rst_ni & btn_i[3];
```

a všade:

```systemverilog
always_ff @(posedge ... or negedge rst_w)
```

Ak je tlačidlo na doske aktívne-low a nie je vytiahnuté správne, môžeš mať TX doménu permanentne v resete.

Skontroloval by som:

```systemverilog
txc_state_q
```

či sa vôbec dostane z IDLE.

---

### Čo by som zmeral ako prvé

Podľa debug busu ktorý už máš:

```systemverilog
dbg_ctrl_o[0] = tx_meta_valid
dbg_ctrl_o[1] = tx_meta_ready
dbg_ctrl_o[2] = txb_tvalid
dbg_ctrl_o[3] = txb_fire_w
dbg_ctrl_o[4] = meta_wr_valid_q
dbg_ctrl_o[5] = pkt_rd_valid
dbg_ctrl_o[6] = meta_rd_valid
dbg_ctrl_o[7] = eth_txen_o
```

Pri prijatí UDP paketu by som očakával:

```text
0 -> pulz
1 -> 1
2 -> beh
3 -> beh
4 -> pulz
5 -> 1
6 -> 1
7 -> pulz TX
```

Ak vidíš:

```text
4 funguje
5 = 1
6 = 1
7 = 0
```

tak problém je v TX FSM alebo gmii_tx_mac.

Ak:

```text
4 funguje
5 = 1
6 = 0
```

tak meta FIFO sa nikdy nenaplní.

Ak:

```text
4 = 0
```

tak problém je ešte pred CDC, teda v builder/meta commit logike.

Z toho čo vidím bez ostatných modulov, **najpravdepodobnejší kandidát je štart TX iba na `meta_rd_valid` bez kontroly `pkt_rd_valid`**, prípadne nezhoda handshake medzi `tx_start_i` a prvým payload bajtom v `gmii_tx_mac`. To sú dve miesta, ktoré by som preveroval ako prvé.
