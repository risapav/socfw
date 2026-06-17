# XFCP — CPU Mailbox Backend

**Moduly:** `axil_cpu_mailbox.sv`, `xfcp_stream_mux.sv`
**Transport:** `xfcp_axis_adapter` sid=1 (CPU0 STREAM slot)
**AXI-Lite slot:** 7 @ `0xFF070000` (CPUM target, GET_TARGET_INFO index 10)

---

## Ucel

`axil_cpu_mailbox` implementuje bidirektcny mailbox medzi XFCP hostom a CPU (alebo
softcore agentom). Host komunikuje cez STREAM_WRITE/READ (sid=1), CPU cez AXI-Lite
registre. Kazdy smer ma nezavisly FIFO (DEPTH=256 slov po 9 bitov: `{tlast, data[7:0]}`).

```
Host side                        CPU side
---------                        --------
STREAM_WRITE sid=1  ->  RX FIFO  ->  RX_POP_DATA register
STREAM_READ  sid=1  <-  TX FIFO  <-  TX_PUSH_DATA register
```

---

## xfcp_stream_mux

`xfcp_stream_mux` dispatchuje stream_id na spravny AXI-Stream port:

```
xfcp_axis_adapter[1] (CPU0)
  |
  +-- stream_id=0 -> s_axis_str0 (loopback FIFO)
  +-- stream_id=1 -> s_axis_cpu0 / m_axis_cpu0 (axil_cpu_mailbox)
```

**Parameter:** `NUM_STREAMS = 2`

---

## axil_cpu_mailbox — Register mapa (0xFF070000)

| Offset | Register    | Pristup | Popis |
|--------|-------------|---------|-------|
| 0x00   | ID          | RO      | 0x4350554D (`CPUM` v big-endian ASCII) |
| 0x04   | CTRL        | RW      | [0]=rx_flush, [1]=tx_flush (single-cycle pulse) |
| 0x08   | STATUS      | RO      | viz. nizssie |
| 0x0C   | IRQ_EN      | RW      | rezervovane (future IRQ enable) |
| 0x10   | RX_LEVEL    | RO      | pocet slov v RX FIFO (0..256) |
| 0x14   | TX_LEVEL    | RO      | pocet slov v TX FIFO (0..256) |
| 0x18   | RX_POP_DATA | RO*     | citanie = pop; viz. nizssie |
| 0x1C   | TX_PUSH_DATA| WO*     | zapis = push; viz. nizssie |

### STATUS [0x08]

| Bit | Nazov       | Popis |
|-----|-------------|-------|
| 0   | rx_not_empty| RX FIFO obsahuje aspon jedno slovo |
| 1   | rx_full     | RX FIFO plny (256 slov) |
| 2   | tx_not_empty| TX FIFO obsahuje aspon jedno slovo |
| 3   | tx_full     | TX FIFO plny |

### RX_POP_DATA [0x18] — citanie = pop

| Bity  | Popis |
|-------|-------|
| [7:0] | data byte |
| [8]   | tlast bit (posledny bajt v pakete) |
| [9]   | rezervovane (=0) |
| [10]  | underflow: 1 ak FIFO bol prazdny pri cite |

**Poznamka:** ak underflow=1, data[8:0] su nedefinovane.

### TX_PUSH_DATA [0x1C] — zapis = push

| Bity  | Popis |
|-------|-------|
| [7:0] | data byte |
| [8]   | tlast bit (posledny bajt v pakete) |

**Poznamka:** ak TX FIFO je plny, zapis sa zahodí (ziadne blokovanie, bez chyboveho signalu).

### CTRL [0x04] — flush

| Bit | Funkcia |
|-----|---------|
| 0   | rx_flush: vyprazdni RX FIFO (1 cyklus) |
| 1   | tx_flush: vyprazdni TX FIFO (1 cyklus) |

Flush je single-cycle pulse — registrova hodnota sa nevratí do 1.

---

## Datovy tok

### Host -> CPU (RX FIFO)

1. Host posle `STREAM_WRITE sid=1 count=N data[0..N-1]`
2. `xfcp_axis_adapter` preposle bajty do `axil_cpu_mailbox.s_axis`
3. Posledny bajt ma `s_axis_tlast=1` (generuje ho adapter)
4. CPU cita bajty cez AXI-Lite: `READ(0xFF070018)` → pop, data+tlast
5. CPU kontroluje `STATUS[0]` (rx_not_empty) pred citanim

**Poznamka:** count musi byt nasobok 4 (obmedzenie `xfcp_axis_adapter`).
Ak nie, adapter vraci `STATUS=BAD_LENGTH`.

### CPU -> Host (TX FIFO)

1. CPU zapisuje bajty: `WRITE(0xFF07001C, {23'h0, tlast, data[7:0]})`
2. Posledny bajt musi mat tlast=1 (inak STREAM_READ caka indefinitely)
3. Host posle `STREAM_READ sid=1 count=N`
4. `xfcp_axis_adapter` cita z `axil_cpu_mailbox.m_axis` (TX FIFO output)
5. Citanie konci pri `m_axis_tlast=1` alebo po N bajtoch

---

## Architektura (xfcp_fifo_reg)

Oba FIFO (RX aj TX) su implementovane ako `xfcp_fifo_reg` s:
- `DATA_WIDTH = 9` (8 data + 1 tlast)
- `DEPTH = 256` (256 slov = 256 bajtov + tlast)
- Registrovany vystup z M9K — bez combinacnej cesty cez RAM

**Krit. poznamka pre Quartus:** Pouzivat `xfcp_fifo_reg` (nie `xfcp_fifo`) pre
FIFO, ktore sedia na kriticke timing cesty. `xfcp_fifo_reg` ma M9K vystupny
register, ktory eliminuje Quartus Warning 276020 (read-during-write bypass mux).

---

## Parametre

| Parameter  | Typ | Default | Popis |
|------------|-----|---------|-------|
| FIFO_DEPTH | int | 256     | Hlbka RX a TX FIFO (musi byt mocnina 2) |

---

## Casovanie

- **RX pop latencia:** 2 cykly od AR do RVALID (RD_IDLE -> RD_LATCH -> RD_RESP)
- **TX push latencia:** 0 cyklov — bajt je okamzite v FIFO po WR handshake
- **Flush cas:** 1 cyklus — FIFO je prazdny nasledujuci cyklus po flush pulse
- **m_axis_tvalid**: combinacne z tx_fifo.r_valid (1 cyklus od TX_PUSH)

---

## Known limits (v1.0)

| Limit | Popis |
|-------|-------|
| TX_PUSH bez backpressure | Ak TX FIFO plny, bajt sa zahodí (bez chyby) |
| count % 4 == 0 | STREAM_WRITE/READ count musi byt nasobok 4 |
| DEPTH = 256 | Vacsi FIFO mozny zmenou parametra (obmedzenie M9K) |
| Jeden AXI-Lite master | Paralelny pristup CPU nie je podporovany |
| Bez IRQ | IRQ_EN registre su rezervovane, bez funkcie |
| tlast semantika | Packet framing je zodpovednostou hosta/CPU; adapter neskontroluje |
