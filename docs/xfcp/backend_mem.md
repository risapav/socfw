# XFCP — AXI4-Full MEM Backend

**Moduly:** `xfcp_mem_adapter.sv`, `axifull_sram.sv`  
**Opkody:** MEM_READ (0x30), MEM_WRITE (0x31) → RESP_MEM_READ (0x32), RESP_MEM_WRITE (0x33)

---

## Ucel

`xfcp_mem_adapter` umoznuje hostovi čítať a zapisovať blok pamäti cez AXI4-Full
(burst transakcie). Backend podporuje INCR burst, 32-bit data, max 256 B na transakciu.
`axifull_sram` je jednoduchy AXI4-Full slave (256 x 32b = 1 KiB) s M9K blokami.

---

## xfcp_mem_adapter

### Parametre

| Parameter       | Typ  | Default | Popis                                              |
|-----------------|------|---------|----------------------------------------------------|
| TIMEOUT_CYCLES  | int  | 1024    | Cykly pred TIMEOUT (pocita len ked slave nereaguje)|
| MAX_BYTES       | int  | 256     | Max bajty na transakciu                            |
| ADDR_WIDTH      | int  | 32      | Sirka AXI adresy                                   |
| DATA_WIDTH      | int  | 32      | Sirka AXI dat (= 4 bajty/beat)                     |

### Rozhranie

| Port                         | Smer   | Sirka | Popis                                 |
|------------------------------|--------|-------|---------------------------------------|
| clk, rst_n                   | in     | 1     | Hodiny, asynch. reset                 |
| mem_req_valid/ready          | in/out | 1     | Request handshake od fabric endpointu |
| mem_req_hdr_i                | in     | 56    | xfcp_req_hdr_t                        |
| mem_wdata_i/valid/ready      | in/out | 32    | Payload pre MEM_WRITE                 |
| mem_rdata_o/valid/ready      | out/in | 32    | Payload pre RESP_MEM_READ             |
| mem_resp_done_o              | out    | 1     | Pulse: transakcia dokoncena           |
| mem_resp_status_o            | out    | 8     | Status pre response header            |
| m_axi_aw*                    | out    | —     | AXI4 Write Address channel            |
| m_axi_w*                     | out    | —     | AXI4 Write Data channel               |
| m_axi_b*                     | in     | —     | AXI4 Write Response channel           |
| m_axi_ar*                    | out    | —     | AXI4 Read Address channel             |
| m_axi_r*                     | in     | —     | AXI4 Read Data channel                |

### AXI4 signatury (burst)

| Signal       | Hodnota         | Popis                        |
|--------------|-----------------|------------------------------|
| AWLEN/ARLEN  | COUNT/4 - 1     | Pocet beatov - 1             |
| AWSIZE/ARSIZE| 3'b010          | 4 bajty/beat                 |
| AWBURST/ARBURST | 2'b01        | INCR (adresa inkrementuje)   |
| WSTRB        | 4'b1111         | Vsetky bajty platne          |

### FSM — MEM_READ

```
ST_IDLE
  Caka na mem_req_valid (opcode MEM_READ)

ST_AR
  Vydava ARVALID, ARADDR, ARLEN. Po ARREADY -> ST_R
  Timeout bezi od ST_AR (slave nereaguje na AR)

ST_R
  Prijima RDATA beaty do interneho rfifo (64-entry).
  RREADY = rfifo_not_full (backpressure).
  Po RLAST -> ST_DONE_PLS

ST_DONE_PLS
  Vydava mem_resp_done_o=1, status -> ST_DATA

ST_DATA
  Cita rfifo a vydava mem_rdata_o pre packetizer -> ST_IDLE po poslednom slove
```

### FSM — MEM_WRITE

```
ST_IDLE
  Caka na mem_req_valid (opcode MEM_WRITE)

ST_AW_W
  Vydava AW aj W kanál simultanne.
  Ak AWREADY prislo ale nie WLAST: -> ST_W_ONLY
  Ak WLAST prislo ale nie AWREADY: -> ST_AW_ONLY
  Ak obe: -> ST_B

ST_AW_ONLY / ST_W_ONLY
  Dokoncuje prislusny kanal -> ST_B

ST_B
  Caka na BVALID. Zachytava BRESP -> ST_DONE_PLS

ST_DONE_PLS
  Vydava mem_resp_done_o=1, status -> ST_IDLE
```

### Timeout

Timeout pocitadlo bezi iba ked `mem_wdata_valid_i=1` (slave dostava data) alebo
ked caka na AXI handshake. **Nuluje sa** ked `mem_wdata_valid_i=0` — teda
timeout neplynie pocas cakania na UART payload.

Pre UART 115200 baud: 4 bajty trva ~34 720 cyklov na 125 MHz. `TIMEOUT_CYCLES=1024`
je bezpecny, pretoze pocitadlo neide pocas cakania na bajty.

---

## axifull_sram

### Parametre

| Parameter  | Typ  | Default | Popis                              |
|------------|------|---------|------------------------------------|
| DEPTH      | int  | 256     | Pocet 32-bitovych slov (= 1 KiB)  |
| ADDR_WIDTH | int  | 32      | Sirka AXI adresy                   |

### Architektura (M9K inference)

SRAM je implementovana ako **4 samostatne byte-lane M9K polia**:

```systemverilog
(* ramstyle = "M9K" *) logic [7:0] mem0 [0:DEPTH-1];  // bajty [7:0]
(* ramstyle = "M9K" *) logic [7:0] mem1 [0:DEPTH-1];  // bajty [15:8]
(* ramstyle = "M9K" *) logic [7:0] mem2 [0:DEPTH-1];  // bajty [23:16]
(* ramstyle = "M9K" *) logic [7:0] mem3 [0:DEPTH-1];  // bajty [31:24]
```

**Kritické pravidlo pre M9K inference v Cyclone IV:**

1. Zapis musi byt v **dedicovanom** `always_ff` bloku (bez FSM registrov)
2. Citanie musi byt **bezpodmienecne** — vzdy `rd_data <= mem[addr]`
3. Pametove pole nesmie mat reset

```systemverilog
// Zapis — dedicated always_ff, bez reset
always_ff @(posedge clk) begin
  if (wr_en) begin
    if (s_axi_wstrb[0]) mem0[wr_waddr] <= s_axi_wdata[ 7: 0];
    if (s_axi_wstrb[1]) mem1[wr_waddr] <= s_axi_wdata[15: 8];
    if (s_axi_wstrb[2]) mem2[wr_waddr] <= s_axi_wdata[23:16];
    if (s_axi_wstrb[3]) mem3[wr_waddr] <= s_axi_wdata[31:24];
  end
end

// Citanie — dedicated always_ff, BEZPODMIENECNE (M9K output register)
always_ff @(posedge clk) begin
  rd_data_q <= {mem3[rd_waddr], mem2[rd_waddr],
                mem1[rd_waddr], mem0[rd_waddr]};
end
```

Podmienecne citanie (napr. `if (rd_en) rd_data <= mem[addr]`) sposobi, ze
Quartus namapuje pamäť na LUT mux (~10 ns combinacna cesta, WNS -2 ns na 125 MHz).

### FSM

**WR FSM:** WR_IDLE → WR_DATA → WR_RESP

```
WR_IDLE: caka na AWVALID, zachytava awaddr -> WR_DATA
WR_DATA: prijima WDATA beaty (WREADY=1), posledny beat (WLAST) -> WR_RESP
WR_RESP: vydava BVALID, BRESP=OKAY -> WR_IDLE
```

**RD FSM:** RD_IDLE → RD_DATA → RD_WAIT

```
RD_IDLE: caka na ARVALID, zachytava araddr, arlen -> RD_DATA
RD_DATA: vydava RDATA z rfifo, RVALID=1, RLAST pri poslednom -> RD_WAIT
RD_WAIT: caka na RREADY pre posledny beat -> RD_IDLE
```

Citacia latencia: 1 cyklus (M9K output register) — RD_DATA vydava platne data
1 cyklus po zachyteni adresy.

### Resource usage (sama axifull_sram, 256x32b)

| Metric       | Hodnota          |
|--------------|------------------|
| M9K bloky    | 4 (jeden/lane)   |
| Memory bits  | 4 × 2048 = 8192  |
| LEs (FSM)    | ~50              |

---

## Known limits (v1.0)

| Limit                  | Popis                                                 |
|------------------------|-------------------------------------------------------|
| Single outstanding     | Len jedna MEM transakcia naraz (busy flag v endpointe)|
| INCR burst only        | AWBURST/ARBURST = 2'b01 (WRAP/FIXED nepodporovane)    |
| DATA_WIDTH = 32b       | Ine sirky dat nepodporovane                           |
| MAX_BYTES = 256 B      | Vacsie transfery treba segmentovat na hosta           |
| 4-byte align           | COUNT musi byt nasobok 4                              |
| Adresny priestor 1 KiB | axifull_sram: DEPTH=256 x 4B = 1024 B                 |
| No ECC                 | Bez detekcie/opravy chyb v pamati                     |
