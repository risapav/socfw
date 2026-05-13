Prešiel som aktuálnu nahratú sadu SystemVerilog súborov priamo z `/mnt/data`. Táto verzia už zodpovedá tomu, čo si opisoval: nepoužíva `generic_serializer`, má `tmds_phy_ddr_aligned`, má `ST_VIDEO_PREAMBLE`, `blank_remaining_i`, `data_island_formatter`, dynamický CH0 data guard band a opravenú polaritu TMDS video.

Nižšie je analýza aktuálneho stavu a ďalšie kroky k plnému HDMI.

---

## 1. Aktuálny stav architektúry

Aktuálny hlavný tok je:

```text
RGB565 + timing
  ↓
vga_hdmi_tx
  ├─ RGB565 → RGB888
  ├─ hdmi_tx_core
  └─ tmds_phy_ddr_aligned
       ↓
     HDMI TMDS výstup
```

`vga_hdmi_tx.sv` používa:

```systemverilog
tmds_phy_ddr_aligned u_phy (
```

Čiže aktuálna cesta už nejde cez `generic_serializer`.

`hdmi_tx_core.sv` má už explicitné timing vstupy:

```systemverilog
input  logic        hblank_i,
input  logic        vblank_i,
input  logic        frame_start_i,
input  logic        line_start_i,
input  logic [15:0] blank_remaining_i,
```

To je správne. Core si už nemusí hádať `vblank` z `vsync`.

---

## 2. Čo je už vyriešené dobre

### TMDS video polarita

V `tmds_video_encoder.sv` je:

```systemverilog
tmds_o <= ~word;
```

To je oprava, ktorú si hardvérovo overil podľa správania:

```text
red   → cyan
white → black
blue  → yellow
```

Teda farebný negatív bol spôsobený opačnou polaritou video TMDS slov. Teraz je oprava na správnom mieste, priamo v `tmds_video_encoder`, nie v muxe.

---

### Period scheduler

`hdmi_period_scheduler.sv` má už 8 stavov:

```systemverilog
ST_CONTROL,
ST_VIDEO_PREAMBLE,
ST_VIDEO_GB,
ST_VIDEO,
ST_DATA_PREAMBLE,
ST_DATA_GB_LEAD,
ST_DATA_PAYLOAD,
ST_DATA_GB_TRAIL
```

a generuje aj:

```systemverilog
HDMI_PERIOD_VIDEO_PREAMBLE
HDMI_PERIOD_VIDEO_GB
HDMI_PERIOD_DATA_PREAMBLE
HDMI_PERIOD_DATA_GB_LEAD
HDMI_PERIOD_DATA_PAYLOAD
HDMI_PERIOD_DATA_GB_TRAIL
```

Toto je správna štruktúra HDMI období.

Dôležité je aj to, že data island sa už nespúšťa len podľa `hblank`, ale kontroluje sa priestor:

```systemverilog
blank_remaining_i >= 16'(ISLAND_TOTAL + VIDEO_TRIG)
```

To je presne potrebná ochrana, aby data island nezasiahol do aktívneho videa.

---

### Channel mux

`hdmi_channel_mux.sv` už pozná:

```systemverilog
HDMI_PERIOD_VIDEO_PREAMBLE
HDMI_PERIOD_VIDEO_GB
HDMI_PERIOD_DATA_PREAMBLE
HDMI_PERIOD_DATA_GB_LEAD
HDMI_PERIOD_DATA_PAYLOAD
HDMI_PERIOD_DATA_GB_TRAIL
```

Video preamble nastavuje:

```systemverilog
ch1_next = PRE_VIDEO_CH1;
```

Data preamble nastavuje:

```systemverilog
ch1_next = PRE_DATA_CH1;
```

A CH0 data guard band je už dynamický podľa HS/VS:

```systemverilog
unique case ({vsync_i, hsync_i})
  2'b00: gb_data_ch0 = 10'b0100111001;  // TERC4(4'b1001)
  2'b01: gb_data_ch0 = 10'b1011000110;  // TERC4(4'b1011)
  2'b10: gb_data_ch0 = 10'b1001110001;  // TERC4(4'b1101)
  2'b11: gb_data_ch0 = 10'b1011000011;  // TERC4(4'b1111)
endcase
```

Toto je správny smer. Mux už nie je len DVI mux, ale vie aj HDMI preamble a guard bandy.

---

### Data island formatter

`data_island_formatter.sv` už robí plnohodnotnejší HDMI mapping:

```text
HB0..HB2 + BCH
PB0..PB27 + subpacket BCH
→ 32 symbol periods
→ ch0/ch1/ch2 4-bit TERC4 nibbles
```

Toto je zásadný blok pre HDMI. Už nejde o starú skratku `byte → TERC4`.

---

## 3. Najväčšie aktuálne riziko: plánovanie AVI packetu

V `hdmi_tx_core.sv` je stále AVI packet plánovaný takto:

```systemverilog
// packet_pending: set on vsync rising edge (once per frame), cleared on
// packet_start so only one data island per frame is scheduled.
logic vsync_prev;
always_ff @(posedge pix_clk_i) vsync_prev <= vsync_r;

logic pending;
always_ff @(posedge pix_clk_i) begin
  if (!rst_ni)       pending <= 1'b0;
  else if (vsync_r && !vsync_prev) pending <= 1'b1;
  else if (packet_start)           pending <= 1'b0;
end
assign packet_pending = pending;
```

Toto je podľa mňa najdôležitejšie miesto na zlepšenie. Už máš `frame_start_i`, `line_start_i` a `vblank_i`, ale packet sa stále spúšťa podľa hrany `vsync_r`.

Ak si videl, že pri `ENABLE_DATA_ISLAND=1` je obraz posunutý nižšie o 2 riadky, toto je prvé miesto, ktoré by som upravil.

### Odporúčaná zmena

Použi bezpečné okno vo vertical blankingu, nie hranu VSYNC.

Napríklad:

```systemverilog
logic [7:0] vblank_line_cnt;
logic       pending;

always_ff @(posedge pix_clk_i) begin
  if (!rst_ni) begin
    vblank_line_cnt <= 8'd0;
    pending         <= 1'b0;
  end else begin
    if (frame_start_r) begin
      vblank_line_cnt <= 8'd0;
      pending         <= 1'b0;
    end else if (line_start_r && vblank_r) begin
      vblank_line_cnt <= vblank_line_cnt + 1'b1;

      if (vblank_line_cnt == 8'd4)
        pending <= 1'b1;
    end

    if (packet_start)
      pending <= 1'b0;
  end
end
```

Tým sa AVI packet nebude plánovať priamo na VSYNC hrane, ale až v bezpečnej časti vertical blankingu.

Ak sa tým odstráni 2-riadkový posun, príčina bola potvrdená.

---

## 4. Fázovanie HS/VS v data islande

V `data_island_formatter` je:

```systemverilog
.hsync_i  (hsync_r),
.vsync_i  (vsync_r),
```

ale `hdmi_channel_mux` dostáva:

```systemverilog
.vsync_i (vsync_enc),
.hsync_i (hsync_enc),
```

kde `vsync_enc/hsync_enc` sú oneskorené o 2 cykly.

To znamená:

```text
data payload CH0 používa hsync_r/vsync_r
data guard band CH0 používa hsync_enc/vsync_enc
```

To môže byť v hraničných situáciách fázovo rozdielne.

Preto odporúčam simuláciou overiť, že počas celého data islandu sú HS/VS bity v CH0 konzistentné s tým, čo očakáva mux na guard bandách.

Možné riešenia:

1. Nechať formatter na `hsync_r/vsync_r`, ak je to zámerne predlatencované kvôli TERC4 latencii.
2. Alebo prepojiť formatter na oneskorené HS/VS, ak simulácia ukáže posun.

Toto by som nerobil naslepo. Najprv testbench alebo SignalTap.

---

## 5. Latencia data island cesty

TERC4 encoder má registrovaný výstup a mux má tiež register. Teda data island cesta má latenciu:

```text
formatter nibble
  ↓
TERC4 encoder
  ↓
channel mux
```

V scheduleri a core je k tomu už komentovaná pipeline úvaha. Napriek tomu by som to overil assertami.

Minimálne overiť:

```text
packet_start: 1 pulz na začiatku DATA_PREAMBLE
packet_pop: presne 32 pulzov počas DATA_PAYLOAD
DATA_PAYLOAD na výstupe muxu vyberá správne TERC4 symboly
VIDEO_PREAMBLE: 8 cyklov
VIDEO_GB: 2 cykly
VIDEO začína presne na prvom aktívnom TMDS video slove
```

Toto je dôležité pred tým, než pridáš ďalšie pakety.

---

## 6. PHY vrstva

`tmds_phy_ddr_aligned.sv` je už správna náhrada za `generic_serializer`.

Má:

```text
pair_cnt 0..4
load word pri pair_cnt==4
LSB-first DDR serializáciu
```

A výstupné mapovanie:

```text
hdmi_p_o[0] = Blue
hdmi_p_o[1] = Green
hdmi_p_o[2] = Red
hdmi_p_o[3] = Clock
```

Toto je rozumné.

Zostáva však timing constraint problém. Musíš mať SDC pre prechod:

```text
pix_clk domain → clk_x_i domain
```

Nedávaj tieto hodiny ako úplne asynchrónne, ak sa spoliehaš na PLL fázový vzťah.

Odporúčanie:

```tcl
set_multicycle_path -setup -from [get_clocks clk_pixel] -to [get_clocks clk_pixel5x] 5
set_multicycle_path -hold  -from [get_clocks clk_pixel] -to [get_clocks clk_pixel5x] 4
```

Názvy clockov treba prispôsobiť konkrétnemu Quartus projektu. Over v Timing Analyzer, že sa pravidlo vzťahuje len na cesty z registrovaných TMDS slov do PHY shift registrov.

---

## 7. Čo ešte chýba k plnému HDMI

Aktuálne máš:

```text
HDMI video + AVI InfoFrame data island
```

To ešte nie je plný HDMI s audio.

Chýba:

```text
GCP packet
packet arbiter
Audio InfoFrame zapojenie
ACR N/CTS packet
Audio Sample Packet
audio FIFO alebo I2S/PCM vstup
EDID/DDC
```

---

## 8. Odporúčaný ďalší postup

### Krok 1: stabilizovať AVI InfoFrame

Najskôr vyriešiť packet timing:

```text
vsync edge trigger → bezpečné vblank line trigger
```

Čiže použiť `line_start_r && vblank_r` a oneskorený riadok vo vblanku.

Cieľ:

```text
ENABLE_DATA_ISLAND=1
obraz nie je posunutý
farby sú správne
monitor drží lock
```

---

### Krok 2: pridať testbench pre scheduler + formatter

Overiť:

```text
packet_pop má 32 pulzov
data island nezačne, ak blank_remaining nestačí
video preamble/guard sú presne pred active video
DATA_PAYLOAD nezasahuje do DE
```

---

### Krok 3: pridať `hdmi_packet_arbiter`

Teraz je AVI zapojený priamo. Pre plné HDMI potrebuješ packet arbiter.

Prvá verzia arbitra:

```text
každý frame:
  slot 1: GCP
  slot 2: AVI
```

Neskôr:

```text
sloty pre Audio InfoFrame
ACR
Audio Sample Packet
```

Navrhnuté rozhranie:

```systemverilog
output logic [7:0] hb_o [0:2],
output logic [7:0] pb_o [0:27],
output logic       packet_valid_o,
input  logic       packet_accept_i
```

alebo packed vector forma:

```systemverilog
output logic [23:0]  hb_flat_o,
output logic [223:0] pb_flat_o
```

Packed forma býva pre toolchain robustnejšia.

---

### Krok 4: GCP

Pridaj `gcp_packet_builder`.

Pre základný 8-bit RGB režim môže byť payload prakticky nulový, ale GCP je dobrý ďalší test packet pred audio.

---

### Krok 5: Audio Clock Regeneration

Pred audio sample paketmi potrebuješ ACR:

```text
N/CTS
```

Prvý režim:

```text
2ch LPCM
48 kHz
N = 6144
CTS podľa pixel clocku
```

Pre začiatok použi tabuľku pre konkrétne pixel clocky.

---

### Krok 6: Audio InfoFrame

`infoframe_builder` už obsahuje Audio InfoFrame logiku, ale nie je zapojená do hlavnej packet cesty.

Po GCP/AVI pridaj Audio InfoFrame ako ďalší packet source do arbitra.

---

### Krok 7: Audio Sample Packetizer

Až potom rieš audio dáta.

Prvý test nerob cez I2S, ale interným generátorom:

```text
48 kHz
2-kanál
1 kHz test tón
16 alebo 24 bit LPCM
```

Potom pridať:

```text
I2S receiver
audio async FIFO
audio sample packetizer
```

---

## 9. Zhrnutie aktuálneho stavu

Aktuálne súbory sú už v dobrom stave pre HDMI video + AVI InfoFrame:

```text
Hotové / dobré:
+ RGB565 → RGB888 wrapper
+ hdmi_tx_core s explicitným blanking timingom
+ tmds_video_encoder s opravenou polaritou
+ period scheduler s VIDEO_PREAMBLE/VIDEO_GB
+ blank_remaining guard pre data island
+ data_island_formatter s BCH/ECC
+ TERC4 cesta
+ dynamický CH0 data guard band
+ word-aligned DDR PHY
```

Najväčšie riziká:

```text
- packet_pending sa stále spúšťa na VSYNC hrane
- HS/VS fáza medzi formatterom a mux guard bandom treba overiť
- data-island latenciu treba potvrdiť simuláciou
- PHY potrebuje korektné SDC multicycle constraints
```

Najbližší najlepší krok:

```text
Nahradiť AVI trigger z VSYNC edge na bezpečný vblank-line trigger pomocou line_start_i.
```

Potom pokračovať na:

```text
GCP → packet arbiter → ACR → Audio InfoFrame → Audio Sample Packetizer.
```
