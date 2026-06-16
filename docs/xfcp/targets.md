# XFCP — Target Discovery (GET_CAPS + GET_TARGET_INFO)

XFCP poskytuje dva mechanizmy pre host-side discovery: `GET_CAPS` vracia
moznosti FPGA, `GET_TARGET_INFO` vracia opis jednotlivych backendov.

---

## GET_CAPS (opcode 0x01)

### Request (9 bajtov)

```
FE 01 SEQ  00 00  00 00 00 00
```

### Response (14 bajtov)

```
FD 02 SEQ STATUS  W0[31:24] W0[23:16] W0[15:8] W0[7:0]
                  W1[31:24] W1[23:16] W1[15:8] W1[7:0]
                  00+TLAST
```

### Payload (8 bajtov, 2 x 32-bit slovo, MSB-first)

| Offset | Pole              | Typ   | Popis                                          |
|--------|-------------------|-------|------------------------------------------------|
| 0      | proto_major       | u8    | Hlavna verzia protokolu (aktualne 1)           |
| 1      | proto_minor       | u8    | Vedlajsia verzia protokolu (aktualne 3)        |
| 2      | num_axil_slots    | u8    | Pocet AXI-Lite engineov                        |
| 3      | num_stream_slots  | u8    | Pocet AXI-Stream adapterov                     |
| 4-5    | max_stream_bytes  | u16be | Max bajty na STREAM transakciu (aktualne 256)  |
| 6      | stream_align      | u8    | Zarovnanie COUNT pre STREAM (4)                |
| 7      | caps_flags        | u8    | Bitova maska schopnosti (pozri tabulku)        |

### caps_flags

| Bit | Maska  | Meno         | Popis                              |
|-----|--------|--------------|------------------------------------|
| 0   | 0x01   | HAS_AXIL     | Suporuje AXI-Lite READ/WRITE       |
| 1   | 0x02   | HAS_STREAM   | Suporuje STREAM_WRITE/READ         |
| 2   | 0x04   | HAS_CAPS     | Suporuje GET_CAPS                  |
| 3   | 0x08   | HAS_TARGETS  | Suporuje GET_TARGET_INFO           |
| 4   | 0x10   | HAS_MEM      | Suporuje MEM_READ/MEM_WRITE        |

Pre `xfcp_test_10_axifull`: `caps_flags = 0x1F` (vsetky 5 bitov set).

### Python

```python
caps = bus.get_caps()
# {'proto_major': 1, 'proto_minor': 3, 'num_axil_slots': 7,
#  'num_stream_slots': 1, 'max_stream_bytes': 256, 'stream_align': 4,
#  'caps_flags': 31}
```

---

## GET_TARGET_INFO (opcode 0x03)

### Request (9 bajtov)

```
FE 03 SEQ  00 00  00 00 00 INDEX
```

- `ADDR[7:0]` = index (0-based)
- Neplatny index vracia `STATUS=BAD_ADDRESS` (0x03)

### Response (21 bajtov)

```
FD 04 SEQ STATUS  [16 bajtov target struct]  00+TLAST
```

### Target struct (16 bajtov, 4 x 32-bit slovo, MSB-first)

| Offset | Pole         | Typ   | Popis                                       |
|--------|--------------|-------|---------------------------------------------|
| 0      | target_type  | u8    | Typ backendu (pozri tabulku typov)          |
| 1      | target_id    | u8    | ID (rovne indexu)                           |
| 2      | flags        | u8    | 0x00 (rezervovane)                          |
| 3      | reserved     | u8    | 0x00                                        |
| 4-7    | base_addr    | u32be | Bazova adresa (pre AXIL/MEM)                |
| 8-9    | max_transfer | u16be | Max bajty na transakciu                     |
| 10     | align        | u8    | Pozadovane zarovnanie COUNT (zvycajne 4)    |
| 11     | reserved     | u8    | 0x00                                        |
| 12-15  | name         | ascii | 4-znakovy ASCII nazov (napr. "SYSC", "MEM0")|

### Typy targetov

| Kod  | Meno   | Backend               |
|------|--------|-----------------------|
| 0x01 | AXIL   | AXI-Lite engine       |
| 0x02 | STREAM | AXI-Stream adapter    |
| 0x03 | MEM    | AXI4-Full MEM adapter |

### Priklad tabulky targetov (xfcp_test_10_axifull)

| Index | Nazov | Typ    | base_addr    | max_transfer | align |
|-------|-------|--------|--------------|--------------|-------|
| 0     | SYSC  | AXIL   | 0xFF000000   | 128 B        | 4     |
| 1     | UART  | AXIL   | 0xFF010000   | 128 B        | 4     |
| 2     | OUT_  | AXIL   | 0xFF020000   | 128 B        | 4     |
| 3     | OUT_  | AXIL   | 0xFF030000   | 128 B        | 4     |
| 4     | OUT_  | AXIL   | 0xFF040000   | 128 B        | 4     |
| 5     | SEG7  | AXIL   | 0xFF050000   | 128 B        | 4     |
| 6     | DIAG  | AXIL   | 0xFF060000   | 128 B        | 4     |
| 7     | STR0  | STREAM | 0x00000000   | 256 B        | 4     |
| 8     | MEM0  | MEM    | 0x00000000   | 256 B        | 4     |

Index 9 vrati `BAD_ADDRESS` — host to pouziva ako koniec tabulky.

### Python

```python
# Jeden target
info = bus.get_target_info(8)
# {'target_type': 3, 'target_id': 8, 'flags': 0, 'base_addr': 0,
#  'max_transfer': 256, 'align': 4, 'name': 'MEM0'}

# Vsetky targety
targets = bus.list_targets()
# Vrati zoznam dict-ov, zastavi pri BAD_ADDRESS
```

---

## RTL konfigurácia targetov (xfcp_target_info_adapter)

Targety su definovane ako parameter pole pri instanciacii:

```systemverilog
xfcp_target_info_adapter #(
  .NUM_TARGETS      (9),
  .TARGET_TYPE      ('{8'h01, 8'h01, ..., 8'h02, 8'h03}),
  .TARGET_BASE_ADDR ('{32'hFF00_0000, ..., 32'h0, 32'h0}),
  .TARGET_MAX_XFER  ('{16'd128, ..., 16'd256, 16'd256}),
  .TARGET_ALIGN     ('{8'd4, ...}),
  .TARGET_NAME      ('{32'h53595343, ..., 32'h4D454D30})  // "SYSC".."MEM0"
) u_ti (...);
```

ASCII kodovanie nazvov (4 znaky ako 32-bit literal):
```
"SYSC" = 0x53595343
"UART" = 0x55415254
"OUT_" = 0x4F55545F
"SEG7" = 0x53454737
"DIAG" = 0x44494147
"STR0" = 0x53545230
"MEM0" = 0x4D454D30
```
