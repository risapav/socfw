# XFCP — Packet Protocol Reference

**Version:** v1.3+MEM  
**Definicia:** `rtl/xfcp/xfcp_pkg.sv`

---

## Prenosovy layer

XFCP prenasa pakety po bajtoch. Kazdy paket je ohraniceny:
- **SOP** (Start of Packet) — prvy bajt: `0xFE` (request) alebo `0xFD` (response)
- **EOP** (End of Packet) — posledny bajt `0x00` so signalom `TLAST=1`

Adresy a COUNT su prenasane **MSB-first** (big-endian).

---

## Request format (PC -> FPGA)

```
Offset  Bajt        Popis
------  --------    -------------------------------------------
0       0xFE        SOP_REQ
1       OPCODE      Typ operacie (pozri tabulku opkodov)
2       SEQ         Sequence number (0x00–0xFF, wraps)
3       COUNT[15:8] Dlzka dat (bajty), vyssi bajt
4       COUNT[7:0]  Dlzka dat (bajty), nizsi bajt
5       ADDR[31:24] Adresa, bajt 3 (MSB)
6       ADDR[23:16] Adresa, bajt 2
7       ADDR[15:8]  Adresa, bajt 1
8       ADDR[7:0]   Adresa, bajt 0 (LSB)
9+      [payload]   Volitelne datove bajty (COUNT bajtov pre WRITE/STREAM_WRITE/MEM_WRITE)
```

Pre READ/GET_CAPS/GET_TARGET_INFO/MEM_READ: payload chyba (COUNT=0 alebo COUNT=dlzka odpovede).

---

## Response format (FPGA -> PC)

```
Offset  Bajt         Popis
------  ---------    -------------------------------------------
0       0xFD         SOP_RESP
1       OPCODE_RESP  Typ odpovede (zodpovedajuci request opcode + 2 alebo 0x32/0x33)
2       SEQ          Echo sequence number z requestu
3       STATUS       Stavovy kod (0x00=OK, pozri status.md)
4+      [payload]    Datove bajty (pre READ/STREAM_READ/MEM_READ/GET_CAPS/GET_TARGET_INFO)
last    0x00+TLAST   Ukoncovaci bajt (vzdy nulovy, s TLAST=1)
```

---

## Opkody

| Opcode | Hex  | Smer    | Popis                               |
|--------|------|---------|-------------------------------------|
| GET_CAPS              | 0x01 | req     | Zistit schopnosti FPGA              |
| RESP_GET_CAPS         | 0x02 | resp    | Odpoved na GET_CAPS                 |
| GET_TARGET_INFO       | 0x03 | req     | Info o jednom targete (index)       |
| RESP_GET_TARGET_INFO  | 0x04 | resp    | Odpoved na GET_TARGET_INFO          |
| READ                  | 0x10 | req     | AXI-Lite burst read                 |
| WRITE                 | 0x11 | req     | AXI-Lite burst write                |
| RESP_READ             | 0x12 | resp    | Odpoved na READ (data)              |
| RESP_WRITE            | 0x13 | resp    | Odpoved na WRITE (len status)       |
| STREAM_WRITE          | 0x20 | req     | Zapis dat na AXI-Stream master port |
| STREAM_READ           | 0x21 | req     | Citanie dat z AXI-Stream slave port |
| RESP_STREAM_WRITE     | 0x22 | resp    | Odpoved na STREAM_WRITE             |
| RESP_STREAM_READ      | 0x23 | resp    | Odpoved na STREAM_READ (data)       |
| MEM_READ              | 0x30 | req     | Citanie z pamati (AXI4-Full burst)  |
| MEM_WRITE             | 0x31 | req     | Zapis do pamate (AXI4-Full burst)   |
| RESP_MEM_READ         | 0x32 | resp    | Odpoved na MEM_READ (data)          |
| RESP_MEM_WRITE        | 0x33 | resp    | Odpoved na MEM_WRITE (len status)   |

---

## Pakety po opkodoch

### READ (0x10)

Request:
```
FE 10 SEQ  COUNT[15:8] COUNT[7:0]  ADDR[31:24] ADDR[23:16] ADDR[15:8] ADDR[7:0]
```

- `COUNT` = pocet bajtov (musi byt nasobok 4, max 128 B = 32 slov)
- `ADDR` = baza adresa AXI-Lite slavu

Response:
```
FD 12 SEQ STATUS  DATA[0..COUNT-1]  0x00+TLAST
```

Celkova dlzka response: `4 + COUNT + 1` bajtov.

---

### WRITE (0x11)

Request:
```
FE 11 SEQ  COUNT[15:8] COUNT[7:0]  ADDR[31:24..0]  DATA[0..COUNT-1]
```

- `COUNT` = pocet bajtov (nasobok 4, max 128 B = 32 slov)

Response:
```
FD 13 SEQ STATUS  0x00+TLAST
```

Celkova dlzka response: `5` bajtov.

---

### STREAM_WRITE (0x20)

Request:
```
FE 20 SEQ  COUNT[15:8] COUNT[7:0]  STREAM_ID[31:24..0]  DATA[0..COUNT-1]
```

- `COUNT` = pocet bajtov (nasobok 4, max 256 B)
- `ADDR[7:0]` = stream_id (obvykle 0)

Response:
```
FD 22 SEQ STATUS  0x00+TLAST
```

---

### STREAM_READ (0x21)

Request:
```
FE 21 SEQ  COUNT[15:8] COUNT[7:0]  STREAM_ID[31:24..0]
```

Response:
```
FD 23 SEQ STATUS  DATA[0..COUNT-1]  0x00+TLAST
```

---

### MEM_READ (0x30)

Request:
```
FE 30 SEQ  COUNT[15:8] COUNT[7:0]  ADDR[31:24] ADDR[23:16] ADDR[15:8] ADDR[7:0]
```

- `COUNT` = pocet bajtov (nasobok 4, max 256 B)
- `ADDR` = fyzicka adresa v pamati (zvycajne zacina od 0x00000000)

Response:
```
FD 32 SEQ STATUS  DATA[0..COUNT-1]  0x00+TLAST
```

Celkova dlzka response: `4 + COUNT + 1` bajtov.

---

### MEM_WRITE (0x31)

Request:
```
FE 31 SEQ  COUNT[15:8] COUNT[7:0]  ADDR[31:24..0]  DATA[0..COUNT-1]
```

Response:
```
FD 33 SEQ STATUS  0x00+TLAST
```

---

### GET_CAPS (0x01)

Request:
```
FE 01 SEQ  00 00  00 00 00 00
```

(COUNT=0, ADDR=0 — prazdne, bez payloadu)

Response:
```
FD 02 SEQ STATUS  CAPS[0..7]  0x00+TLAST
```

8-bajtovy payload, format popisany v [targets.md](targets.md).

---

### GET_TARGET_INFO (0x03)

Request:
```
FE 03 SEQ  00 00  00 00 00 INDEX
```

- `ADDR[7:0]` = index targetu (0-based)

Response:
```
FD 04 SEQ STATUS  TARGET[0..15]  0x00+TLAST
```

16-bajtovy payload, format popisany v [targets.md](targets.md).

---

## Obmedzenia

| Parameter        | Hodnota      |
|------------------|--------------|
| MAX_BURST_WORDS  | 32 (128 B)   |
| MAX_STREAM_BYTES | 256 B        |
| MAX_MEM_BYTES    | 256 B        |
| COUNT zarovnanie | 4 bajty      |
| SEQ              | 8-bit, wraps |

---

## Identifikacia opkodov v RTL

V SystemVerilog su opkody definovane ako enum `xfcp_op_e` v `xfcp_pkg.sv`.
Helper funkcie:

| Funkcia                       | Vrati 1 pre...                |
|-------------------------------|-------------------------------|
| `xfcp_op_is_axil(op)`         | READ, WRITE, ID               |
| `xfcp_op_is_stream(op)`       | STREAM_WRITE, STREAM_READ     |
| `xfcp_op_is_caps(op)`         | GET_CAPS                      |
| `xfcp_op_is_targets(op)`      | GET_TARGET_INFO               |
| `xfcp_op_is_mem(op)`          | MEM_READ, MEM_WRITE           |
| `xfcp_resp_for_op(op)`        | zodpovedajuci response opcode |
| `xfcp_resp_has_payload(op)`   | 1 ak response niesie data     |
