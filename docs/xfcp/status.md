# XFCP — Status Codes

**Definicia:** `xfcp_pkg.sv`, typ `xfcp_status_e`

Kazdy response obsahuje na offsete 3 stavovy bajt. `0x00` = OK.

---

## Tabulka stavov

| Kod  | Meno                | Popis                                                         |
|------|---------------------|---------------------------------------------------------------|
| 0x00 | OK                  | Operacia prebehla uspesne.                                    |
| 0x01 | BAD_OPCODE          | Neznamy alebo nepodporovany opcode.                           |
| 0x02 | BAD_LENGTH          | COUNT je 0, nenasobok 4, alebo presahuje maximum.             |
| 0x03 | BAD_ADDRESS         | Adresa je mimo dekodom alebo index targetu neexistuje.        |
| 0x04 | AXI_SLVERR          | AXI slave vrátil SLVERR (napr. neimplementovany register).   |
| 0x05 | AXI_DECERR          | AXI decode error (adresa mimo mapy slavu).                    |
| 0x06 | TIMEOUT             | AXI slave nereagoval do TIMEOUT_CYCLES cyklov.                |
| 0x07 | BUSY                | Zariadenie je zaneprazdnene (MEM single-outstanding blocker). |
| 0x08 | OVERFLOW            | FIFO pretecenie (stream rfifo plna).                          |
| 0x09 | UNSUPPORTED         | Parametricky nepodporovana operacia (napr. stream_id != 0).   |
| 0x7F | INTERNAL_ERROR      | Interna chyba (FSM fault, neocakavany stav).                  |

---

## Zdroje chyb podla operacie

### AXIL READ/WRITE (0x10/0x11)

| Status        | Podmienka                                                  |
|---------------|------------------------------------------------------------|
| OK            | AXI BRESP/RRESP = OKAY                                     |
| AXI_SLVERR    | Slave vrátil SLVERR                                        |
| AXI_DECERR    | Slave vrátil DECERR                                        |
| TIMEOUT       | `m_axi_rvalid` / `m_axi_bvalid` neprišlo do TIMEOUT_VAL   |
| BAD_ADDRESS   | Adresa nesedí so žiadnym SLAVE_BASE/SLAVE_MASK             |

### STREAM_WRITE (0x20) / STREAM_READ (0x21)

| Status        | Podmienka                                                    |
|---------------|--------------------------------------------------------------|
| OK            | Vsetky bajty odoslane/prijaté bez chyby                      |
| BAD_LENGTH    | COUNT=0, COUNT%4≠0, alebo COUNT > MAX_STREAM_BYTES           |
| UNSUPPORTED   | stream_id ≠ 0                                                |
| TIMEOUT       | `m_axis_tready` / `s_axis_tvalid` neprišlo do TIMEOUT_CYCLES |

### MEM_READ (0x30) / MEM_WRITE (0x31)

| Status        | Podmienka                                                      |
|---------------|----------------------------------------------------------------|
| OK            | AXI RRESP/BRESP = OKAY pre vsetky beaty                        |
| AXI_SLVERR    | RRESP/BRESP = SLVERR                                           |
| AXI_DECERR    | RRESP/BRESP = DECERR                                           |
| TIMEOUT       | AXI slave nereagoval (ARREADY/AWREADY/RVALID/BVALID timeout)  |
| BAD_LENGTH    | COUNT=0, COUNT%4≠0, alebo COUNT > MAX_MEM_BYTES (RTL check)   |

### GET_TARGET_INFO (0x03)

| Status        | Podmienka                        |
|---------------|----------------------------------|
| OK            | Index je v rozsahu 0..NUM_TARGETS-1 |
| BAD_ADDRESS   | Index >= NUM_TARGETS             |

---

## Sprava chyb na PC strane

V `tools/xfcp/errors.py`:

| Exception             | Vyvolana ked                                              |
|-----------------------|-----------------------------------------------------------|
| `XfcpTimeoutError`    | Neprišla žiadna odpoved po N pokusoch                     |
| `XfcpProtocolError`   | Zly SOP/OPCODE/SEQ v response                             |
| `XfcpStatusError`     | STATUS ≠ 0x00 (obsahuje `.status` atribut s kodom)        |
| `XfcpRecoveryError`   | `bus.recover()` zlyhal (link neodpovedá po drain)         |

### Retry politika

| Operacia        | Default retries | Poznamka                                      |
|-----------------|-----------------|-----------------------------------------------|
| read32          | 1 (default)     | Bezpecne opakovatelna (idempotentna)           |
| read_block      | 1               | Bezpecne opakovatelna                          |
| write32         | 0               | Write-only, bez retry (mozna duplikacia)       |
| write_block     | 0               | Bez retry                                      |
| stream_write    | 0               | NIE je bezpecne opakovatelna (mozna duplikacia)|
| stream_read     | 1               | Bezpecne                                       |
| mem_write       | 0               | Idempotentna na rovnaku adresu+data, ale bez retry |
| mem_read        | 1               | Bezpecne                                       |
| get_caps        | 1               | Bezpecne                                       |
| get_target_info | 1               | Bezpecne                                       |

`retries=N` znamena: jeden pokus + N opakovani pri timeoutu = N+1 celkovo.
