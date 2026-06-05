Po zhliadnutí `async_fifo.sv` môžem jednu z predchádzajúcich hypotéz vylúčiť.

Tvoje FIFO **nie je AXI FIFO**. Zápis je:

```systemverilog
if (wr_valid_i && !full_w)
```

takže jednocyklový pulz `meta_wr_valid_q` je úplne v poriadku.

Teda toto:

```systemverilog
meta_wr_valid_q <= 1'b1;
```

na jeden takt FIFO zapíše korektne.

---

## Našiel som podozrivejšiu vec

Pozri TX FSM:

```systemverilog
TXC_IDLE:
  if (meta_rd_valid && !tx_mac_busy_w) begin
      ...
      txc_state_q <= TXC_START;
  end
```

a:

```systemverilog
assign meta_rd_ready =
    (txc_state_q == TXC_IDLE) &&
    meta_rd_valid &&
    !tx_mac_busy_w;
```

FIFO je FWFT.

To znamená:

```text
meta_rd_valid = 1
meta_rd_data  = prvý záznam
```

už pred handshake.

Keď nastavíš `meta_rd_ready=1`, FIFO okamžite posunie pointer.

V tom istom takte však čítaš:

```systemverilog
txc_dst_mac_q <= meta_rd_data[95:48];
txc_src_mac_q <= meta_rd_data[47:0];
```

To by malo byť OK, pretože pointer sa posúva až na hrane.

Takže ani tu nevidím fatálnu chybu.

---

# Skutočný problém môže byť v TX štarte

Pozri sekvenciu:

### cyklus N

```text
TXC_IDLE
meta_rd_valid=1
pkt_rd_valid=0
```

FSM prejde:

```text
TXC_START
```

---

### cyklus N+1

```text
tx_start_i = 1
```

GMII MAC začne vysielať preambulu.

---

### cyklus N+2

```text
TXC_DATA
```

až teraz:

```systemverilog
pkt_rd_ready = txmac_s_tready;
```

---

Ak je `gmii_tx_mac` navrhnutý tak, že po:

```systemverilog
tx_start_i
```

očakáva payload bez medzery, vznikne problém.

---

# Ale je tu ešte horšia vec

Pozri FIFO:

```systemverilog
assign do_rd_w =
    !empty_w &&
    (!oq_valid_q || rd_ready_i);
```

To znamená FWFT.

Keď:

```text
pkt_rd_valid = 1
```

dáta už sedia v:

```systemverilog
pkt_rd_data
```

---

Ty však robíš:

```systemverilog
assign pkt_rd_ready =
    (txc_state_q == TXC_DATA) &&
    txmac_s_tready;
```

takže prvý bajt sa začne odoberať až v stave DATA.

---

A teraz kritická otázka:

### ako vyzerá gmii_tx_mac ?

Ak má:

```systemverilog
s_axis_tready=1
```

už počas preambuly,

tak v prvom takte DATA:

```text
pkt_rd_ready=1
```

FIFO odhodí prvý bajt.

Súčasne:

```text
txmac_s_tdata = pkt_rd_data
```

sa zmení na druhý bajt.

GMII MAC tak môže vidieť:

```text
2. bajt
3. bajt
4. bajt
...
```

Prvý bajt payloadu zmizne.

---

# Veľmi podozrivý detail

V starom návrhu:

```systemverilog
udp
  -> RAM
  -> TX
```

neexistoval FWFT buffer.

V novom návrhu:

```systemverilog
builder
 -> async_fifo FWFT
 -> gmii_tx_mac
```

už áno.

A FWFT + AXI-stream býva presne miesto, kde sa stráca prvý symbol.

---

# Čo by som odmeral

Pridaj na debug:

```systemverilog
logic [7:0] first_pkt_byte;

always_ff @(posedge eth_tx_clk_i)
begin
    if (pkt_rd_valid)
        first_pkt_byte <= pkt_rd_data[7:0];
end
```

a porovnaj s:

```systemverilog
txmac_s_tdata
```

a interným stavom v `gmii_tx_mac`.

---

# Najviac podozrivá časť

Ak by som mal staviť bez ďalších modulov:

1. `gmii_tx_mac` dostáva `tx_start_i` príliš skoro.
2. `meta_rd_valid` sa objaví skôr než `pkt_rd_valid`.
3. TX FSM odštartuje bez payloadu.
4. GMII MAC sa dostane do stavu BUSY a čaká na prvý bajt.
5. Prvý bajt sa stratí alebo nikdy nepríde v očakávanom čase.

Preto by som ako prvý experiment zmenil:

```systemverilog
TXC_IDLE:
  if (meta_rd_valid &&
      pkt_rd_valid &&
      !tx_mac_busy_w)
```

To je najjednoduchší test, ktorý často odhalí CDC rozjazdový problém medzi meta FIFO a packet FIFO. Ak po tejto zmene TX začne fungovať, problém je prakticky určite v časovaní štartu medzi oboma FIFO a `gmii_tx_mac`, nie v samotnom PHY ani v async FIFO implementácii.
