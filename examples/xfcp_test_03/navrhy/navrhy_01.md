Skontroloval som nahratú verziu RTL. `xfcp_uart_mmio_top.sv` už vyzerá správne v dvoch dôležitých bodoch: má `LITTLE_ENDIAN(1'b0)` a RX cestu cez `u_rx_fifo`. To sedí so stavom v `XFCP2_STATUS.md`, kde je RX FIFO uvedené ako oprava po regresii.

Ale v aktuálne nahratom `xfcp_fabric_endpoint.sv` stále vidím **3 zásadné problémy**.

## 1. Problem F ešte nie je opravený

V aktuálnom súbore stále platí:

```systemverilog
assign req_ready    = dec_valid
                      && !eng_busy[dec_sel]
                      && eng_req_ready[dec_sel]
                      && ofifo_wready;

assign ofifo_wvalid = req_fire;
assign wdata_sel    = req_valid ? dec_sel : slave_sel_q;
assign wdata_valid  = wdata_valid_raw;
assign wdata_ready  = eng_wdata_ready[wdata_sel];
```

To znamená:

* pri neplatnej adrese je `dec_valid=0`,
* `req_ready=0`,
* header sa neodoberie,
* `dec_sel` ostáva defaultne `0`,
* write payload môže stále tiecť na slave 0.

Toto presne zodpovedá riziku v statuse: invalid WRITE môže defaultovať na slave 0 a T4 bol zatiaľ skipnutý.

Minimálna oprava:

```systemverilog
logic invalid_req;
assign invalid_req = req_valid && !dec_valid;

assign req_ready =
    invalid_req ? 1'b1 :
    dec_valid && !eng_busy[dec_sel] && eng_req_ready[dec_sel] && ofifo_wready;

assign ofifo_wvalid = req_fire && !invalid_req;
assign wdata_valid  = wdata_valid_raw && dec_valid;
```

Pre WRITE je však lepšie doplniť aj `drop_wdata_q`, aby sa payload neplatného WRITE paketu celý odčerpal a parser nezostal zaseknutý.

## 2. `eng_busy` sa môže omylom nastaviť pri invalid requeste

Aktuálne:

```systemverilog
if (req_valid && req_ready && dec_sel == SEL_W'(i))
  eng_busy[i] <= 1'b1;
```

Keď pridáš invalid path s `req_ready=1`, toto by bez ďalšej ochrany nastavilo `eng_busy[0]`.

Správne:

```systemverilog
if (req_valid && req_ready && dec_valid && dec_sel == SEL_W'(i))
  eng_busy[i] <= 1'b1;
```

alebo s pomocným signálom:

```systemverilog
logic dispatch_fire;
assign dispatch_fire = req_valid && req_ready && dec_valid;

if (dispatch_fire && dec_sel == SEL_W'(i))
  eng_busy[i] <= 1'b1;
```

## 3. Timeout `resp_type` z engine sa stále stráca

V `xfcp_axi_engine.sv` je timeout oprava pripravená: pri timeout READ má engine vrátiť `RESP_WRITE`, aby packetizer nečakal na payload. Status to označuje ako FIX G.

Ale vo `xfcp_fabric_endpoint.sv` je výstup engine stále nezapojený:

```systemverilog
.resp_type         (),
.error_timeout     ()
```

a fabric si typ odpovede generuje iba z pôvodného opcode:

```systemverilog
resp_type_q <= (ofifo_rdata.op == XFCP_OP_READ)
             ? XFCP_OP_RESP_READ
             : XFCP_OP_RESP_WRITE;
```

To znamená: ak READ timeoutne, engine chce poslať `RESP_WRITE`, ale fabric aj tak spustí packetizer ako `RESP_READ`. To môže viesť na packetizer čakanie na neexistujúce dáta.

Oprava:

```systemverilog
xfcp_op_e eng_resp_type [NUM_SLAVES];
logic     eng_error_timeout [NUM_SLAVES];
```

v inštancii engine:

```systemverilog
.resp_type     (eng_resp_type[gi]),
.error_timeout (eng_error_timeout[gi])
```

a pri `resp_start_pulse`:

```systemverilog
resp_type_q <= eng_resp_type[ofifo_rdata.sel];
```

## 4. `resp_done_mux = resp_start_pulse || resp_done_held_q` je stále podozrivé

Toto je uvedené v statuse ako oprava pôvodného deadlocku.  Funkčne však stále platí riziko, ktoré som spomínal predtým: packetizer dostane `resp_done_i` hneď na začiatku response, ešte pred payloadom.

Pre single-word READ to môže fungovať. Pre multi-word READ je to rizikové, pretože `done_latch_q` sa nastaví už pred prvým slovom a packetizer môže ukončiť payload po prvom 32-bit slove.

Najčistejšie riešenie je neprenášať „koniec payloadu“ cez oneskorený pulz, ale cez počet slov z requestu. Čiže do `order_entry_t` pridať `count`:

```systemverilog
typedef struct packed {
  logic [SEL_W-1:0] sel;
  xfcp_op_e         op;
  logic [15:0]      count;
} order_entry_t;
```

a packetizer nech ukončuje READ response po presnom počte odoslaných slov, nie podľa `resp_done_i`.

## Moje odporúčané poradie

Najprv by som nerobil ďalší HW test. Opravil by som tieto veci:

1. invalid WRITE drain/drop path,
2. `eng_busy` iba pri `dec_valid`,
3. prepojenie `eng_resp_type` do fabricu,
4. multi-word READ test cez fabric,
5. invalid WRITE test odskipovať ako T4,
6. až potom `make regression` a Quartus rebuild.

Najpravdepodobnejší zdroj sporadických `0B response` teraz vidím vo fabric/packetizer handshaku a invalid-path správaní, nie v UART RX FIFO.
