# XFCP — AXI-Stream Backend

**Modul:** `xfcp_axis_adapter.sv`  
**Opkody:** STREAM_WRITE (0x20), STREAM_READ (0x21) → RESP_STREAM_WRITE (0x22), RESP_STREAM_READ (0x23)

---

## Ucel

`xfcp_axis_adapter` umoznuje hostovi posiela a prijimať bajty cez AXI-Stream.
Typicke pouzitie: loopback test, prenos bloku dat, pipeline inject/capture.

---

## Parametre

| Parameter        | Typ  | Default | Popis                                          |
|------------------|------|---------|------------------------------------------------|
| TIMEOUT_CYCLES   | int  | 1024    | Cykly bez handshake pred TIMEOUT               |
| MAX_STREAM_BYTES | int  | 256     | Max bajty na transakciu (COUNT <= tato hodnota)|
| RFIFO_DEPTH      | int  | 64      | Hlbka rdata FIFO v slovach (>= MAX/4)          |

---

## Rozhranie

| Port                        | Smer   | Sirka | Popis                                        |
|-----------------------------|--------|-------|----------------------------------------------|
| clk, rst_n                  | in     | 1     | Hodiny, asynch. reset                        |
| axis_req_valid/ready        | in/out | 1     | Request handshake od fabric endpointu        |
| axis_req_hdr_i              | in     | 56    | xfcp_req_hdr_t (opcode, seq, addr, count)    |
| axis_wdata_i/valid/ready    | in/out | 32    | Wdata payload (STREAM_WRITE)                 |
| axis_rdata_o/valid/ready    | out/in | 32    | Rdata payload (STREAM_READ odpoved)          |
| axis_resp_done_o            | out    | 1     | Pulse: transakcia dokoncena                  |
| axis_resp_status_o          | out    | 8     | Status pre response header                   |
| m_axis_tdata/tvalid/tready/tlast | out/in | 8 | AXI-Stream master (STREAM_WRITE -> FPGA) |
| s_axis_tdata/tvalid/tready/tlast | in/out | 8 | AXI-Stream slave (FPGA -> STREAM_READ)   |

---

## STREAM_WRITE — priebeh

```
1. Fabric: axis_req_valid=1, req_hdr.opcode=STREAM_WRITE, req_hdr.count=N
2. Adapter prijme request: -> FSM ST_WR
3. N/4 slov z axis_wdata serialzuje na bajty MSB-first -> m_axis (1 bajt/cyklus)
4. Po m_axis_tready na poslednom bajte: -> ST_WR_DONE
5. axis_resp_done_o=1, axis_resp_status_o=OK
```

Bajty na m_axis su v poradi MSB-first zo 32-bitoveho slova:
```
axis_wdata = 0xDEADBEEF  ->  m_axis bajty: DE AD BE EF
```

---

## STREAM_READ — priebeh

```
1. Fabric: axis_req_valid=1, req_hdr.opcode=STREAM_READ, req_hdr.count=N
2. Adapter caka na N bajtov z s_axis (s_axis_tready=1)
3. Bity pakuje do 32-bitovych slov MSB-first do rfifo
4. Po N bajtoch: axis_resp_done_o=1
5. Fabric cita axis_rdata (N/4 slov) cez axis_rdata_o/valid/ready
```

---

## Chybove stavy

| Stav     | Status kod   | Podmienka                                        |
|----------|--------------|--------------------------------------------------|
| BAD_LEN  | 0x02         | COUNT=0, COUNT%4≠0, alebo COUNT > MAX_STREAM_BYTES |
| UNSPRTD  | 0x09         | stream_id (addr[7:0]) ≠ 0                        |
| TIMEOUT  | 0x06         | m_axis_tready alebo s_axis_tvalid timeout        |

Pri STREAM_WRITE s chybou adapter drainuje zvysne wdata slova pred odoslaniem
error response (zabrani deadlocku vo fabric endpointe).

---

## Poriadok bajtov

Adapter prenasa bajty **MSB-first** v ramci 32-bitoveho slova. Toto korešponduje
s `LITTLE_ENDIAN=0` pre stream port (na rozdiel od AXIL enginu kde je LE swap).

Pre loopback test: data zapisane cez STREAM_WRITE sa prečitaju identicky cez STREAM_READ.

---

## Integrácia

```systemverilog
xfcp_axis_adapter #(
  .TIMEOUT_CYCLES   (1024),
  .MAX_STREAM_BYTES (256),
  .RFIFO_DEPTH      (64)
) u_axis_adapter (
  .clk (clk), .rst_n (rst_n),
  // fabric ports ...
  .m_axis_tdata  (stream_out_data),
  .m_axis_tvalid (stream_out_valid),
  .m_axis_tready (stream_out_ready),
  .m_axis_tlast  (stream_out_last),
  .s_axis_tdata  (stream_in_data),
  .s_axis_tvalid (stream_in_valid),
  .s_axis_tready (stream_in_ready),
  .s_axis_tlast  (stream_in_last)
);
```

Pre jednoduchy loopback: prepoj `m_axis -> s_axis` (tdata, tvalid, tready, tlast).
