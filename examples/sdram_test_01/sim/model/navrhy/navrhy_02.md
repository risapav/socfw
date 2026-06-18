Analyzoval som `axil_slave_model.sv`. Je to dobrý jednoduchý AXI-Lite slave model pre testbench, ale našiel som niekoľko miest, ktoré by som pred zaradením do sim knižnice upravil.

## Krátky verdikt

Model je použiteľný pre jednoduché testy:

```text
AXI-Lite master → axil_slave_model → interná RAM
```

Podporuje:

```text
- nezávislé prijatie AW a W kanála,
- byte strobes cez WSTRB,
- jednoduché READ,
- základnú internú pamäť,
- B/R response OKAY.
```

Ale nie je ešte ideálny ako všeobecný „referenčný AXI-Lite slave model“, lebo:

```text
- out-of-range access stále vracia OKAY, nie SLVERR/DECERR,
- šírky sú miestami natvrdo 32-bit,
- model umožní prijať ďalší write request počas neprevzatej B odpovede,
- reset inicializuje celú pamäť slučkou, čo môže byť pri väčšom MEM_DEPTH pomalé,
- debug `$warning` pri BREADY=0 bude hlučný pri legitímnom backpressure,
- chýbajú voliteľné wait-states/backpressure režimy.
```

---

# 1. AXI-Lite handshake

WRITE cesta je koncepčne dobrá:

```systemverilog
assign s_axil.AWREADY = !aw_pend_q;
assign s_axil.WREADY  = !w_pend_q;
```

To znamená, že AW a W kanál môžu prísť v ľubovoľnom poradí. Toto je správne.

Zápis sa vykoná až keď sú zachytené oba:

```systemverilog
if (aw_pend_q && w_pend_q && !b_valid_q) begin
  ...
  b_valid_q <= 1'b1;
end
```

To je tiež správne.

## Pozor na ďalší write počas `BVALID`

Keď `b_valid_q=1`, model znova nastaví:

```systemverilog
AWREADY = 1
WREADY  = 1
```

pretože `aw_pend_q=0` a `w_pend_q=0`.

Teda model môže prijať ďalší AW/W ešte predtým, než master prevezme predchádzajúci `BVALID`.

Nie je to nutne chyba, pretože máš interný 1-entry buffer pre ďalší AW a W. Ale pre AXI-Lite slave model je jednoduchšie a bezpečnejšie štandardne držať iba **jeden outstanding write**.

Odporúčam pridať parameter:

```systemverilog
parameter bit ALLOW_WRITE_PIPELINING = 1'b0
```

a pre jednoduchý režim:

```systemverilog
assign s_axil.AWREADY = !aw_pend_q && (!b_valid_q || ALLOW_WRITE_PIPELINING);
assign s_axil.WREADY  = !w_pend_q  && (!b_valid_q || ALLOW_WRITE_PIPELINING);
```

Pre väčšinu testbenchov by som defaultne dal:

```systemverilog
ALLOW_WRITE_PIPELINING = 1'b0
```

---

# 2. READ cesta

READ cesta je jednoduchá a v zásade správna:

```systemverilog
assign s_axil.ARREADY = !r_valid_q;
assign s_axil.RVALID  = r_valid_q;
assign s_axil.RDATA   = rdata_q;
```

To znamená jeden outstanding read. To je pre AXI-Lite úplne v poriadku.

Pri prijatí adresy:

```systemverilog
if (s_axil.ARVALID && s_axil.ARREADY) begin
  rdata_q   <= rdata_comb;
  r_valid_q <= 1'b1;
end
```

a `RDATA` sa drží, kým master dá `RREADY`.

Toto je správne.

---

# 3. Parametrizácia nie je úplne čistá

Máš:

```systemverilog
parameter int unsigned ADDR_WIDTH = 32,
parameter int unsigned DATA_WIDTH = 32,
parameter int unsigned MEM_DEPTH  = 1024
```

Ale niektoré veci sú natvrdo 32-bit:

```systemverilog
logic [31:0] widx, ridx;
assign widx = 32'(s_axil.AWADDR) >> WORD_BITS;
assign ridx = 32'(s_axil.ARADDR) >> WORD_BITS;
assign rdata_comb = (ridx < MEM_DEPTH) ? mem[ridx] : 32'hBAAD_F00D;
```

Ak `DATA_WIDTH != 32`, toto bude problém. Ak `ADDR_WIDTH > 32`, adresu orežeš.

Odporúčam:

```systemverilog
localparam int unsigned STRB_W     = DATA_WIDTH / 8;
localparam int unsigned WORD_BITS  = $clog2(STRB_W);
localparam int unsigned MEM_IDX_W  = (MEM_DEPTH <= 1) ? 1 : $clog2(MEM_DEPTH);

logic [ADDR_WIDTH-1:0] widx_full, ridx_full;

assign widx_full = s_axil.AWADDR >> WORD_BITS;
assign ridx_full = s_axil.ARADDR >> WORD_BITS;
```

A out-of-range dátovú hodnotu parametrizovať:

```systemverilog
parameter logic [DATA_WIDTH-1:0] OOR_READ_DATA = {DATA_WIDTH{1'bx}};
```

alebo ak chceš čitateľný pattern:

```systemverilog
function automatic logic [DATA_WIDTH-1:0] bad_read_data();
  logic [DATA_WIDTH-1:0] v;
  v = '0;
  v[31:0] = 32'hBAAD_F00D;
  return v;
endfunction
```

---

# 4. `WSTRB` support je dobrý

Toto je správne:

```systemverilog
for (int b = 0; b < STRB_W; b++)
  if (wstrb_q[b])
    mem[waddr_idx_q][b*8 +: 8] <= wdata_q[b*8 +: 8];
```

To dobre testuje byte-enable zápisy.

Odporúčam doplniť parameter:

```systemverilog
parameter bit CHECK_WSTRB_ZERO = 1'b0
```

Ak `WSTRB == 0`, AXI-Lite write je teoreticky no-op, ale pre testy je dobré vedieť, že sa to stalo:

```systemverilog
if (CHECK_WSTRB_ZERO && (wstrb_q == '0))
  $warning("[AXIL_SLAVE] WRITE with WSTRB=0 at addr=0x%0h", awaddr_q);
```

---

# 5. Out-of-range access by mal vedieť vrátiť chybu

Teraz pri out-of-range WRITE model len nič nezapíše, ale stále vráti:

```systemverilog
BRESP = OKAY
```

a pri READ vráti:

```systemverilog
RDATA = 32'hBAAD_F00D
RRESP = OKAY
```

Pre jednoduchý model je to použiteľné, ale pre testovanie AXI masterov by bolo lepšie mať parameter:

```systemverilog
parameter bit ERROR_ON_OOR = 1'b1
```

A potom:

```systemverilog
logic [1:0] bresp_q;
logic [1:0] rresp_q;

assign s_axil.BRESP = bresp_q;
assign s_axil.RRESP = rresp_q;
```

Pri write:

```systemverilog
if (waddr_idx_q < MEM_DEPTH) begin
  bresp_q <= AXI_RESP_OKAY;
  ...
end else begin
  bresp_q <= ERROR_ON_OOR ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
end
```

Pri read:

```systemverilog
if (ridx < MEM_DEPTH) begin
  rdata_q <= mem[ridx];
  rresp_q <= AXI_RESP_OKAY;
end else begin
  rdata_q <= OOR_READ_DATA;
  rresp_q <= ERROR_ON_OOR ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
end
```

Toto ti veľmi pomôže pri testovaní `xfcp_axi_engine`, lebo uvidíš, či master správne spracuje `SLVERR`.

---

# 6. Chýbajú wait-state režimy

Momentálne model odpovedá takmer okamžite:

```text
AWREADY=1, ak nie je pending
WREADY=1, ak nie je pending
ARREADY=1, ak nie je RVALID
```

Na základné testy dobré. Ale pre robustné testovanie AXI mastera by som pridal voliteľné ready delaye:

```systemverilog
parameter int unsigned AW_READY_DELAY = 0;
parameter int unsigned W_READY_DELAY  = 0;
parameter int unsigned AR_READY_DELAY = 0;
parameter int unsigned B_VALID_DELAY  = 0;
parameter int unsigned R_VALID_DELAY  = 0;
```

Alebo jednoduchší variant:

```systemverilog
parameter bit RANDOM_STALL = 1'b0;
```

S tým vieš overiť, že master drží `AWVALID/WVALID/ARVALID` a správne čaká.

Pre tvoje XFCP testy je toto veľmi užitočné, lebo AXI engine by mal zvládnuť:

```text
- AWREADY oneskorené,
- WREADY oneskorené,
- BVALID oneskorené,
- ARREADY oneskorené,
- RVALID oneskorené.
```

---

# 7. Debug `$warning` pri `BVALID && !BREADY` je príliš hlučný

Máš:

```systemverilog
if (b_valid_q && !s_axil.BREADY)
  $warning("[%0t ns] SLAVE: BVALID high but BREADY low!", $time);
```

Toto nie je chyba. Je úplne legálne, že master drží `BREADY=0` niekoľko taktov.

Tento warning by som odstránil alebo zmenil na watchdog:

```systemverilog
parameter int unsigned BREADY_TIMEOUT = 0; // 0 = disabled
```

A warning až keď `BVALID` čaká príliš dlho:

```systemverilog
if (BREADY_TIMEOUT != 0 && b_wait_cnt_q > BREADY_TIMEOUT)
  $warning("[AXIL_SLAVE] BVALID held for %0d cycles", b_wait_cnt_q);
```

Rovnako pre `RVALID && !RREADY`.

---

# 8. Reset inicializuje celú pamäť

Toto:

```systemverilog
for (int i = 0; i < MEM_DEPTH; i++) mem[i] <= '0;
```

je OK pre `MEM_DEPTH=1024`. Pri väčšej pamäti to spomalí simuláciu.

Odporúčam parameter:

```systemverilog
parameter bit CLEAR_MEM_ON_RESET = 1'b1
```

Potom:

```systemverilog
if (CLEAR_MEM_ON_RESET) begin
  for (int i = 0; i < MEM_DEPTH; i++)
    mem[i] <= '0;
end
```

Pre väčšie testy môžeš vypnúť a inicializovať iba použité adresy.

---

# 9. Chýba inicializácia zo súboru

Pre testovanie CPU/firmware/loaderov sa hodí:

```systemverilog
parameter string INIT_FILE = "";
```

A:

```systemverilog
initial begin
  if (INIT_FILE != "") begin
    $readmemh(INIT_FILE, mem);
  end
end
```

Tým môžeš prednačítať RAM obraz.

---

# 10. Odporúčaný refaktor modulu

Navrhol by som z neho urobiť sim-only model s týmito parametrami:

```systemverilog
module axil_slave_model #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned MEM_DEPTH  = 1024,

  parameter bit          CLEAR_MEM_ON_RESET = 1'b1,
  parameter bit          ERROR_ON_OOR       = 1'b1,
  parameter bit          ALLOW_WRITE_PIPELINING = 1'b0,
  parameter string       INIT_FILE = "",

  parameter logic [DATA_WIDTH-1:0] OOR_READ_DATA = 'x,

  parameter int unsigned AW_READY_DELAY = 0,
  parameter int unsigned W_READY_DELAY  = 0,
  parameter int unsigned AR_READY_DELAY = 0,
  parameter int unsigned B_VALID_DELAY  = 0,
  parameter int unsigned R_VALID_DELAY  = 0
)(
  input  wire       clk,
  input  wire       rstn,
  axi4lite_if.slave s_axil
);
```

Nemusíš implementovať všetko naraz, ale minimálne by som teraz spravil:

```text
1. parametrické RRESP/BRESP pre out-of-range,
2. odstrániť hlučný BREADY warning,
3. CLEAR_MEM_ON_RESET,
4. INIT_FILE,
5. DATA_WIDTH-safe OOR_READ_DATA.
```

---

# 11. Assertion odporúčania

Do modelu by som pridal voliteľné assertions pod `ASSERT_ON`.

## Master drží AWADDR pri stalled AW

```systemverilog
property p_awaddr_stable;
  @(posedge clk) disable iff (!rstn)
    s_axil.AWVALID && !s_axil.AWREADY
    |=> s_axil.AWVALID && $stable(s_axil.AWADDR);
endproperty
assert property (p_awaddr_stable);
```

## Master drží WDATA/WSTRB pri stalled W

```systemverilog
property p_wdata_stable;
  @(posedge clk) disable iff (!rstn)
    s_axil.WVALID && !s_axil.WREADY
    |=> s_axil.WVALID
        && $stable(s_axil.WDATA)
        && $stable(s_axil.WSTRB);
endproperty
assert property (p_wdata_stable);
```

## Master drží ARADDR pri stalled AR

```systemverilog
property p_araddr_stable;
  @(posedge clk) disable iff (!rstn)
    s_axil.ARVALID && !s_axil.ARREADY
    |=> s_axil.ARVALID && $stable(s_axil.ARADDR);
endproperty
assert property (p_araddr_stable);
```

Tieto assertions testujú mastera, nie slave model. Sú veľmi užitočné v testbenchoch.

---

# 12. Vhodnosť pre XFCP

Pre testovanie `xfcp_axi_engine` je tento model veľmi vhodný, ak ho doplníš o wait-state režimy.

Testy, ktoré by som s ním robil:

```text
T1: READ32 z inicializovanej adresy
T2: WRITE32 + READ32 späť
T3: WSTRB byte mask write
T4: AW pred W
T5: W pred AW
T6: BREADY oneskorené
T7: RREADY oneskorené
T8: ARREADY oneskorené
T9: out-of-range READ → SLVERR
T10: out-of-range WRITE → SLVERR
```

Tým veľmi dobre preveríš AXI engine.

---

# Celkové hodnotenie

## Dobré

```text
- AW/W nezávislé zachytenie.
- WSTRB byte write.
- Jednoduchý a rýchly memory model.
- Kombinačné read source a registrované RDATA.
- Vhodné pre základné testy.
```

## Upraviť

```text
- Parametrizovať out-of-range response.
- Nepoužívať natvrdo 32'hBAAD_F00D pri DATA_WIDTH != 32.
- Odstrániť warning pri legitímnom BREADY backpressure.
- Pridať CLEAR_MEM_ON_RESET a INIT_FILE.
- Pridať voliteľné wait-states/random stalls.
- Pridať assertions na AXI-Lite master stabilitu.
```

Krátko: **model je dobrý základ, ale zatiaľ je príliš “prívetivý” k masterovi.** Pre seriózne overenie AXI-Lite masterov v socfw/XFCP by som ho rozšíril o chybové odpovede, wait-states a assertions.
