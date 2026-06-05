Toto je presne bod, kde sa z „demo GMII MAC“ stáva **reálny produkčný Ethernet RX pipeline**. Nižšie máš návrh architektúry, ktorá je použiteľná v serióznom FPGA systéme (SoC, DMA do DDR, TCP/IP stack, atď.).

---

# 🧱 Cieľ “production-grade” RX MAC

Chceme:

* ✔ správny RX decode (preamble/SFD)
* ✔ CRC32 kontrolu (FCS)
* ✔ FIFO buffering (elastic buffer)
* ✔ CDC medzi RX_CLK a system clock
* ✔ AXI-stream s backpressure (tready)
* ✔ drop bad frames
* ✔ robustné správanie pri preťažení

---

# 🧩 Celková architektúra

```text
            PHY (GMII / RGMII)
                   |
             RX_CLK domain
                   |
        ┌─────────────────────┐
        │ 1) RX DESERIALIZER   │
        │  - DV / ER sync      │
        │  - preamble detect   │
        │  - SFD strip         │
        └─────────┬───────────┘
                  data
                   |
        ┌─────────────────────┐
        │ 2) CRC32 ENGINE      │
        │  - Ethernet CRC      │
        │  - running checksum  │
        └─────────┬───────────┘
              frame data + ok/bad
                   |
        ┌─────────────────────┐
        │ 3) ASYNC FIFO        │
        │  RX_CLK → SYS_CLK    │
        │  (elastic buffer)    │
        └─────────┬───────────┘
                   |
            SYSTEM CLOCK DOMAIN
                   |
        ┌─────────────────────┐
        │ 4) AXI STREAM IFACE  │
        │  - tvalid/tready     │
        │  - tlast             │
        │  - drop bad frames   │
        └─────────────────────┘
```

---

# ⚙️ 1) RX Frontend (RX_CLK doména)

## Funkcia:

* detekcia preamble
* odstránenie SFD (0xD5)
* zarovnanie streamu

---

## FSM (robustnejšia verzia)

```text
IDLE
  ↓ (DV & 0x55 or 0xD5)
PREAMBLE
  ↓
SFD
  ↓
DATA
  ↓ (DV drops)
END_FRAME
```

---

## Kľúčový rozdiel oproti tvojmu kódu:

👉 tu už NIE je AXI stream

len interný:

```text
rx_valid
rx_data
frame_start
frame_end
```

---

# 🧮 2) CRC32 engine (Ethernet standard)

Používa sa:

```text
poly = 0x04C11DB7 (reflected 0xEDB88320)
init = 0xFFFFFFFF
xorout = 0xFFFFFFFF
```

---

## Správanie:

```text
start frame → reset CRC
every byte → update CRC
end frame → compare CRC
```

---

## Výstup:

```text
crc_ok
crc_bad
```

---

# 🧠 3) CDC + FIFO (najdôležitejšia časť)

Toto je rozdiel medzi hobby a production designom.

---

## FIFO medzi doménami:

```text
RX_CLK domain → async FIFO → SYS_CLK domain
```

Obsah FIFO:

```text
{data[7:0], sop, eop, crc_ok}
```

---

## Prečo FIFO?

Lebo:

* RX_CLK = 10/100/1000 MHz (PHY dependent)
* SYS_CLK = napr. 100–200 MHz
* AXI slave môže byť pomalý

👉 bez FIFO = stratíš rámce

---

# 📡 4) AXI-stream output (SYSTEM CLOCK)

```systemverilog
output tdata
output tvalid
input  tready
output tlast
output tuser (crc_error)
```

---

## Správanie:

### tvalid

FIFO nie je empty

### tready

ak 0 → FIFO sa plní (backpressure)

---

## tlast

```text
EOP z FIFO
```

---

## tuser

```text
crc_bad
```

---

# 🔥 5) Backpressure handling

Toto je zásadné.

## RX side:

👉 nikdy nezastaví PHY (GMII nemá flow control)

takže:

### ak FIFO full:

```text
DROP FRAME
```

---

## detekcia:

```text
fifo_full + rx_active → drop_mode
```

---

## v drop mode:

* ignoruj RX bytes
* čakaj na DV=0
* reset FSM

---

# 🧷 6) kompletný signálový tok

```text
PHY
 |
 | GMII RX
 v
[RX FSM + SFD strip]
 |
 v
[CRC32 generator]
 |
 v
[ASYNC FIFO]
 |
 v
[AXI STREAM OUTPUT]
 |
 v
DMA / CPU / UDP stack
```

---

# 🧩 7) rozdiel oproti tvojmu gmii_rx_mac

| vlastnosť          | tvoj kód  | production |
| ------------------ | --------- | ---------- |
| preamble strip     | ✔         | ✔          |
| SFD handling       | ✔         | ✔          |
| CRC check          | ❌         | ✔          |
| FIFO               | ❌         | ✔          |
| CDC                | ❌         | ✔          |
| backpressure       | ❌         | ✔          |
| frame drop control | ❌         | ✔          |
| AXI compliance     | čiastočne | plne       |

---

# ⚠️ 8) najčastejšie chyby v real dizajnoch

### ❌ ignorovanie tready

→ data corruption

### ❌ bez FIFO

→ RX overflow

### ❌ CRC mimo RX clock domény

→ timing glitches

### ❌ mixing RX_CLK a SYS_CLK

→ metastability

---

# 🧠 9) odporúčaná “clean” implementácia (praktická)

Najlepšia kombinácia pre FPGA:

### RX_CLK domain:

* GMII RX parser
* CRC32
* small skid buffer (2–4 words)

### SYS_CLK domain:

* async FIFO
* AXI stream master
