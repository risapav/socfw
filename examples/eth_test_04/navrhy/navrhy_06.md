Porovnal som tieto dva podobné RX moduly:

```text id="0u0jdb"
1. eth_rx_mac.sv          — tvoj clean RX MAC
2. taxi_axis_gmii_rx.sv   — referenčný GMII->AXIS RX modul od taxi/Alex Forencich
```

Tvoj modul má ambicióznejší cieľ: stripnúť preambulu, SFD, Ethernet header aj FCS a von posielať iba payload + metadata. Referenčný `taxi_axis_gmii_rx` je skôr klasický GMII receiver: rieši preambulu/SFD, oneskorenie kvôli FCS, CRC/FCS validáciu, štatistiky, ale nerobí MAC filtering ani payload-only metadata API.

---

# Hlavný rozdiel v architektúre

## Tvoj `eth_rx_mac.sv`

Cieľ:

```text id="qmxxl4"
GMII RX
  -> strip preamble/SFD
  -> parse DST/SRC/EtherType
  -> MAC filter
  -> strip header
  -> strip FCS
  -> payload-only AXI stream
  -> metadata: dst, src, eth_type, fcs_ok
```

Výstup je:

```text id="7ln92j"
payload-only stream
m_meta_* sideband
```

To je presne smer, ktorý chceš pre clean MAC loopback.

---

## `taxi_axis_gmii_rx.sv`

Cieľ:

```text id="zmkuun"
GMII RX
  -> detect preamble/SFD
  -> pipeline data
  -> compute CRC
  -> mark frame good/bad
  -> AXI stream frame
```

Výstup je klasický AXI frame stream cez `taxi_axis_if.src`, nie oddelený payload + metadata. Modul má aj PTP timestamp, MII/GMII prepínanie, VLAN štatistiku, fragment/jabber/oversize štatistiky a `cfg_rx_enable`.

---

# 1. SFD/preamble spracovanie

Toto bol problém, ktorý sme už riešili.

Tvoj modul teraz v `ST_IDLE` vie akceptovať priamy `D5`:

```systemverilog id="d9patr"
if (rxdv_q) begin
  if (rxd_q == 8'hD5) begin
    state_q <= ST_HEADER;
    ...
  end else begin
    state_q <= ST_PREAMBLE;
  end
end
```

To je správne pre RTL8211EG/GMII, kde `RXDV` často začne až na SFD byte `0xD5`.

Referenčný taxi modul tiež vie zachytiť SFD priamo:

```systemverilog id="xyxtfa"
else if (gmii_rxd_d0_reg == ETH_SFD) begin
  // start
  ...
end
```

a má navyše `STATE_PIPE`, kde nechá naplniť oneskorovaciu pipeline.

Verdikt:

```text id="hak8i1"
SFD problém máš už v princípe opravený.
V tomto bode by som nehľadal hlavnú príčinu 0/10 echo, pokiaľ je táto verzia naozaj v naprogramovanom SOF.
```

---

# 2. CRC/FCS stratégia

## Taxi modul

Taxi používa klasický Ethernet residue check:

```systemverilog id="ebudbz"
wire crc_valid = crc_state == ~32'h2144df1c;
```

To znamená, že CRC počíta cez celý frame vrátane prijatého FCS a na konci porovnáva známy reziduálny stav.

Výhoda:

```text id="dg3ovr"
nemusí skladať fcs_rx osobitne
dobré na overenie, či CRC pipeline a byte order sedia
```

---

## Tvoj modul

Tvoj modul používa 5-byte shift window:

```systemverilog id="x2wp90"
win_q[0] = newest
win_q[4] = oldest
```

a na konci porovnáva prijaté FCS s dopočítaným CRC:

```systemverilog id="efkjnk"
fcs_rx_w = {win_q[0], win_q[1], win_q[2], win_q[3]};
fcs_ok_w = (fcs_rx_w == ~crc_next_w);
```

Komentár hovorí, že `win_q[4]` je posledný payload byte a `win_q[0..3]` sú posledné štyri FCS bajty.

Táto metóda je tiež správna, ale je citlivejšia na off-by-one chybu.

Verdikt:

```text id="pqc9ze"
Obe CRC stratégie sú legitímne.
Pre debug by som dočasne doplnil aj taxi-style residue check ako paralelný diagnostický bit.
```

Napríklad:

```systemverilog id="cwv3un"
logic [31:0] crc_with_fcs_q;
logic [31:0] crc_with_fcs_next_w;
logic        fcs_residue_ok_w;

eth_crc32_8 u_crc_residue (
  .data_i (rxd_q),
  .crc_i  (crc_with_fcs_q),
  .crc_o  (crc_with_fcs_next_w)
);

assign fcs_residue_ok_w = (crc_with_fcs_q == ~32'h2144df1c);
```

Potom vieš porovnať:

```text id="oc4m5r"
direct FCS compare OK?
residue check OK?
```

Ak sa líšia, problém je v skladaní `fcs_rx_w` alebo v tom, ktorý posledný bajt ešte počítaš do CRC.

---

# 3. Veľký rozdiel: tvoj modul stripuje header, taxi nie

Taxi modul primárne streamuje Ethernet frame po SFD pipeline. Nerobí:

```text id="k5xorj"
LOCAL_MAC filtering
payload-only výstup
oddelené dst/src/eth_type metadata
```

Tvoj modul toto robí.

Pre clean echo je tvoja architektúra správnejšia, ale je aj náchylnejšia na stratu synchronizácie medzi:

```text id="4yxatb"
payload FIFO
metadata FIFO
echo_app
TX MAC
```

Pri `0/10 no echo` je preto dôležité zistiť, či:

```text id="pnhx5e"
RX payload vôbec vzniká,
RX metadata vôbec vznikajú,
m_meta_fcs_ok je 1,
echo_app prečíta payload,
TX dostane tx_meta.
```

---

# 4. Chýba ti reálne použitie `MAX_FRAME_LEN`

V tvojom module máš parameter:

```systemverilog id="c5p24q"
parameter int MAX_FRAME_LEN = 1518
```

ale v kóde sa nepoužíva na počítanie dĺžky frame.

Taxi modul má na toto samostatnú logiku:

```systemverilog id="3s7ktm"
frame_len_reg
frame_len_lim_reg
frame_len_lim_check_reg
cfg_rx_max_pkt_len
stat_rx_err_oversize
```

a vie označiť oversize/jabber/fragment.

Tvoj modul aktuálne kontroluje prakticky iba:

```text id="qlpbcc"
či po headeri prišlo aspoň 5 bajtov do window
FCS OK
RXER
MAC match
```

Ale nekontroluje:

```text id="3fjsb3"
min frame length 64B vrátane FCS
max frame length 1518B vrátane FCS
payload length
oversize
runt frame podľa Ethernet pravidiel
```

Odporúčam doplniť:

```systemverilog id="r2gdae"
logic [15:0] frame_len_q;
logic        too_short_w;
logic        too_long_w;
```

Počítať od prvého byte po SFD, teda od DST MAC po posledný FCS byte:

```systemverilog id="tqz1sh"
if (state_q == ST_HEADER || state_q == ST_PAYLOAD) begin
  if (rxdv_q && frame_len_q != 16'hffff) begin
    frame_len_q <= frame_len_q + 16'd1;
  end
end
```

Na konci:

```systemverilog id="4797bz"
too_short_w = (frame_len_q < 16'd64);
too_long_w  = (frame_len_q > MAX_FRAME_LEN[15:0]);
```

A do meta:

```systemverilog id="h7ad5o"
meta_fcs_ok_q <= fcs_ok_w &&
                 !rx_er_acc_q &&
                 mac_match_q &&
                 !too_short_w &&
                 !too_long_w;
```

---

# 5. `m_meta_fcs_ok` nie je len FCS OK

Tvoj výstup sa volá:

```systemverilog id="i4m4nj"
m_meta_fcs_ok
```

ale doň dávaš:

```systemverilog id="t9wesu"
meta_fcs_ok_q <= fcs_ok_w && !rx_er_acc_q && mac_match_q;
```

Čiže to nie je iba FCS, ale skôr:

```text id="xae9th"
frame_accept_ok = fcs_ok && no_rx_error && mac_match
```

To je logicky v poriadku, ale názov je zavádzajúci.

Odporúčam zmeniť API:

```systemverilog id="u8qz87"
output logic m_meta_fcs_ok,
output logic m_meta_mac_ok,
output logic m_meta_frame_ok,
```

alebo aspoň:

```systemverilog id="b5x1wc"
m_meta_fcs_ok      = čisté FCS
m_meta_accept_ok   = FCS && MAC && length && !RXER
```

Lebo pri debugovaní potrebuješ vedieť, či frame padol na:

```text id="kgckd4"
FCS
MAC adrese
RXER
dĺžke
overflowe
```

Teraz sa všetko zlieva do jedného bitu.

---

# 6. `axis_user_q` nezahŕňa MAC reject

Na konci frame nastavuješ:

```systemverilog id="yn64cr"
axis_user_q <= !(fcs_ok_w && !rx_er_acc_q);
```

Ale metadata robia:

```systemverilog id="pjwzus"
meta_fcs_ok_q <= fcs_ok_w && !rx_er_acc_q && mac_match_q;
```

To znamená:

```text id="bbdv5y"
ak FCS je OK, ale MAC nesedí:
  payload stream má tuser=0
  metadata má fcs_ok/accept=0
```

Ak echo_app dôveruje iba meta, je to OK. Ale diagnosticky je to nejednotné.

Odporúčanie:

```systemverilog id="dx9ax3"
axis_user_q <= !(fcs_ok_w && !rx_er_acc_q && mac_match_q);
```

alebo lepšie oddeliť:

```text id="62esne"
tuser = fyzická/frame chyba
meta_accept_ok = rozhodnutie filtra
```

Len to treba jasne dodržať v echo_app.

---

# 7. Riziko: metadata sa môžu stratiť, payload už odišiel

Tvoj modul pri konci frame robí:

```systemverilog id="62acmg"
if (!meta_valid_q || m_meta_ready) begin
  meta_valid_q <= 1'b1;
  ...
end
```

Ak `meta_valid_q == 1` a `m_meta_ready == 0`, nová metadata položka sa nezapíše. Payload ale už mohol ísť do payload FIFO.

To je nebezpečné:

```text id="pay10a"
payload FIFO obsahuje frame,
ale meta FIFO nemá zodpovedajúci záznam
echo_app potom stratí synchronizáciu
```

Taxi tento problém nemá, lebo nemá oddelené payload/meta FIFO. Stream má `tlast/tuser` priamo v jednej ceste.

Pre tvoj návrh treba pridať:

```systemverilog id="cchjgw"
logic meta_overflow_q;
```

a pri konci frame:

```systemverilog id="oamxix"
if (!meta_valid_q || m_meta_ready) begin
  meta_valid_q <= 1'b1;
  ...
end else begin
  meta_overflow_q <= 1'b1;
  rx_drop_q <= rx_drop_q + 16'd1;
end
```

Ešte lepšie: `eth_rx_mac` by nemal držať iba jeden meta register, ale mal by mať malé meta FIFO alebo jasný `stat_meta_overflow`.

---

# 8. `pkt_mcast_q` je zatiaľ mŕtvy signál

V tvojom module sa nastavuje:

```systemverilog id="l6jy6k"
pkt_mcast_q <= rxd_q[0];
```

ale nepoužíva sa vo výslednom MAC match.

Taxi modul multicast/broadcast používa aspoň pre status:

```systemverilog id="0gzvyc"
stat_rx_pkt_ucast
stat_rx_pkt_mcast
stat_rx_pkt_bcast
```

Odporúčam buď:

```text id="vojgvh"
1. odstrániť pkt_mcast_q, ak ho teraz nepotrebuješ,
```

alebo pridať parameter:

```systemverilog id="klco7l"
parameter bit ACCEPT_MULTICAST = 1'b0
```

a použiť:

```systemverilog id="tn4lt0"
mac_match_q <= (dst_mac_q == LOCAL_MAC) ||
               (ACCEPT_BROADCAST && pkt_bcast_q) ||
               (ACCEPT_MULTICAST && pkt_mcast_q);
```

---

# 9. Tvoj modul má payload-only kontrakt, ale nemá payload length

Pre TX MAC budeš potrebovať:

```text id="k8wzv5"
payload_len
```

Najmä kvôli:

```text id="7lj6kd"
paddingu na minimum 46 B,
diagnostike,
kontrole, či payload FIFO obsahuje presne očakávaný počet bajtov.
```

Taxi modul reportuje `stat_rx_pkt_len`.

Tvoj modul zatiaľ posiela iba:

```systemverilog id="gxcx9h"
m_meta_dst_mac
m_meta_src_mac
m_meta_eth_type
m_meta_fcs_ok
```

Odporúčam doplniť:

```systemverilog id="57ax9l"
output logic [15:0] m_meta_frame_len,
output logic [15:0] m_meta_payload_len
```

Pre non-VLAN Ethernet II:

```text id="e8ix6e"
frame_len = DST+SRC+TYPE+PAYLOAD+FCS
payload_len = frame_len - 14 - 4
```

Pri min frame bude payload obsahovať aj padding, ak nejdeš vyššie do IP/UDP vrstvy. Pre EtherType `0x9000` test je to v poriadku.

---

# 10. Dôležité porovnanie CRC pipeline

Taxi počíta CRC z `gmii_rxd_d0_reg`:

```systemverilog id="knzefr"
.data_in(gmii_rxd_d0_reg)
.state_in(crc_state_reg)
```

a výstup posúva cez `gmii_rxd_d4_reg`.

Tvoj modul počíta:

```systemverilog id="o02eaw"
ST_HEADER:  crc_data_w = rxd_q;
ST_PAYLOAD: crc_data_w = win_q[4];
```

To je správna myšlienka pre stripping FCS, ale odporúčam pridať explicitné debug signály:

```systemverilog id="g3avj1"
output logic [31:0] dbg_fcs_rx,
output logic [31:0] dbg_fcs_calc,
output logic        dbg_fcs_ok,
output logic [15:0] dbg_frame_len,
output logic [15:0] dbg_payload_len
```

alebo aspoň do status FIFO. Bez toho budeš pri `no echo` stále hádať, či padáš na CRC, MAC alebo meta FIFO.

---

# 11. Najväčší praktický rozdiel pre debug

Taxi modul má veľa jednocyklických statusov:

```text id="3zk0za"
stat_rx_pkt_good
stat_rx_pkt_bad
stat_rx_err_bad_fcs
stat_rx_err_framing
stat_rx_err_preamble
stat_rx_err_oversize
stat_rx_pkt_ucast/mcast/bcast
```

Tvoj modul má iba:

```text id="x9bgco"
stat_overflow
stat_rx_frames
stat_rx_drop
```

Pre HW bring-up je to málo.

Minimálne by som doplnil:

```systemverilog id="txmc2f"
output logic stat_sfd_seen,
output logic stat_hdr_done,
output logic stat_mac_match,
output logic stat_fcs_ok,
output logic stat_frame_good,
output logic stat_frame_bad_fcs,
output logic stat_frame_bad_mac,
output logic stat_frame_runt,
output logic stat_frame_oversize,
output logic stat_meta_overflow
```

Alebo ako counters:

```systemverilog id="nlyfeq"
stat_rx_good
stat_rx_bad_fcs
stat_rx_bad_mac
stat_rx_runt
stat_rx_oversize
stat_rx_er
```

---

# 12. Najpravdepodobnejšia príčina tvojho aktuálneho `0/10 no echo`

Po tomto porovnaní by som už nevinil SFD ako prvé, ak máš aktuálny súbor naozaj zapracovaný. Pravdepodobnejšie sú teraz tieto veci:

## Kandidát 1 — frame padá na `m_meta_fcs_ok`

Keďže `m_meta_fcs_ok` obsahuje aj MAC match:

```systemverilog id="tjkkdm"
meta_fcs_ok_q <= fcs_ok_w && !rx_er_acc_q && mac_match_q;
```

stačí, aby bol zlý CRC compare alebo MAC match a echo_app frame zahodí.

Preto potrebuješ rozbiť jeden bit na viac bitov:

```text id="5g3zdb"
fcs_ok
mac_match
rx_er_seen
too_short
too_long
accept_ok
```

---

## Kandidát 2 — metadata sa nevložia do meta FIFO

Ak `m_meta_ready` nie je v správnom stave alebo `meta_valid_q` ostáva držané, payload môže ísť ďalej, ale meta sa stratí.

Debug bit:

```text id="dwafhw"
m_meta_valid
m_meta_ready
meta_overflow
```

je teraz kritický.

---

## Kandidát 3 — echo_app čaká iné poradie payload/meta

Tvoj RX je cut-through: payload bajty môžu byť vo FIFO skôr než meta, meta vznikne až na konci frame.

Echo app musí robiť:

```text id="dk6gl5"
najprv čakať na meta,
ak accept_ok, potom prečítať presne payload_len bajtov z payload FIFO,
ak nie accept_ok, payload zahodiť.
```

Ak echo_app začne čítať payload skôr alebo nevie payload_len, môže sa rozísť.

---

# Odporúčaná úprava tvojho `eth_rx_mac`

## Krátkodobý patch pre diagnostiku

Doplň výstupy:

```systemverilog id="ycm43k"
output logic        m_meta_fcs_raw_ok,
output logic        m_meta_mac_ok,
output logic        m_meta_frame_ok,
output logic [15:0] m_meta_frame_len,
output logic [15:0] m_meta_payload_len,
output logic [31:0] dbg_fcs_rx,
output logic [31:0] dbg_fcs_calc
```

A zmeň význam:

```systemverilog id="x7hvz2"
m_meta_fcs_ok    = fcs_ok_w;
m_meta_mac_ok    = mac_match_q;
m_meta_frame_ok  = fcs_ok_w &&
                   !rx_er_acc_q &&
                   mac_match_q &&
                   !too_short_w &&
                   !too_long_w;
```

Echo app nech používa `m_meta_frame_ok`.

---

## Strednodobý patch

Doplň `frame_len_q` a `payload_len_q`.

```systemverilog id="6tkb6a"
frame_len_q:
  počíta DST..FCS

payload_len:
  frame_len - 18
```

Pre Ethernet II clean loopback bude TX potrebovať práve `payload_len`.

---

## Dlhodobá architektúra

Použi taxi filozofiu pre robustný RX frontend:

```text id="rcw44a"
GMII pipeline d0..d4
preamble/SFD detector
CRC residue debug
frame length/status
```

a na to navrstvi svoj clean filter:

```text id="zwo2ld"
header strip
MAC filter
FCS strip
payload-only output
metadata FIFO
```

Teda nekopírovať taxi celý, ale prevziať z neho:

```text id="j76u1b"
5-stage RX pipeline
residue CRC check
frame length limit
detailné status bity
```

---

## Záver

Tvoj `eth_rx_mac.sv` je architektonicky správnym smerom pre clean MAC RX, ale oproti referenčnému `taxi_axis_gmii_rx` mu chýbajú tri veci, ktoré sú teraz kritické pre HW debug:

```text id="lgxgts"
1. detailné status bity: fcs_ok, mac_ok, frame_len, runt, oversize, rx_er,
2. bezpečné metadata flow: meta_overflow / meta FIFO,
3. dĺžka frame/payload a MAX_FRAME_LEN kontrola.
```

Najdôležitejšia okamžitá zmena:

```text id="pdyrg0"
nepoužívaj jeden bit m_meta_fcs_ok ako „všetko OK“.
Rozdeľ ho na fcs_ok, mac_ok a frame_ok.
```

Potom pri ďalšom `make loopback-test` hneď uvidíme, či padáš na CRC, MAC adrese, dĺžke alebo meta/echo handshake.
