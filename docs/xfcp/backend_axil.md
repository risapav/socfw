# XFCP — AXI-Lite Backend

**Modul:** `xfcp_axi_engine.sv`  
**Opkody:** READ (0x10), WRITE (0x11) → RESP_READ (0x12), RESP_WRITE (0x13)

---

## Ucel

`xfcp_axi_engine` prekladá XFCP READ/WRITE prikazy na AXI4-Lite transakcie.
Jeden engine obsluhuje jeden AXI-Lite slave. `xfcp_fabric_endpoint` inštanciuje
`NUM_SLAVES` engineov (typicky 7 pre xfcp_test_10_axifull).

---

## Parametre

| Parameter      | Typ  | Default | Popis                                        |
|----------------|------|---------|----------------------------------------------|
| LITTLE_ENDIAN  | bit  | 1       | 1 = byte-swap RDATA/WDATA (PC je LE)         |
| AXI_ADDR_WIDTH | int  | 32      | Sirka adresy AXI-Lite                        |
| AXI_DATA_WIDTH | int  | 32      | Sirka dat AXI-Lite                           |
| COUNT_WIDTH    | int  | 16      | Sirka XFCP COUNT pola                        |
| FIFO_DEPTH     | int  | 32      | Hlbka rdata FIFO (min = max burst words)     |
| TIMEOUT_VAL    | int  | 1000    | Watchdog v taktoch (ocaka RVALID/BVALID)     |

---

## Rozhranie

| Port                   | Smer   | Sirka | Popis                                       |
|------------------------|--------|-------|---------------------------------------------|
| clk, rst_n             | in     | 1     | Hodiny, asynch. reset aktívny v 0           |
| m_axil                 | master | —     | AXI4-Lite master interface                  |
| req_hdr                | in     | 56    | XFCP request header (xfcp_req_hdr_t)        |
| req_valid, req_ready   | in/out | 1     | Request handshake od fabric endpointu       |
| req_is_write_i         | in     | 1     | Pre-decoded: 1 ak WRITE                     |
| write_data, _valid, _ready | in/out | 32 | Payload pre WRITE (z parsera)           |
| read_data, _valid, _ready  | out/in | 32 | Payload pre RESP_READ (do packetizera)  |
| done_o                 | out    | 1     | 1 cyklus pulse po dokonceni transakcie      |
| resp_status_o          | out    | 8     | xfcp_status_e pre response                  |

---

## FSM stavy

### WRITE path

```
ST_IDLE
  req_valid && req_ready -> ST_WR_ADDR

ST_WR_ADDR
  Vydava AWVALID. Po AWREADY -> ST_WR_DATA

ST_WR_DATA
  Vydava WVALID pre kazde slovo z write_data.
  WLAST pre posledne slovo. Po WREADY+WLAST -> ST_WR_B

ST_WR_B
  Caka na BVALID. Zachytava BRESP -> ST_NEXT

ST_NEXT
  Ak zostali dalsi slova: -> ST_WR_ADDR (burst pokracovanie)
  Ak koniec: -> ST_DONE

ST_DONE
  Vydava done_o=1, nastavi resp_status_o -> ST_IDLE
```

### READ path

```
ST_IDLE
  req_valid && req_ready -> ST_RD_ADDR

ST_RD_ADDR
  Vydava ARVALID+ARADDR. Po ARREADY -> ST_RD_WAIT

ST_RD_WAIT
  Caka na RVALID. Uklada RDATA do rfifo. Po RVALID+RLAST -> ST_NEXT

ST_NEXT
  Ak zostali dalsi slova: -> ST_RD_ADDR
  Ak koniec: -> ST_DONE

ST_DONE
  Vydava done_o=1 -> ST_IDLE
```

Burst je rozdeleny na jednowordove AXI-Lite transakcie (ARLEN=0, AWLEN=0).

---

## Timing

- Minimalna latencia READ: 4 cykly (RD_ADDR + ARREADY + RD_WAIT + RVALID)
- Minimalna latencia WRITE: 5 cyklov (WR_ADDR + AWREADY + WR_DATA + WREADY + WR_B + BVALID)
- Pri `TIMEOUT_VAL=1000`: 8 µs na 125 MHz

---

## Endianita

`LITTLE_ENDIAN=1` (default): bajty v kazdom slove su prehodene.
XFCP prenaša bajty MSB-first (sietovy poriadok), PC registre su LE:
```
XFCP bajty: [0xFF000004] -> AB CD EF 01  (request bajty 9..12)
AXI WDATA (LE):           -> 01 EF CD AB (zapisane do registra)
readback cez XFCP:        -> AB CD EF 01 (odoslane MSB-first)
```

---

## Integrácia (xfcp_fabric_endpoint)

Fabric endpoint inštanciuje engine takto:

```systemverilog
xfcp_axi_engine #(
  .LITTLE_ENDIAN (1),
  .TIMEOUT_VAL   (1000)
) g_engine[N-1:0] (
  .clk            (clk),
  .rst_n          (rst_n),
  .m_axil         (m_axil[N-1:0]),
  .req_hdr        (eng_req_hdr),
  .req_valid      (eng_req_valid[i]),
  .req_ready      (eng_req_ready[i]),
  ...
);
```
