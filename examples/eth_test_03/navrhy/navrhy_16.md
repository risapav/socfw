Aktuálny stav je už veľmi dobre lokalizovaný. Ako ďalší krok by som nerobil ďalší veľký refaktor ani nešiel naslepo do TX/UDP. Teraz treba **izolovať RX L2 problém v hardvéri** a súčasne **dotiahnuť timing**.

## Expertný záver

Podľa statusu je najdôležitejšie toto:

```text
LED2 bliká  -> PHY dáva RXDV, link a RX fyzická aktivita existujú
LED3 blikla -> gmii_rx_mac dokončil frame, preambula/SFD je OK
LED4 nie    -> eth_header_parser zahadzuje frame na MAC porovnaní
promiscuous L2 -> LED4 blikne
promiscuous L2+L3 -> LED5 blikne
```

Tým je problém veľmi úzko lokalizovaný:

```text
gmii_rx_mac výstup existuje,
ale eth_header_parser vyhodnotí dst_mac != LOCAL_MAC
```

To znamená, že momentálne nemá zmysel riešiť FCS, UDP checksum, TX MAC ani echo app. Rámec sa stráca v L2.

---

# 1. Najväčší konkrétny bug v `eth_header_parser`

V aktuálnom `eth_header_parser.sv` je stále jemný, ale zásadný problém:

```systemverilog
4'd13: begin
  header_reg.ethertype[7:0] <= s_axis_tdata;
  state_q <= drop_decision_w ? ST_DROP : ST_PAYLOAD;
end
```

`drop_decision_w` je vypočítaný z registrovaného:

```systemverilog
header_reg.dst_mac
```

To by pri byte 13 malo byť už v poriadku, lebo `dst_mac` je z bajtov 0 až 5. Ale v hardvéri by som túto konštrukciu aj tak odstránil, pretože rozhoduješ stav v tom istom `always_ff`, kde sa ešte zbiera hlavička, a používaš packed struct member comparison.

V simulácii to prechádza, ale HW presne na tomto porovnaní zlyháva. Preto by som to prepisal na jednoduchý, explicitný, „Quartus-friendly“ parser bez packed struct porovnania.

## Odporúčaná oprava

V parseri nepoužívaj `eth_hdr_t header_reg` na rozhodovanie. Použi explicitné registre:

```systemverilog
logic [47:0] dst_mac_q;
logic [47:0] src_mac_q;
logic [15:0] ethertype_q;
```

A pri každom bajte skladaj hodnotu explicitne.

Pri byte 5 si už vieš vytvoriť kompletný destination MAC cez `dst_mac_next_w`:

```systemverilog
logic [47:0] dst_mac_next_w;

assign dst_mac_next_w = {dst_mac_q[39:0], s_axis_tdata};
```

A rozhodnutie si môžeš zaregistrovať hneď po byte 5:

```systemverilog
if (byte_cnt == 4'd5) begin
  dst_mac_q <= dst_mac_next_w;

  mac_accept_q <= promiscuous_i ||
                  (dst_mac_next_w == local_mac_i) ||
                  (accept_broadcast_i &&
                   (dst_mac_next_w == ETH_BROADCAST_MAC));
end
```

Potom pri byte 13 rozhodneš iba podľa `mac_accept_q`:

```systemverilog
if (byte_cnt == 4'd13) begin
  ethertype_q <= {ethertype_q[7:0], s_axis_tdata};
  state_q <= mac_accept_q ? ST_PAYLOAD : ST_DROP;
end
```

Tým sa odstráni:

```text
packed struct member comparison
48-bit compare v neskorom bode FSM
závislosť drop_decision_w od header_reg počas header FSM
```

A hlavne získaš debugovateľný signál:

```systemverilog
mac_accept_q
```

ktorý môžeš dať na LED.

---

# 2. Pridaj L2 debug register/signály

Teraz vieš, že L2 zlyháva. Potrebuješ zistiť, **čo presne parser vidí ako dst_mac**.

Dočasne do `eth_header_parser` pridaj debug výstupy:

```systemverilog
output logic [47:0] dbg_dst_mac_o,
output logic        dbg_mac_match_o,
output logic        dbg_broadcast_o,
output logic        dbg_hdr_done_o
```

A v top-e ich pripoj aspoň na LED v niekoľkých debug buildoch.

Pretože máš len 6 LED, sprav **nibble debug režim**:

```text
zachyť dbg_dst_mac_o pri prvom frame
zobrazuj jeho nibbly postupne na LED[3:0]
LED4 = dbg_mac_match
LED5 = dbg_hdr_done
```

Ak nemáš prepínače, môžeš nibbly rotovať časovačom:

```text
každých ~0.5 s ukáž ďalší nibble z 12 nibbles MAC adresy
```

Očakávaš:

```text
0 0 0 A 3 5 0 1 F E C 0
```

Ak uvidíš niečo iné, problém nie je porovnanie, ale skutočné bajty po RX MAC.

---

# 3. Pridaj špeciálny „MAC byte probe“ test build

Najrýchlejší HW diagnostický build by som spravil takto:

```text
LED0 = heartbeat
LED1 = phy reset done
LED2 = RXDV activity
LED3 = gmii_rx_mac frame_done
LED4 = eth parser header byte counter reached 13
LED5 = mac_accept_q
```

Interpretácia:

```text
LED3 bliká, LED4 nie:
  L2 parser nedostane celý frame alebo tlast/valid rozbije header.

LED4 bliká, LED5 nie:
  L2 parser vidí celý header, ale MAC nesedí.

LED4 bliká, LED5 bliká:
  MAC sedí, problém je ďalej, ale status tvrdí opak.
```

Toto je presnejšie než aktuálne `eth_hdr_valid`, lebo rozlíši:

```text
parser nedokončil header
vs.
parser dokončil header, ale MAC porovnanie failuje
```

---

# 4. Pozor na význam `hdr_valid_o`

V aktuálnom parseri:

```systemverilog
assign hdr_valid_o = (state_q == ST_PAYLOAD);
```

To znamená, že `hdr_valid_o` nie je jednocykový „header accepted pulse“, ale level signál počas payloadu.

Pre LED je to použiteľné, ale pre diagnostiku nie ideálne. Odporúčam pridať samostatný pulz:

```systemverilog
output logic hdr_accept_pulse_o;
output logic hdr_drop_pulse_o;
```

A generovať:

```systemverilog
if (byte_cnt == 4'd13 && s_axis_tvalid) begin
  hdr_accept_pulse_o <= mac_accept_q;
  hdr_drop_pulse_o   <= !mac_accept_q;
end
```

Potom LED activity stretcher bude ukazovať presne prijaté/dropnuté hlavičky.

---

# 5. FCS nie je príčina aktuálneho L2 dropu

FCS je až na konci rámca. L2 parser sa rozhoduje na prvých 14 bajtoch:

```text
dst_mac
src_mac
ethertype
```

Keďže LED4 v normálnom L2 filtri nebliká, ale v promiscuous áno, problém vzniká ešte predtým, než FCS vôbec príde do hry.

Takže FCS teraz nerieš. V tejto fáze by som FCS nepoužíval ako hypotézu.

---

# 6. Preambula už pravdepodobne nie je problém

Debug build ukázal:

```text
LED3 = gmii_rx_mac frame_done blikla
```

To znamená, že:

```text
EXPECT_PREAMBLE=1 je pravdepodobne správne
gmii_rx_mac deteguje SFD
frame skončí a vygeneruje tlast
```

Takže preambula už nie je primárny kandidát. Môžeš ponechať:

```yaml
EXPECT_PREAMBLE: true
```

---

# 7. RXD bit order stále treba overiť, ale už je menej pravdepodobný

Ak by bol RXD bit order úplne otočený, `gmii_rx_mac` by pravdepodobne nevidel správne `0x55` a `0xD5`. Keďže `frame_done` bliká, bit order aspoň pre preambulu/SFD sedí.

Ale stále môže existovať problém typu:

```text
nie všetky RXD bity sú správne namapované
niektorý dátový bit je zlý
```

To by vysvetľovalo:

```text
preambula/SFD sedí, ale destination MAC je poškodený
```

Preto je `dbg_dst_mac_o` dôležitejší než ďalšie teoretizovanie.

---

# 8. Timing stále musí byť opravený

Aktuálny STA hovorí:

```text
ETH_RXC slow 85°C slack = -0.441 ns
TNS = -14.768
```

To je stále fail. Je menší než predtým, ale nie je uzavretý.

Najhoršia cesta:

```text
udp_echo_app.rx_meta_q.payload_len[*]
  -> async_fifo.u_meta_fifo.mem
```

To je už za L2/L3 prijatím, takže to pravdepodobne nevysvetľuje **L2 MAC comparison fail**. Ale pre finálny HW build to musí prejsť.

Odporúčanie:

```text
P0 pre aktuálnu diagnostiku: L2 MAC debug
P1 pre finálny build: ETH_RXC timing closure
```

Čiže najprv zisti, čo reálne vidí L2 parser. Ale pred ďalším „serióznym“ UDP echo testom uzavri timing na `>= 0`.

---

# 9. Ako opraviť aktuálny timing fail

Kritická cesta ide do `u_meta_fifo.mem`. Teraz zapisuješ metadata takto:

```systemverilog
assign meta_wr_valid = txb_tvalid && pkt_wr_ready && txb_tlast;

async_fifo #(.DATA_WIDTH(96)) u_meta_fifo (
  .wr_data_i ({meta_latch_dst_q, meta_latch_src_q}),
  .wr_valid_i(meta_wr_valid),
  ...
);
```

Najhoršia cesta začína z `udp_echo_app.rx_meta_q.payload_len`, čo znamená, že pravdepodobne časť `tx_meta` alebo latche stále ovplyvňujú write data do meta FIFO v príliš dlhom reťazci.

Sprav register tesne pred FIFO:

```systemverilog
logic [95:0] meta_wr_data_q;
logic        meta_wr_valid_q;

always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    meta_wr_data_q  <= '0;
    meta_wr_valid_q <= 1'b0;
  end else begin
    meta_wr_valid_q <= 1'b0;

    if (txb_tvalid && pkt_wr_ready && txb_tlast && meta_wr_ready) begin
      meta_wr_data_q  <= {meta_latch_dst_q, meta_latch_src_q};
      meta_wr_valid_q <= 1'b1;
    end
  end
end
```

Potom FIFO:

```systemverilog
.wr_data_i  (meta_wr_data_q),
.wr_valid_i (meta_wr_valid_q)
```

Ale musíš si dať pozor na handshake: ak `meta_wr_ready=0`, nesmieš commitnúť packet do packet FIFO bez metadata. Pre robustné riešenie urob malý `TX_COMMIT` stav alebo zabezpeč, že meta FIFO má rezervu pred začiatkom packetu.

---

# 10. Odporúčaný ďalší postup

## Krok A — opraviť L2 parser na explicitný MAC compare

Prepíš `eth_header_parser` takto:

```text
nepoužívať packed struct na drop decision
dst_mac_q/src_mac_q/ethertype_q ako samostatné registre
mac_accept_q zaregistrovať po byte 5
pri byte 13 rozhodnúť podľa mac_accept_q
pridať hdr_accept_pulse/hdr_drop_pulse
```

Toto je podľa mňa najdôležitejšia zmena.

---

## Krok B — pridať L2 debug signály

Pridaj:

```text
dbg_dst_mac_o
dbg_mac_accept_o
dbg_hdr_done_o
dbg_hdr_drop_o
```

A dočasný LED debug build.

Cieľ: zistiť, či hardvér vidí:

```text
00:0A:35:01:FE:C0
```

alebo nie.

---

## Krok C — urobiť „first frame capture“ do debug registra

Ak máš možnosť použiť nejaký jednoduchý register export neskôr cez UART/XFCP, bolo by to ideálne. Ak nie, LED nibble rotácia stačí.

Minimálne zachyť:

```text
first_dst_mac
first_src_mac
first_ethertype
```

To je presne to, čo teraz potrebuješ.

---

## Krok D — spustiť HW v troch režimoch

1. **L2 strict nový parser**

   ```text
   promiscuous_i = 0
   očakávanie: LED4 alebo udp_accept začne fungovať
   ```

2. **L2 debug**

   ```text
   zobraz dst_mac alebo mac_accept
   ```

3. **Full promiscuous**

   ```text
   L2 promiscuous = 1
   L4 promiscuous = 1
   LED3=udp_accept, LED4=tx_busy, LED5=tx_en
   ```

Ak full promiscuous stále nedá TX, problém je za L2.

---

# 11. Nezabudni, že L2 promiscuous je len diagnostika

Ak s promiscuous L2/L3/L4 dostaneš TX odpoveď, neznamená to, že stack je správny. Znamená to len:

```text
RX/TX fyzická cesta funguje,
filtre sú problém.
```

Potom sa vráť na strict filtre a oprav ich podľa debugovaných hodnôt.

---

# 12. Čo by som nerobil hneď

Teraz by som nerobil:

```text
FCS strip refaktor
MDIO master
ARP responder
UDP checksum
veľké presúvanie TX buildera
```

Tieto veci sú menej naliehavé. Momentálne je najväčšia hodnota v zistení, **aký destination MAC reálne vidí FPGA po gmii_rx_mac**.

---

## Krátky akčný plán

Najbližší commit:

```text
1. Prepísať eth_header_parser na explicitné registre a mac_accept_q.
2. Pridať hdr_accept_pulse_o / hdr_drop_pulse_o.
3. Pridať dbg_dst_mac_o / dbg_mac_accept_o.
4. Upraviť tb_eth_header_parser, aby pokryl nový parser.
5. Pridať LED debug build:
   LED3 = hdr_done
   LED4 = mac_accept
   LED5 = hdr_drop
6. V HW overiť, či mac_accept blikne.
```

Potom:

```text
7. Ak mac_accept stále nie, zobraz dbg_dst_mac_o cez LED nibbly.
8. Ak dbg_dst_mac_o nie je 00:0A:35:01:FE:C0, rieš RXD bit/pin/data corruption.
9. Ak dbg_dst_mac_o je správny a mac_accept nie, rieš local_mac_i parameter/generovanie/top.
10. Po L2 oprave uzavri ETH_RXC timing na >= 0.
```

Môj odhad: najrýchlejšie ťa posunie **prepis `eth_header_parser` bez packed struct porovnania + debug zachytenie prvého dst_mac**. To priamo testuje jedinú vec, ktorá podľa LED a promiscuous testu skutočne zlyháva.
