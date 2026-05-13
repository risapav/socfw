Áno, presne toto je veľmi dobrý nápad. Pre simuláciu je vhodné vytvoriť **neštandardný „HDMI debug video mode“**, kde bude rámec veľmi krátky, napríklad iba 10 až 16 riadkov, aby sa dali rýchlo overiť:

```text
video period
control period
video preamble
video guard band
data island preamble
data island guard band
data island payload
packet arbiter
TERC4 encoder
BCH/ECC formatter
návrat späť do video režimu
```

Tento režim nemusí byť kompatibilný s monitorom. Je určený iba pre simuláciu.

---

## Odporúčaný simulačný HDMI režim

Navrhol by som napríklad tento režim:

```systemverilog
localparam int SIM_H_ACTIVE = 32;
localparam int SIM_H_FP     = 8;
localparam int SIM_H_SYNC   = 8;
localparam int SIM_H_BP     = 16;
localparam int SIM_H_TOTAL  = SIM_H_ACTIVE + SIM_H_FP + SIM_H_SYNC + SIM_H_BP;

localparam int SIM_V_ACTIVE = 10;
localparam int SIM_V_FP     = 2;
localparam int SIM_V_SYNC   = 2;
localparam int SIM_V_BP     = 2;
localparam int SIM_V_TOTAL  = SIM_V_ACTIVE + SIM_V_FP + SIM_V_SYNC + SIM_V_BP;
```

Teda:

```text
H_TOTAL = 64 pixelov
V_TOTAL = 16 riadkov
aktívny obraz = 32 × 10 pixelov
```

To je veľmi malé, ale pre simuláciu ideálne.

---

## Dôležitá podmienka

Ak chceš testovať data island payload s dĺžkou 32 symbolov, horizontálny blanking musí byť dostatočne dlhý.

HDMI data island potrebuje približne:

```text
8 symbolov  data island preamble
2 symboly   leading guard band
32 symbolov payload
2 symboly   trailing guard band
```

Spolu minimálne:

```text
44 pixel clock cyklov
```

Preto by horizontálny blanking mal mať aspoň 48 cyklov.

Pri návrhu vyššie:

```text
H_ACTIVE = 32
H_BLANK  = 8 + 8 + 16 = 32
```

To je málo pre celý data island. Preto lepší debug režim je:

```systemverilog
localparam int SIM_H_ACTIVE = 32;
localparam int SIM_H_FP     = 8;
localparam int SIM_H_SYNC   = 8;
localparam int SIM_H_BP     = 40;
localparam int SIM_H_TOTAL  = 88;

localparam int SIM_V_ACTIVE = 10;
localparam int SIM_V_FP     = 2;
localparam int SIM_V_SYNC   = 2;
localparam int SIM_V_BP     = 2;
localparam int SIM_V_TOTAL  = 16;
```

Tu máš:

```text
H_ACTIVE = 32
H_BLANK  = 56
```

To už stačí na jeden data island packet v blankingu.

---

# Navrhovaný režim: `HDMI_SIM_32x10`

Použil by som názov napríklad:

```systemverilog
VIDEO_MODE_SIM_32x10
```

alebo:

```systemverilog
HDMI_DEBUG_32x10
```

Parametre:

```systemverilog
localparam int H_ACTIVE = 32;
localparam int H_FP     = 8;
localparam int H_SYNC   = 8;
localparam int H_BP     = 40;

localparam int V_ACTIVE = 10;
localparam int V_FP     = 2;
localparam int V_SYNC   = 2;
localparam int V_BP     = 2;

localparam bit HSYNC_POL = 1'b1;
localparam bit VSYNC_POL = 1'b1;
```

Celkový frame:

```text
H_TOTAL = 88
V_TOTAL = 16
frame   = 1408 pixel clock cyklov
```

To je veľmi rýchle na simuláciu. Vieš nasimulovať desiatky frame-ov bez veľkej záťaže.

---

## Čo tým vieš overiť

Tento režim je veľmi vhodný na overenie, či tvoj `hdmi_period_scheduler.sv` generuje správne prechody.

Pre každý riadok vieš očakávať približne:

```text
CONTROL / DATA obdobie počas blankingu
VIDEO_PREAMBLE pred aktívnym obrazom
VIDEO_GB
VIDEO počas 32 aktívnych pixelov
```

Ak je v riadku vložený data island packet:

```text
DATA_PREAMBLE = 8 cyklov
DATA_GB_LEAD  = 2 cykly
DATA_PAYLOAD  = 32 cyklov
DATA_GB_TRAIL = 2 cykly
```

---

# Odporúčaná testovacia štruktúra

Vytvoril by som samostatný testbench:

```text
tb_hdmi_tx_core_sim_mode.sv
```

Ten by nemal ísť cez PHY serializer. Najprv testuj iba pixel-clock úroveň:

```text
RGB / DE / HS / VS
        ↓
hdmi_tx_core
        ↓
ch0/ch1/ch2 10-bit TMDS symboly
```

Čiže netestovať zatiaľ `tmds_phy_ddr_aligned.sv`.

PHY testovať samostatne.

---

## Prečo najprv bez PHY

Pretože pri debugovaní HDMI protokolu je lepšie oddeliť:

```text
protokolová vrstva:
  period scheduler
  packet arbiter
  infoframe builder
  data island formatter
  TMDS/TERC4 encoder

fyzická vrstva:
  DDR serializer
  5× clock
  pinout
```

V simulácii protokolu nepotrebuješ 200 MHz `clk_x_i`. Stačí pixel clock.

---

# Praktický návrh testbench signálov

Testbench by generoval jednoduchý obraz:

```systemverilog
always_ff @(posedge pix_clk) begin
  if (!rst_n) begin
    x <= 0;
    y <= 0;
  end else begin
    if (x == H_TOTAL-1) begin
      x <= 0;
      if (y == V_TOTAL-1)
        y <= 0;
      else
        y <= y + 1;
    end else begin
      x <= x + 1;
    end
  end
end
```

Aktívna oblasť:

```systemverilog
assign de = (x < H_ACTIVE) && (y < V_ACTIVE);
```

Sync:

```systemverilog
assign hsync = ((x >= H_ACTIVE + H_FP) &&
                (x <  H_ACTIVE + H_FP + H_SYNC)) ? HSYNC_POL : ~HSYNC_POL;

assign vsync = ((y >= V_ACTIVE + V_FP) &&
                (y <  V_ACTIVE + V_FP + V_SYNC)) ? VSYNC_POL : ~VSYNC_POL;
```

Jednoduché RGB:

```systemverilog
assign rgb_r = x[7:0];
assign rgb_g = y[7:0];
assign rgb_b = {x[3:0], y[3:0]};
```

---

# Čo treba v simulácii kontrolovať

## 1. Video period nesmie byť počas blankingu

Assertion:

```systemverilog
assert property (@(posedge pix_clk)
  period_o == HDMI_PERIOD_VIDEO |-> de_aligned
);
```

Alebo jednoduchšie procedurálne:

```systemverilog
always_ff @(posedge pix_clk) begin
  if (rst_n) begin
    if (period_o == HDMI_PERIOD_VIDEO && !de_aligned) begin
      $error("VIDEO period outside active video at x=%0d y=%0d", x, y);
    end
  end
end
```

---

## 2. Data payload nesmie zasiahnuť do aktívneho videa

```systemverilog
always_ff @(posedge pix_clk) begin
  if (rst_n) begin
    if (period_o == HDMI_PERIOD_DATA_PAYLOAD && de_aligned) begin
      $error("DATA PAYLOAD overlaps active video at x=%0d y=%0d", x, y);
    end
  end
end
```

---

## 3. Data island payload musí mať presne 32 cyklov

```systemverilog
int data_payload_cnt;

always_ff @(posedge pix_clk) begin
  if (!rst_n) begin
    data_payload_cnt <= 0;
  end else begin
    if (period_o == HDMI_PERIOD_DATA_PAYLOAD) begin
      data_payload_cnt <= data_payload_cnt + 1;
    end else begin
      if (data_payload_cnt != 0 && data_payload_cnt != 32) begin
        $error("Bad DATA_PAYLOAD length: %0d", data_payload_cnt);
      end
      data_payload_cnt <= 0;
    end
  end
end
```

---

## 4. Video guard band musí mať očakávanú dĺžku

Ak máš `HDMI_PERIOD_VIDEO_GB`, kontroluj:

```systemverilog
int video_gb_cnt;

always_ff @(posedge pix_clk) begin
  if (!rst_n) begin
    video_gb_cnt <= 0;
  end else begin
    if (period_o == HDMI_PERIOD_VIDEO_GB) begin
      video_gb_cnt <= video_gb_cnt + 1;
    end else begin
      if (video_gb_cnt != 0 && video_gb_cnt != 2) begin
        $error("Bad VIDEO_GB length: %0d", video_gb_cnt);
      end
      video_gb_cnt <= 0;
    end
  end
end
```

---

## 5. Data preamble musí mať 8 cyklov

```systemverilog
int data_pre_cnt;

always_ff @(posedge pix_clk) begin
  if (!rst_n) begin
    data_pre_cnt <= 0;
  end else begin
    if (period_o == HDMI_PERIOD_DATA_PREAMBLE) begin
      data_pre_cnt <= data_pre_cnt + 1;
    end else begin
      if (data_pre_cnt != 0 && data_pre_cnt != 8) begin
        $error("Bad DATA_PREAMBLE length: %0d", data_pre_cnt);
      end
      data_pre_cnt <= 0;
    end
  end
end
```

---

# Veľmi užitočné: dump textového logu

Okrem waveform by som pridal aj textový log pre prvých 10 riadkov:

```systemverilog
always_ff @(posedge pix_clk) begin
  if (rst_n) begin
    if (period_o != period_prev) begin
      $display("t=%0t x=%0d y=%0d period=%s",
               $time, x, y, period_name(period_o));
    end
  end
end
```

Funkcia:

```systemverilog
function string period_name(input hdmi_period_e p);
  case (p)
    HDMI_PERIOD_CONTROL:       return "CONTROL";
    HDMI_PERIOD_VIDEO_PREAMBLE:return "VIDEO_PREAMBLE";
    HDMI_PERIOD_VIDEO_GB:      return "VIDEO_GB";
    HDMI_PERIOD_VIDEO:         return "VIDEO";
    HDMI_PERIOD_DATA_PREAMBLE: return "DATA_PREAMBLE";
    HDMI_PERIOD_DATA_GB_LEAD:  return "DATA_GB_LEAD";
    HDMI_PERIOD_DATA_PAYLOAD:  return "DATA_PAYLOAD";
    HDMI_PERIOD_DATA_GB_TRAIL: return "DATA_GB_TRAIL";
    default:                   return "UNKNOWN";
  endcase
endfunction
```

Tento log ti okamžite ukáže napríklad:

```text
x=34 y=0 CONTROL
x=40 y=0 DATA_PREAMBLE
x=48 y=0 DATA_GB_LEAD
x=50 y=0 DATA_PAYLOAD
x=82 y=0 DATA_GB_TRAIL
x=84 y=0 CONTROL
...
x=78 y=1 VIDEO_PREAMBLE
x=86 y=1 VIDEO_GB
x=0  y=2 VIDEO
```

Ak uvidíš, že `DATA_PAYLOAD` zasahuje do `VIDEO`, máš chybu v scheduleri.

---

# Dôležitá poznámka k aktívnemu videu

Pri malom režime `32 × 10` musíš dobre rozhodnúť, kde začína aktívne video.

V bežnom VGA časovaní je často:

```text
x = 0 ... H_ACTIVE-1
```

aktívna časť, potom blanking.

Pre HDMI scheduler je však často vhodnejšie, aby pred aktívnym videom existoval blanking čas na:

```text
video preamble
video guard band
```

Preto môže byť pre simuláciu výhodnejší timing, kde aktívne video nie je na začiatku riadku, ale až po blankingu:

```text
front/control/blanking → preamble → guard band → active video
```

Ak tvoj existujúci timing generator má aktívne video od `x=0`, scheduler musí vedieť pripraviť video preamble na konci predchádzajúceho riadku. To je v HDMI bežné, ale v malom sim móde treba mať dostatočný blanking na konci predchádzajúceho riadku.

Preto by som v simulácii sledoval najmä prechod:

```text
koniec blankingu → VIDEO_PREAMBLE → VIDEO_GB → prvý aktívny pixel
```

---

# Odporúčané test scenáre

## Scenár 1: čisté video

```systemverilog
ENABLE_DATA_ISLAND = 0
ENABLE_AUDIO       = 0
```

Cieľ:

```text
CONTROL → VIDEO_PREAMBLE → VIDEO_GB → VIDEO
```

---

## Scenár 2: data island bez audia

```systemverilog
ENABLE_DATA_ISLAND = 1
ENABLE_AUDIO       = 0
```

Cieľ:

```text
GCP/AVI packet sa vloží iba do blankingu
video stále začne korektne
```

---

## Scenár 3: ACR only

```text
DATA_ISLAND = 1
ACR = 1
AUDIO_IF = 0
SAMPLE = 0
```

Cieľ:

```text
ACR packet má korektnú dĺžku a neprekrýva video
```

---

## Scenár 4: Audio InfoFrame only

```text
DATA_ISLAND = 1
ACR = 0
AUDIO_IF = 1
SAMPLE = 0
```

---

## Scenár 5: Audio Sample only

```text
DATA_ISLAND = 1
ACR = 0
AUDIO_IF = 0
SAMPLE = 1
```

---

## Scenár 6: full audio

```text
DATA_ISLAND = 1
ACR = 1
AUDIO_IF = 1
SAMPLE = 1
```

---

# Pre tento účel by som pridal parameter `SIM_MODE`

Do `vga_hdmi_tx.sv` alebo timing generátora:

```systemverilog
parameter bit SIM_MODE = 0
```

a potom:

```systemverilog
localparam int C_H_ACTIVE = SIM_MODE ? 32 : H_ACTIVE;
localparam int C_H_FP     = SIM_MODE ? 8  : H_FP;
localparam int C_H_SYNC   = SIM_MODE ? 8  : H_SYNC;
localparam int C_H_BP     = SIM_MODE ? 40 : H_BP;

localparam int C_V_ACTIVE = SIM_MODE ? 10 : V_ACTIVE;
localparam int C_V_FP     = SIM_MODE ? 2  : V_FP;
localparam int C_V_SYNC   = SIM_MODE ? 2  : V_SYNC;
localparam int C_V_BP     = SIM_MODE ? 2  : V_BP;
```

Ale ešte čistejšie je nemať `SIM_MODE` priamo v HDMI jadre. Lepšie:

```text
timing generator má malé parametre,
hdmi_tx_core nevie, že ide o simuláciu.
```

Tým overuješ skutočné jadro bez simulačných výnimiek.

---

# Môj odporúčaný postup

## Krok 1

Vytvoriť nový testbench:

```text
tb_hdmi_tx_core_32x10.sv
```

Bez PHY.

---

## Krok 2

Použiť tiny timing:

```text
32 aktívnych pixelov
56 blanking pixelov
10 aktívnych riadkov
6 blanking riadkov
```

---

## Krok 3

Pridať procedurálne asserty na:

```text
DATA_PAYLOAD length = 32
DATA_PREAMBLE length = 8
DATA_GB length = 2
VIDEO_GB length = 2
žiadny DATA_PAYLOAD počas DE
žiadny VIDEO mimo DE
```

---

## Krok 4

Logovať každú zmenu `period_o`.

---

## Krok 5

Až keď toto prejde, testovať reálny 800×600 režim.

---

## Kľúčový benefit

Týmto režimom vieš za pár mikrosekúnd simulácie zistiť:

```text
či scheduler stíha vložiť packet,
či packet netrafí active video,
či TERC4 nie je posunutý o 1 takt,
či arbiter neposiela packet v zlom čase,
či sa core vie vrátiť späť do video režimu.
```

Čiže áno — **neštandardný HDMI sim režim na 10 riadkov je nielen možný, ale pre tento projekt veľmi odporúčaný**.
