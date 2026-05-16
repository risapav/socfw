Tento `soc_top.sv` zodpovedá testu **2B: GCP only**.

V inštancii `vga_hdmi_tx` máš:

```systemverilog
.ENABLE_ACR_PACKET(0),
.ENABLE_AUDIO(0),
.ENABLE_AUDIO_INFOFRAME(0),
.ENABLE_AUDIO_SAMPLE(0),
.ENABLE_AVI_PACKET(0),
.ENABLE_DATA_ISLAND(1),
.ENABLE_GCP_PACKET(1)
```

Čiže konfigurácia je:

```text
DATA = 1
AUDIO = 0
GCP = 1
AVI = 0
ACR = 0
AudioIF = 0
Sample = 0
```

## Ak je tento bitstream PASS

Potom je prakticky potvrdené:

```text
GCP packet samotný monitor nezahodí.
GCP builder + BCH/ECC + data-island formatter + guard/preamble timing sú aspoň pre GCP akceptované.
```

Potom pokračuj na **2C: AVI only**:

```systemverilog
.ENABLE_GCP_PACKET(0),
.ENABLE_AVI_PACKET(1)
```

Ak 2C zlyhá, vinník je veľmi pravdepodobne AVI InfoFrame obsah/checksum/BCH alebo konkrétna AVI konfigurácia.

## Ak je tento bitstream FAIL

Potom je problém už v GCP-only ceste:

```text
GCP payload/layout,
BCH/ECC nad GCP,
data-island encoding pri reálnom packete,
alebo fyzický sink netoleruje GCP v aktuálnom umiestnení.
```

Ale podľa predchádzajúceho 2A PASS už vieme, že samotné `ENABLE_DATA_ISLAND=1` bez paketov video nerozbije.

Do `TEST_MATRIX.md` zapíš tento test ako:

```text
2B | DATA=1 AUDIO=0 GCP=1 AVI=0 | Result: PASS/FAIL | Notes: <symptóm>
```

Rozumiem. Výsledok je teraz veľmi užitočný:

```text
#1  DATA=0 AUDIO=0              PASS
#2A DATA=1 AUDIO=0 GCP=0 AVI=0  PASS
#2B DATA=1 AUDIO=0 GCP=1 AVI=0  FAIL
```

Tým sa problém výrazne zúžil: **zlyháva GCP-only cesta**.

## Čo to znamená

Keďže 2A prešiel, samotné `ENABLE_DATA_ISLAND=1` video nerozbíja. Problém nastane až vtedy, keď sa vloží prvý reálny HDMI packet — v tomto prípade **GCP**.

Najpravdepodobnejšie príčiny teraz sú:

```text
1. GCP packet payload/layout nie je správny.
2. BCH/ECC pre GCP sa na finálnom data islande nezhoduje s očakávaním.
3. Data island payload mapping je chybný pre packet s HB0=0x00/PB=0.
4. GCP sa posiela v čase, ktorý monitor neakceptuje.
5. Data island guard/preamble prejde v sim, ale reálny sink GCP aj tak odmietne kvôli obsahu.
```

Dôležité: teraz už **nerob 2C/2D**, kým nevyriešiš 2B alebo aspoň nepotvrdíš, že AVI-only sa správa inak. Ak chceš rýchlo porovnať, môžeš urobiť 2C, ale primárny bug je už GCP-only.

---

## Okamžitý ďalší test: GCP bez AVMUTE, all-zero payload

Skontroluj `gcp_packet_builder.sv`. Pre bezpečný GCP bring-up musí byť:

```text
HB0 = 0x00
HB1 = 0x00
HB2 = 0x00

PB0 = 0x00
PB1..PB27 = 0x00
```

Teda žiadny `Set_AVMUTE`, žiadny `Clear_AVMUTE`, žiadny color depth indication.

Ak máš `PB0` napríklad:

```text
Clear_AVMUTE = 1
```

niektoré sinky to môžu zle tolerovať, najmä ak je to posielané opakovane každý frame.

Pre debug urob najkonzervatívnejší GCP:

```systemverilog
assign hb_o[0] = 8'h00;
assign hb_o[1] = 8'h00;
assign hb_o[2] = 8'h00;

always_comb begin
  for (int i = 0; i < 28; i++)
    pb_o[i] = 8'h00;
end
```

A `valid_o = enable_i`.

Potom zopakuj 2B.

### Interpretácia

```text
2B PASS s all-zero GCP:
  pôvodný GCP payload mal problematický bit, pravdepodobne AVMUTE/Clear_AVMUTE/CD.

2B FAIL aj s all-zero GCP:
  problém nie je obsah PB0, ale GCP header/ECC/data island mapping/timing.
```

---

## Druhý test: neposielaj GCP každý frame

Ak GCP-only s all-zero payloadom stále zlyhá, skús poslať GCP iba raz po resete alebo raz za napríklad 60 frameov.

Pre debug v arbitri:

```systemverilog
logic [7:0] gcp_frame_div;

always_ff @(posedge clk_i) begin
  if (!rst_ni)
    gcp_frame_div <= 8'd0;
  else if (frame_start_i)
    gcp_frame_div <= gcp_frame_div + 1'b1;
end
```

a GCP povoľ len ak:

```systemverilog
valid_gcp_i && (gcp_frame_div == 8'd1)
```

alebo dočasne:

```systemverilog
valid_gcp_i && (gcp_frame_div[5:0] == 6'd0)
```

### Interpretácia

```text
Rare GCP PASS, every-frame GCP FAIL:
  problém je opakovanie/umiestnenie/sekvencia GCP.

Rare GCP FAIL:
  problém je samotný GCP data island.
```

---

## Tretí test: GCP packet cez „AVI packet type“ neodporúčam

Nerobil by som hack typu „GCP payload poslať ako AVI“ alebo meniť packet type náhodne. Teraz treba ostať disciplinovaný: GCP-only musí byť platný alebo úplne vypnutý.

---

## Čo skontrolovať v simulácii pre GCP-only

Doplň alebo over v `tb_di_2b` presne tieto hodnoty na úrovni formatter inputu:

```text
HB = 00 00 00
PB[0..27] = 00
```

Potom očakávané ECC:

```text
Header BCH pre 00 00 00 = 0x0E
Subpacket BCH pre all-zero subpacket = 0xF5
```

Toto už zrejme máš v `tb_hdmi_bch_ecc`, ale pre GCP-only core test chcem vidieť, že sa tieto hodnoty skutočne dostanú do `data_island_formatter`.

Čiže v `tb_di_2b` over:

```text
packet_hb[0] = 0x00
packet_hb[1] = 0x00
packet_hb[2] = 0x00
packet_pb[*] = 0x00
```

a potom finálne data island nibbles obsahujú header ECC `0x0E` a subpacket ECC `0xF5`.

---

## Veľmi podozrivý bod: GCP s HB0=0x00 a all-zero payload môže vyzerať ako „nulový packet“

GCP má packet type `0x00`, header `00 00 00`, payload často celý `00`. To znamená, že jeho data island je extrémne špecifický:

```text
veľa núl + ECC
```

Ak máš v niektorom mieste logiku typu:

```systemverilog
packet_valid = |hb || |pb;
```

alebo filter, ktorý vyhodnotí all-zero packet ako „žiadny packet“, môže to rozbiť handshaking alebo formatter start.

Skontroluj, či nikde nie je rozhodovanie podľa obsahu packetu. Packet musí byť platný podľa `valid_o`, nie podľa toho, či sú dáta nenulové.

Hľadaj:

```bash
grep -R "|.*hb\||.*pb\|packet.*zero\|any" rtl/hdmi
```

---

## Čo zapísať do TEST_MATRIX.md

Do 2B:

```text
FAIL — no signal / <presný symptóm>; GCP-only fails while 2A no-packet data island passes.
```

Aktuálny rozhodovací strom:

```text
2A PASS
2B FAIL
=> GCP-only path is the first failing case.
```

---

## Najbližší praktický patch

Ja by som teraz spravil minimálny debug patch:

### A. Do `gcp_packet_builder.sv` pridať debug parameter

```systemverilog
parameter bit FORCE_ZERO_GCP = 1
```

alebo rovno dočasne natvrdo all-zero GCP.

### B. Do `tb_di_2b` pridať assert, že GCP vstup je presne:

```text
HB = 00 00 00
PB = all zero
```

### C. Do `tb_di_2b` pridať výpis prvého GCP data islandu:

```text
cy, payload_idx, ch0_nibble, ch1_nibble, ch2_nibble
```

### D. Zopakovať HW 2B.

---

## Krátky záver

Teraz nehľadaj v audio ani AVI. Výsledky hovoria:

```text
DATA island bez packetov: OK
GCP-only packet: FAIL
```

Najbližší cieľ je potvrdiť, či zlyháva:

```text
GCP obsah / AVMUTE / CD
```

alebo

```text
GCP ako all-zero packet cez formatter/BCH/TERC4/data island cestu.
```
