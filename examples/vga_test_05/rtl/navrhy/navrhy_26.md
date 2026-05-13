Áno. Obsah `sim/` je užitočný a ide správnym smerom, ale aktuálne testy ešte **neoverujú najdôležitejšiu vec pre tvoj aktuálny HDMI problém**: či sa po `data_island_formatter → TERC4 → mux` dostane na výstup správna **32-symbolová payload sekvencia** bez posunu, duplikácie alebo straty symbolu.

## Čo je v `sim/`

Adresár obsahuje:

```text
Makefile
tb_acr_packet_builder.sv
tb_audio_sample_packet_builder.sv
tb_data_island_formatter.sv
tb_hdmi_bch_ecc.sv
tb_hdmi_period_scheduler.sv
tb_hdmi_tx_core_32x10.sv
transcript
```

Je to dobrý základ testovacej sady:

```text
packet builder unit testy
BCH/ECC unit test
data island formatter unit test
period scheduler unit test
malý 32×10 hdmi_tx_core integračný test
```

Najdôležitejšie: `tb_hdmi_tx_core_32x10.sv` už prešiel podľa transcriptu:

```text
ALL ASSERTIONS PASSED
Errors: 0
Warnings: 15
```

To znamená, že základné časovanie periód je aktuálne konzistentné.

---

# 1. `Makefile`

Makefile je prehľadný a má rozumné targety:

```makefile
all: bch_ecc data_island scheduler acr_packet audio_sample_pkt tx_core_32x10
```

Toto je dobré.

## Pozitíva

* Každý testbench má vlastný target.
* `tx_core_32x10` kompiluje celý relevantný HDMI reťazec bez PHY.
* Čistí sa `work`, `transcript`, `*.log`.

## Problém

Makefile používa relatívne cesty:

```makefile
RTL  := ../rtl/hdmi
VRTL := ../rtl/video
```

To je v poriadku, ak reálne adresárová štruktúra je:

```text
project/
  rtl/
    hdmi/
    video/
  sim/
```

Ale nahraté súbory tu sú všetky v jednom adresári. Takže samotný upload nie je samostatne spustiteľný mimo tvojej lokálnej štruktúry.

## Odporúčanie

Doplniť možnosť override z príkazového riadku:

```makefile
RTL  ?= ../rtl/hdmi
VRTL ?= ../rtl/video
```

Potom vieš spustiť napríklad:

```bash
make RTL=/mnt/data VRTL=/mnt/data tx_core_32x10
```

---

# 2. `tb_hdmi_bch_ecc.sv`

Tento test je dobrý a cielene overuje:

```text
header BCH/ECC
subpacket BCH/ECC
all-zero subpacket = 0xF5
známe AVI/GCP hodnoty
```

Testy:

```systemverilog
chk_hdr(24'h0D_02_82, 8'h67, "AVI hdr {0x82,0x02,0x0D}");
chk_hdr(24'h00_00_00, 8'h0E, "header all-zeros");
chk_hdr(24'h00_00_03, 8'hAE, "GCP hdr {0x03,0x00,0x00}");
chk_sp(56'h00_00_00_00_00_00_00, 8'hF5, "SP all-zeros");
```

Toto je presne typ golden-vector testu, ktorý potrebuješ.

## Odporúčanie

Doplniť ešte minimálne jeden test pre ACR subpacket a jeden pre Audio Sample subpacket, lebo práve audio režim zhadzuje monitor.

---

# 3. `tb_data_island_formatter.sv`

Toto je zatiaľ najcennejší unit test v sim adresári.

Overuje:

```text
AVI InfoFrame HB/PB
BCH header ECC
BCH subpacket ECC
32 data island symbolov
ch0/ch1/ch2 nibble mapping
paritu v ch0[3]
```

To je veľmi dobré.

## Dôležité pozitívum

Test kontroluje presné nibbly:

```systemverilog
exp_ch0[0:31]
exp_ch1[0:31]
exp_ch2[0:31]
```

a postupne volá:

```systemverilog
check_sym(0);
...
check_sym(31);
```

Čiže samotný `data_island_formatter` ako izolovaný blok vie generovať správnu sekvenciu, ak dostane správne `start_i` a `advance_i`.

## Slabina

Tento test overuje formatter izolovane, ale nie jeho zarovnanie s:

```text
hdmi_period_scheduler
TERC4 encoder latency
hdmi_channel_mux register
```

Presne tam je teraz najväčšie riziko.

Tvoj unit test robí:

```systemverilog
start_i = 1;
@(posedge clk);
start_i = 0;
#1;
check_sym(0);
```

Potom:

```systemverilog
advance_i = 1;
@(posedge clk);
advance_i = 0;
#1;
check_sym(p);
```

To znamená, že overuješ **formatter výstup bez downstream pipeline**. To je správne pre unit test, ale nestačí pre core-level bug.

## Menší problém v komentári

V `data_island_formatter.sv` komentár stále hovorí:

```systemverilog
input logic hsync_i, // passed to ch0[1]
input logic vsync_i, // passed to ch0[0]
```

ale implementácia je:

```systemverilog
assign ch0_o = {parity, hdr_bit, vsync_i, hsync_i};
```

Čiže reálne:

```text
ch0[1] = vsync
ch0[0] = hsync
```

Komentár je opačne. Kód vyzerá logicky, komentár treba opraviť.

---

# 4. `tb_hdmi_period_scheduler.sv`

Tento test je užitočný pre lokálne overenie FSM.

Overuje scenáre:

```text
1. bez data islandu
2. data island pri dostatočnom budgete
3. plné počty periód
4. tight budget
```

Kontroluje:

```text
VIDEO_PREAMBLE = 8
VIDEO_GB = 2
DATA_PREAMBLE = 8
DATA_GB_LEAD = 2
DATA_PAYLOAD = 32
DATA_GB_TRAIL = 2
packet_pop = 32
DATA_PAYLOAD neprekrýva DE
```

To je dobré.

## Slabina

Test je stále na úrovni `period_o`, nie na úrovni výstupu `ch*_o`.

Teda potvrdzuje:

```text
scheduler generuje správne dĺžky periód
```

ale nepotvrdzuje:

```text
data symbol 0 vyjde počas prvého DATA_PAYLOAD cyklu na ch*_o
data symbol 1 vyjde počas druhého DATA_PAYLOAD cyklu na ch*_o
...
data symbol 31 vyjde počas posledného DATA_PAYLOAD cyklu na ch*_o
```

Presne toto teraz treba doplniť inde, ideálne do `tb_hdmi_tx_core_32x10.sv`.

---

# 5. `tb_acr_packet_builder.sv`

Tu je vážny nesúlad medzi testbenchom a aktuálnym `acr_packet_builder.sv`.

Testbench očakáva pre ACR:

```systemverilog
pb[sp*7+0] = {4'h0, cts_val[19:16]};
pb[sp*7+1] = cts_val[15:8];
pb[sp*7+2] = cts_val[7:0];
pb[sp*7+3] = {4'h0, n_val[19:16]};
pb[sp*7+4] = n_val[15:8];
pb[sp*7+5] = n_val[7:0];
pb[sp*7+6] = 8'h00;
```

Ale aktuálny `acr_packet_builder.sv` generuje:

```systemverilog
pb_o[sp*7 + 0] = cts_i[7:0];
pb_o[sp*7 + 1] = cts_i[15:8];
pb_o[sp*7 + 2] = {4'h0, cts_i[19:16]};
pb_o[sp*7 + 3] = 8'h00;
pb_o[sp*7 + 4] = n_i[7:0];
pb_o[sp*7 + 5] = n_i[15:8];
pb_o[sp*7 + 6] = {4'h0, n_i[19:16]};
```

Čiže test očakáva **MSB-first**, builder generuje **LSB-first s reserved byte medzi CTS a N**.

Toto je kritické, lebo ACR bol jeden z režimov, ktorý uspával monitor.

## Treba rozhodnúť podľa HDMI špecifikácie

Momentálne máš konflikt:

```text
tb_acr_packet_builder.sv     očakáva ACR layout A
acr_packet_builder.sv        implementuje ACR layout B
```

Nemôžu byť správne oba.

Keďže `data_island_formatter` posiela subpacket bity LSB-first z PB0, je veľmi pravdepodobné, že builder má dávať bytes v poradí PB0..PB6 podľa HDMI packet layoutu, nie podľa ľudskej MSB reprezentácie čísla.

Ale bez definitívneho golden modelu ACR by som to neuzatváral. Praktický ďalší krok je: vytvoriť Python referenčný ACR packet model a porovnať ho s HDMI 1.3/1.4 tabuľkou pre ACR.

## Teraz minimálne oprav konzistenciu

Buď upraviť testbench podľa buildera:

```systemverilog
chk8("CTS[7:0]",   pb[base+0], cts_val[7:0]);
chk8("CTS[15:8]",  pb[base+1], cts_val[15:8]);
chk8("CTS[19:16]", pb[base+2], {4'h0, cts_val[19:16]});
chk8("reserved",   pb[base+3], 8'h00);
chk8("N[7:0]",     pb[base+4], n_val[7:0]);
chk8("N[15:8]",    pb[base+5], n_val[15:8]);
chk8("N[19:16]",   pb[base+6], {4'h0, n_val[19:16]});
```

alebo upraviť builder podľa testbench očakávania.

Toto je potrebné vyriešiť pred ďalším HW testom `ACR only`.

---

# 6. `tb_audio_sample_packet_builder.sv`

Test je dobrý ako unit test:

```text
header 0x02
HB1 = 0x0F
HB2 = 0x00
4 sample páry
parita ľavého/pravého kanálu
byte split 16-bit sample do 24-bit AW
```

Súhlasí s aktuálnym builderom.

## Slabina

Test overuje iba 16-bit audio sample packovanie, ale nie:

```text
IEC60958 channel status bity
valid/user/channel status režim
flat layout
sample present bits
vzťah k Audio InfoFrame
vzťah k ACR
```

Na prvý bring-up je to OK. Pre finálny HDMI audio bude treba neskôr rozšíriť.

---

# 7. `tb_hdmi_tx_core_32x10.sv`

Toto je najdôležitejší testbench. Je veľmi dobré, že existuje.

Aktuálny transcript ukazuje:

```text
ALL ASSERTIONS PASSED
```

a prechody periód vyzerajú konzistentne:

```text
DATA_PREAMBLE  len=8
DATA_GB_LEAD   len=2
DATA_PAYLOAD   len=32
DATA_GB_TRAIL  len=2
CONTROL        len=9
VIDEO_PREAMBLE len=8
VIDEO_GB       len=2
VIDEO          len=32
```

To znamená, že problém `VIDEO outside de_r` bol v testbenchi správne preinterpretovaný ako pipeline alignment:

```systemverilog
period_o  VIDEO ↔ de_r_d1
period_d1 VIDEO ↔ de_r_d2
```

Toto je rozumné.

## Pozitívne

Test teraz rozlišuje:

```text
period_o
period_d1
de_r
de_r_d1
de_r_d2
```

To je správny smer.

## Veľká slabina

Test stále neoveruje **obsah `ch0/ch1/ch2` počas data island payloadu**.

Aktuálne kontroluje:

```text
dĺžky periód
VIDEO/de pipeline alignment
DATA_PAYLOAD neprekrýva DE
```

ale nekontroluje:

```text
či DATA_PAYLOAD na výstupe ch*_o obsahuje správne TERC4 symboly
či prvý payload symbol nie je zopakovaný
či posledný payload symbol nie je stratený
či DATA_GB_TRAIL nenesie ešte posledný payload
či prvý VIDEO symbol nie je ešte guard/control
```

Toto je presne medzera, ktorú treba teraz zaplniť.

---

# 8. Transcript

Transcript obsahuje iba beh:

```text
tb_hdmi_tx_core_32x10
```

Nie je to transcript z `make all`.

Výsledok:

```text
ALL ASSERTIONS PASSED
Errors: 0
Warnings: 15
Suppressed Errors: 216
```

## Warnings

Väčšina warningov je typu:

```text
Defaulting port ... kind to 'var' rather than 'wire'
```

To je spôsobené unpacked array portami typu:

```systemverilog
input logic [7:0] hb_i [0:2]
```

Nie je to funkčný problém.

Dva warningy sú:

```text
No condition is true in the unique/priority if/case statement
```

v čase 0:

```text
hdmi_channel_mux.sv
hdmi_period_scheduler.sv
```

To je pravdepodobne X/initialization problém pred resetom. Nie je kritický, ale dá sa vyčistiť.

## Odporúčanie

V `unique case` pridať explicitnejšie defaulty, alebo nepoužívať `unique` tam, kde vstup môže byť X pri time 0.

Napríklad v `hdmi_channel_mux.sv`:

```systemverilog
case (period_i)
  ...
  default: begin
    ch2_next = ctrl_ch2_i;
    ch1_next = ctrl_ch1_i;
    ch0_next = ctrl_ch0_i;
  end
endcase
```

Default už máš, ale `unique case` s X stavom vie stále upozorniť. Môžeš použiť obyčajné `case`.

---

# Najväčšia aktuálna medzera v `sim/`

Toto je najdôležitejšie:

```text
Máme test formatteru izolovane.
Máme test schedulera izolovane.
Máme test core period timing.
Nemáme test, ktorý spojí:
scheduler packet_pop
→ formatter advance
→ TERC4 latency
→ channel_mux period_d1
→ ch*_o
a overí 32 payload symbolov na finálnom výstupe.
```

Bez tohto testu môže všetko „prejsť“, ale monitor môže stále spať, pretože data island packet je obsahovo posunutý.

---

# Čo by som doplnil ako ďalšie testy

## 1. `tb_hdmi_tx_core_32x10_payload.sv`

Alebo rozšíriť existujúci `tb_hdmi_tx_core_32x10.sv`.

Cieľ: počas `period_d1 == HDMI_PERIOD_DATA_PAYLOAD` alebo ešte lepšie počas output stage očakávať konkrétne TERC4 symboly.

Keďže `ch*_o` je už TMDS/TERC4 10-bit výstup, treba použiť TERC4 LUT v testbenchi:

```systemverilog
function automatic tmds_word_t terc4_ref(input logic [3:0] n);
  case (n)
    4'h0: return 10'b1010011100;
    4'h1: return 10'b1001100011;
    4'h2: return 10'b1011100100;
    4'h3: return 10'b1011100010;
    4'h4: return 10'b0101110001;
    4'h5: return 10'b0100011110;
    4'h6: return 10'b0110001110;
    4'h7: return 10'b0100111100;
    4'h8: return 10'b1011001100;
    4'h9: return 10'b0100111001;
    4'ha: return 10'b0110011100;
    4'hb: return 10'b1011000110;
    4'hc: return 10'b1010001110;
    4'hd: return 10'b1001110001;
    4'he: return 10'b0101100011;
    4'hf: return 10'b1011000011;
  endcase
endfunction
```

Potom pri known AVI/GCP packete očakávať:

```text
ch0 == terc4_ref(exp_ch0[p])
ch1 == terc4_ref(exp_ch1[p])
ch2 == terc4_ref(exp_ch2[p])
```

Len treba správne určiť output-stage period signál. Pravdepodobne budeš potrebovať:

```systemverilog
period_d2 <= period_d1;
```

pre zarovnanie s registrovaným mux výstupom.

---

## 2. Test `packet_pop` vs formatter symbol index

V `tb_hdmi_tx_core_32x10.sv` dočasne sondovať interné signály:

```systemverilog
wire [4:0] fmt_sym = u_dut.gen_data_island.u_formatter.sym_cnt;
wire       fmt_active = u_dut.gen_data_island.u_formatter.active;
wire       pkt_pop = u_dut.packet_pop;
```

a logovať:

```text
cy period packet_pop fmt_sym di_ch0 di_ch1 di_ch2 ch0 ch1 ch2
```

Hľadaj pattern:

```text
fmt_sym: 0,0,1,2,...   zle
fmt_sym: 0,1,2,...31   dobre na správnom output stage
```

---

## 3. Audio packet formatter test

`tb_data_island_formatter.sv` aktuálne testuje AVI. Doplnil by som:

```text
ACR packet formatter golden nibbles
Audio Sample packet formatter golden nibbles
Audio InfoFrame formatter golden nibbles
```

Pretože práve tieto pakety spúšťajú problém na monitore.

---

## 4. `tb_hdmi_packet_arbiter.sv`

Momentálne chýba samostatný test arbiteru.

Treba overiť:

```text
frame_start/vsync trigger
GCP → AVI → ACR → AUDIO_IF poradie
preskočenie ACR, keď valid_acr=0
preskočenie Audio IF, keď valid_audio_if=0
sample_consume_o iba pri prijatom sample packete
sample packet nemá prednosť pred frame sekvenciou
```

Aktuálny upload stále používa `vsync_i` v `hdmi_packet_arbiter.sv`, nie `frame_start_i`. Ak už máš refaktor na `frame_start_i` inde, tento nahratý súbor ešte nie je posledná verzia.

---

# Prioritný zoznam opráv v `sim/`

## Priorita 1 — vyriešiť ACR test mismatch

`tb_acr_packet_builder.sv` a `acr_packet_builder.sv` si odporujú.

Toto treba opraviť hneď, lebo inak ACR-only testy nemajú dôveryhodný základ.

---

## Priorita 2 — rozšíriť `tb_hdmi_tx_core_32x10` o kontrolu `ch*_o`

Nestačí `period_o`. Treba overiť finálne TMDS slová.

Minimálne:

```text
DATA_PREAMBLE výstup = control symbols s data preamble tokenom
DATA_GB_LEAD výstup = data guard band
DATA_PAYLOAD výstup = TERC4(payload symbol 0..31)
DATA_GB_TRAIL výstup = data guard band
VIDEO_GB výstup = video guard band
VIDEO výstup = video TMDS encoder output
```

---

## Priorita 3 — doplniť audio/data scenáre do 32×10 core testu

Teraz testuješ:

```systemverilog
ENABLE_DATA_ISLAND = 1
ENABLE_ACR_PACKET = 0
ENABLE_AUDIO_INFOFRAME = 0
ENABLE_AUDIO_SAMPLE = 0
enable_audio_i = 0
```

Čiže vlastne testuješ hlavne GCP/AVI bez audia.

Treba doplniť varianty:

```text
ACR only
Audio IF only
Sample only
ACR + Audio IF
Full audio
```

A pre každý aspoň overiť, že:

```text
packet sa vložil
dĺžky periód sedia
payload sekvencia na ch*_o sedí s očakávaným packetom
video sa po packete obnoví
```

---

## Priorita 4 — pridať `tb_terc4_encoder.sv`

Keďže TERC4 latencia bola nedávno kritická chyba, mal by mať vlastný test:

```text
vstup nibble N v cykle T
výstup TERC4(N) v cykle T+2
```

Tým sa zabráni regresii späť na 1-cyklový encoder.

---

# Krátky verdikt

`sim/` je dobrý základ a `tb_hdmi_tx_core_32x10` už potvrdzuje, že **period scheduler a DE alignment sú v malom režime pod kontrolou**.

Ale ešte stále nemáš test, ktorý by chytil najpravdepodobnejšiu aktuálnu chybu:

```text
správna dĺžka DATA_PAYLOAD, ale nesprávny obsah na výstupe ch0/ch1/ch2
kvôli posunu medzi packet_pop, formatterom, TERC4 a muxom.
```

Najbližší krok by som spravil tento:

```text
1. opraviť ACR test vs builder mismatch
2. doplniť do tb_hdmi_tx_core_32x10 kontrolu finálnych ch*_o počas DATA_PAYLOAD
3. pridať ACR/Audio IF/Sample scenáre do core-level simulácie
```

Až keď prejdú tieto testy, má zmysel opakovať test na monitore s `ENABLE_AUDIO=1` a `ENABLE_DATA_ISLAND=1`.
