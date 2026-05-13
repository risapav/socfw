Navrhol by som ACR packet builder ako **čistý packet builder**, nie ako generátor časovania. Časovanie, kedy sa ACR pošle, nech rieši `hdmi_packet_arbiter`.

### Odporúčaná hlavička

```systemverilog
// -----------------------------------------------------------------------------
// HDMI Audio Clock Regeneration (ACR) Packet Builder
//
// Builds HDMI ACR packet:
//   HB0 = Packet Type
//   HB1 = 0
//   HB2 = 0
//   PB  = N / CTS payload, remaining bytes zero
//
// This module does not decide when the packet is sent.
// Packet scheduling is handled by hdmi_packet_arbiter.
// -----------------------------------------------------------------------------
module acr_packet_builder #(
  parameter int N_WIDTH   = 20,
  parameter int CTS_WIDTH = 20
) (
  input  logic [N_WIDTH-1:0]   n_i,
  input  logic [CTS_WIDTH-1:0] cts_i,

  input  logic                 cts_valid_i,

  output logic [7:0]           hb_o [0:2],
  output logic [7:0]           pb_o [0:27],
  output logic                 valid_o
);
```

---

## Význam portov

```text
n_i
  HDMI ACR N hodnota.
  Pre 48 kHz audio sa často používa N = 6144.

cts_i
  HDMI ACR CTS hodnota.
  Buď tabuľková podľa pixel clocku, alebo meraná/generovaná samostatným blokom.

cts_valid_i
  Hovorí, že CTS je platná.
  Ak používaš pevné tabuľkové CTS, môže byť trvalo 1.

hb_o
  3 header bajty packetu.

pb_o
  28 payload bajtov packetu.
  Nevyužité bajty nulovať.

valid_o
  Packet je platný a môže ísť do hdmi_packet_arbiter.
```

---

## Prečo takto

Tento modul má robiť iba:

```text
N + CTS → HDMI packet HB/PB
```

Nemá robiť:

```text
kedy packet odoslať
ako často packet odoslať
výpočet CTS z pixel clocku
audio FIFO logiku
TERC4
BCH/ECC
```

Tie patria inde:

```text
acr_cts_generator      → vypočíta alebo zmeria CTS
acr_packet_builder     → postaví packet
hdmi_packet_arbiter    → rozhodne, kedy ho pošle
data_island_formatter  → pridá BCH/ECC a rozmapuje do data islandu
TERC4 encoder          → zakóduje nibbles
```

---

## Ak chceš robustnejšiu verziu

Praktickejšia hlavička pre budúci arbiter môže byť:

```systemverilog
module acr_packet_builder #(
  parameter int N_WIDTH   = 20,
  parameter int CTS_WIDTH = 20
) (
  input  logic                 enable_i,

  input  logic [N_WIDTH-1:0]   n_i,
  input  logic [CTS_WIDTH-1:0] cts_i,
  input  logic                 cts_valid_i,

  output logic [7:0]           hb_o [0:2],
  output logic [7:0]           pb_o [0:27],
  output logic                 packet_valid_o
);
```

S pravidlom:

```systemverilog
assign packet_valid_o = enable_i && cts_valid_i;
```

---

## Moja preferovaná verzia pre tvoj projekt

Použil by som túto:

```systemverilog
module acr_packet_builder (
  input  logic        enable_i,

  input  logic [19:0] n_i,
  input  logic [19:0] cts_i,
  input  logic        cts_valid_i,

  output logic [7:0]  hb_o [0:2],
  output logic [7:0]  pb_o [0:27],
  output logic        packet_valid_o
);
```

Je jednoduchá, čitateľná a dobre zapadne do tvojej existujúcej schémy:

```text
gcp_packet_builder
infoframe_builder
acr_packet_builder
    ↓
hdmi_packet_arbiter
    ↓
data_island_formatter
```
