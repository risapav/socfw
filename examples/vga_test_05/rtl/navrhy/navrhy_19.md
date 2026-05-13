Tento `acr_packet_builder` je už v dobrom stave ako **čistý packet builder**. Ďalej by som neriešil jeho vnútro, ale jeho **integráciu do HDMI packet vrstvy**.

Najbližšie kroky:

```text id="hirt4k"
1. pridať ACR builder do hdmi_tx_core
2. rozšíriť hdmi_packet_arbiter o ACR vstup
3. vyriešiť ACR scheduling
4. pridať N/CTS generátor alebo tabuľku
5. až potom Audio InfoFrame a Audio Sample Packet
```

---

## 1. Pridať ACR do `hdmi_tx_core`

V `hdmi_tx_core` pridaj signály:

```systemverilog id="bmw0rg"
logic [7:0] hb_acr [0:2];
logic [7:0] pb_acr [0:27];
logic       valid_acr;
```

a inštanciu:

```systemverilog id="cshd9a"
acr_packet_builder u_acr_packet_builder (
  .enable_i    (enable_audio_i),
  .n_i         (acr_n_i),
  .cts_i       (acr_cts_i),
  .cts_valid_i (acr_cts_valid_i),

  .hb_o        (hb_acr),
  .pb_o        (pb_acr),
  .valid_o     (valid_acr)
);
```

To znamená, že `hdmi_tx_core` bude potrebovať nové audio/ACR porty:

```systemverilog id="g4cav9"
input logic        enable_audio_i,
input logic [19:0] acr_n_i,
input logic [19:0] acr_cts_i,
input logic        acr_cts_valid_i,
```

Ale ak chceš ešte len testovať ACR s fixnými hodnotami, môžeš dočasne dať:

```systemverilog id="o2uio9"
localparam logic [19:0] ACR_N_48K = 20'd6144;

assign acr_n_test         = ACR_N_48K;
assign acr_cts_test       = 20'dXXXXX;
assign acr_cts_valid_test = 1'b1;
```

---

## 2. Rozšíriť `hdmi_packet_arbiter`

Aktuálne máš pravdepodobne niečo ako:

```text id="7si806"
GCP → AVI
```

Treba pridať:

```text id="vx0gnc"
GCP → AVI → ACR
```

Rozhranie arbitra rozšíriť o:

```systemverilog id="gphnbx"
input logic [7:0] hb_acr_i [0:2],
input logic [7:0] pb_acr_i [0:27],
input logic       valid_acr_i,
```

a v rozhodovaní pridať ACR ako ďalší packet.

Pre prvú verziu stačí jednoduchá sekvencia raz za frame:

```text id="6bm9sg"
slot 0: GCP
slot 1: AVI
slot 2: ACR
```

Lepšie je ale ACR posielať pravidelnejšie než raz za frame. Na prvý bring-up však raz za frame môže stačiť na overenie, že packet path funguje.

---

## 3. ACR scheduling

ACR nie je len „jeden packet pri frame“. Pre audio bude potrebný periodický prenos ACR.

Na začiatok odporúčam spraviť jednoduchý počítadlový request:

```systemverilog id="u0ipzg"
logic [11:0] acr_interval_cnt;
logic        acr_req;

always_ff @(posedge pix_clk_i) begin
  if (!rst_ni) begin
    acr_interval_cnt <= '0;
    acr_req          <= 1'b0;
  end else begin
    acr_req <= 1'b0;

    if (acr_interval_cnt == ACR_INTERVAL-1) begin
      acr_interval_cnt <= '0;
      acr_req          <= 1'b1;
    end else begin
      acr_interval_cnt <= acr_interval_cnt + 1'b1;
    end
  end
end
```

Potom arbiter rozhodne, kedy sa ACR skutočne pošle v najbližšom bezpečnom data-island okne.

Na úplne prvý test ale môžeš urobiť:

```text id="h96bqq"
každý frame:
  GCP
  AVI
  ACR
```

---

## 4. N/CTS zdroj

Pre 48 kHz audio je bežná hodnota:

```systemverilog id="yhej0a"
N = 20'd6144;
```

CTS závisí od TMDS/pixel clocku.

Dočasne sprav modul alebo tabuľku:

```systemverilog id="d0z5db"
module acr_cts_lookup (
  input  logic [31:0] pixel_clock_hz_i,
  input  logic [31:0] audio_sample_rate_hz_i,

  output logic [19:0] n_o,
  output logic [19:0] cts_o,
  output logic        valid_o
);
```

Pre prvú verziu môže byť ešte jednoduchšie mať parameter v top-leveli:

```systemverilog id="n35g69"
parameter logic [19:0] HDMI_ACR_N   = 20'd6144,
parameter logic [19:0] HDMI_ACR_CTS = 20'dXXXXX
```

a neskôr to nahradiť lookup/generatorom.

---

## 5. Testbench pre `acr_packet_builder`

Skôr než ho zapojíš do core, sprav malý testbench:

```text id="6r8nnb"
enable_i = 1
n_i = 6144
cts_i = zvolená hodnota
cts_valid_i = 1
```

Over:

```text id="c5euqq"
hb_o[0] = 8'h01
hb_o[1] = 8'h00
hb_o[2] = 8'h00

pb_o[0..6]   = CTS/N subpacket
pb_o[7..13]  = identická kópia
pb_o[14..20] = identická kópia
pb_o[21..27] = identická kópia

valid_o = 1
```

A tiež:

```text id="9zm9h0"
enable_i=0 → valid_o=0
cts_valid_i=0 → valid_o=0
```

---

## 6. Potom Audio InfoFrame

Po ACR pridaj Audio InfoFrame ako ďalší packet source. Tvoj `infoframe_builder` ho už vie generovať, takže ďalší krok bude hlavne arbitráž:

```text id="44acg9"
GCP
AVI
ACR
Audio InfoFrame
```

Audio InfoFrame stačí posielať raz za frame alebo pri zmene audio konfigurácie.

---

## 7. Až potom Audio Sample Packetizer

Až keď máš:

```text id="d1so2r"
GCP
AVI
ACR
Audio InfoFrame
```

potom pridaj reálne audio dáta.

Prvý packetizer by som navrhol pre:

```text id="koqmf3"
2ch LPCM
48 kHz
16-bit alebo 24-bit
interný test tone
```

Nepájaj hneď I2S. Najprv interný generátor tónu, aby si neladil naraz HDMI aj audio vstup.

---

## Praktické poradie commitov

```text id="a0maum"
Commit 1:
  acr_packet_builder.sv + testbench

Commit 2:
  hdmi_packet_arbiter rozšírený o ACR vstup
  zatiaľ GCP → AVI → ACR raz za frame

Commit 3:
  hdmi_tx_core porty:
    enable_audio_i
    acr_n_i
    acr_cts_i
    acr_cts_valid_i

Commit 4:
  ACR CTS lookup alebo fixné parametre pre prvý mód

Commit 5:
  Audio InfoFrame source do arbitra

Commit 6:
  Audio sample packetizer s interným tónom
```

---

## Najbližšia konkrétna úloha

Najbližšie sprav:

```text id="a0twzl"
tb_acr_packet_builder.sv
```

a potom zapoj `acr_packet_builder` ako tretí zdroj do `hdmi_packet_arbiter` za `GCP` a `AVI`.

Teda cieľ ďalšej fázy:

```text id="h5xheo"
každý frame alebo periodicky:
  GCP
  AVI
  ACR
```

Až keď toto prejde simuláciou a obraz ostane stabilný, pokračovať na Audio InfoFrame.
